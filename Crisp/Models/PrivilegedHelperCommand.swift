import Foundation

/// Whitelisted privileged actions executed via passwordless sudo once authorized.
enum PrivilegedAction: Equatable, Sendable {
    case setLowPowerMode(enabled: Bool, batteryOnly: Bool)
    case purgeMemory

    var executablePath: String {
        switch self {
        case .setLowPowerMode:
            return "/usr/bin/pmset"
        case .purgeMemory:
            return "/usr/sbin/purge"
        }
    }

    var arguments: [String] {
        switch self {
        case let .setLowPowerMode(enabled, batteryOnly):
            return [batteryOnly ? "-b" : "-a", "lowpowermode", enabled ? "1" : "0"]
        case .purgeMemory:
            return []
        }
    }

    var sudoArguments: [String] {
        ["-n", executablePath] + arguments
    }
}

/// Builds and validates the narrow per-UID sudoers drop-in used for one-time privileged helper
/// authorization. Only five exact root commands are ever permitted; all dynamic values are fixed
/// constants or the numeric POSIX user ID.
enum PrivilegedHelperCommand {
    static let markerComment = "# Managed by Crisper"

    private static let sudoersDirectory = "/etc/sudoers.d"
    private static let sudoersFilePrefix = "crisper-power-"

    static var sudoersFilePath: String {
        sudoersFilePath(uid: getuid())
    }

    static func sudoersFilePath(uid: uid_t = getuid()) -> String {
        "\(sudoersDirectory)/\(sudoersFilePrefix)\(uid)"
    }

    private static let allowedCommands: [(executable: String, arguments: [String])] = [
        ("/usr/bin/pmset", ["-a", "lowpowermode", "0"]),
        ("/usr/bin/pmset", ["-a", "lowpowermode", "1"]),
        ("/usr/bin/pmset", ["-b", "lowpowermode", "0"]),
        ("/usr/bin/pmset", ["-b", "lowpowermode", "1"]),
        ("/usr/sbin/purge", [])
    ]

    /// Strict exact-match allowlist guard checked before every `sudo -n` invocation.
    static func isAllowedAction(_ executable: String, arguments: [String]) -> Bool {
        allowedCommands.contains { $0.executable == executable && $0.arguments == arguments }
    }

    /// Generates the exact `/etc/sudoers.d/crisper-power-<uid>` file contents scoped solely to `#<uid>`.
    /// `/usr/sbin/purge ""` restricts `purge` to zero arguments per sudoers(5).
    static func sudoersContent(uid: uid_t = getuid()) -> String {
        let principal = "#\(uid)"
        let rules = [
            markerComment,
            "\(principal) ALL=(root) NOPASSWD: /usr/bin/pmset -a lowpowermode 0",
            "\(principal) ALL=(root) NOPASSWD: /usr/bin/pmset -a lowpowermode 1",
            "\(principal) ALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode 0",
            "\(principal) ALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode 1",
            "\(principal) ALL=(root) NOPASSWD: /usr/sbin/purge \"\""
        ]
        return rules.joined(separator: "\n") + "\n"
    }

    /// Atomic root-only install script validated with `visudo -cf` before placement via `/bin/mv -f`.
    /// Stages inside root-owned `/etc/sudoers.d` with a leading dot (ignored by `#includedir`)
    /// so no user-writable temporary directory or `install(1)` `INS@*` artifact is ever created.
    static func installShellScript(uid: uid_t = getuid()) -> String {
        let encoded = Data(sudoersContent(uid: uid).utf8).base64EncodedString()
        let targetPath = sudoersFilePath(uid: uid)
        return """
        set -eu
        /bin/mkdir -p -m 0755 '\(sudoersDirectory)'
        stage=$(/usr/bin/mktemp '\(sudoersDirectory)/.crisper-power.XXXXXXXX')
        trap '/bin/rm -f "$stage"' EXIT
        /usr/bin/printf '%s' '\(encoded)' | /usr/bin/base64 -D > "$stage"
        /bin/chmod 0440 "$stage"
        /usr/sbin/chown root:wheel "$stage"
        /usr/sbin/visudo -cf "$stage"
        /bin/mv -f "$stage" '\(targetPath)'
        """
    }

    /// Removes the managed per-UID sudoers drop-in cleanly.
    static func uninstallShellScript(uid: uid_t = getuid()) -> String {
        let targetPath = sudoersFilePath(uid: uid)
        return """
        set -eu
        /bin/rm -f '\(targetPath)'
        """
    }

    /// Escapes a shell script for embedding inside an AppleScript double-quoted string literal.
    static func appleScriptLiteral(_ command: String) -> String {
        command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
