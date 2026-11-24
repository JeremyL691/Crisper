import Foundation
import os

/// Puts the bundled crisperctl (Contents/MacOS/crisperctl) on the PATH via a symlink into
/// /usr/local/bin, behind the same admin prompt as the HiDPI override (root-owned dir).
@MainActor
enum CrispctlInstaller {
    private static let log = Logger(subsystem: "com.crisper.app", category: "app")
    static let linkPath = "/usr/local/bin/crisperctl"
    static let bundledPath = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/crisperctl").path

    /// A translocated app has a temporary bundle path that would leave a dangling link.
    static var isAvailable: Bool {
        validatedBundledPath() != nil
    }

    /// Only a link pointing to this bundle is managed here.
    static var isInstalled: Bool {
        guard let resolved = validatedBundledPath() else { return false }
        let target = try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
        return target == resolved || target == bundledPath
    }

    @discardableResult
    static func install() -> String? {
        guard let safeTarget = validatedBundledPath() else {
            log.error("crisperctl install refused: bundled binary path failed safety checks")
            return String(localized: "The bundled command line tool is unavailable.")
        }
        if isInstalled { return nil }
        // Try unprivileged first (VS Code's shell command install does the same): works
        // where /usr/local/bin belongs to the user, e.g. Intel Macs with Homebrew.
        if symlink(safeTarget, linkPath) == 0 { return nil }
        if errno == EEXIST {
            return String(localized: "Something already exists at /usr/local/bin/crisperctl.")
        }

        // With the directory as the destination, ln uses the tool's basename and
        // the symlink syscall fails if an entry of any kind already exists there.
        let command = """
        /bin/mkdir -p /usr/local/bin &&
        /bin/ln -sh \(shellQuote(safeTarget)) /usr/local/bin/
        """
        if let error = HiDPIService.shared.executePrivilegedCommand(command) {
            log.error("crisperctl install failed: \(error, privacy: .public)")
            return error
        }
        return nil
    }

    @discardableResult
    static func uninstall() -> String? {
        guard isInstalled, let resolved = validatedBundledPath() else { return nil }
        if unlink(linkPath) == 0 { return nil }
        let command = """
        destination=$(/usr/bin/readlink '\(linkPath)') &&
        { [ "$destination" = \(shellQuote(resolved)) ] || [ "$destination" = \(shellQuote(bundledPath)) ]; } &&
        /bin/rm -f '\(linkPath)'
        """
        if let error = HiDPIService.shared.executePrivilegedCommand(command) {
            log.error("crisperctl uninstall failed: \(error, privacy: .public)")
            return error
        }
        return nil
    }

    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Ensures the bundled CLI binary is a non-translocated regular executable inside a safe,
    /// non-world-writable bundle owned by root or the current user before elevating privileges.
    private static func validatedBundledPath() -> String? {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: bundledPath),
              !bundledPath.contains("/AppTranslocation/") else { return nil }

        let resolvedURL = URL(fileURLWithPath: bundledPath).resolvingSymlinksInPath()
        let resolvedPath = resolvedURL.path
        guard !resolvedPath.isEmpty,
              !resolvedPath.contains("\0"),
              !resolvedPath.contains("\n"),
              !resolvedPath.contains("\r"),
              resolvedPath.hasSuffix("/Contents/MacOS/crisperctl") else { return nil }

        guard let attrs = try? fm.attributesOfItem(atPath: resolvedPath),
              (attrs[.type] as? FileAttributeType) == .typeRegular,
              let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value,
              (perms & 0o022) == 0,
              let ownerID = (attrs[.ownerAccountID] as? NSNumber)?.uint32Value,
              ownerID == 0 || ownerID == getuid() else { return nil }

        let bundleDir = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        guard let dirAttrs = try? fm.attributesOfItem(atPath: bundleDir),
              let dirPerms = (dirAttrs[.posixPermissions] as? NSNumber)?.uint16Value,
              (dirPerms & 0o002) == 0 else { return nil }

        return resolvedPath
    }
}
