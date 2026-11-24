import AppKit
import CoreGraphics
import ColorSync
import IOKit
import os.log

/// Disconnects / reconnects REAL (physical) displays via the private SkyLight API
/// `SLSConfigureDisplayEnabled`, the way BetterDisplay's "Disconnect Display" works.
/// Apple Silicon only (`isSupported`); on Intel the API doesn't perform a true disconnect.
/// A disabled display drops out of CGGetOnlineDisplayList/CGGetActiveDisplayList but still
/// enumerates via SLSGetDisplayList, so `disconnected` keeps its own snapshot for the UI.
/// See docs/display-notes.md (PhysicalDisplayToggleService).
@MainActor
final class PhysicalDisplayToggleService: ObservableObject {
    static let shared = PhysicalDisplayToggleService()
    private init() {
        loadDesired()
        loadParked()
        observeSleepAndWake()
    }

    private var wakeObservers: [NSObjectProtocol] = []

    /// Set by DisplayManager at launch. The restore below needs a DisplayInfo to read and put
    /// back a display's HDR switch, and this service otherwise works from CGDirectDisplayIDs.
    weak var displayManager: DisplayManager?
    /// Disconnects and the user's reconnects run one at a time: two disconnects that both
    /// passed the last-screen guard while the DDC hold drained turned every screen off.
    private let connectionQueue = DisplayConnectionQueue()

    /// Snapshot of a display we disconnected, kept because a disconnected display no longer
    /// appears in DisplayManager.displays, so we need its metadata to render a Reconnect row.
    struct DisconnectedDisplay: Identifiable, Codable, Sendable, Equatable {
        let uuid: String            // stable identity across CGDirectDisplayID reassignment
        var displayID: CGDirectDisplayID  // last-known ID (used to reconnect)
        var name: String
        var width: Int
        var height: Int
        /// Whether this was the built-in panel, captured at disconnect time. Optional so
        /// records written before this field decode instead of throwing away the whole list.
        var isBuiltin: Bool?
        /// The input to switch the monitor back to on Reconnect, when it left through an
        /// input switch (InputSwitchService). Optional for the same reason as isBuiltin.
        var returnInput: UInt16?
        /// For the built-in: UUIDs of the externals lit when it was disconnected, so a parked
        /// record knows which dock to re-apply on (#202). Optional for the same reason as isBuiltin.
        var companions: [String]?
        var hardwareIdentity: DDCServiceMatcher.Identity?
        /// Keep offering Reconnect without switching the display off again if it comes back late.
        var reconnectRequested: Bool?
        var id: String { uuid }
    }

    enum ToggleError: Error, Sendable, CustomStringConvertible {
        case unsupportedPlatform
        case wouldLeaveNoActiveDisplay
        case configurationFailed(CGError)
        case displayNotFound
        case inputRestoreFailed
        /// The 10s wrapper only stops waiting; it can't cancel CGCompleteDisplayConfiguration,
        /// so this is not proof the change didn't take.
        case timedOut

        var description: String {
            switch self {
            case .unsupportedPlatform:
                return String(localized: "Physical display disconnect requires Apple Silicon (macOS 13+).")
            case .wouldLeaveNoActiveDisplay:
                return String(localized: "Refusing to disconnect: it would leave no active display.")
            case .configurationFailed(let err):
                return String(localized: "Display configuration failed (CGError \(String(err.rawValue))).")
            case .displayNotFound:
                return String(localized: "Display not found.")
            case .inputRestoreFailed:
                return String(localized: "Could not switch the display back to its Mac input. Try reconnecting again.")
            case .timedOut:
                return String(localized: "Display configuration timed out.")
            }
        }
    }

    // MARK: - State

    /// Displays the user has disconnected and can reconnect. Persisted (by UUID) so wake and
    /// relaunch can restore the intended state.
    @Published private(set) var disconnected: [DisconnectedDisplay] = []

    private let desiredKey = "crisp.PhysicalDisconnectedUUIDs"
    /// Dead-man markers for displays softReconnect is (or was, if the app died) mid-toggle on.
    /// A list: two displays can blink at once. See softReconnect / recoverStrandedSoftReconnect.
    private let softReconnectPendingKey = "crisp.PhysicalDisplayToggleService.softReconnectPending"
    /// Displays whose softReconnect is mid-blink right now, so recovery and the disabled-display
    /// sweep don't re-enable one out from under its own retry loop.
    private var softReconnectInFlight: Set<String> = []
    /// UUIDs mid-reconnect right now. reconcile() must not read `disconnected` for these: a
    /// reconfig callback firing before setEnabled(true) returns would see the record still in
    /// place and switch the display straight back off.
    private var reconnectInFlight: Set<String> = []
    /// UUIDs whose disable or enable timed out and may still land (#33 had WindowServer hold
    /// a commit for 29.5 s). reconcile() leaves them alone until enumeration settles it, so
    /// it does not send a second change into the pending one.
    private var awaitingLateCommit: Set<String> = []

    private typealias PendingSoftReconnect = PhysicalDisplayReconnectPolicy.PendingSoftReconnect

    private func pendingSoftReconnects() -> [PendingSoftReconnect] {
        PhysicalDisplayReconnectPolicy.decodePendingSoftReconnects(
            data: UserDefaults.standard.data(forKey: softReconnectPendingKey),
            legacyUUIDs: UserDefaults.standard.stringArray(forKey: softReconnectPendingKey)
        )
    }

    private func savePendingSoftReconnects(_ pending: [PendingSoftReconnect]) {
        if pending.isEmpty {
            UserDefaults.standard.removeObject(forKey: softReconnectPendingKey)
        } else if let data = try? JSONEncoder().encode(pending) {
            UserDefaults.standard.set(data, forKey: softReconnectPendingKey)
        }
    }

    private func addPendingSoftReconnect(_ displayUUID: String, displayID: CGDirectDisplayID) {
        var pending = pendingSoftReconnects().filter { $0.uuid != displayUUID }
        pending.append(PendingSoftReconnect(uuid: displayUUID, displayID: displayID))
        savePendingSoftReconnects(pending)
    }

    private func removePendingSoftReconnect(_ displayUUID: String) {
        savePendingSoftReconnects(pendingSoftReconnects().filter { $0.uuid != displayUUID })
    }

    // MARK: - Logging

    /// Every step here logs: issue #33 (a whole-machine freeze on reconnect) had only
    /// WindowServer's side of the story. See docs/display-notes.md (PhysicalDisplayToggleService).
    private nonisolated static let log = Logger(subsystem: "com.crisp.app", category: "display")

    /// Matches DDCService's threshold so slow operations read the same across categories.
    private nonisolated static let slowOpThresholdMs = 500.0

    private nonisolated static func millisSince(_ start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    // MARK: - Support gate

    /// True only on Apple Silicon. The disconnect API is a no-op / misbehaves on Intel.
    let isSupported: Bool = {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }()

    // MARK: - Queries

    func isDisconnected(uuid: String) -> Bool {
        disconnected.contains { $0.uuid == uuid }
    }

    private static let headlessFallbackVendor: UInt32 = 0x756E_6B6E  // 'unkn'
    private static let headlessFallbackModel: UInt32 = 0x7669_7274   // 'virt'

    /// Online physical displays (including hardware-mirrored targets), excluding Crisper virtual
    /// displays, soft-disconnected records, macOS `'unkn'/'virt'` fallback, and `0/0` stubs.
    func onlinePhysicalDisplayCount() -> Int {
        let virtual = VirtualDisplayService.shared
        let softDisconnectedUUIDs = Set(disconnected.map(\.uuid))
        var count = 0
        for id in onlineDisplayIDs() {
            if virtual.isVirtualDisplay(id) { continue }
            if !softDisconnectedUUIDs.isEmpty, softDisconnectedUUIDs.contains(uuid(for: id)) {
                continue
            }
            if CGDisplayIsBuiltin(id) == 0 {
                let vendor = CGDisplayVendorNumber(id)
                let model = CGDisplayModelNumber(id)
                if vendor == Self.headlessFallbackVendor && model == Self.headlessFallbackModel { continue }
                if vendor == 0 && model == 0 { continue }
            }
            count += 1
        }
        return count
    }

    /// True if disconnecting `display` now would leave no *viewable* screen. Uses online physical
    /// display count so hardware-mirrored pairs are not misread as a single screen, and allows
    /// disconnecting the true last physical display only when Smart Dummy is mounted or enabled on AC.
    func wouldLeaveNoActiveDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        guard CGDisplayIsOnline(displayID) != 0 && onlinePhysicalDisplayCount() <= 1 else {
            return false
        }
        let smartDummy = VirtualDisplayService.shared
        if smartDummy.isSmartDummyMounted {
            return false
        }
        if smartDummy.isSmartDummyEnabled && smartDummy.liveInput.isOnACPower {
            return false
        }
        return true
    }

    /// All display IDs known to the window server, INCLUDING ones disabled via
    /// `SLSConfigureDisplayEnabled` (which `CGGetOnlineDisplayList` omits).
    private func allDisplaysIncludingDisabled() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard SLSGetDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard SLSGetDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// Active physical (non-virtual) screens. Used by the Disconnect row and the launch
    /// re-apply; the blackout rescue uses phantomAwareActiveDisplayCount instead.
    private func physicalActiveDisplayCount() -> Int {
        viewableActiveDisplays().count
    }

    private func viewableActiveDisplays() -> [CGDirectDisplayID] {
        ScreenCount.viewable(activeEntries()).map(\.id)
    }

    private func activeEntries() -> [ScreenCount.Entry] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        let virtual = VirtualDisplayService.shared
        return ids.prefix(Int(count)).map { id in
            ScreenCount.Entry(id: id, isCrispVirtual: virtual.isVirtualDisplay(id), isBuiltin: CGDisplayIsBuiltin(id) == 1,
                              vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id))
        }
    }

    /// physicalActiveDisplayCount with the #112 phantoms (stale post-wake externals) filtered
    /// by port presence. Read only by restoreIfNoActiveDisplay: a wrong answer here can only
    /// make the rescue fire, never hide a row or refuse a remembered disconnect.
    /// See docs/display-notes.md (phantomAwareActiveDisplayCount).
    private func phantomAwareActiveDisplayCount() -> Int {
        ScreenCount.phantomAwareCount(activeEntries(), portCap: liveDisplayPortCount(), hasProductName: Self.hasProductName)
    }

    /// Whether CoreDisplay still knows the display by name; empty for a #112 phantom or a
    /// display WindowServer is mid-re-enumerating. See docs/display-notes.md
    /// (phantomAwareActiveDisplayCount).
    private static func hasProductName(_ id: CGDirectDisplayID) -> Bool {
        guard let info = _CoreDisplayCreateInfoDictionary?(id)?.takeRetainedValue() as? [String: Any] else {
            return false
        }
        if let names = info["DisplayProductName"] as? [String: Any] {
            return names.values.contains { ($0 as? String)?.isEmpty == false }
        }
        return (info["DisplayProductName"] as? String)?.isEmpty == false
    }

    /// Reads the port transport nodes; ScreenCount.portCap decides what they say.
    /// See docs/display-notes.md (liveDisplayPortCount).
    private func liveDisplayPortCount() -> Int? {
        var nodes: [ScreenCount.PortNode] = []
        for cls in ["IOPortTransportStateDisplayPort", "IOPortTransportStateCIO", "IOPortTransportStateCC"] {
            var it: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &it) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(it) }
            while case let node = IOIteratorNext(it), node != 0 {
                defer { IOObjectRelease(node) }
                let hpd = IORegistryEntryCreateCFProperty(node, "HPD_StateDescription" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String
                let sinks = IORegistryEntryCreateCFProperty(node, "SinkCount" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Int ?? 0
                nodes.append(ScreenCount.PortNode(hpd: hpd, sinkCount: sinks))
            }
        }
        return ScreenCount.portCap(nodes)
    }

    private func cgUUID(for displayID: CGDirectDisplayID) -> String? {
        guard let cf = CGDisplayCreateUUIDFromDisplayID(displayID),
              let s = CFUUIDCreateString(nil, cf.takeRetainedValue()) else { return nil }
        return s as String
    }

    private func enumeratedDisplays() -> [PhysicalDisplayReconnectPolicy.EnumeratedDisplay] {
        allDisplaysIncludingDisabled().map { .init(id: $0, cgUUID: cgUUID(for: $0)) }
    }

    private func uuid(for displayID: CGDirectDisplayID) -> String {
        cgUUID(for: displayID) ?? "id-\(displayID)"
    }

    // MARK: - Disconnect / Reconnect

    /// Disconnects a physical display and records a snapshot for later reconnect. Refuses if it
    /// would leave zero active displays, so the user can never black out their only screen.
    /// Runs in `connectionQueue`, so the last-screen guard sees every earlier change.
    /// `fromPreset` (#211): a built-in disconnect leaves no parked record, so it ends at the next
    /// undock, and the restore of the other displays is awaited, so the preset's own settings
    /// land after it instead of being undone by it.
    @discardableResult
    func disconnect(_ display: DisplayInfo, returnInput: UInt16? = nil, fromPreset: Bool = false) async -> Result<Void, ToggleError> {
        await connectionQueue.run { await self.performDisconnect(display, returnInput: returnInput, fromPreset: fromPreset) }
    }

    private func performDisconnect(_ display: DisplayInfo, returnInput: UInt16?, fromPreset: Bool) async -> Result<Void, ToggleError> {
        guard !softReconnectInFlight.contains(display.displayUUID) else { return .failure(.timedOut) }
        guard isSupported else { return .failure(.unsupportedPlatform) }
        // The ID can be reassigned while the call waited its turn.
        let displayID = onlineDisplayIDs().first { uuid(for: $0) == display.displayUUID } ?? display.displayID
        if wouldLeaveNoActiveDisplay(displayID) {
            Self.log.notice("disconnect refused: \(display.displayUUID, privacy: .public) id \(displayID, privacy: .public) is the last active display")
            return .failure(.wouldLeaveNoActiveDisplay)
        }
        var holdingPreMountedSmartDummy = false
        if CGDisplayIsOnline(displayID) != 0 && onlinePhysicalDisplayCount() <= 1 {
            let smartDummy = VirtualDisplayService.shared
            if !smartDummy.isSmartDummyMounted {
                let preMounted = await smartDummy.mountBeforeLastPhysicalDisconnect()
                if !preMounted {
                    Self.log.notice("disconnect refused: Smart Dummy failed to pre-mount before disconnecting last display \(displayID, privacy: .public)")
                    return .failure(.wouldLeaveNoActiveDisplay)
                }
                holdingPreMountedSmartDummy = true
            }
        }
        defer {
            if holdingPreMountedSmartDummy {
                VirtualDisplayService.shared.releaseLastPhysicalDisconnectHold()
            }
        }

        // A new click adds this dock's externals to the ones a parked record already knew.
        var companions: [String]?
        if display.isBuiltin, !fromPreset {
            let externals = viewableActiveDisplays().filter { $0 != displayID }.map { uuid(for: $0) }
            let known = parked?.uuid == display.displayUUID ? parked?.companions ?? [] : []
            companions = Array(Set(externals + known))
        }
        // Snapshot BEFORE disabling, afterwards the display is gone from the normal APIs.
        let snapshot = DisconnectedDisplay(
            uuid: display.displayUUID,
            displayID: displayID,
            name: display.name,
            width: display.pixelWidth,
            height: display.pixelHeight,
            isBuiltin: display.isBuiltin,
            returnInput: returnInput,
            companions: companions,
            hardwareIdentity: display.isBuiltin ? nil : DDCServiceMatcher.Identity(
                vendor: CGDisplayVendorNumber(displayID),
                product: CGDisplayModelNumber(displayID),
                serial: CGDisplaySerialNumber(displayID),
                location: DDCService.shared.channelLocation(for: displayID)
            )
        )

        Self.log.notice("disconnect requested: \(display.displayUUID, privacy: .public) id \(displayID, privacy: .public)")
        let otherStates = currentStates(excluding: [displayID])
        let result = await setEnabled(false, displayID: displayID)
        switch result {
        case .success:
            remember(snapshot)
            PresetService.shared.noteConnectionChange()
            VirtualDisplayService.shared.evaluateNow(reason: "PhysicalDisplayDisconnected")
            if fromPreset {
                await restoreStates(otherStates)
            } else {
                Task { [weak self] in await self?.restoreStates(otherStates) }
            }
        case .failure(.timedOut):
            // Not proof the change failed (see ToggleError.timedOut). Without the record, a
            // disable that lands late has no Reconnect row and no blackout rescue.
            remember(snapshot)
            watchLateDisconnect(snapshot.uuid, displayID: displayID, otherStates: otherStates)
        default:
            break
        }
        return result
    }

    /// What an arrangement decides for one display: its mode, its rotation, and whether it is
    /// in HDR. `hdr` is nil for a display that has no HDR switch to put back.
    struct DisplayState {
        let id: CGDirectDisplayID
        let mode: CGDisplayMode
        let isVariableRefresh: Bool?
        let rotation: Double
        let hdr: Bool?
    }

    private func currentStates(excluding displayIDs: Set<CGDirectDisplayID> = []) -> [DisplayState] {
        let virtual = VirtualDisplayService.shared
        return onlineDisplayIDs()
            .filter { !displayIDs.contains($0) && !virtual.isVirtualDisplay($0) }
            .compactMap { id in
                CGDisplayCopyDisplayMode(id).map { mode in
                    DisplayState(
                        id: id, mode: mode,
                        isVariableRefresh: currentIsVariableRefresh(for: id, modeID: mode.ioDisplayModeID),
                        rotation: CGDisplayRotation(id), hdr: liveHDR(id)
                    )
                }
            }
    }

    private func currentIsVariableRefresh(for displayID: CGDirectDisplayID, modeID: Int32) -> Bool? {
        if let cached = displayManager?.displays.first(where: { $0.displayID == displayID })?.currentDisplayMode,
           cached.id == modeID {
            return cached.isVariableRefresh
        }
        return DisplayMode.currentMode(for: displayID)?.isVariableRefresh
    }

    private func liveHDR(_ displayID: CGDirectDisplayID) -> Bool? {
        guard let display = displayManager?.displays.first(where: { $0.displayID == displayID }),
              BrightnessBoostService.shared.isEligibleForHDRToggle(display) else { return nil }
        return BrightnessBoostService.shared.isHDREnabled(for: display)
    }

    /// The same mode in the menu's list, hidden HiDPI variants included.
    private static func same(_ mode: CGDisplayMode, isVariableRefresh: Bool? = nil) -> (DisplayMode) -> Bool {
        {
            $0.width == mode.width && $0.height == mode.height && $0.pixelWidth == mode.pixelWidth
                && $0.pixelHeight == mode.pixelHeight && abs($0.refreshRate - mode.refreshRate) < 1
                && (isVariableRefresh == nil || $0.isVariableRefresh == isVariableRefresh)
        }
    }

    private func restoreStates(_ states: [DisplayState]) async {
        // A mirror target's mode is driven by its source (see ResolutionService).
        let moved = {
            states.filter { state in
                guard self.onlineDisplayIDs().contains(state.id),
                      !MirroredModeService.shared.isActive(for: state.id) else { return false }
                if let current = CGDisplayCopyDisplayMode(state.id),
                   current.ioDisplayModeID != state.mode.ioDisplayModeID { return true }
                if CGDisplayRotation(state.id) != state.rotation { return true }
                if let hdr = state.hdr, self.liveHDR(state.id) != hdr { return true }
                return false
            }
        }
        // Poll for the re-arrangement (lands ~1s after commit) instead of a fixed sleep, so
        // the user-visible flip stays short.
        var changed = moved()
        for _ in 0..<30 where changed.isEmpty {
            try? await Task.sleep(nanoseconds: 100_000_000)
            changed = moved()
        }
        guard !changed.isEmpty else { return }
        try? await Task.sleep(nanoseconds: 100_000_000)
        for state in moved() {
            let id = state.id
            if let current = CGDisplayCopyDisplayMode(id),
               current.ioDisplayModeID != state.mode.ioDisplayModeID {
                let restored: Bool
                if let vrr = state.isVariableRefresh,
                   let exact = await ResolutionService.shared.reapply(on: id, where: Self.same(state.mode, isVariableRefresh: vrr)) {
                    restored = exact
                } else {
                    restored = await ResolutionService.shared.reapply(on: id, where: Self.same(state.mode)) ?? false
                }
                Self.log.notice("display \(id, privacy: .public) moved to \(current.width, privacy: .public)x\(current.height, privacy: .public) after the disconnect, restoring \(state.mode.width, privacy: .public)x\(state.mode.height, privacy: .public) @\(Int(state.mode.refreshRate), privacy: .public): \(restored ? "ok" : "failed", privacy: .public)")
            }
            let rotation = CGDisplayRotation(id)
            if rotation != state.rotation {
                let err = SLSSetDisplayRotation(id, Int32(state.rotation))
                Self.log.notice("display \(id, privacy: .public) turned to \(Int(rotation), privacy: .public) degrees after the disconnect, restoring \(Int(state.rotation), privacy: .public): \(err == .success ? "ok" : "failed", privacy: .public)")
            }
            if let hdr = state.hdr, liveHDR(id) != hdr,
               let display = displayManager?.displays.first(where: { $0.displayID == id }) {
                let restored = await BrightnessBoostService.shared.setHDRPreference(hdr, for: display)
                Self.log.notice("display \(id, privacy: .public) switched \(hdr ? "out of" : "into", privacy: .public) HDR after the disconnect, restoring: \(restored ? "ok" : "failed", privacy: .public)")
            }
        }
    }

    /// Reconnects a previously disconnected display and drops it from the disconnected set.
    /// `byUser` is false only for the blackout rescue; a user's Reconnect of the built-in holds
    /// the Tools switch off until the next undock.
    /// The blackout rescue (`byUser` false) skips `connectionQueue`: with no screen lit, it
    /// must not wait behind a change stuck in the DDC hold.
    @discardableResult
    func reconnect(uuid: String, byUser: Bool = true) async -> Result<Void, ToggleError> {
        guard byUser else { return await performReconnect(uuid: uuid, byUser: false) }
        return await connectionQueue.run { await self.performReconnect(uuid: uuid, byUser: true) }
    }

    private func performReconnect(uuid: String, byUser: Bool) async -> Result<Void, ToggleError> {
        guard isSupported else { return .failure(.unsupportedPlatform) }
        guard let index = disconnected.firstIndex(where: { $0.uuid == uuid }) else {
            return .failure(.displayNotFound)
        }
        guard !awaitingLateCommit.contains(uuid), !reapplyInFlight.contains(uuid),
              reconnectInFlight.insert(uuid).inserted else { return .failure(.timedOut) }
        defer { reconnectInFlight.remove(uuid) }
        let record = disconnected[index]
        if onlineID(for: uuid) == nil {
            guard let targetID = reconnectTarget(for: record, rescuingBlackout: !byUser) else {
                return .failure(.displayNotFound)
            }
            let prevRequested = setReconnectRequestedIfNeeded(uuid: uuid, byUser: byUser)
            Self.log.notice("reconnect requested: \(uuid, privacy: .public) id \(targetID, privacy: .public)")
            let result = await setEnabled(true, displayID: targetID)
            if case .failure(.timedOut) = result {
                watchLateReconnect(uuid, byUser: byUser)
                return .failure(.timedOut)
            }
            guard case .success = result else {
                restoreReconnectRequested(uuid: uuid, previous: prevRequested)
                return result
            }
            guard await verifyBackOnline(uuid: uuid, timeout: 2.0) else {
                watchLateReconnect(uuid, byUser: byUser)
                return .failure(.timedOut)
            }
        }
        if byUser, record.isBuiltin == true, SettingsService.shared.disconnectBuiltinWhenDocked {
            standDownUntilUndock = true
        }
        var inputRestoreFailed = false
        if byUser, let returnInput = record.returnInput {
            let restored: Bool
            if let id = onlineID(for: uuid) {
                restored = await DDCService.shared.writeInputAfterReconnect(displayID: id, value: returnInput)
            } else {
                restored = false
            }
            inputRestoreFailed = !restored
        }
        completeReconnect(uuid)
        return inputRestoreFailed ? .failure(.inputRestoreFailed) : .success(())
    }

    private func setReconnectRequestedIfNeeded(uuid: String, byUser: Bool) -> Bool?? {
        guard byUser, let idx = disconnected.firstIndex(where: { $0.uuid == uuid }),
              disconnected[idx].reconnectRequested != true else { return nil }
        let previous = disconnected[idx].reconnectRequested
        disconnected[idx].reconnectRequested = true
        saveDesired()
        return .some(previous)
    }

    private func restoreReconnectRequested(uuid: String, previous: Bool??) {
        guard let previous, let idx = disconnected.firstIndex(where: { $0.uuid == uuid }) else { return }
        disconnected[idx].reconnectRequested = previous
        saveDesired()
    }

    private func completeReconnect(_ uuid: String) {
        disconnected.removeAll { $0.uuid == uuid }
        saveDesired()
        PresetService.shared.noteConnectionChange()
        VirtualDisplayService.shared.evaluateNow(reason: "PhysicalDisplayReconnected")
    }

    /// Prefers the flag captured at disconnect time: in the all-black state, SLSGetDisplayList
    /// has collapsed to a placeholder and CGDisplayIsBuiltin answers garbage for stale IDs.
    private func wasBuiltin(_ record: DisconnectedDisplay, id: CGDirectDisplayID) -> Bool {
        record.isBuiltin ?? (CGDisplayIsBuiltin(id) == 1)
    }

    private func resolveCurrentID(for record: DisconnectedDisplay) -> CGDirectDisplayID? {
        allDisplaysIncludingDisabled().first { cgUUID(for: $0) == record.uuid }
    }

    private func reconnectTarget(for record: DisconnectedDisplay, rescuingBlackout: Bool) -> CGDirectDisplayID? {
        let otherDisconnectedIDs = Set(disconnected.lazy.filter { $0.uuid != record.uuid }.map(\.displayID))
        return PhysicalDisplayReconnectPolicy.resolveTargetID(
            recordDisplayID: record.displayID,
            recordUUID: record.uuid,
            enumerated: enumeratedDisplays(),
            onlineIDs: onlineDisplayIDs(),
            otherDisconnectedIDs: otherDisconnectedIDs,
            rescuingBlackout: rescuingBlackout,
            screensAsleep: screensAsleep,
            activeDisplayCount: rescuingBlackout ? phantomAwareActiveDisplayCount() : 0
        )
    }

    /// Safety net for softReconnect's re-enable retries all failing: sweeps every SLS-disabled
    /// display Crisp didn't disconnect on purpose, so a transient failure can't leave a screen
    /// stuck black. Leaves other apps' intentional disables alone.
    private func reenableUnintentionallyDisabled(includingBlink: String? = nil) async {
        let onlineSet = onlineDisplayIDs()
        let intentionalUUIDs = Set(disconnected.map { $0.uuid })
        for id in allDisplaysIncludingDisabled() where !onlineSet.contains(id) {
            let displayUUID = uuid(for: id)
            guard !intentionalUUIDs.contains(displayUUID) else { continue }
            // A display mid-blink is off on purpose; racing it here would fight its own retry loop.
            guard !softReconnectInFlight.contains(displayUUID) || displayUUID == includingBlink else { continue }
            _ = await setEnabled(true, displayID: id)
        }
    }

    /// Display IDs currently online. SLS-disabled displays are omitted here (see
    /// allDisplaysIncludingDisabled), so "online" doubles as the enabled check.
    private func onlineDisplayIDs() -> Set<CGDirectDisplayID> {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Set(ids.prefix(Int(count)))
    }

    /// True once the display is back in the online list. A successful setEnabled transaction
    /// is NOT proof: around sleep transitions it reports success while still disabled
    /// (verified live). Only enumeration counts.
    private func verifyBackOnline(uuid displayUUID: String, timeout: TimeInterval = 1.0) async -> Bool {
        for _ in 0..<max(Int(timeout * 10), 1) {
            if onlineID(for: displayUUID) != nil { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return onlineID(for: displayUUID) != nil
    }

    private func onlineID(for displayUUID: String) -> CGDirectDisplayID? {
        onlineDisplayIDs().first { uuid(for: $0) == displayUUID }
    }

    /// The disable half of verifyBackOnline, untrustworthy the same way: the transaction
    /// reports what was asked, not what took.
    private func verifyOffline(displayID: CGDirectDisplayID, timeout: TimeInterval) async -> Bool {
        for _ in 0..<max(Int(timeout * 10), 1) {
            if !onlineDisplayIDs().contains(displayID) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// Battery presence is the lid-independent laptop test for Clamshell Sleep: the built-in
    /// panel can vanish from the display list entirely while the lid is closed.
    static let hasBattery: Bool = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }()

    /// Throwaway virtual display held while blinking a portable's sole active display, to
    /// block Clamshell Sleep (see docs/display-notes.md, softReconnect).
    private func makeBlinkSleepGuard() async -> CGVirtualDisplay? {
        let w = 1920, h = 1080, ppi = 110.0
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.sizeInMillimeters = CGSize(width: Double(w) / ppi * 25.4, height: Double(h) / ppi * 25.4)
        descriptor.maxPixelsWide = UInt32(w)
        descriptor.maxPixelsHigh = UInt32(h)
        descriptor.name = "Crisp Blink Guard"
        descriptor.vendorID = VirtualDisplayService.crispVirtualVendorID
        descriptor.productID = 0xB11C
        descriptor.serialNum = 0xB11C
        guard let vd = CGVirtualDisplay(descriptor: descriptor) else { return nil }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = false
        let mode: CGVirtualDisplayMode = CGVirtualDisplayMode(width: UInt(w), height: UInt(h), refreshRate: 60.0)
        settings.modes = [mode]
        let applied: Bool = await CGHelpers.runWithTimeout(seconds: 10, fallback: false) { vd.apply(settings) }
        guard applied, vd.displayID != kCGNullDirectDisplay else { return nil }
        for _ in 0..<20 {
            if onlineDisplayIDs().contains(vd.displayID) { return vd }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    // MARK: - Reconcile / Wake restore

    /// Re-applies a remembered disconnect once its display is back online (reboot, replug, or
    /// macOS re-enabling it) so it doesn't have to be redone by hand every boot (issue #93);
    /// drops the record if it can't take, so the list never claims a lit display is
    /// disconnected. See docs/display-notes.md (reconcile).
    func reconcile() {
        guard !disconnected.isEmpty else { return }
        let onlineIDs = onlineDisplayIDs()
        let onlineUUIDs = Set(onlineIDs.map { uuid(for: $0) })
        let resurfaced = disconnected.filter { onlineUUIDs.contains($0.uuid) }
        guard !resurfaced.isEmpty else {
            // Baseline for restoreStates: a resolution picked in between is what goes back, not a stale one.
            baselineModes = currentStates()
            return
        }
        // Intel has no working disconnect to re-apply; forget the record and keep the UI honest.
        guard isSupported else {
            disconnected.removeAll { onlineUUIDs.contains($0.uuid) }
            saveDesired()
            return
        }
        for record in resurfaced where record.reconnectRequested == true
            && !reconnectInFlight.contains(record.uuid)
            && !awaitingLateCommit.contains(record.uuid) {
            completeReconnect(record.uuid)
        }
        let pending = resurfaced.filter {
            $0.reconnectRequested != true
                && !reapplyInFlight.contains($0.uuid)
                && !softReconnectInFlight.contains($0.uuid)
                && !reconnectInFlight.contains($0.uuid)
                && !awaitingLateCommit.contains($0.uuid)
        }
        guard !pending.isEmpty else { return }
        let leaving = Set(onlineIDs.filter { id in
            let displayUUID = uuid(for: id)
            return pending.contains { $0.uuid == displayUUID }
        })
        pendingPassModes = (baselineModes.isEmpty ? currentStates() : baselineModes)
            .filter { !leaving.contains($0.id) }
        for record in pending {
            reapplyInFlight.insert(record.uuid)
            Task { [weak self] in
                guard let self else { return }
                await self.reapplyRemembered(record.uuid)
                self.reapplyInFlight.remove(record.uuid)
            }
        }
    }

    /// Displays whose remembered disconnect is mid-reapply, so a reconfiguration burst can't
    /// stack a second attempt on the same display.
    private var reapplyInFlight: Set<String> = []

    /// The other displays' modes as of the last refresh with no remembered display online:
    /// the arrangement WindowServer puts back once the remembered display goes off again.
    /// Must be captured before the reapply, not live inside it (measured, not reasoned: #101).
    /// See docs/display-notes.md (restoreStates).
    private var baselineModes: [DisplayState] = []

    /// One restore snapshot per reconcile pass, not one per record (two records each taking
    /// their own landed the same restore twice, 19ms apart).
    private var pendingPassModes: [DisplayState]?

    /// Starts this pass's one restore, once a disable has actually moved things (restoreStates'
    /// window is finite).
    private func startPassRestoreIfNeeded() {
        guard let states = pendingPassModes else { return }
        pendingPassModes = nil
        Task { [weak self] in await self?.restoreStates(states) }
    }

    private func reapplyRemembered(_ recordUUID: String) async {
        guard !reconnectInFlight.contains(recordUUID) else { return }
        guard let liveID = onlineDisplayIDs().first(where: { uuid(for: $0) == recordUUID }) else { return }
        let liveIdentity: DDCServiceMatcher.Identity? = CGDisplayIsBuiltin(liveID) == 1 ? nil : .init(
            vendor: CGDisplayVendorNumber(liveID), product: CGDisplayModelNumber(liveID),
            serial: CGDisplaySerialNumber(liveID), location: DDCService.shared.channelLocation(for: liveID)
        )
        var refused = wouldLeaveNoActiveDisplay(liveID)
        var holdingPreMountedSmartDummy = false
        if !refused && CGDisplayIsOnline(liveID) != 0 && onlinePhysicalDisplayCount() <= 1 {
            let smartDummy = VirtualDisplayService.shared
            if !smartDummy.isSmartDummyMounted {
                if await smartDummy.mountBeforeLastPhysicalDisconnect() {
                    holdingPreMountedSmartDummy = true
                } else {
                    refused = true
                }
            }
        }
        defer {
            if holdingPreMountedSmartDummy { VirtualDisplayService.shared.releaseLastPhysicalDisconnectHold() }
        }
        Self.log.notice("remembered disconnect for \(recordUUID, privacy: .public) id \(liveID, privacy: .public): \(refused ? "refused, it is the last active display" : "re-applying", privacy: .public)")
        var stillOnline = true
        var timedOut = false
        if !refused {
            if case .failure(.timedOut) = await setEnabled(false, displayID: liveID) { timedOut = true }
            startPassRestoreIfNeeded()
            stillOnline = !(await verifyOffline(displayID: liveID, timeout: 4.0))
            if stillOnline { stillOnline = !(await verifyOffline(displayID: liveID, timeout: 2.0)) }
        }
        guard let idx = disconnected.firstIndex(where: { $0.uuid == recordUUID }) else { return }
        if stillOnline, !timedOut, onlineDisplayIDs().contains(liveID) {
            Self.log.notice("record dropped for \(recordUUID, privacy: .public) id \(liveID, privacy: .public): still lit")
            if refused { park(disconnected[idx]) }
            disconnected.remove(at: idx)
        } else {
            disconnected[idx].displayID = liveID
            if let liveIdentity { disconnected[idx].hardwareIdentity = liveIdentity }
        }
        saveDesired()
    }

    private var strandedRecoveryInFlight = false
    private var strandedRecoveryPending = false
    private var lingeringSleepGuard: CGVirtualDisplay?
    private static let settleRepolls = 10
    private static let settleRepollInterval: UInt64 = 100_000_000
    private static let wakeSettleRepolls = 40
    private static let wakeSettleSpan = 15.0
    private var lastWake: DispatchTime?
    private var screensAsleep = false
    private var restoreInFlight = false
    private var parked: DisconnectedDisplay?
    private let parkedKey = "crisp.PhysicalParkedDisconnect"
    private var parkedReapplyInFlight = false
    private var standDownUntilUndock = false
}

// MARK: - Stranded recovery & blackout rescue

extension PhysicalDisplayToggleService {
    /// Recovery for a softReconnect the app died mid-toggle on (crash, force-quit).
    func recoverStrandedSoftReconnect() async {
        guard isSupported else { return }
        if strandedRecoveryInFlight {
            strandedRecoveryPending = true
            return
        }
        guard !pendingSoftReconnects().isEmpty || lingeringSleepGuard != nil else { return }
        strandedRecoveryInFlight = true
        defer { strandedRecoveryInFlight = false }
        repeat {
            strandedRecoveryPending = false
            for marker in pendingSoftReconnects() {
                guard !softReconnectInFlight.contains(marker.uuid) else { continue }
                await recoverStrandedMarker(marker)
            }
            if lingeringSleepGuard != nil, pendingSoftReconnects().isEmpty {
                lingeringSleepGuard = nil
            }
        } while strandedRecoveryPending && (!pendingSoftReconnects().isEmpty || lingeringSleepGuard != nil)
    }

    private func recoverStrandedMarker(_ marker: PendingSoftReconnect) async {
        let onlineIDs = onlineDisplayIDs()
        guard let targetID = PhysicalDisplayReconnectPolicy.resolveStrandedSoftReconnectID(
            markedUUID: marker.uuid, savedDisplayID: marker.displayID,
            enumerated: enumeratedDisplays(), onlineIDs: onlineIDs
        ) else {
            removePendingSoftReconnect(marker.uuid)
            return
        }
        if onlineIDs.contains(targetID) {
            removePendingSoftReconnect(marker.uuid)
            return
        }
        var recovered = false
        for _ in 0..<3 {
            if case .success = await setEnabled(true, displayID: targetID),
               await verifyBackOnline(uuid: marker.uuid) {
                recovered = true
                break
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        if !recovered { await reenableUnintentionallyDisabled() }
        if recovered || onlineID(for: marker.uuid) != nil || onlineDisplayIDs().contains(targetID) {
            removePendingSoftReconnect(marker.uuid)
        }
    }

    private func repollLimit(askedAt asked: DispatchTime) -> Int {
        guard let lastWake, lastWake + Self.wakeSettleSpan > asked else { return Self.settleRepolls }
        return Self.wakeSettleRepolls
    }

    /// Blackout rescue: re-enables a still-attached disconnected display (built-in first) when
    /// zero active displays remain. See docs/display-notes.md (restoreIfNoActiveDisplay).
    func restoreIfNoActiveDisplay() {
        guard isSupported, !disconnected.isEmpty else { return }
        if VirtualDisplayService.shared.isSmartDummyMounted && !canRestoreOpenLidBuiltin {
            Self.log.notice("restore skipped: Smart Dummy is mounted")
            return
        }
        let active = phantomAwareActiveDisplayCount()
        guard !restoreInFlight, active == 0 else {
            Self.log.notice("restore asked with \(self.disconnected.count, privacy: .public) record(s): \(active, privacy: .public) active display(s), in flight \(self.restoreInFlight, privacy: .public), standing down")
            return
        }
        restoreInFlight = true
        let asked = DispatchTime.now()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            defer { self.restoreInFlight = false }
            var settled = self.phantomAwareActiveDisplayCount()
            var repolls = 0
            while settled == 0, repolls < self.repollLimit(askedAt: asked) {
                try? await Task.sleep(nanoseconds: Self.settleRepollInterval)
                guard !Task.isCancelled else { return }
                settled = self.phantomAwareActiveDisplayCount()
                repolls += 1
            }
            guard settled == 0 else {
                Self.log.notice("restore settled: \(settled, privacy: .public) active display(s) after 2 s and \(repolls, privacy: .public) re-poll(s), standing down")
                return
            }
            guard !self.screensAsleep else {
                Self.log.notice("screens asleep, restore stands down: \(self.disconnected.count, privacy: .public) record(s) kept")
                return
            }
            let restoreBuiltin = self.canRestoreOpenLidBuiltin
            guard !VirtualDisplayService.shared.isSmartDummyMounted || restoreBuiltin else {
                Self.log.notice("Smart Dummy mounted during settle window, restore stands down")
                return
            }
            Self.log.notice("no active display, restoring from \(self.disconnected.count, privacy: .public) record(s) after 2 s and \(repolls, privacy: .public) re-poll(s)")
            let smartDummyMounted = VirtualDisplayService.shared.isSmartDummyMounted
            let candidates = self.disconnected
                .filter { !smartDummyMounted || $0.isBuiltin == true }
                .map { record in (record, self.resolveCurrentID(for: record) ?? record.displayID) }
                .sorted { self.wasBuiltin($0.0, id: $0.1) && !self.wasBuiltin($1.0, id: $1.1) }
            for (record, _) in candidates {
                let allowDespiteDummy = record.isBuiltin == true && self.canRestoreOpenLidBuiltin
                let canProceed = !VirtualDisplayService.shared.isSmartDummyMounted || allowDespiteDummy
                guard !self.screensAsleep, canProceed, self.phantomAwareActiveDisplayCount() == 0 else { return }
                guard case .success = await self.reconnect(uuid: record.uuid, byUser: false) else { continue }
                self.park(record)
                for _ in 0..<20 {
                    if self.phantomAwareActiveDisplayCount() > 0 { return }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }
    }
}

// MARK: - Soft reconnect

extension PhysicalDisplayToggleService {

    /// Disables then re-enables a display's framebuffer to force macOS to re-read a freshly
    /// written HiDPI override and re-enumerate modes, without a physical unplug. Leaves
    /// `disconnected` untouched (a re-enumeration blip, not a user disconnect); blinks even
    /// the sole active display, using a throwaway virtual display to block Clamshell Sleep on
    /// portables. See docs/display-notes.md (softReconnect).
    @discardableResult
    func softReconnect(_ display: DisplayInfo) async -> Bool {
        await connectionQueue.run { await self.performSoftReconnect(display) }
    }

    private func performSoftReconnect(_ display: DisplayInfo) async -> Bool {
        guard isSupported else { return false }
        let blinkUUID = display.displayUUID
        // All blinks share the same temporary virtual display identity.
        guard softReconnectInFlight.isEmpty, !strandedRecoveryInFlight,
              !isDisconnected(uuid: blinkUUID) else { return false }
        softReconnectInFlight.insert(blinkUUID)
        var recoveringLateDisable = false
        defer { if !recoveringLateDisable { softReconnectInFlight.remove(blinkUUID) } }
        let startID = onlineID(for: blinkUUID) ?? display.displayID
        let previousMode = CGDisplayCopyDisplayMode(startID)
        let previousVRR = previousMode.flatMap { currentIsVariableRefresh(for: startID, modeID: $0.ioDisplayModeID) }
        var sleepGuard: CGVirtualDisplay?
        if needsBlinkSleepGuard(for: startID) {
            sleepGuard = lingeringSleepGuard
            lingeringSleepGuard = nil
            if sleepGuard == nil { sleepGuard = await makeBlinkSleepGuard() }
            if sleepGuard == nil { return false }
        }
        defer { withExtendedLifetime(sleepGuard) {} }
        Self.log.notice("soft reconnect blink: \(blinkUUID, privacy: .public) id \(startID, privacy: .public)")
        addPendingSoftReconnect(blinkUUID, displayID: startID)
        let (lateDisable, continuation) = AsyncStream<Result<Void, ToggleError>>.makeStream()
        let disabled = await setEnabled(false, displayID: startID, onLateCompletion: {
            continuation.yield($0)
            continuation.finish()
        })
        if case .failure(.timedOut) = disabled {
            recoveringLateDisable = true
            if let sleepGuard { lingeringSleepGuard = sleepGuard }
            recoverAfterLateDisable(lateDisable, uuid: blinkUUID, displayID: startID)
            return false
        }
        continuation.finish()
        guard case .success = disabled else {
            removePendingSoftReconnect(blinkUUID)
            return false
        }
        await ReconfigEvents.shared.next(for: startID, matching: .removeFlag, timeout: 0.9)
        var backOnline = false
        for _ in 0..<3 {
            let targetID = PhysicalDisplayReconnectPolicy.resolveStrandedSoftReconnectID(
                markedUUID: blinkUUID, savedDisplayID: startID,
                enumerated: enumeratedDisplays(), onlineIDs: onlineDisplayIDs()
            ) ?? startID
            Task { _ = await setEnabled(true, displayID: targetID) }
            if await verifyBackOnline(uuid: blinkUUID, timeout: 4.0) { backOnline = true; break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        if !backOnline {
            await reenableUnintentionallyDisabled(includingBlink: blinkUUID)
            backOnline = await verifyBackOnline(uuid: blinkUUID, timeout: 2.0)
        }
        guard backOnline else {
            if sleepGuard != nil { lingeringSleepGuard = sleepGuard }
            return false
        }
        removePendingSoftReconnect(blinkUUID)
        if let previousMode, let backID = onlineID(for: blinkUUID) {
            await restoreBlinkMode(previousMode, isVariableRefresh: previousVRR, displayID: backID)
        }
        return true
    }

    private func needsBlinkSleepGuard(for displayID: CGDirectDisplayID) -> Bool {
        Self.hasBattery && CGDisplayIsActive(displayID) != 0 && physicalActiveDisplayCount() <= 1
            && !VirtualDisplayService.shared.isSmartDummyMounted
    }

    private func recoverAfterLateDisable(
        _ completion: AsyncStream<Result<Void, ToggleError>>, uuid: String, displayID: CGDirectDisplayID
    ) {
        // A display that is still online can disappear until the WindowServer call returns.
        Task {
            for await result in completion {
                if case .success = result {
                    _ = await verifyOffline(displayID: displayID, timeout: 0.9)
                }
                softReconnectInFlight.remove(uuid)
                await recoverStrandedSoftReconnect()
            }
        }
    }

    private func restoreBlinkMode(
        _ previous: CGDisplayMode, isVariableRefresh: Bool?, displayID: CGDirectDisplayID
    ) async {
        // Re-enumeration renumbers every mode ID, so re-find the previous mode by parameters.
        let modes = DisplayMode.availableModes(for: displayID)
        let matches: (DisplayMode) -> Bool
        let target: DisplayMode
        if let vrr = isVariableRefresh,
           let exact = modes.first(where: Self.same(previous, isVariableRefresh: vrr)) {
            matches = Self.same(previous, isVariableRefresh: vrr)
            target = exact
        } else if let fallback = modes.first(where: Self.same(previous)) {
            matches = Self.same(previous)
            target = fallback
        } else {
            return
        }
        for _ in 0..<4 {
            if CGDisplayCopyDisplayMode(displayID)?.ioDisplayModeID == target.id { break }
            _ = await ResolutionService.shared.reapply(on: displayID, where: matches)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// Runs SLSConfigureDisplayEnabled inside a CG transaction with `.permanently` (matching
    /// Lunar BlackOut, screen_tune, BetterDisplay), which is what makes the disconnect stick.
    private func setEnabled(
        _ enabled: Bool, displayID: CGDirectDisplayID,
        onLateCompletion: (@Sendable (Result<Void, ToggleError>) -> Void)? = nil
    ) async -> Result<Void, ToggleError> {
        let action = enabled ? "enable" : "disable"
        let waited = DispatchTime.now()
        // No DDC traffic while this transaction runs: WindowServer's enable can wait behind an
        // in-flight I2C read and freeze the whole machine with it (issue #33).
        // See docs/display-notes.md (PhysicalDisplayToggleService).
        let releaseDDC = await DDCService.shared.hold()
        let heldMs = Self.millisSince(waited)
        if heldMs > Self.slowOpThresholdMs {
            Self.log.notice("\(action, privacy: .public) \(displayID, privacy: .public): waited \(Int(heldMs), privacy: .public) ms for DDC to go idle")
        }
        let result: Result<Void, ToggleError> = await CGHelpers.runWithTimeout(
            seconds: 10, fallback: .failure(.timedOut), onLateCompletion: onLateCompletion
        ) {
            // Released when the transaction returns, which can be after the wrapper gave up:
            // DDC must stay parked while a late commit is still in WindowServer.
            defer { releaseDDC() }
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else {
                Self.log.error("\(action, privacy: .public) \(displayID, privacy: .public): CGBeginDisplayConfiguration failed")
                return .failure(.configurationFailed(.failure))
            }
            let setErr = SLSConfigureDisplayEnabled(cfg, displayID, enabled)
            guard setErr == .success else {
                CGCancelDisplayConfiguration(cfg)
                Self.log.error("\(action, privacy: .public) \(displayID, privacy: .public): SLSConfigureDisplayEnabled failed \(setErr.rawValue, privacy: .public)")
                return .failure(.configurationFailed(setErr))
            }
            // The call that can block: keeps running after the 10s wrapper gives up (it can
            // only stop waiting, not cancel), and WindowServer holding it can stall the whole
            // machine, not just Crisp (issue #33). Timed unconditionally for captures.
            let committing = DispatchTime.now()
            let complete = CGCompleteDisplayConfiguration(cfg, .permanently)
            let commitMs = Self.millisSince(committing)
            guard complete == .success else {
                Self.log.error("\(action, privacy: .public) \(displayID, privacy: .public): commit failed \(complete.rawValue, privacy: .public) after \(Int(commitMs), privacy: .public) ms")
                return .failure(.configurationFailed(complete))
            }
            if commitMs > Self.slowOpThresholdMs {
                Self.log.notice("slow \(action, privacy: .public) \(displayID, privacy: .public): commit took \(Int(commitMs), privacy: .public) ms")
            }
            return .success(())
        }
        // Not the same as what WindowServer will actually do: on a wrapper timeout this
        // reports failure at ~10000ms while the commit keeps running.
        let waitedMs = Self.millisSince(waited)
        if case .failure = result {
            Self.log.notice("\(action, privacy: .public) \(displayID, privacy: .public): reported failure after \(Int(waitedMs), privacy: .public) ms")
        } else {
            Self.log.notice("\(action, privacy: .public) \(displayID, privacy: .public): reported success after \(Int(waitedMs), privacy: .public) ms")
        }
        return result
    }
}

// MARK: - Parked record and persistence

extension PhysicalDisplayToggleService {
    private func park(_ record: DisconnectedDisplay) {
        guard record.isBuiltin == true, record.companions?.isEmpty == false else { return }
        Self.log.notice("parked disconnect for \(record.uuid, privacy: .public), re-applies with \(record.companions?.count ?? 0, privacy: .public) external(s)")
        setParked(record)
    }

    /// Turning the Tools switch off also ends what it set up.
    func clearParked() {
        setParked(nil)
        standDownUntilUndock = false
    }

    /// Called on every refresh and when the Tools switch turns on. Waits 4 s (a display link
    /// handshake runs 2 to 4 s) and looks again before acting, so a dock that is still
    /// settling does not count.
    func reapplyParkedIfDocked() {
        if standDownUntilUndock, !viewableActiveDisplays().contains(where: { CGDisplayIsBuiltin($0) != 1 }) {
            standDownUntilUndock = false
        }
        guard isSupported, !parkedReapplyInFlight, let target = dockTarget(),
              dockedExternal(builtinUUID: target.uuid, companions: target.companions) != nil else { return }
        parkedReapplyInFlight = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self else { return }
            defer { self.parkedReapplyInFlight = false }
            guard let now = self.dockTarget(), now.uuid == target.uuid,
                  let external = self.dockedExternal(builtinUUID: now.uuid, companions: now.companions),
                  let display = self.displayManager?.displays.first(where: { $0.displayUUID == now.uuid })
            else { return }
            let source = now.companions == nil ? "the switch" : "the parked record"
            Self.log.notice("built-in \(now.uuid, privacy: .public) off again by \(source, privacy: .public): \(external, privacy: .public) is active")
            if case .failure(let error) = await self.disconnect(display) {
                Self.log.notice("built-in \(now.uuid, privacy: .public) off again refused: \(error.description, privacy: .public)")
            }
        }
    }

    /// The built-in to switch off and which externals count: any (nil) with the Tools switch
    /// on, otherwise the parked record's own.
    private func dockTarget() -> (uuid: String, companions: Set<String>?)? {
        if SettingsService.shared.disconnectBuiltinWhenDocked {
            guard !standDownUntilUndock,
                  let builtin = displayManager?.displays.first(where: { $0.isBuiltin }) else { return nil }
            return (builtin.displayUUID, nil)
        }
        guard let parked else { return nil }
        return (parked.uuid, Set(parked.companions ?? []))
    }

    /// An external that counts, when the built-in is lit and the rescue's own phantom-aware
    /// count sees at least one display besides it: a #112 phantom at wake carries a real
    /// external's UUID and must not switch the built-in off.
    private func dockedExternal(builtinUUID: String, companions: Set<String>?) -> String? {
        guard let builtinID = onlineDisplayIDs().first(where: { uuid(for: $0) == builtinUUID }),
              CGDisplayIsActive(builtinID) != 0,
              phantomAwareActiveDisplayCount() >= 2 else { return nil }
        return viewableActiveDisplays().filter { $0 != builtinID }.map { uuid(for: $0) }
            .first { companions?.contains($0) ?? true }
    }

    private func setParked(_ record: DisconnectedDisplay?) {
        parked = record
        if let record, let data = try? JSONEncoder().encode(record) {
            UserDefaults.standard.set(data, forKey: parkedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: parkedKey)
        }
    }

    private func loadParked() {
        guard let data = UserDefaults.standard.data(forKey: parkedKey) else { return }
        parked = try? JSONDecoder().decode(DisconnectedDisplay.self, from: data)
    }

    // MARK: - Persistence

    private func saveDesired() {
        guard let data = try? JSONEncoder().encode(disconnected) else { return }
        UserDefaults.standard.set(data, forKey: desiredKey)
    }

    private func loadDesired() {
        guard let data = UserDefaults.standard.data(forKey: desiredKey),
              let decoded = try? JSONDecoder().decode([DisconnectedDisplay].self, from: data)
        else { return }
        disconnected = decoded
        // Nothing is disconnected yet; this only seeds the "Disconnected" UI. The first
        // refresh after launch re-applies it through reconcile(), where the safety rails are.
    }
}

// MARK: - Late commits

extension PhysicalDisplayToggleService {
    /// How long a timed-out change is watched before the record is left as it is.
    private static let lateCommitWindow: TimeInterval = 30

    private func remember(_ snapshot: DisconnectedDisplay) {
        disconnected.removeAll { $0.uuid == snapshot.uuid }
        disconnected.append(snapshot)
        saveDesired()
        if parked?.uuid == snapshot.uuid { setParked(nil) }
    }

    /// A timed-out disconnect: decided by enumeration. If it never lands, reconcile re-applies
    /// the record, or drops it if the display stays lit.
    private func watchLateDisconnect(_ uuid: String, displayID: CGDirectDisplayID, otherStates: [DisplayState]) {
        awaitingLateCommit.insert(uuid)
        Task { [weak self] in
            guard let self else { return }
            let landed = await verifyOffline(displayID: displayID, timeout: Self.lateCommitWindow)
            awaitingLateCommit.remove(uuid)
            Self.log.notice("timed-out disconnect of \(uuid, privacy: .public): \(landed ? "landed late" : "not landed after the late-commit window", privacy: .public)")
            if landed {
                await restoreStates(otherStates)
                VirtualDisplayService.shared.evaluateNow(reason: "PhysicalDisplayLateDisconnected")
            }
            displayManager?.refreshDisplays()
        }
    }

    /// A timed-out reconnect: the record drops once the display is back online. The input is
    /// not written back after a late landing.
    private func watchLateReconnect(_ uuid: String, byUser: Bool) {
        awaitingLateCommit.insert(uuid)
        Task { [weak self] in
            guard let self else { return }
            let landed = await verifyBackOnline(uuid: uuid, timeout: Self.lateCommitWindow)
            if landed {
                if let record = disconnected.first(where: { $0.uuid == uuid }) {
                    if !byUser {
                        park(record)
                    } else if record.isBuiltin == true, SettingsService.shared.disconnectBuiltinWhenDocked {
                        standDownUntilUndock = true
                    }
                }
                completeReconnect(uuid)
            }
            awaitingLateCommit.remove(uuid)
            Self.log.notice("timed-out reconnect of \(uuid, privacy: .public): \(landed ? "landed late, record dropped" : "not landed after the late-commit window", privacy: .public)")
            displayManager?.refreshDisplays()
        }
    }
}

// MARK: - Sleep and wake

extension PhysicalDisplayToggleService {
    /// didWake and screensDidWake both: the blackout restore waits longer near a wake (#168).
    /// willSleep and screensDidSleep: a display enabled while macOS takes the screens down
    /// stays off until logout, so the restore stands down until the next wake (#246).
    private func observeSleepAndWake() {
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            wakeObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.noteWake() }
            })
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            wakeObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensAsleep = true }
            })
        }
    }

    private func noteWake() {
        lastWake = .now()
        screensAsleep = false
        Self.log.notice("wake noted: the blackout restore allows \(Self.wakeSettleRepolls, privacy: .public) re-polls for \(Int(Self.wakeSettleSpan), privacy: .public) s")
        // A rescue that stood down while the screens were asleep gets no callback to re-ask it
        // when only the screens wake (a display sleep, or a keyboard wake in clamshell).
        restoreIfNoActiveDisplay()
    }
}

extension PhysicalDisplayToggleService {
    /// True when the built-in display was disconnected while docked, the lid is open, and an
    /// undock caused Smart Dummy to mount before blackout rescue could restore the built-in panel.
    var canRestoreOpenLidBuiltin: Bool {
        SettingsService.shared.disconnectBuiltinWhenDocked
            && !PowerAndTopologyMonitor.readIsClamshellClosed()
            && disconnected.contains { $0.isBuiltin == true }
    }

    /// Synchronous quit-time safety rail called before `VirtualDisplayService.shared.shutdown()`:
    /// if disconnecting the last physical display relied on Smart Dummy and zero online physical
    /// displays remain, synchronously re-enable a disconnected physical display (built-in first)
    /// so tearing down Smart Dummy never leaves the machine black across exit or reboot.
    func restoreAtLeastOnePhysicalDisplaySync() {
        guard isSupported, !disconnected.isEmpty, onlinePhysicalDisplayCount() == 0 else { return }

        let candidates = disconnected
            .map { record in (record, resolveCurrentID(for: record) ?? record.displayID) }
            .sorted { wasBuiltin($0.0, id: $0.1) && !wasBuiltin($1.0, id: $1.1) }

        for (record, resolvedID) in candidates {
            let candidateIDs = resolvedID == record.displayID ? [resolvedID] : [resolvedID, record.displayID]
            for targetID in candidateIDs {
                var config: CGDisplayConfigRef?
                guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else { continue }
                let setErr = SLSConfigureDisplayEnabled(cfg, targetID, true)
                guard setErr == .success else {
                    CGCancelDisplayConfiguration(cfg)
                    continue
                }
                let completeErr = CGCompleteDisplayConfiguration(cfg, .permanently)
                guard completeErr == .success else { continue }
                Self.log.notice("quit rescue: synchronously restored display \(record.uuid, privacy: .public) id \(targetID, privacy: .public)")
                park(record)
                disconnected.removeAll { $0.uuid == record.uuid }
                saveDesired()
                return
            }
        }
        Self.log.error("quit rescue: failed to synchronously restore any disconnected physical display")
    }

    /// The disconnected displays that are still plugged in, which the panel offers to
    /// reconnect. An unplugged one keeps its record, so a re-plug turns it off again (#101),
    /// but gets no row: Reconnect cannot bring it back.
    var reconnectable: [DisconnectedDisplay] {
        guard disconnected.contains(where: { $0.isBuiltin != true }) else { return disconnected }
        let attached = attachedExternalDisplays()
        let online = displayManager?.displays.filter { !$0.isBuiltin && $0.isOnline } ?? []
        let onlineEntries: [(uuid: String, name: String, identity: DDCServiceMatcher.Identity)] = online.map {
            ($0.displayUUID, $0.name, Self.hardwareIdentity(for: $0))
        }
        return disconnected.filter { record in
            if record.isBuiltin == true { return true }
            let peers = disconnected.filter { $0.uuid != record.uuid && $0.isBuiltin != true }
            let onlinePeers = onlineEntries.filter { $0.uuid != record.uuid }
            let identities = peers.compactMap(\.hardwareIdentity) + onlinePeers.map(\.identity)
            if attached.contains(where: { name, identity in
                if let saved = record.hardwareIdentity, let identity {
                    return saved.matchesAttachment(identity, excluding: identities)
                }
                guard let name, PhysicalDisplayReconnectPolicy.matchesProductName(record.name, productName: name) else { return false }
                return !(peers.map(\.name) + onlinePeers.map(\.name)).contains {
                    PhysicalDisplayReconnectPolicy.matchesProductName($0, productName: name)
                }
            }) {
                return true
            }
            return PhysicalDisplayReconnectPolicy.hasUnclaimedIdenticalAttachment(
                recordName: record.name, savedIdentity: record.hardwareIdentity,
                attached: attached, onlinePeers: onlinePeers.map { ($0.name, $0.identity) }
            )
        }
    }

    private static func hardwareIdentity(for display: DisplayInfo) -> DDCServiceMatcher.Identity {
        let id = display.displayID
        return .init(vendor: CGDisplayVendorNumber(id), product: CGDisplayModelNumber(id),
                     serial: CGDisplaySerialNumber(id), location: DDCService.shared.channelLocation(for: id))
    }

    /// The framebuffer's EDID attributes disappear at unplug, even when SkyLight still lists its ID.
    private func attachedExternalDisplays() -> [(String?, DDCServiceMatcher.Identity?)] {
        var attached: [(String?, DDCServiceMatcher.Identity?)] = []
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferShim"), &iterator
        ) == KERN_SUCCESS else { return attached }
        defer { IOObjectRelease(iterator) }
        var entry = IOIteratorNext(iterator)
        while entry != IO_OBJECT_NULL {
            let attributes = IORegistryEntryCreateCFProperty(
                entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any]
            if let product = attributes?["ProductAttributes"] as? [String: Any] {
                var path = [CChar](repeating: 0, count: 1024)
                let location = IORegistryEntryGetPath(entry, kIOServicePlane, &path) == KERN_SUCCESS
                    ? String(bytes: path.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), encoding: .utf8)
                    : nil
                attached.append((product["ProductName"] as? String,
                                 DDCService.displayIdentity(from: product, location: location)))
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return attached
    }
}
