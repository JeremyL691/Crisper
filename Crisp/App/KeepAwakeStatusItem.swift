import AppKit
import Combine

/// The opt-in cup in the menu bar: a click toggles Keep Awake on or off,
/// and a right click opens a menu to switch between Always Awake and On AC Power.
@MainActor
final class KeepAwakeStatusItem: NSObject {
    private var item: NSStatusItem?
    private var cancellable: AnyCancellable?

    override init() {
        super.init()
        let keepAwake = KeepAwakeService.shared
        cancellable = SettingsService.shared.$showKeepAwakeInMenuBar
            .combineLatest(keepAwake.$isActive, keepAwake.$config, keepAwake.$phase)
            .sink { [weak self] shown, active, _, _ in
                self?.update(shown: shown && !KeepAwakeService.isDisabledByPolicy, active: active)
            }
    }

    private func update(shown: Bool, active: Bool) {
        guard shown else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        let item = self.item ?? makeItem()
        self.item = item
        let icon = NSImage(
            systemSymbolName: active ? "cup.and.saucer.fill" : "cup.and.saucer",
            accessibilityDescription: String(localized: "Keep Awake")
        )
        icon?.isTemplate = true
        item.button?.image = icon
    }

    private func makeItem() -> NSStatusItem {
        let length = SystemLook.isMacOS27OrLater ? NSStatusItem.variableLength : NSStatusItem.squareLength
        let item = NSStatusBar.system.statusItem(withLength: length)
        item.autosaveName = "crisp.keepAwake"
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        return item
    }

    @objc private func clicked() {
        let keepAwake = KeepAwakeService.shared
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        guard wantsMenu, let item else {
            keepAwake.setEnabled(!keepAwake.isEnabled)
            return
        }
        item.menu = makeMenu()
        item.button?.performClick(nil)
        item.menu = nil
    }

    private func makeMenu() -> NSMenu {
        let keepAwake = KeepAwakeService.shared
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: statusHeaderTitle(for: keepAwake)))
        for mode in KeepAwakeMode.allCases {
            let entry = NSMenuItem(title: modeTitle(mode), action: #selector(pickMode(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = mode.rawValue
            entry.state = keepAwake.mode == mode ? .on : .off
            menu.addItem(entry)
        }
        if keepAwake.isEnabled {
            menu.addItem(.separator())
            let off = NSMenuItem(title: String(localized: "Turn Off"), action: #selector(turnOff), keyEquivalent: "")
            off.target = self
            menu.addItem(off)
        }
        return menu
    }

    private func statusHeaderTitle(for keepAwake: KeepAwakeService) -> String {
        switch keepAwake.phase {
        case .active:
            return keepAwake.mode == .alwaysAwake
                ? String(localized: "Always Awake")
                : String(localized: "Active · On AC Power")
        case .suspendedOnBattery:
            return String(localized: "Paused on battery · Resumes on AC")
        case .disabled:
            return String(localized: "Keep Awake")
        }
    }

    private func modeTitle(_ mode: KeepAwakeMode) -> String {
        switch mode {
        case .alwaysAwake:
            return String(localized: "Always Awake")
        case .onACPower:
            return String(localized: "On AC Power")
        }
    }

    @objc private func pickMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = KeepAwakeMode(rawValue: raw) else { return }
        KeepAwakeService.shared.selectMode(mode)
    }

    @objc private func turnOff() {
        KeepAwakeService.shared.setEnabled(false)
    }
}
