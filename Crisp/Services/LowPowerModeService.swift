import Foundation

/// Event-driven Low Power Mode controller backed by `ProcessInfo.isLowPowerModeEnabled`
/// and `PrivilegedHelperService` (`pmset -a lowpowermode 0|1`). Zero polling.
@MainActor
final class LowPowerModeService: ObservableObject {
    static let shared = LowPowerModeService()

    @Published private(set) var isEnabled: Bool = false
    @Published private(set) var isTransitioning: Bool = false
    @Published var lastError: String? = nil

    private var powerStateObserver: NSObjectProtocol?
    private var panelOpenObserver: NSObjectProtocol?

    private init() {
        isEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        observeSystemChanges()
    }

    /// Reads the authoritative macOS Low Power Mode state.
    func refresh() {
        let actual = ProcessInfo.processInfo.isLowPowerModeEnabled
        if isEnabled != actual {
            isEnabled = actual
        }
    }

    /// Toggles macOS Low Power Mode via the privileged helper.
    func toggle() {
        setEnabled(!isEnabled)
    }

    /// Sets macOS Low Power Mode across all power sources (`pmset -a lowpowermode`).
    func setEnabled(_ enabled: Bool) {
        guard !isTransitioning else { return }
        isTransitioning = true
        lastError = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isTransitioning = false }

            let result = await PrivilegedHelperService.shared.execute(
                .setLowPowerMode(enabled: enabled, batteryOnly: false),
                promptIfNeeded: true
            )

            switch result {
            case .success:
                self.isEnabled = enabled
                // Give powerd a brief moment to post NSProcessInfoPowerStateDidChange, then confirm live state.
                try? await Task.sleep(nanoseconds: 150_000_000)
                self.refresh()
            case let .failure(error):
                self.lastError = error == .authorizationCancelled ? nil : error.localizedDescription
                self.refresh()
            }
        }
    }

    private func observeSystemChanges() {
        powerStateObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        panelOpenObserver = NotificationCenter.default.addObserver(
            forName: .crispPanelDidOpen,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
}
