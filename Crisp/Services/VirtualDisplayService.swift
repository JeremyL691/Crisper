import CoreGraphics
import Foundation
import os.log

// CGVirtualDisplay and CGVirtualDisplaySettings are ObjC objects without Sendable
// conformance, but we only use them sequentially (create on main -> pass to background
// for apply -> use result on main), so @unchecked Sendable is safe here.
extension CGVirtualDisplayDescriptor: @unchecked @retroactive Sendable {}
extension CGVirtualDisplay: @unchecked @retroactive Sendable {}
extension CGVirtualDisplaySettings: @unchecked @retroactive Sendable {}

extension SmartVirtualDisplayConfig {
    var asLegacy: VirtualDisplayService.VirtualDisplayConfig {
        var legacy = VirtualDisplayService.VirtualDisplayConfig(
            id: id,
            name: name,
            width: width,
            height: height,
            refreshRate: refreshRate,
            hiDPI: hiDPI,
            autoCreate: isEnabled
        )
        legacy.startsHiDPI = startsHiDPI
        return legacy
    }
}

/// Manages the single Smart Dummy virtual display engine driven by `SmartVirtualDisplayPolicy`,
/// combining `PowerAndTopologyMonitor` and `ClamshellGuardService` while preserving legacy
/// virtual display query/preset compatibility for existing Crisp subsystems.
@MainActor
final class VirtualDisplayService: ObservableObject, @unchecked Sendable {
    static let shared = VirtualDisplayService()

    private static let log = Logger(subsystem: "com.crisper.app", category: "smart-dummy")
    private static let smartConfigKey = "crisper.SmartVirtualDisplayConfig"

    private init() {
        let initialConfig = Self.sanitize(Self.loadSmartConfig())
        smartConfig = initialConfig
        configs = [initialConfig.asLegacy]
        liveInput = SmartVirtualDisplayInput(
            isOnACPower: PowerAndTopologyMonitor.readIsOnACPower(),
            isClamshellClosed: PowerAndTopologyMonitor.readIsClamshellClosed(),
            activePhysicalExternalCount: 0,
            activeBuiltinCount: 0
        )
    }

    // MARK: - Legacy Compatibility Config Model

    struct VirtualDisplayConfig: Codable, Identifiable, Equatable {
        let id: UUID
        var name: String
        var width: Int
        var height: Int
        var refreshRate: Double
        var hiDPI: Bool
        var autoCreate: Bool
        var startsHiDPI: Bool?

        var productID: UInt32 {
            let bytes = id.uuid
            return UInt32(bytes.0) << 24 | UInt32(bytes.1) << 16 | UInt32(bytes.2) << 8 | UInt32(bytes.3)
        }

        var serialNumber: UInt32 {
            let bytes = id.uuid
            return UInt32(bytes.4) << 24 | UInt32(bytes.5) << 16 | UInt32(bytes.6) << 8 | UInt32(bytes.7)
        }

        var displayUUID: String {
            CrispVirtualDisplayIdentity.uuid(productID: productID, serialNumber: serialNumber)
        }

        init(
            id: UUID = UUID(),
            name: String,
            width: Int,
            height: Int,
            refreshRate: Double = 60.0,
            hiDPI: Bool = true,
            autoCreate: Bool = true
        ) {
            self.id = id
            self.name = name
            self.width = width
            self.height = height
            self.refreshRate = refreshRate
            self.hiDPI = hiDPI
            self.autoCreate = autoCreate
        }
    }

    static let refreshRateOptions: [Double] = [50, 60, 75, 120, 144]

    /// Vendor ID stamped on every Crisper virtual display's descriptor, and the race-free
    /// signature filtered on: CGDisplayVendorNumber reports it the instant the display is online.
    static let crispVirtualVendorID = CrispVirtualDisplayIdentity.vendorID

    static func smartSummary(_ config: SmartVirtualDisplayConfig) -> String {
        let hiDPIActive = config.hiDPI && config.startsHiDPI
            && config.width.isMultiple(of: 2) && config.height.isMultiple(of: 2)
        if hiDPIActive {
            return "\(config.logicalWidth) × \(config.logicalHeight) HiDPI · \(RefreshRateFormat.label(config.refreshRate))"
        }
        return "\(config.width) × \(config.height) · \(RefreshRateFormat.label(config.refreshRate))"
    }

    static func summary(_ config: VirtualDisplayConfig) -> String {
        "\(config.width) × \(config.height) · \(RefreshRateFormat.label(config.refreshRate))"
            + (config.startsHiDPI == true ? " · HiDPI" : "")
    }

    // MARK: - Published Smart Dummy State

    @Published private(set) var smartConfig: SmartVirtualDisplayConfig
    @Published private(set) var phase: SmartVirtualDisplayPhase = .disabled
    @Published private(set) var liveInput: SmartVirtualDisplayInput
    @Published private(set) var isTransitioning: Bool = false
    @Published private(set) var lastError: String? = nil

    // Legacy compatibility state kept synchronized with smartConfig
    @Published var configs: [VirtualDisplayConfig] = []
    @Published private(set) var activeConfigIDs: Set<UUID> = []

    var isSmartDummyMounted: Bool { !activeConfigIDs.isEmpty }
    var isSmartDummyEnabled: Bool { smartConfig.isEnabled }

    private enum MountOutcome {
        case mounted
        case yielded
        case failed
    }

    // MARK: - Internal Engine Components

    private let clamshellGuard = ClamshellGuardService.shared
    private let monitor = PowerAndTopologyMonitor()
    private let vdisplayQueue = DispatchQueue(label: "com.crisper.app.vdisplay")

    /// Strong references to live CGVirtualDisplay objects; releasing an entry destroys it.
    private var activeDisplayObjects: [UUID: CGVirtualDisplay] = [:]
    /// Display IDs currently tearing down so WindowServer `.removeFlag` callbacks recognize them
    /// as our own virtual display instead of triggering a concurrent `DisplayHotplug` self-race.
    private var destroyingDisplayIDs: Set<CGDirectDisplayID> = []
    private var mountedAt: CFAbsoluteTime = 0
    private var mountGeneration: UInt64 = 0
    private var isDestroyingIntentionally = false
    private var monitoringStarted = false

    // Single @MainActor FIFO async critical section serializing all state-mutating transitions.
    private var isTransitionLocked = false
    private var transitionWaiters: [CheckedContinuation<Void, Never>] = []
    private var evaluationPumpRunning = false
    private var pendingEvaluationReason: String?
    private var scheduledEvaluationTask: Task<Void, Never>?
    private var settleTasks: [Task<Void, Never>] = []
    /// Held while PhysicalDisplayToggleService is disabling the last physical display after
    /// pre-mounting Smart Dummy, preventing an intermediate evaluation from yielding mid-transaction.
    private var lastPhysicalDisconnectHoldCount = 0

    private func withTransitionLock<T>(_ operation: () async -> T) async -> T {
        if isTransitionLocked {
            await withCheckedContinuation { continuation in
                transitionWaiters.append(continuation)
            }
        }
        isTransitionLocked = true
        defer {
            if !transitionWaiters.isEmpty {
                let next = transitionWaiters.removeFirst()
                next.resume()
            } else {
                isTransitionLocked = false
            }
        }
        return await operation()
    }

    // MARK: - Lifecycle

    func startMonitoring() {
        guard !monitoringStarted else { return }
        monitoringStarted = true

        clamshellGuard.onPowerWakePreSync = {
            KeepAwakeService.shared.syncForPowerWake(reason: "SystemPowerWake")
        }
        clamshellGuard.shouldPreArmClamshellOnACWake = { [weak self] in
            guard let self else { return false }
            return self.smartConfig.isEnabled
                && self.smartConfig.clamshellGuardEnabled
                && PowerAndTopologyMonitor.readIsOnACPower()
                && PowerAndTopologyMonitor.readIsClamshellClosed()
        }
        clamshellGuard.shouldPromoteHeadlessACWake = { [weak self] in
            guard let self else { return false }
            let decision = SmartVirtualDisplayPolicy.evaluate(
                config: self.smartConfig,
                input: self.sampleCurrentInput()
            )
            return decision.shouldHoldDisplaySleepAssertion
        }
        clamshellGuard.onSystemWake = { [weak self] in
            guard let self else { return }
            self.monitor.noteSystemWake()
            KeepAwakeService.shared.syncForPowerWake(reason: "SystemHasPoweredOn")
            self.evaluateNow(reason: "SystemPowerHasPoweredOn")
            self.scheduleEvaluation(reason: "SystemPowerHasPoweredOnFollowup", delayMs: 150)
        }
        clamshellGuard.start()

        monitor.start(handlers: .init(
            onFastHardwareEvent: { [weak self] in
                guard let self else { return }
                self.clamshellGuard.reinforceIfArmed()
            },
            onEvent: { [weak self] reason, immediate, followupDelayMs in
                guard let self else { return }
                if reason == "PowerSourceChange" {
                    KeepAwakeService.shared.syncForPowerSourceChange()
                }
                if immediate {
                    self.evaluateNow(reason: reason)
                }
                if let delayMs = followupDelayMs {
                    self.scheduleEvaluation(reason: "\(reason)Followup", delayMs: delayMs)
                }
            },
            isOwnVirtualDisplay: { [weak self] displayID in
                guard let self else { return false }
                return self.destroyingDisplayIDs.contains(displayID)
                    || self.activeDisplayObjects.values.contains { $0.displayID == displayID }
            }
        ), enableFallbackPolling: smartConfig.isEnabled)

        evaluateNow(reason: "Startup")
    }

    func shutdown() {
        scheduledEvaluationTask?.cancel()
        scheduledEvaluationTask = nil
        pendingEvaluationReason = nil
        cancelSettleTasks()
        monitor.stop()
        monitoringStarted = false

        // Destroy virtual display BEFORE releasing assertions on shutdown.
        destroyActiveVirtualDisplay(reason: "Shutdown")
        destroyingDisplayIDs.removeAll()
        clamshellGuard.shutdown()
        phase = .disabled
        isTransitioning = false
    }

    // MARK: - Smart Dummy Controls

    func evaluateNow(reason: String) {
        clamshellGuard.reinforceIfArmed()
        pendingEvaluationReason = reason
        guard !evaluationPumpRunning else { return }
        evaluationPumpRunning = true
        Task { @MainActor [weak self] in
            await self?.drainPendingEvaluations()
        }
    }

    private func drainPendingEvaluations() async {
        defer { evaluationPumpRunning = false }
        while let nextReason = pendingEvaluationReason {
            pendingEvaluationReason = nil
            await withTransitionLock {
                await self.evaluateLocked(reason: nextReason)
            }
        }
    }

    @discardableResult
    func setSmartDummyEnabled(_ enabled: Bool) async -> Bool {
        await withTransitionLock {
            self.smartConfig.isEnabled = enabled
            self.lastError = nil
            self.persistSmartConfig()
            await self.evaluateLocked(reason: enabled ? "UserEnabled" : "UserDisabled")
            return self.lastError == nil
        }
    }

    @discardableResult
    func updateSmartConfig(_ mutate: (inout SmartVirtualDisplayConfig) -> Void) async -> Bool {
        await withTransitionLock {
            let old = self.smartConfig
            var updated = self.smartConfig
            mutate(&updated)
            updated = Self.sanitize(updated)

            self.smartConfig = updated
            self.lastError = nil
            self.persistSmartConfig()

            let geometryChanged = old.width != updated.width
                || old.height != updated.height
                || old.hiDPI != updated.hiDPI
                || old.refreshRate != updated.refreshRate
                || old.name != updated.name

            if geometryChanged, let existingID = self.activeDisplayObjects[updated.id]?.displayID {
                self.isTransitioning = true
                self.destroyingDisplayIDs.insert(existingID)
                self.destroyActiveVirtualDisplay(reason: "ConfigChanged", keepDestroyingID: true)
                await self.waitForDisplayOffline(existingID)
                self.destroyingDisplayIDs.remove(existingID)
                self.isTransitioning = false
            } else if old.startsHiDPI != updated.startsHiDPI,
                      let existingID = self.activeDisplayObjects[updated.id]?.displayID {
                await self.ensureConfiguredMode(existingID, config: updated)
            }

            await self.evaluateLocked(reason: "ConfigUpdated")
            return self.lastError == nil
        }
    }

    /// Pre-mounts the Smart Dummy before `PhysicalDisplayToggleService` disables the last active
    /// physical display so the user can never hit a blackout state. When this returns `true`, the
    /// caller MUST pair it with `releaseLastPhysicalDisconnectHold()` once the disconnect completes.
    func mountBeforeLastPhysicalDisconnect() async -> Bool {
        await withTransitionLock {
            let input = self.sampleCurrentInput()
            self.liveInput = input
            guard self.smartConfig.isEnabled, input.isOnACPower else { return false }

            if let existing = self.activeDisplayObjects[self.smartConfig.id],
               CGDisplayIsOnline(existing.displayID) != 0 {
                self.lastPhysicalDisconnectHoldCount += 1
                return true
            }

            self.clamshellGuard.sync(
                disableClamshellSleep: self.smartConfig.clamshellGuardEnabled && input.isClamshellClosed,
                holdSystemSleep: self.smartConfig.clamshellGuardEnabled,
                holdDisplaySleep: self.smartConfig.clamshellGuardEnabled,
                forceTickle: true
            )

            let outcome = await self.mountSmartDummy(config: self.smartConfig, allowYieldDuringApply: false)
            var online = false
            if outcome == .mounted, let displayID = self.activeDisplayObjects[self.smartConfig.id]?.displayID {
                for _ in 0..<25 {
                    if CGDisplayIsOnline(displayID) != 0 {
                        online = true
                        break
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }

            if online {
                self.lastPhysicalDisconnectHoldCount += 1
                self.phase = .activeMounted
                return true
            }

            // Failure or timeout: clean up partial virtual display and reconcile assertions back
            // to the evaluated policy so no display-sleep assertion or 60s tickle timer leaks.
            self.destroyActiveVirtualDisplay(reason: "PreMountFailed")
            let refreshedInput = self.sampleCurrentInput()
            self.liveInput = refreshedInput
            let reconciled = SmartVirtualDisplayPolicy.evaluate(config: self.smartConfig, input: refreshedInput)
            self.phase = reconciled.phase
            self.clamshellGuard.apply(decision: reconciled, forceTickle: false)
            return false
        }
    }

    func releaseLastPhysicalDisconnectHold() {
        lastPhysicalDisconnectHoldCount = max(0, lastPhysicalDisconnectHoldCount - 1)
        if lastPhysicalDisconnectHoldCount == 0 {
            evaluateNow(reason: "LastPhysicalDisconnectComplete")
        }
    }

    // MARK: - Queries & Legacy Compatibility

    func isActive(_ configID: UUID) -> Bool {
        activeConfigIDs.contains(configID)
    }

    func presetUUID(of display: DisplayInfo) -> String {
        let id = display.displayID
        guard CGDisplayVendorNumber(id) == Self.crispVirtualVendorID,
              let config = configs.first(where: {
                  $0.productID == CGDisplayModelNumber(id) && $0.serialNumber == CGDisplaySerialNumber(id)
              }) else { return display.displayUUID }
        return config.displayUUID
    }

    func isVirtualDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        if CGDisplayVendorNumber(displayID) == Self.crispVirtualVendorID { return true }
        if destroyingDisplayIDs.contains(displayID) { return true }
        return activeDisplayObjects.values.contains { $0.displayID == displayID }
    }

    func configuredRefreshRate(for displayID: CGDirectDisplayID) -> Double? {
        guard CGDisplayVendorNumber(displayID) == Self.crispVirtualVendorID else { return nil }
        let product = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)
        return configs.first(where: { $0.productID == product && $0.serialNumber == serial })?.refreshRate
    }

    func applyConfiguredRefreshRate(for displayID: CGDirectDisplayID) async {
        guard let rate = configuredRefreshRate(for: displayID),
              let current = CGDisplayCopyDisplayMode(displayID) else { return }
        var cfg = smartConfig
        cfg.width = current.pixelWidth
        cfg.height = current.pixelHeight
        cfg.refreshRate = rate
        cfg.startsHiDPI = current.pixelWidth > current.width
        await ensureConfiguredMode(displayID, config: Self.sanitize(cfg))
    }

    @discardableResult
    func setActive(_ enabled: Bool, configID: UUID) async -> Bool {
        guard configID == smartConfig.id else { return false }
        return await setSmartDummyEnabled(enabled)
    }

    @discardableResult
    func create(config: VirtualDisplayConfig) async -> Bool {
        guard config.id == smartConfig.id else { return false }
        return await setSmartDummyEnabled(true)
    }

    @discardableResult
    func destroy(configID: UUID) -> Bool {
        guard configID == smartConfig.id else { return false }
        let hadObject = activeDisplayObjects[configID] != nil
        destroyActiveVirtualDisplay(reason: "ExplicitDestroy")
        return hadObject
    }

    func destroyAll() {
        destroyActiveVirtualDisplay(reason: "DestroyAll")
        clamshellGuard.releaseAll()
    }

    // MARK: - Policy Evaluation Loop (must be called under withTransitionLock)

    private func scheduleEvaluation(reason: String, delayMs: UInt64) {
        scheduledEvaluationTask?.cancel()
        scheduledEvaluationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            guard !Task.isCancelled, let self else { return }
            self.evaluateNow(reason: reason)
        }
    }

    private func sampleCurrentInput() -> SmartVirtualDisplayInput {
        let disconnected = PhysicalDisplayToggleService.shared.disconnected
        let softDisconnectedUUIDs = Set(disconnected.map(\.uuid))
        let softDisconnectedExternalCount = disconnected.filter { $0.isBuiltin != true }.count
        return monitor.sampleInput(
            isVirtualDisplay: { [weak self] id in
                self?.isVirtualDisplay(id) ?? (CGDisplayVendorNumber(id) == Self.crispVirtualVendorID)
            },
            softDisconnectedUUIDs: softDisconnectedUUIDs,
            softDisconnectedExternalCount: softDisconnectedExternalCount
        )
    }

    private func clearErrorIfNeeded() {
        if lastError != nil {
            lastError = nil
        }
    }

    private func evaluateLocked(reason: String) async {
        monitor.setFallbackPollingEnabled(smartConfig.isEnabled)
        let input = sampleCurrentInput()
        if liveInput != input { liveInput = input }
        let decision = SmartVirtualDisplayPolicy.evaluate(config: smartConfig, input: input)
        let previousPhase = phase
        if phase != decision.phase { phase = decision.phase }

        if previousPhase != decision.phase {
            Self.log.notice(
                "[\(reason, privacy: .public)] phase \(previousPhase.rawValue, privacy: .public) -> \(decision.phase.rawValue, privacy: .public) (ac=\(input.isOnACPower, privacy: .public), lidClosed=\(input.isClamshellClosed, privacy: .public), ext=\(input.activePhysicalExternalCount, privacy: .public), builtin=\(input.activeBuiltinCount, privacy: .public))"
            )
        }

        switch decision.phase {
        case .disabled:
            // Destroy virtual display BEFORE releasing assertions on disable.
            destroyActiveVirtualDisplay(reason: "Disabled (\(reason))")
            clamshellGuard.releaseAll()
            clearErrorIfNeeded()

        case .suspendedOnBattery:
            // Release guard BEFORE/WITH destroy on AC->Battery suspend so Mac sleeps cleanly.
            clamshellGuard.releaseAll()
            destroyActiveVirtualDisplay(reason: "SuspendedOnBattery (\(reason))")
            clearErrorIfNeeded()

        case .armedStandby:
            if lastPhysicalDisconnectHoldCount > 0 && isSmartDummyMounted {
                if phase != .activeMounted { phase = .activeMounted }
                return
            }
            // Destroy virtual display FIRST so yield teardown has zero extra latency.
            destroyActiveVirtualDisplay(reason: "AutoYield (\(reason))")
            clamshellGuard.apply(decision: decision, forceTickle: false)
            clearErrorIfNeeded()

        case .activeMounted:
            await applyActiveMountedLocked(reason: reason, decision: decision, previousPhase: previousPhase)
        }
    }

    private func applyActiveMountedLocked(
        reason: String,
        decision: SmartVirtualDisplayDecision,
        previousPhase: SmartVirtualDisplayPhase
    ) async {
        // Engage clamshell guard before mounting so unplugging the last display never races sleep.
        clamshellGuard.apply(
            decision: decision,
            forceTickle: previousPhase != .activeMounted
        )

        // Detect stale virtual display missing from WindowServer after 5s grace period.
        if let existing = activeDisplayObjects[smartConfig.id],
           CGDisplayIsOnline(existing.displayID) == 0,
           (CFAbsoluteTimeGetCurrent() - mountedAt) > 5.0 {
            Self.log.notice("[\(reason, privacy: .public)] virtual display \(existing.displayID, privacy: .public) missing after grace period; remounting")
            destroyActiveVirtualDisplay(reason: "StaleRemount")
        }

        if let existing = activeDisplayObjects[smartConfig.id] {
            ensureNotMirrored(existing.displayID)
            await ensureConfiguredMode(existing.displayID, config: smartConfig)
        } else {
            switch await mountSmartDummy(config: smartConfig, allowYieldDuringApply: true) {
            case .mounted, .yielded:
                clearErrorIfNeeded()
            case .failed:
                lastError = "Failed to mount Smart Dummy virtual display."
                Self.log.error("[\(reason, privacy: .public)] failed to mount Smart Dummy")
            }
        }
    }

    // MARK: - Persistence & Sanitization

    private static func sanitize(_ config: SmartVirtualDisplayConfig) -> SmartVirtualDisplayConfig {
        var sanitized = config
        sanitized.width = min(max(sanitized.width, 640), 8192)
        sanitized.height = min(max(sanitized.height, 480), 8192)
        if !sanitized.width.isMultiple(of: 2) || !sanitized.height.isMultiple(of: 2) {
            sanitized.hiDPI = false
            sanitized.startsHiDPI = false
        }
        if sanitized.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sanitized.name = "Smart Dummy"
        }
        return sanitized
    }

    private static func loadSmartConfig() -> SmartVirtualDisplayConfig {
        guard let data = UserDefaults.standard.data(forKey: smartConfigKey),
              let decoded = try? JSONDecoder().decode(SmartVirtualDisplayConfig.self, from: data) else {
            return SmartVirtualDisplayConfig()
        }
        return decoded
    }

    private func persistSmartConfig() {
        configs = [smartConfig.asLegacy]
        guard let data = try? JSONEncoder().encode(smartConfig) else { return }
        UserDefaults.standard.set(data, forKey: Self.smartConfigKey)
    }
}

// MARK: - CGVirtualDisplay Mount / Teardown & Mode Helpers

extension VirtualDisplayService {
    private func mountSmartDummy(
        config: SmartVirtualDisplayConfig,
        allowYieldDuringApply: Bool
    ) async -> MountOutcome {
        isTransitioning = true
        defer { isTransitioning = false }

        PanelOpenGuard.suppressAutoDismiss = true
        defer {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                PanelOpenGuard.suppressAutoDismiss = false
            }
        }

        let w = config.width
        let h = config.height
        let hiDPI = config.hiDPI && w.isMultiple(of: 2) && h.isMultiple(of: 2)
        let startsHiDPI = hiDPI && config.startsHiDPI

        let descriptor = CGVirtualDisplayDescriptor()
        let ppi: Double = startsHiDPI ? 220.0 : 110.0
        descriptor.sizeInMillimeters = CGSize(
            width: Double(w) / ppi * 25.4,
            height: Double(h) / ppi * 25.4
        )
        descriptor.maxPixelsWide = UInt32(w)
        descriptor.maxPixelsHigh = UInt32(h)
        descriptor.redPrimary = NSPoint(x: 0.6400, y: 0.3300)
        descriptor.greenPrimary = NSPoint(x: 0.3000, y: 0.6000)
        descriptor.bluePrimary = NSPoint(x: 0.1500, y: 0.0600)
        descriptor.whitePoint = NSPoint(x: 0.3127, y: 0.3290)
        descriptor.name = config.name.isEmpty ? "Smart Dummy" : config.name
        descriptor.vendorID = Self.crispVirtualVendorID
        descriptor.productID = config.productID
        descriptor.serialNum = config.serialNumber

        if descriptor.responds(to: #selector(CGVirtualDisplayDescriptor.setDispatchQueue(_:))) {
            descriptor.setDispatchQueue(vdisplayQueue)
        } else {
            descriptor.queue = vdisplayQueue
        }

        let expectedConfigID = config.id
        descriptor.terminationHandler = { [weak self] terminatedDisplay, _ in
            let terminatedDisplayID = (terminatedDisplay as? CGVirtualDisplay)?.displayID ?? kCGNullDirectDisplay
            Task { @MainActor [weak self] in
                self?.handleVirtualDisplayTerminated(configID: expectedConfigID, displayID: terminatedDisplayID)
            }
        }

        guard let virtualDisplay = CGVirtualDisplay(descriptor: descriptor) else {
            return .failed
        }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI

        // Match esp32-smart-dummy: supply only the configured refresh rate's modes so
        // WindowServer commits in <100ms instead of enumerating 15+ modes.
        var modes: [CGVirtualDisplayMode] = []
        let rate = config.refreshRate
        let halfW = w / 2
        let halfH = h / 2
        if startsHiDPI && halfW >= 1 && halfH >= 1 {
            modes.append(CGVirtualDisplayMode(width: UInt(halfW), height: UInt(halfH), refreshRate: rate))
            modes.append(CGVirtualDisplayMode(width: UInt(w), height: UInt(h), refreshRate: rate))
        } else {
            modes.append(CGVirtualDisplayMode(width: UInt(w), height: UInt(h), refreshRate: rate))
            if hiDPI && halfW >= 1 && halfH >= 1 {
                modes.append(CGVirtualDisplayMode(width: UInt(halfW), height: UInt(halfH), refreshRate: rate))
            }
        }
        settings.modes = modes

        let vd = virtualDisplay
        let s = settings
        let applied: Bool = await CGHelpers.runWithTimeout(seconds: 10, fallback: false) {
            vd.apply(s)
        }
        guard applied, virtualDisplay.displayID != kCGNullDirectDisplay else {
            return .failed
        }

        // Post-apply Auto-Yield re-check: if a physical display connected, lid opened, or AC was
        // removed while WindowServer was applying settings, drop the virtual display immediately.
        if allowYieldDuringApply && lastPhysicalDisconnectHoldCount == 0 {
            let postApplyInput = sampleCurrentInput()
            liveInput = postApplyInput
            let rechecked = SmartVirtualDisplayPolicy.evaluate(config: smartConfig, input: postApplyInput)
            if !rechecked.shouldMountVirtualDisplay {
                let discardedID = virtualDisplay.displayID
                destroyingDisplayIDs.insert(discardedID)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self?.destroyingDisplayIDs.remove(discardedID)
                }
                phase = rechecked.phase
                clamshellGuard.apply(decision: rechecked, forceTickle: false)
                Self.log.notice("Yielded freshly mounted Smart Dummy (displayID=\(discardedID, privacy: .public)) -> \(rechecked.phase.rawValue, privacy: .public)")
                return .yielded
            }
        }

        activeDisplayObjects[config.id] = virtualDisplay
        activeConfigIDs.insert(config.id)
        mountedAt = CFAbsoluteTimeGetCurrent()
        mountGeneration &+= 1
        let gen = mountGeneration
        let displayID = virtualDisplay.displayID
        destroyingDisplayIDs.remove(displayID)

        ensureNotMirrored(displayID)
        await ensureConfiguredMode(displayID, config: config)
        scheduleSettleChecks(displayID: displayID, config: config, generation: gen)

        Self.log.notice("Mounted Smart Dummy '\(config.name, privacy: .public)' (\(config.logicalWidth, privacy: .public)x\(config.logicalHeight, privacy: .public), backing \(w, privacy: .public)x\(h, privacy: .public), displayID=\(displayID, privacy: .public))")
        return .mounted
    }

    private func destroyActiveVirtualDisplay(reason: String, keepDestroyingID: Bool = false) {
        guard !activeDisplayObjects.isEmpty else {
            activeConfigIDs.removeAll()
            return
        }
        cancelSettleTasks()
        mountGeneration &+= 1
        isDestroyingIntentionally = true
        defer { isDestroyingIntentionally = false }

        let ids = activeDisplayObjects.values.map(\.displayID).filter { $0 != kCGNullDirectDisplay }
        for id in ids {
            destroyingDisplayIDs.insert(id)
        }
        activeDisplayObjects.removeAll()
        activeConfigIDs.removeAll()
        mountedAt = 0

        if !keepDestroyingID && !ids.isEmpty {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                for id in ids where !self.activeDisplayObjects.values.contains(where: { $0.displayID == id }) {
                    self.destroyingDisplayIDs.remove(id)
                }
            }
        }
        Self.log.notice("Destroyed Smart Dummy displayID(s)=\(ids, privacy: .public) — \(reason, privacy: .public)")
    }

    private func handleVirtualDisplayTerminated(configID: UUID, displayID: CGDirectDisplayID) {
        guard !isDestroyingIntentionally else { return }
        guard let current = activeDisplayObjects[configID],
              displayID == kCGNullDirectDisplay || current.displayID == displayID else {
            return
        }
        Self.log.notice("CGVirtualDisplay terminationHandler fired for displayID=\(current.displayID, privacy: .public); scheduling self-heal")
        cancelSettleTasks()
        mountGeneration &+= 1
        activeDisplayObjects.removeValue(forKey: configID)
        activeConfigIDs.remove(configID)
        mountedAt = 0
        scheduleEvaluation(reason: "VirtualDisplayTerminated", delayMs: 500)
    }

    private func cancelSettleTasks() {
        for task in settleTasks {
            task.cancel()
        }
        settleTasks.removeAll()
    }

    private func scheduleSettleChecks(
        displayID: CGDirectDisplayID,
        config: SmartVirtualDisplayConfig,
        generation: UInt64
    ) {
        cancelSettleTasks()
        let delaysMs: [UInt64] = [120, 400, 900]
        for delayMs in delaysMs {
            let task = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                guard !Task.isCancelled, let self,
                      self.mountGeneration == generation,
                      self.activeDisplayObjects[config.id]?.displayID == displayID else {
                    return
                }
                self.ensureNotMirrored(displayID)
                await self.ensureConfiguredMode(displayID, config: config)
                self.clamshellGuard.reinforceIfArmed()
                if delayMs == 400 && self.clamshellGuard.displaySleepAssertionHeld {
                    self.clamshellGuard.tickleDisplayWake(force: true)
                }
            }
            settleTasks.append(task)
        }
    }

    /// Breaks mirroring in both directions strictly using `.forSession` (never `.permanently`).
    private func ensureNotMirrored(_ dummyID: CGDirectDisplayID) {
        guard dummyID != kCGNullDirectDisplay, CGDisplayIsInMirrorSet(dummyID) != 0 else { return }
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return }

        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let cfg = configRef else { return }
        var changed = false

        if CGDisplayMirrorsDisplay(dummyID) != kCGNullDirectDisplay {
            if CGConfigureDisplayMirrorOfDisplay(cfg, dummyID, kCGNullDirectDisplay) == .success {
                changed = true
            }
        }
        for otherID in displays.prefix(Int(count)) where otherID != dummyID {
            if CGDisplayMirrorsDisplay(otherID) == dummyID {
                if CGConfigureDisplayMirrorOfDisplay(cfg, otherID, kCGNullDirectDisplay) == .success {
                    changed = true
                }
            }
        }

        if changed {
            CGCompleteDisplayConfiguration(cfg, .forSession)
        } else {
            CGCancelDisplayConfiguration(cfg)
        }
    }

    /// Locks the configured mode (2x HiDPI or native 1x) using `.forSession`.
    private func ensureConfiguredMode(_ displayID: CGDirectDisplayID, config: SmartVirtualDisplayConfig) async {
        guard displayID != kCGNullDirectDisplay else { return }
        let targetWidth = config.logicalWidth
        let targetHeight = config.logicalHeight
        let backingWidth = config.width
        let backingHeight = config.height

        if let cur = CGDisplayCopyDisplayMode(displayID),
           cur.width == targetWidth,
           cur.height == targetHeight,
           cur.pixelWidth == backingWidth,
           cur.pixelHeight == backingHeight,
           abs(cur.refreshRate - config.refreshRate) < 0.5 {
            return
        }

        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            return
        }
        let target = modes.first(where: {
            $0.width == targetWidth
                && $0.height == targetHeight
                && $0.pixelWidth == backingWidth
                && $0.pixelHeight == backingHeight
                && abs($0.refreshRate - config.refreshRate) < 0.5
        }) ?? modes.first(where: {
            $0.width == targetWidth
                && $0.height == targetHeight
                && $0.pixelWidth == backingWidth
                && $0.pixelHeight == backingHeight
        })

        guard let target else { return }
        _ = await CGHelpers.runWithTimeout(seconds: 5, fallback: false) {
            var configRef: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&configRef) == .success, let cfg = configRef else {
                return false
            }
            guard CGConfigureDisplayWithDisplayMode(cfg, displayID, target, nil) == .success else {
                CGCancelDisplayConfiguration(cfg)
                return false
            }
            return CGCompleteDisplayConfiguration(cfg, .forSession) == .success
        }
    }

    private func waitForDisplayOffline(_ displayID: CGDirectDisplayID) async {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        guard ids.contains(displayID) else { return }
        await ReconfigEvents.shared.next(for: displayID, matching: .removeFlag, timeout: 1.5)
    }
}

extension DisplayInfo {
    /// The UUID presets store for this display (see `VirtualDisplayService.presetUUID(of:)`).
    var presetUUID: String { VirtualDisplayService.shared.presetUUID(of: self) }
}
