import XCTest

final class PrivilegedHelperCommandTests: XCTestCase {
    func testPrivilegedActionPathsAndArguments() {
        let allOn = PrivilegedAction.setLowPowerMode(enabled: true, batteryOnly: false)
        XCTAssertEqual(allOn.executablePath, "/usr/bin/pmset")
        XCTAssertEqual(allOn.arguments, ["-a", "lowpowermode", "1"])
        XCTAssertEqual(allOn.sudoArguments, ["-n", "/usr/bin/pmset", "-a", "lowpowermode", "1"])

        let allOff = PrivilegedAction.setLowPowerMode(enabled: false, batteryOnly: false)
        XCTAssertEqual(allOff.arguments, ["-a", "lowpowermode", "0"])

        let batteryOn = PrivilegedAction.setLowPowerMode(enabled: true, batteryOnly: true)
        XCTAssertEqual(batteryOn.arguments, ["-b", "lowpowermode", "1"])

        let batteryOff = PrivilegedAction.setLowPowerMode(enabled: false, batteryOnly: true)
        XCTAssertEqual(batteryOff.arguments, ["-b", "lowpowermode", "0"])

        let purge = PrivilegedAction.purgeMemory
        XCTAssertEqual(purge.executablePath, "/usr/sbin/purge")
        XCTAssertEqual(purge.arguments, [])
        XCTAssertEqual(purge.sudoArguments, ["-n", "/usr/sbin/purge"])
    }

    func testAllowlistAllowsOnlyFiveExactCommands() {
        let allowed: [(String, [String])] = [
            ("/usr/bin/pmset", ["-a", "lowpowermode", "0"]),
            ("/usr/bin/pmset", ["-a", "lowpowermode", "1"]),
            ("/usr/bin/pmset", ["-b", "lowpowermode", "0"]),
            ("/usr/bin/pmset", ["-b", "lowpowermode", "1"]),
            ("/usr/sbin/purge", [])
        ]
        for (executable, arguments) in allowed {
            XCTAssertTrue(
                PrivilegedHelperCommand.isAllowedAction(executable, arguments: arguments),
                "Expected allowed: \(executable) \(arguments)"
            )
        }

        let rejected: [(String, [String])] = [
            ("/usr/bin/pmset", ["-a", "lowpowermode", "2"]),
            ("/usr/bin/pmset", ["-c", "lowpowermode", "1"]),
            ("/usr/bin/pmset", ["-a", "lowpowermode", "1", "sleep", "0"]),
            ("/usr/bin/pmset", ["-a", "displaysleep", "0"]),
            ("/usr/sbin/purge", ["-v"]),
            ("/usr/sbin/purge", [" "]),
            ("pmset", ["-a", "lowpowermode", "1"]),
            ("/usr/bin/../bin/pmset", ["-a", "lowpowermode", "1"]),
            ("/bin/sh", ["-c", "id"]),
            ("", [])
        ]
        for (executable, arguments) in rejected {
            XCTAssertFalse(
                PrivilegedHelperCommand.isAllowedAction(executable, arguments: arguments),
                "Expected rejected: \(executable) \(arguments)"
            )
        }
    }

    func testSudoersContentIsUIDScopedAndPassesVisudoValidation() throws {
        let testUID: uid_t = 502
        let content = PrivilegedHelperCommand.sudoersContent(uid: testUID)
        XCTAssertEqual(PrivilegedHelperCommand.sudoersFilePath(uid: testUID), "/etc/sudoers.d/crisper-power-502")
        XCTAssertTrue(content.hasPrefix("\(PrivilegedHelperCommand.markerComment)\n"))
        XCTAssertTrue(content.hasSuffix("\n"))
        XCTAssertTrue(content.contains("#502 ALL=(root) NOPASSWD: /usr/bin/pmset -a lowpowermode 0"))
        XCTAssertTrue(content.contains("#502 ALL=(root) NOPASSWD: /usr/bin/pmset -a lowpowermode 1"))
        XCTAssertTrue(content.contains("#502 ALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode 0"))
        XCTAssertTrue(content.contains("#502 ALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode 1"))
        XCTAssertTrue(content.contains("#502 ALL=(root) NOPASSWD: /usr/sbin/purge \"\""))
        XCTAssertFalse(content.contains("%admin"))
        XCTAssertFalse(content.contains("NOPASSWD: ALL"))

        // Default parameter scopes to the current user's numeric UID.
        XCTAssertTrue(PrivilegedHelperCommand.sudoersContent().contains("#\(getuid()) ALL=(root) NOPASSWD:"))
        XCTAssertEqual(PrivilegedHelperCommand.sudoersFilePath, "/etc/sudoers.d/crisper-power-\(getuid())")

        // Validate real sudoers grammar via visudo without modifying system state.
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/visudo")
        process.arguments = ["-cf", "-"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        input.fileHandleForWriting.write(Data(content.utf8))
        try input.fileHandleForWriting.close()
        _ = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testInstallScriptStagesAtomicallyWithMvAndRoundTripsPayload() throws {
        let testUID: uid_t = 502
        let script = PrivilegedHelperCommand.installShellScript(uid: testUID)
        XCTAssertTrue(script.contains("/usr/bin/mktemp"))
        XCTAssertTrue(script.contains("/bin/chmod 0440 \"$stage\""))
        XCTAssertTrue(script.contains("/usr/sbin/chown root:wheel \"$stage\""))
        XCTAssertTrue(script.contains("/usr/sbin/visudo -cf \"$stage\""))
        XCTAssertTrue(script.contains("/bin/mv -f \"$stage\" '/etc/sudoers.d/crisper-power-502'"))
        XCTAssertFalse(script.contains("/usr/bin/install"))
        XCTAssertTrue(script.contains("trap '/bin/rm -f \"$stage\"' EXIT"))
        XCTAssertFalse(script.contains("/tmp"))
        XCTAssertFalse(script.contains(NSTemporaryDirectory()))

        let encoded = try XCTUnwrap(
            script.components(separatedBy: "/usr/bin/printf '%s' '").last?
                .components(separatedBy: "'").first
        )
        let decoded = try XCTUnwrap(Data(base64Encoded: encoded))
        XCTAssertEqual(
            String(data: decoded, encoding: .utf8),
            PrivilegedHelperCommand.sudoersContent(uid: testUID)
        )

        try assertValidShellSyntax(script)
    }

    func testUninstallScriptSyntax() throws {
        let testUID: uid_t = 502
        let script = PrivilegedHelperCommand.uninstallShellScript(uid: testUID)
        XCTAssertTrue(script.contains("/bin/rm -f '/etc/sudoers.d/crisper-power-502'"))
        try assertValidShellSyntax(script)
    }

    func testAppleScriptLiteralEscaping() {
        XCTAssertEqual(
            PrivilegedHelperCommand.appleScriptLiteral("echo \"$stage\" \\ test"),
            "echo \\\"$stage\\\" \\\\ test"
        )
    }

    private func assertValidShellSyntax(_ script: String) throws {
        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n"]
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
