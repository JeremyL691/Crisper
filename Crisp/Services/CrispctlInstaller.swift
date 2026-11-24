import Foundation
import os

/// Puts the bundled crisperctl (Contents/MacOS/crisperctl) on the PATH via a symlink into
/// /usr/local/bin, behind the same admin prompt as the HiDPI override (root-owned dir).
@MainActor
enum CrispctlInstaller {
    private static let log = Logger(subsystem: "com.crisper.app", category: "app")
    static let linkPath = "/usr/local/bin/crisperctl"
    static let bundledPath = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/crisperctl").path

    /// False on a dev build (dev.sh swaps the app binary only) and while the app
    /// runs translocated from a DMG or Downloads, where the bundle path is a
    /// temporary mount and a link to it would dangle on the next launch.
    static var isAvailable: Bool {
        validatedBundledPath() != nil
    }

    /// The link must point at this bundle: a moved app offers the install again.
    static var isInstalled: Bool {
        guard let resolved = validatedBundledPath() else { return false }
        let target = try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
        return target == resolved || target == bundledPath
    }

    static func install() {
        guard let safeTarget = validatedBundledPath() else {
            log.error("crisperctl install refused: bundled binary path failed safety checks")
            return
        }
        // Try unprivileged first (VS Code's shell command install does the same): works
        // where /usr/local/bin belongs to the user, e.g. Intel Macs with Homebrew.
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: linkPath)) != nil { try? fm.removeItem(atPath: linkPath) }
        if (try? fm.createSymbolicLink(atPath: linkPath, withDestinationPath: safeTarget)) != nil { return }

        // HiDPIService.executePrivilegedCommand escapes for AppleScript internally; only single-quote for sh.
        let shellPath = safeTarget.replacingOccurrences(of: "'", with: "'\\''")
        let command = "/bin/mkdir -p /usr/local/bin && /bin/ln -sfn '\(shellPath)' '\(linkPath)'"
        if let error = HiDPIService.shared.executePrivilegedCommand(command) {
            log.error("crisperctl install failed: \(error, privacy: .public)")
        }
    }

    /// Removes the link; a regular file at that path is not ours and is left alone.
    static func uninstall() {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath)) != nil else { return }
        if (try? FileManager.default.removeItem(atPath: linkPath)) != nil { return }
        if let error = HiDPIService.shared.executePrivilegedCommand("/bin/rm -f '\(linkPath)'") {
            log.error("crisperctl uninstall failed: \(error, privacy: .public)")
        }
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
