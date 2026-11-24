import AppKit
import CoreGraphics
import Foundation
import IOKit
import IOKit.ps
import os.log

private let kIOPMMessageClamshellStateChangeCode: UInt32 = 0xE000_0100

private func powerSourceNotificationCallback(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let monitor = Unmanaged<PowerAndTopologyMonitor>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated {
        monitor.handlePowerSourceChanged()
    }
}

private func rootDomainInterestCallback(
    _ refcon: UnsafeMutableRawPointer?,
    _ service: io_service_t,
    _ messageType: UInt32,
    _ messageArgument: UnsafeMutableRawPointer?
) {
    _ = service
    _ = messageArgument
    guard let refcon else { return }
    let monitor = Unmanaged<PowerAndTopologyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated {
        monitor.handleRootDomainInterest(messageType: messageType)
    }
}

private func kernelFramebufferInterestCallback(
    _ refcon: UnsafeMutableRawPointer?,
    _ service: io_service_t,
    _ messageType: UInt32,
    _ messageArgument: UnsafeMutableRawPointer?
) {
    _ = service
    _ = messageType
    _ = messageArgument
    guard let refcon else { return }
    let monitor = Unmanaged<PowerAndTopologyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated {
        monitor.handleKernelFramebufferEvent()
    }
}

private func smartDummyDisplayReconfigCallback(
    _ display: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else { return }
    let monitor = Unmanaged<PowerAndTopologyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    let displayID = display
    let rawFlags = flags.rawValue
    if Thread.isMainThread {
        MainActor.assumeIsolated {
            monitor.handleDisplayReconfiguration(
                display: displayID,
                flags: CGDisplayChangeSummaryFlags(rawValue: rawFlags)
            )
        }
    } else {
        Task { @MainActor in
            monitor.handleDisplayReconfiguration(
                display: displayID,
                flags: CGDisplayChangeSummaryFlags(rawValue: rawFlags)
            )
        }
    }
}

/// Event-driven monitor for AC/battery power, clamshell lid state, external IOMobileFramebuffer
/// hotplug fast-path (<5ms on Apple Silicon), CoreGraphics display topology changes, and sleep/wake.
@MainActor
final class PowerAndTopologyMonitor {
    private static let log = Logger(subsystem: "com.crisper.app", category: "power-topology")
    private static let fallbackIntervalSeconds: TimeInterval = 30.0
    private static let headlessFallbackVendor: UInt32 = 0x756E_6B6E  // 'unkn'
    private static let headlessFallbackModel: UInt32 = 0x7669_7274   // 'virt'

    struct Handlers {
        var onFastHardwareEvent: () -> Void = {}
        var onEvent: (_ reason: String, _ immediate: Bool, _ followupDelayMs: UInt64?) -> Void = { _, _, _ in }
        var isOwnVirtualDisplay: (CGDirectDisplayID) -> Bool = { _ in false }
    }

    private var handlers = Handlers()
    private var isStarted = false
    private var callbackContext: UnsafeMutableRawPointer?

    private var ioNotifyPort: IONotificationPortRef?
    private var rootDomainNotifier: io_object_t = IO_OBJECT_NULL
    private var fbNotifiers: [io_object_t] = []
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var fallbackTimer: Timer?
    private var fallbackPollingEnabled = true

    private(set) var areScreensAsleep = false
    private var lastKnownClamshellClosed: Bool?
    private var lastKnownOnACPower: Bool?

    func start(handlers: Handlers, enableFallbackPolling: Bool = true) {
        self.handlers = handlers
        self.fallbackPollingEnabled = enableFallbackPolling
        guard !isStarted else {
            updateFallbackTimer()
            return
        }
        isStarted = true
        areScreensAsleep = false
        lastKnownClamshellClosed = Self.readIsClamshellClosed()
        lastKnownOnACPower = Self.readIsOnACPower()

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        callbackContext = ctx

        // 1. IOKit notification port for IOPMrootDomain clamshell + external IOMobileFramebuffer nodes
        if let port = IONotificationPortCreate(kIOMainPortDefault) {
            ioNotifyPort = port
            let rlSource = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
            CFRunLoopAddSource(CFRunLoopGetMain(), rlSource, .commonModes)

            let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
            if rootDomain != IO_OBJECT_NULL {
                var notifier: io_object_t = IO_OBJECT_NULL
                let kr = IOServiceAddInterestNotification(
                    port,
                    rootDomain,
                    kIOGeneralInterest,
                    rootDomainInterestCallback,
                    ctx,
                    &notifier
                )
                if kr == KERN_SUCCESS {
                    rootDomainNotifier = notifier
                }
                IOObjectRelease(rootDomain)
            }

            var fbIter: io_iterator_t = 0
            if let matching = IOServiceMatching("IOMobileFramebuffer"),
               IOServiceGetMatchingServices(kIOMainPortDefault, matching, &fbIter) == KERN_SUCCESS {
                defer { IOObjectRelease(fbIter) }
                while case let fbService = IOIteratorNext(fbIter), fbService != IO_OBJECT_NULL {
                    defer { IOObjectRelease(fbService) }
                    if Self.isExternalFramebuffer(fbService) {
                        var notifier: io_object_t = IO_OBJECT_NULL
                        let kr = IOServiceAddInterestNotification(
                            port,
                            fbService,
                            kIOGeneralInterest,
                            kernelFramebufferInterestCallback,
                            ctx,
                            &notifier
                        )
                        if kr == KERN_SUCCESS, notifier != IO_OBJECT_NULL {
                            fbNotifiers.append(notifier)
                        }
                    }
                }
            }
        }

        // 2. IOKit power source (AC <-> Battery) notifications
        if let psSource = IOPSNotificationCreateRunLoopSource(powerSourceNotificationCallback, ctx)?.takeRetainedValue() {
            powerSourceRunLoopSource = psSource
            CFRunLoopAddSource(CFRunLoopGetMain(), psSource, .commonModes)
        }

        // 3. CoreGraphics display reconfiguration callback
        CGDisplayRegisterReconfigurationCallback(smartDummyDisplayReconfigCallback, ctx)

        // 4. NSWorkspace sleep / wake notifications (both system and display idle sleep)
        let wsCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            let obs = wsCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.areScreensAsleep = true
                    self?.updateFallbackTimer()
                }
            }
            workspaceObservers.append(obs)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            let reason = (name == NSWorkspace.didWakeNotification) ? "WorkspaceDidWake" : "ScreensDidWake"
            let obs = wsCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.areScreensAsleep = false
                    self?.updateFallbackTimer()
                    self?.handlers.onEvent(reason, false, 50)
                }
            }
            workspaceObservers.append(obs)
        }

        // 5. Low-frequency 30s fallback check (paused automatically while disabled or asleep)
        updateFallbackTimer()

        Self.log.notice("PowerAndTopologyMonitor started (fbNotifiers=\(self.fbNotifiers.count, privacy: .public))")
    }

    func setFallbackPollingEnabled(_ enabled: Bool) {
        guard fallbackPollingEnabled != enabled else { return }
        fallbackPollingEnabled = enabled
        updateFallbackTimer()
    }

    private func updateFallbackTimer() {
        let shouldRun = isStarted && fallbackPollingEnabled && !areScreensAsleep
        if shouldRun {
            guard fallbackTimer == nil else { return }
            let timer = Timer(timeInterval: Self.fallbackIntervalSeconds, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handlers.onEvent("PeriodicFallback", true, nil)
                }
            }
            timer.tolerance = 3.0
            RunLoop.main.add(timer, forMode: .common)
            fallbackTimer = timer
        } else {
            fallbackTimer?.invalidate()
            fallbackTimer = nil
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false

        fallbackTimer?.invalidate()
        fallbackTimer = nil

        for obs in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        workspaceObservers.removeAll()
        areScreensAsleep = false

        if let ctx = callbackContext {
            CGDisplayRemoveReconfigurationCallback(smartDummyDisplayReconfigCallback, ctx)
            callbackContext = nil
        }

        if let psSource = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), psSource, .commonModes)
            powerSourceRunLoopSource = nil
        }

        for notifier in fbNotifiers where notifier != IO_OBJECT_NULL {
            IOObjectRelease(notifier)
        }
        fbNotifiers.removeAll()

        if rootDomainNotifier != IO_OBJECT_NULL {
            IOObjectRelease(rootDomainNotifier)
            rootDomainNotifier = IO_OBJECT_NULL
        }

        if let port = ioNotifyPort {
            let rlSource = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
            CFRunLoopRemoveSource(CFRunLoopGetMain(), rlSource, .commonModes)
            IONotificationPortDestroy(port)
            ioNotifyPort = nil
        }
    }

    func noteSystemWake() {
        areScreensAsleep = false
        updateFallbackTimer()
    }

    // MARK: - Live Sampling

    private struct CoreGraphicsPhysicalSnapshot {
        let external: Int
        let builtin: Int
        let anyPhysicalAsleep: Bool
    }

    /// Samples power, clamshell, and online physical display counts by combining CoreGraphics
    /// online display state (which preserves sleeping and hardware-mirrored physical panels),
    /// Crisper's soft-disconnect state, and the Apple Silicon kernel IOMobileFramebuffer
    /// fast-path (<5ms hotplug-in and hotplug-out detection when awake).
    func sampleInput(
        isVirtualDisplay: (CGDirectDisplayID) -> Bool,
        softDisconnectedUUIDs: Set<String>,
        softDisconnectedExternalCount: Int = 0
    ) -> SmartVirtualDisplayInput {
        let onAC = Self.readIsOnACPower()
        let clamshellClosed = Self.readIsClamshellClosed()
        let cg = Self.countCoreGraphicsPhysicalDisplays(
            isVirtualDisplay: isVirtualDisplay,
            softDisconnectedUUIDs: softDisconnectedUUIDs
        )
        let kernelExt = Self.countKernelExternalDisplays()
        let activePhysicalExternalCount = SmartVirtualDisplayPolicy.resolveExternalPhysicalCount(
            cgOnlineExternalCount: cg.external,
            kernelExternalCount: kernelExt,
            softDisconnectedExternalCount: softDisconnectedExternalCount,
            areScreensAsleep: areScreensAsleep || cg.anyPhysicalAsleep
        )

        return SmartVirtualDisplayInput(
            isOnACPower: onAC,
            isClamshellClosed: clamshellClosed,
            activePhysicalExternalCount: activePhysicalExternalCount,
            activeBuiltinCount: cg.builtin
        )
    }

    static func readIsOnACPower() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return true
        }
        guard let sourceType = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String? else {
            return true
        }
        return sourceType == (kIOPMACPowerKey as String)
    }

    static func readIsClamshellClosed() -> Bool {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(rootDomain) }
        guard let prop = IORegistryEntryCreateCFProperty(
            rootDomain,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else {
            return false
        }
        return (prop as? Bool) ?? false
    }

    /// Queries Apple Silicon DCP external IOMobileFramebuffer nodes. Returns `nil` when no external
    /// DCP pipes exist on this platform (e.g. Intel Macs).
    static func countKernelExternalDisplays() -> Int? {
        guard let matching = IOServiceMatching("IOMobileFramebuffer") else { return nil }
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iter) }

        var extPipesFound = 0
        var connectedCount = 0
        while case let service = IOIteratorNext(iter), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            guard isExternalFramebuffer(service) else { continue }
            extPipesFound += 1
            if let attrs = IORegistryEntryCreateCFProperty(
                service,
                "DisplayAttributes" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any], !attrs.isEmpty {
                connectedCount += 1
            }
        }
        guard extPipesFound > 0 else { return nil }
        return connectedCount
    }

    private static func isExternalFramebuffer(_ service: io_service_t) -> Bool {
        guard let prop = IORegistryEntryCreateCFProperty(
            service,
            "external" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else {
            return false
        }
        return (prop as? Bool) ?? false
    }

    private static func countCoreGraphicsPhysicalDisplays(
        isVirtualDisplay: (CGDirectDisplayID) -> Bool,
        softDisconnectedUUIDs: Set<String>
    ) -> CoreGraphicsPhysicalSnapshot {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            return CoreGraphicsPhysicalSnapshot(external: 0, builtin: 0, anyPhysicalAsleep: false)
        }
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displayIDs, &count) == .success else {
            return CoreGraphicsPhysicalSnapshot(external: 0, builtin: 0, anyPhysicalAsleep: false)
        }

        var extCount = 0
        var builtinCount = 0
        var anyPhysicalAsleep = false
        for id in displayIDs.prefix(Int(count)) {
            if isVirtualDisplay(id) { continue }
            if !softDisconnectedUUIDs.isEmpty,
               let uuid = displayUUID(for: id),
               softDisconnectedUUIDs.contains(uuid) {
                continue
            }
            if CGDisplayIsBuiltin(id) != 0 {
                builtinCount += 1
                if CGDisplayIsAsleep(id) != 0 { anyPhysicalAsleep = true }
                continue
            }
            let vendor = CGDisplayVendorNumber(id)
            let model = CGDisplayModelNumber(id)
            // Exclude only macOS headless fallback ('unkn'/'virt') and zero stubs so valid
            // hardware monitors with unusual EDID vendor IDs are never rejected.
            if vendor == headlessFallbackVendor && model == headlessFallbackModel { continue }
            if vendor == 0 && model == 0 { continue }
            extCount += 1
            if CGDisplayIsAsleep(id) != 0 { anyPhysicalAsleep = true }
        }
        return CoreGraphicsPhysicalSnapshot(
            external: extCount,
            builtin: builtinCount,
            anyPhysicalAsleep: anyPhysicalAsleep
        )
    }

    private static func displayUUID(for displayID: CGDirectDisplayID) -> String? {
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        return CFUUIDCreateString(nil, cfUUID.takeRetainedValue()) as String
    }

    // MARK: - Event Dispatch

    fileprivate func handlePowerSourceChanged() {
        let currentOnAC = Self.readIsOnACPower()
        if lastKnownOnACPower != currentOnAC {
            lastKnownOnACPower = currentOnAC
            areScreensAsleep = false
            updateFallbackTimer()
        }
        handlers.onEvent("PowerSourceChange", true, 50)
    }

    fileprivate func handleRootDomainInterest(messageType: UInt32) {
        guard messageType == kIOPMMessageClamshellStateChangeCode else { return }
        let currentClosed = Self.readIsClamshellClosed()
        if lastKnownClamshellClosed != currentClosed {
            lastKnownClamshellClosed = currentClosed
            areScreensAsleep = false
            updateFallbackTimer()
        }
        handlers.onFastHardwareEvent()
        handlers.onEvent("ClamshellStateChange", true, 150)
    }

    fileprivate func handleKernelFramebufferEvent() {
        handlers.onFastHardwareEvent()
        handlers.onEvent("KernelFramebufferEvent", true, 150)
    }

    fileprivate func handleDisplayReconfiguration(display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        handlers.onFastHardwareEvent()
        if flags.contains(.beginConfigurationFlag) {
            return
        }
        if handlers.isOwnVirtualDisplay(display) {
            return
        }
        let topologyFlags: CGDisplayChangeSummaryFlags = [.addFlag, .removeFlag, .enabledFlag, .disabledFlag]
        if !flags.isDisjoint(with: topologyFlags) {
            handlers.onEvent("DisplayHotplug", true, 150)
        }
    }
}
