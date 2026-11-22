import Combine
import Foundation

/// Local no-op updater stub for Crisper. Upstream Sparkle checks against
/// crispmac.app are intentionally disabled so Crisper stays self-contained
/// and never overwrites itself with upstream Crisp builds.
@MainActor
final class UpdateService: NSObject, ObservableObject {
    static let shared = UpdateService()

    // Current app bundle version (CFBundleShortVersionString)
    let currentVersion: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }()

    @Published var hasUpdate: Bool = false
    @Published var latestVersion: String? = nil

    private override init() {
        super.init()
    }

    // MARK: - Install

    /// No-op stub retained for call-site compatibility.
    func installUpdate() {}
}
