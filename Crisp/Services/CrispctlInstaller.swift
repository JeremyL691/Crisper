import Darwin
import Foundation
import os

/// Puts the bundled crisperctl (Contents/MacOS/crisperctl) on the PATH via a symlink into
/// /usr/local/bin, behind the same admin prompt as the HiDPI override (root-owned dir).
@MainActor
enum CrispctlInstaller {
    private static let log = Logger(subsystem: "com.crisper.app", category: "app")
    static let linkPath = CrispctlInstallCommand.defaultLinkPath
    static let bundledPath = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/crisperctl").path

    /// A translocated app has a temporary bundle path that would leave a dangling link.
    static var isAvailable: Bool {
        validatedBundledPath() != nil
    }

    /// Only a link pointing to this bundle is managed here.
    static var isInstalled: Bool {
        guard let resolved = validatedBundledPath(),
              CrispctlInstallCommand.hasSafeParents(forLinkPath: linkPath) else { return false }
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
        switch CrispctlInstallCommand.inspectLink(at: linkPath) {
        case .blocked:
            return String(localized: "Something already exists at /usr/local/bin/crisperctl.")
        case .replaceableDanglingCrisperSymlink:
            if unlink(linkPath) == 0, symlink(safeTarget, linkPath) == 0 { return nil }
            if errno != EACCES && errno != EPERM {
                return String(localized: "Something already exists at /usr/local/bin/crisperctl.")
            }
        case .missing:
            // Try unprivileged first (VS Code's shell command install does the same): works
            // where /usr/local/bin belongs to the user, e.g. Intel Macs with Homebrew.
            if symlink(safeTarget, linkPath) == 0 { return nil }
            if errno == EEXIST {
                return String(localized: "Something already exists at /usr/local/bin/crisperctl.")
            }
        }

        guard let command = CrispctlInstallCommand.installScript(targetPath: safeTarget) else {
            log.error("crisperctl install refused: could not build install command")
            return String(localized: "The bundled command line tool is unavailable.")
        }
        if let error = HiDPIService.shared.executePrivilegedCommand(command) {
            log.error("crisperctl install failed: \(error, privacy: .public)")
            return error
        }
        return nil
    }

    @discardableResult
    static func uninstall() -> String? {
        guard isInstalled, let resolved = validatedBundledPath() else { return nil }
        guard CrispctlInstallCommand.hasSafeParents(forLinkPath: linkPath) else {
            return String(localized: "Something already exists at /usr/local/bin/crisperctl.")
        }
        if unlink(linkPath) == 0 { return nil }
        guard let command = CrispctlInstallCommand.uninstallScript(
            resolvedTargetPath: resolved,
            bundledPath: bundledPath
        ) else {
            return String(localized: "The bundled command line tool is unavailable.")
        }
        if let error = HiDPIService.shared.executePrivilegedCommand(command) {
            log.error("crisperctl uninstall failed: \(error, privacy: .public)")
            return error
        }
        return nil
    }

    private static func validatedBundledPath() -> String? {
        CrispctlInstallCommand.validatedBundledPath(bundledPath)
    }
}
