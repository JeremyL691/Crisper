import Foundation
import CoreGraphics
import os.log

/// Manages display configuration presets: save, load, and one-click apply.
@MainActor
final class PresetService: ObservableObject, @unchecked Sendable {
    static let shared = PresetService()
    private static let log = Logger(subsystem: "com.crisp.app", category: "preset")

    @Published private(set) var presets: [DisplayPreset] = []
    @Published var isApplying: Bool = false
    @Published var applyingPresetID: UUID? = nil
    @Published private(set) var operationError: String?

    /// Preset the user last applied. Shown as checked in the UI until any manual
    /// brightness/resolution/arrangement change invalidates it. Session-only.
    @Published var activePresetID: UUID? = nil

    /// Called by services when the user manually changes something a preset controls.
    func noteManualChange() {
        guard !isApplying else { return }
        if activePresetID != nil { activePresetID = nil }
    }

    /// A display turned on or off outside a preset: only a preset that controls
    /// connection (#211) stops being the active one.
    func noteConnectionChange() {
        guard let id = activePresetID, presets.first(where: { $0.id == id })?.includesConnection == true else { return }
        noteManualChange()
    }

    private let filename = "presets.json"

    private init() {
        loadPresets()
    }

    // MARK: - Persistence

    private func loadPresets() {
        presets = SettingsService.shared.load([DisplayPreset].self, filename: filename) ?? []
    }

    private func storePresets(_ updated: [DisplayPreset]) -> Bool {
        do {
            try SettingsService.shared.save(updated, filename: filename)
        } catch {
            Self.log.error("Could not save presets: \(error.localizedDescription, privacy: .public)")
            operationError = String(localized: "Could not save presets. Try again.")
            return false
        }
        presets = updated
        operationError = nil
        return true
    }

    // MARK: - CRUD

    func addPreset(_ preset: DisplayPreset) -> Bool {
        storePreset(preset, replacing: nil)
    }

    @discardableResult
    func deletePreset(id: UUID) -> Bool {
        guard applyingPresetID != id else { return false }
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return false }
        var updated = presets
        updated.remove(at: index)
        guard storePresets(updated) else { return false }
        if activePresetID == id { activePresetID = nil }
        HotkeyService.shared.syncRegistrations()
        return true
    }

    // MARK: - Shortcuts (issue #61)

    private func storePreset(_ preset: DisplayPreset, replacing index: Int?) -> Bool {
        var updated = presets
        if let shortcut = preset.shortcut {
            for i in updated.indices where i != index && updated[i].shortcut?.sameKeys(as: shortcut) == true {
                updated[i].shortcut = nil
            }
        }
        if let index {
            updated[index] = preset
        } else {
            updated.append(preset)
        }
        guard storePresets(updated) else { return false }
        if let shortcut = preset.shortcut { SettingsService.shared.clearStaticShortcuts(matching: shortcut) }
        HotkeyService.shared.syncRegistrations()
        return true
    }

    func releaseShortcut(_ shortcut: KeyboardShortcut) -> Bool {
        let conflicting = presets.indices.filter { presets[$0].shortcut?.sameKeys(as: shortcut) == true }
        guard !conflicting.isEmpty else { return true }
        var updated = presets
        for i in conflicting { updated[i].shortcut = nil }
        return storePresets(updated)
    }

    /// Overwrites a user preset with the current display state (name, icon, and
    /// which attributes it controls are kept).
    @discardableResult
    func updatePreset(id: UUID) -> Bool {
        guard applyingPresetID != id else { return false }
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return false }
        var updated = presets
        let captures = Set(PresetCapture.allCases.filter { updated[index].includes($0) })
        updated[index].displays = captureDisplays(captures)
        guard storePresets(updated) else { return false }
        // The preset now matches the current state by definition.
        activePresetID = id
        return true
    }

    /// Identity (name/icon/color) updates directly; a capture is only dropped or
    /// re-captured when its inclusion actually changed, so captures left alone keep
    /// their stored values across a rename.
    func editPreset(id: UUID, name: String, icon: String, colorName: String?,
                    captures: Set<PresetCapture>, recapture: Bool, shortcut: KeyboardShortcut?) -> Bool {
        operationError = nil
        guard applyingPresetID != id else { return false }
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return false }
        var preset = presets[index]
        preset.name = name
        preset.icon = icon
        preset.colorName = colorName
        preset.shortcut = shortcut
        let changed = PresetCapture.allCases.filter { preset.includes($0) != captures.contains($0) }
        if recapture {
            preset.displays = captureDisplays(captures)
        } else {
            for capture in changed {
                setCapture(capture, included: captures.contains(capture), in: &preset)
            }
        }
        guard storePreset(preset, replacing: index) else { return false }
        if recapture {
            activePresetID = id
        } else if !changed.isEmpty, activePresetID == id {
            activePresetID = nil
        }
        return true
    }

    /// Turning a capture off drops its stored value (nil, so apply skips it); turning it
    /// back on re-captures the live value. An offline display can't be re-captured.
    private func setCapture(_ capture: PresetCapture, included: Bool, in preset: inout DisplayPreset) {
        let displays = DisplayManagerAccessor.shared.displays
        preset.displays = preset.displays.map { entry in
            var e = entry
            guard included else {
                e.clear(capture)
                return e
            }
            if capture == .connection, PhysicalDisplayToggleService.shared.isDisconnected(uuid: entry.displayUUID) {
                e.connected = false
                return e
            }
            guard let live = displays.first(where: { entry.matchesDisplay(uuid: $0.presetUUID) && $0.isOnline }) else {
                return e
            }
            switch capture {
            case .resolution:
                let mode = live.currentDisplayMode
                e.width = mode?.width ?? live.pixelWidth
                e.height = mode?.height ?? live.pixelHeight
                e.isHiDPI = mode?.isHiDPI ?? false
                e.refreshRate = mode?.refreshRate
            case .brightness:
                e.brightness = live.brightness / 100.0
            case .arrangement:
                e.arrangementX = live.bounds.origin.x
                e.arrangementY = live.bounds.origin.y
            case .imageAdjustment:
                e.imageAdjustment = imageAdjustment(of: live)
            case .hdr:
                e.hdr = hdr(of: live)
            case .connection:
                e.connected = true
            case .color:
                e.color = color(of: live)
            }
            return e
        }
        if capture == .connection, included {
            preset.displays += offEntries(excluding: preset.displays)
        }
    }

    // MARK: - Apply

    /// Applies a preset: for each entry, finds the matching display and applies settings.
    @discardableResult
    func applyPreset(_ preset: DisplayPreset) async -> Bool {
        guard !isApplying else { return false }
        isApplying = true
        applyingPresetID = preset.id
        activePresetID = nil
        operationError = nil
        defer {
            isApplying = false
            applyingPresetID = nil
        }

        let displays: [DisplayInfo]
        do {
            displays = try await applyConnection(of: preset).get()
        } catch {
            activePresetID = nil
            operationError = error.description
            Self.log.error("Could not apply preset connections: \(error.description, privacy: .public)")
            return false
        }

        for entry in preset.displays {
            guard let display = displays.first(where: { entry.matchesDisplay(uuid: $0.presetUUID) }),
                  display.isOnline else { continue }
            let displayID = display.displayID

            // Resolution applies only when the preset includes it (width present); the
            // built-in is driven too, resolving to the alreadyActive no-op if unchanged.
            if let w = entry.width, let h = entry.height, let route = entry.resolutionRoute(
                modes: display.availableModes.map { ($0.width, $0.height, $0.isHiDPI) },
                mirrorStops: MirroredModeService.beyondCapStops(for: display)
            ) {
                Self.log.info("display \(displayID): \(w)x\(h) hiDPI \(entry.isHiDPI ?? false), route \(String(describing: route), privacy: .public)")
                switch route {
                case .mode(let index):
                    MirroredModeService.shared.forgetSaved(for: display)
                    let candidate = display.availableModes[index]
                    let preferredRate = VirtualDisplayService.shared.configuredRefreshRate(for: displayID)
                    let mode = display.availableModes.first(where: { mode in
                        mode.width == candidate.width && mode.height == candidate.height
                            && mode.isHiDPI == candidate.isHiDPI
                            && preferredRate.map { abs($0 - mode.refreshRate) < 0.5 } == true
                    }) ?? candidate
                    let currentMode = preferredRate == nil
                        ? display.currentDisplayMode : DisplayMode.currentMode(for: displayID)
                    let alreadyActive = currentMode?.width == mode.width
                        && currentMode?.height == mode.height
                        && currentMode?.isHiDPI == mode.isHiDPI
                        && (preferredRate == nil || abs((currentMode?.refreshRate ?? 0) - mode.refreshRate) < 0.5)
                    if !alreadyActive {
                        // Unmirror first (#65) or WindowServer redirects the change to the
                        // virtual source; a failed unmirror leaves the resolution alone.
                        var unmirrored = true
                        if MirroredModeService.shared.isActive(for: displayID) {
                            unmirrored = await MirroredModeService.shared.restore(display: display)
                        }
                        if unmirrored, await ResolutionService.shared.setDisplayMode(mode, for: displayID) {
                            // refreshDisplays() doesn't re-read the current mode for
                            // already-present displays, so write it back here (as the manual
                            // switch does) or the panel keeps showing the old resolution.
                            display.currentDisplayMode = mode
                        }
                    }
                case .mirror:
                    // A beyond-cap size (#65) never enumerates on the physical panel;
                    // mirror mode is the only route there.
                    await MirroredModeService.shared.apply(display: display, width: w, height: h)
                case .unavailable:
                    break
                }
            }

            // Before brightness: a reference preset fixes the panel's brightness.
            applyColor(entry.color, to: display)

            // After the mode, as the disconnect restore does, and before brightness:
            // the switch moves brightness between DDC and software dimming.
            if let hdr = entry.hdr, BrightnessBoostService.shared.isHDREnabled(for: display) != hdr {
                await BrightnessBoostService.shared.setHDRPreference(hdr, for: display)
            }

            // Convert 0.0-1.0 to the 0-100 range BrightnessService uses; fades over 0.5s
            // instead of snapping.
            if let brightness = entry.brightness {
                BrightnessService.shared.setBrightnessSmooth(
                    brightness * 100.0,
                    for: display,
                    isAutoAdjust: false,
                    duration: 0.5
                )
            }

            if let x = entry.arrangementX, let y = entry.arrangementY {
                _ = await ArrangementService.shared.setPosition(
                    x: Int(x), y: Int(y), for: displayID
                )
            }

            if let adjustment = entry.imageAdjustment {
                GammaService.shared.set(adjustment, for: display, fade: 0.5)
            }
        }

        await applyVirtualRefreshRates(of: preset, displays: displays)
        activePresetID = preset.id
        return true
    }

    private func applyVirtualRefreshRates(of preset: DisplayPreset, displays: [DisplayInfo]) async {
        for display in displays where display.isOnline {
            guard VirtualDisplayService.shared.isVirtualDisplay(display.displayID),
                  preset.displays.contains(where: {
                      $0.matchesDisplay(uuid: display.presetUUID) && ($0.width != nil || $0.connected == true)
                  }) else { continue }
            await VirtualDisplayService.shared.applyConfiguredRefreshRate(for: display.displayID)
            display.currentDisplayMode = DisplayMode.currentMode(for: display.displayID)
        }
    }

    /// Turns displays on and off before the other settings (#211), so those land on the
    /// display set the preset was saved with. Returns the display list after the change.
    /// Smart Dummy is autonomous (Auto-Yield + AC-only), so applying a preset never toggles it.
    private func applyConnection(of preset: DisplayPreset) async -> Result<[DisplayInfo], PhysicalDisplayToggleService.ToggleError> {
        let toggle = PhysicalDisplayToggleService.shared
        let virtual = VirtualDisplayService.shared
        let virtualUUIDs = Set(virtual.configs.map { CrispVirtualDisplayIdentity.canonicalUUID($0.displayUUID) })
        let displays = DisplayManagerAccessor.shared.displays
        let plan = preset.connectionPlan(
            online: Set(displays.filter { $0.isOnline && !virtual.isVirtualDisplay($0.displayID) }.map(\.presetUUID)),
            disconnected: Set(toggle.disconnected.map(\.uuid))
        )
        let reconnect = plan.reconnect.filter { !virtualUUIDs.contains($0) }
        let disconnect = plan.disconnect.filter { !virtualUUIDs.contains($0) }
        // An unsuccessful reconnect must not be followed by disconnecting the fallback screen.
        for uuid in reconnect {
            let storedUUID = toggle.disconnected.first {
                CrispVirtualDisplayIdentity.canonicalUUID($0.uuid) == uuid
            }?.uuid ?? uuid
            if case .failure(let error) = await InputSwitchService.shared.reconnect(uuid: storedUUID) {
                toggle.displayManager?.refreshDisplays()
                return .failure(error)
            }
        }
        if !reconnect.isEmpty {
            toggle.displayManager?.refreshDisplays()
            let online = Set(DisplayManagerAccessor.shared.displays.filter(\.isOnline).map {
                CrispVirtualDisplayIdentity.canonicalUUID($0.displayUUID)
            })
            guard Set(reconnect).isSubset(of: online) else { return .failure(.displayNotFound) }
        }
        for uuid in disconnect {
            guard let display = DisplayManagerAccessor.shared.displays.first(where: {
                CrispVirtualDisplayIdentity.canonicalUUID($0.displayUUID) == uuid && $0.isOnline
            }) else { return .failure(.displayNotFound) }
            if case .failure(let error) = await toggle.disconnect(display, fromPreset: true) {
                toggle.displayManager?.refreshDisplays()
                return .failure(error)
            }
        }
        toggle.displayManager?.refreshDisplays()
        let refreshed = DisplayManagerAccessor.shared.displays
        // refreshDisplays loads a returning display's modes in the background; the
        // resolution below needs them now.
        for display in refreshed where reconnect.contains(CrispVirtualDisplayIdentity.canonicalUUID(display.displayUUID)) {
            await display.loadDetails()
        }
        return .success(refreshed)
    }

    // MARK: - Capture

    /// Snapshots all current online displays into a new preset. The include
    /// flags decide which attributes the preset controls; an excluded attribute
    /// is stored as nil and won't be touched on apply.
    func captureCurrentState(name: String, icon: String, captures: Set<PresetCapture>) -> DisplayPreset {
        DisplayPreset(name: name, icon: icon, displays: captureDisplays(captures))
    }

    private func captureDisplays(_ captures: Set<PresetCapture>) -> [DisplayPresetEntry] {
        let displays = DisplayManagerAccessor.shared.displays
        var entries: [DisplayPresetEntry] = displays.compactMap { display in
            guard display.isOnline else { return nil }
            let mode = display.currentDisplayMode
            return DisplayPresetEntry(
                displayUUID: display.presetUUID,
                width: captures.contains(.resolution) ? (mode?.width ?? display.pixelWidth) : nil,
                height: captures.contains(.resolution) ? (mode?.height ?? display.pixelHeight) : nil,
                isHiDPI: captures.contains(.resolution) ? (mode?.isHiDPI ?? false) : nil,
                refreshRate: captures.contains(.resolution) ? mode?.refreshRate : nil,
                brightness: captures.contains(.brightness) ? display.brightness / 100.0 : nil,
                arrangementX: captures.contains(.arrangement) ? display.bounds.origin.x : nil,
                arrangementY: captures.contains(.arrangement) ? display.bounds.origin.y : nil,
                imageAdjustment: captures.contains(.imageAdjustment) ? imageAdjustment(of: display) : nil,
                hdr: captures.contains(.hdr) ? hdr(of: display) : nil,
                connected: captures.contains(.connection) ? true : nil,
                color: captures.contains(.color) ? color(of: display) : nil
            )
        }
        if captures.contains(.connection) { entries += offEntries(excluding: entries) }
        return entries
    }

    /// Physical displays Crisper disconnected, not already in `entries`, store only that they are off.
    /// Smart Dummy is autonomous and excluded from preset connection capture.
    private func offEntries(excluding entries: [DisplayPresetEntry]) -> [DisplayPresetEntry] {
        PhysicalDisplayToggleService.shared.disconnected
            .filter { record in !entries.contains { $0.matchesDisplay(uuid: record.uuid) } }
            .map { DisplayPresetEntry(displayUUID: $0.uuid, connected: false) }
    }

    /// A display's Image Adjustment as a preset stores it: the saved values without
    /// pause, neutral when it has none.
    private func imageAdjustment(of display: DisplayInfo) -> GammaAdjustment {
        var adjustment = GammaService.shared.loadSavedState(for: display) ?? GammaAdjustment()
        adjustment.isPaused = false
        return adjustment
    }

    /// The HDR switch as a preset stores it; nil for a display without the HDR row.
    private func hdr(of display: DisplayInfo) -> Bool? {
        let boost = BrightnessBoostService.shared
        return boost.isEligibleForHDRToggle(display) ? boost.isHDREnabled(for: display) : nil
    }

    /// A display's color as the card shows it (#226): the active reference preset on a display
    /// that has them, else the ICC profile; nil when neither reads.
    private func color(of display: DisplayInfo) -> PresetColor? {
        let presets = DisplayPresetService.shared.presets(for: display.displayID)
        guard presets.isEmpty else {
            let active = DisplayPresetService.shared.activePresetIndex(for: display.displayID)
            return presets.first { $0.index == active }.map { .referencePreset(index: $0.index, name: $0.name) }
        }
        return ColorProfileService.shared.currentProfileURL(for: display.displayID)
            .map { .profile(path: $0.path) }
    }

    /// Sets a saved color, skipping a reference preset or profile file that is gone.
    private func applyColor(_ color: PresetColor?, to display: DisplayInfo) {
        guard let color else { return }
        let displayID = display.displayID
        switch color {
        case .referencePreset(let index, let name):
            let service = DisplayPresetService.shared
            guard let target = PresetColor.referencePresetIndex(
                index: index, name: name,
                in: service.presets(for: displayID).map { ($0.index, $0.name) }
            ) else {
                Self.log.info("display \(displayID): reference preset \(index) \(name, privacy: .public) is gone")
                return
            }
            if service.activePresetIndex(for: displayID) != target {
                service.setActivePreset(index: target, for: displayID)
            }
        case .profile(let path):
            guard ColorProfileService.shared.currentProfileURL(for: displayID)?.path != path else { return }
            guard let profile = ICCProfile(url: URL(fileURLWithPath: path)) else {
                Self.log.info("display \(displayID): color profile \(path, privacy: .public) is gone")
                return
            }
            ColorProfileService.shared.setProfile(profile, for: displayID)
        }
    }

    /// Whether any online display has the HDR row: the save form shows the HDR capture only then.
    var anyHDRDisplay: Bool {
        DisplayManagerAccessor.shared.displays.contains { $0.isOnline && hdr(of: $0) != nil }
    }

    /// Whether any online display has an Image Adjustment: the save form's default
    /// for including it, so a preset only controls it when there is something to keep.
    var anyImageAdjustment: Bool {
        DisplayManagerAccessor.shared.displays.contains { $0.isOnline && !imageAdjustment(of: $0).isNeutral }
    }

    /// Returns the preset ID that matches the current display state, if any.
    func currentPresetMatch() -> UUID? {
        let displays = DisplayManagerAccessor.shared.displays
        let virtual = VirtualDisplayService.shared
        let disconnected = Set((PhysicalDisplayToggleService.shared.disconnected.map(\.uuid)
            + virtual.configs.filter { !virtual.isActive($0.id) }.map(\.displayUUID))
            .map(CrispVirtualDisplayIdentity.canonicalUUID))
        for preset in presets {
            // Match is resolution-defined; brightness/arrangement-only presets don't participate.
            guard preset.includesResolution else { continue }
            let matches = preset.displays.allSatisfy { entry in
                if entry.connected == false { return disconnected.contains(entry.stableDisplayUUID) }
                guard let display = displays.first(where: { entry.matchesDisplay(uuid: $0.presetUUID) }),
                      display.isOnline else { return false }
                // Entry without a resolution doesn't gate on it
                guard let w = entry.width, let h = entry.height else { return true }
                let mode = display.currentDisplayMode
                return mode?.width == w && mode?.height == h
            }
            if matches && !preset.displays.isEmpty { return preset.id }
        }
        return nil
    }

}
