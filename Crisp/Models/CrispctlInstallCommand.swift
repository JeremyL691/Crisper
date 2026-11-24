import Darwin
import Foundation

/// Pure path validation and privileged shell script builder for installing/removing `crisperctl`.
enum CrispctlInstallCommand {
    static let defaultBinDirectory = "/usr/local/bin"
    static let linkName = "crisperctl"
    static let defaultLinkPath = "\(defaultBinDirectory)/\(linkName)"

    enum ExistingLinkStatus: Equatable {
        case missing
        case replaceableDanglingCrisperSymlink
        case blocked
    }

    static func linkPath(in binDirectory: String = defaultBinDirectory) -> String {
        let normalized = normalizedDirectory(binDirectory)
        return "\(normalized)/\(linkName)"
    }

    static func isSafePath(_ path: String) -> Bool {
        !path.isEmpty && !path.contains("\0") && !path.contains("\n") && !path.contains("\r")
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// True only for an absolute path targeting a bundled `Crisper.app` or `Crisp.app` CLI binary.
    static func isManagedAppTarget(_ target: String) -> Bool {
        guard isSafePath(target), target.hasPrefix("/") else { return false }
        return target.hasSuffix("/Crisper.app/Contents/MacOS/crisperctl")
            || target.hasSuffix("/Crisp.app/Contents/MacOS/crisperctl")
    }

    /// Validates both the raw `bundledPath` and its symlink-resolved path:
    /// - rejects control characters (`\0`, `\n`, `\r`) and AppTranslocation paths;
    /// - verifies the resolved binary is a regular executable file inside `*.app/Contents/MacOS/crisperctl`;
    /// - verifies ownership (`uid == 0 || uid == currentUID`) and no world-write (`0o002`) across
    ///   the binary, `Contents/MacOS`, `Contents`, and the `.app` bundle root.
    static func validatedBundledPath(
        _ bundledPath: String,
        fileManager: FileManager = .default,
        currentUID: uid_t = geteuid()
    ) -> String? {
        guard isSafePath(bundledPath),
              !bundledPath.contains("/AppTranslocation/"),
              fileManager.isExecutableFile(atPath: bundledPath) else { return nil }

        let resolvedURL = URL(fileURLWithPath: bundledPath).resolvingSymlinksInPath()
        let resolvedPath = resolvedURL.path
        guard isSafePath(resolvedPath),
              !resolvedPath.contains("/AppTranslocation/"),
              resolvedPath.hasSuffix("/Contents/MacOS/crisperctl"),
              fileManager.isExecutableFile(atPath: resolvedPath) else { return nil }

        let macOSDir = resolvedURL.deletingLastPathComponent()
        let contentsDir = macOSDir.deletingLastPathComponent()
        let bundleDir = contentsDir.deletingLastPathComponent()
        guard bundleDir.pathExtension == "app" else { return nil }

        guard hasSafeNode(resolvedPath, expectedType: S_IFREG, currentUID: currentUID),
              hasSafeNode(macOSDir.path, expectedType: S_IFDIR, currentUID: currentUID),
              hasSafeNode(contentsDir.path, expectedType: S_IFDIR, currentUID: currentUID),
              hasSafeNode(bundleDir.path, expectedType: S_IFDIR, currentUID: currentUID) else {
            return nil
        }

        return resolvedPath
    }

    /// Ensures neither `binDir` nor its parent (`parentParent`) is a symlink.
    static func hasSafeParents(forLinkPath linkPath: String) -> Bool {
        let linkURL = URL(fileURLWithPath: linkPath)
        let binDir = linkURL.deletingLastPathComponent().path
        let parentParent = linkURL.deletingLastPathComponent().deletingLastPathComponent().path
        guard isSafePath(binDir), isSafePath(parentParent) else { return false }
        return !isSymlink(parentParent) && !isSymlink(binDir)
    }

    /// Inspects `linkPath` without following it to decide whether unprivileged install can proceed.
    static func inspectLink(at linkPath: String, fileManager: FileManager = .default) -> ExistingLinkStatus {
        guard isSafePath(linkPath), hasSafeParents(forLinkPath: linkPath) else { return .blocked }
        var info = stat()
        if lstat(linkPath, &info) != 0 {
            return (errno == ENOENT || errno == ENOTDIR) ? .missing : .blocked
        }
        guard (info.st_mode & S_IFMT) == S_IFLNK else { return .blocked }
        var targetInfo = stat()
        if stat(linkPath, &targetInfo) == 0 { return .blocked }
        guard errno == ENOENT else { return .blocked }
        guard let target = try? fileManager.destinationOfSymbolicLink(atPath: linkPath),
              isManagedAppTarget(target) else { return .blocked }
        return .replaceableDanglingCrisperSymlink
    }

    /// Builds the privileged install script for `binDirectory/crisperctl` -> `targetPath`.
    /// Never passes a trailing slash to `/bin/ln -sh`, guards parent dirs against symlinks,
    /// refuses regular files/directories/foreign symlinks, and replaces only a dangling symlink
    /// whose target matches a moved `Crisper.app` or `Crisp.app` bundle.
    static func installScript(
        targetPath: String,
        binDirectory: String = defaultBinDirectory
    ) -> String? {
        guard isSafePath(targetPath),
              targetPath.hasPrefix("/"),
              targetPath.hasSuffix("/Contents/MacOS/crisperctl"),
              let paths = safeDirectoryPaths(binDirectory) else { return nil }

        let qParent = shellQuote(paths.parentParent)
        let qBin = shellQuote(paths.binDir)
        let qLink = shellQuote(paths.linkPath)
        let qTarget = shellQuote(targetPath)
        let qError = shellQuote("Something already exists at \(paths.linkPath).")

        return """
        set -eu
        [ ! -L \(qParent) ]
        [ ! -L \(qBin) ]
        /bin/mkdir -p \(qBin)
        [ ! -L \(qParent) ]
        [ ! -L \(qBin) ]
        [ -d \(qBin) ]
        if [ -L \(qLink) ]; then
            if [ -e \(qLink) ]; then
                echo \(qError) >&2
                exit 1
            fi
            destination=$(/usr/bin/readlink \(qLink))
            case "$destination" in
                /*/Crisper.app/Contents/MacOS/crisperctl|/Crisper.app/Contents/MacOS/crisperctl)
                    /bin/unlink \(qLink)
                    ;;
                /*/Crisp.app/Contents/MacOS/crisperctl|/Crisp.app/Contents/MacOS/crisperctl)
                    /bin/unlink \(qLink)
                    ;;
                *)
                    echo \(qError) >&2
                    exit 1
                    ;;
            esac
        elif [ -e \(qLink) ]; then
            echo \(qError) >&2
            exit 1
        fi
        /bin/ln -sh \(qTarget) \(qLink)
        """
    }

    /// Builds the privileged uninstall script, guarding parent dirs and verifying the symlink
    /// still points to this app's validated target before unlinking with `/bin/unlink`.
    static func uninstallScript(
        resolvedTargetPath: String,
        bundledPath: String,
        binDirectory: String = defaultBinDirectory
    ) -> String? {
        guard isSafePath(resolvedTargetPath),
              isSafePath(bundledPath),
              resolvedTargetPath.hasPrefix("/"),
              bundledPath.hasPrefix("/"),
              let paths = safeDirectoryPaths(binDirectory) else { return nil }

        let qParent = shellQuote(paths.parentParent)
        let qBin = shellQuote(paths.binDir)
        let qLink = shellQuote(paths.linkPath)
        let qResolved = shellQuote(resolvedTargetPath)
        let qBundled = shellQuote(bundledPath)

        return """
        set -eu
        [ ! -L \(qParent) ]
        [ ! -L \(qBin) ]
        [ -L \(qLink) ]
        destination=$(/usr/bin/readlink \(qLink))
        if [ "$destination" != \(qResolved) ] && [ "$destination" != \(qBundled) ]; then
            exit 1
        fi
        /bin/unlink \(qLink)
        """
    }

    private static func normalizedDirectory(_ path: String) -> String {
        var result = path
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    private static func safeDirectoryPaths(
        _ binDirectory: String
    ) -> (parentParent: String, binDir: String, linkPath: String)? {
        guard isSafePath(binDirectory), binDirectory.hasPrefix("/") else { return nil }
        let binDir = normalizedDirectory(binDirectory)
        guard binDir != "/" else { return nil }
        let parentParent = normalizedDirectory(
            URL(fileURLWithPath: binDir).deletingLastPathComponent().path
        )
        guard isSafePath(parentParent) else { return nil }
        return (parentParent: parentParent, binDir: binDir, linkPath: "\(binDir)/\(linkName)")
    }

    private static func hasSafeNode(_ path: String, expectedType: mode_t, currentUID: uid_t) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        guard (info.st_mode & S_IFMT) == expectedType else { return false }
        guard info.st_uid == 0 || info.st_uid == currentUID else { return false }
        return (info.st_mode & 0o002) == 0
    }

    private static func isSymlink(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFLNK
    }
}
