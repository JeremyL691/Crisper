import XCTest

final class HiDPIOverrideCommandTests: XCTestCase {
    func testPayloadRoundTripsWithoutAUserTemporaryFile() throws {
        let modes = [Data([0, 0, 15, 0, 0, 0, 8, 112]), Data(repeating: 0, count: 8)]
        let command = try HiDPIOverrideCommand.install(vendor: 0x610, product: 0xabcd, scaledModes: modes)
        let encoded = try XCTUnwrap(command.components(separatedBy: "/usr/bin/printf '%s' '").last?
            .components(separatedBy: "'").first)
        let payload = try XCTUnwrap(Data(base64Encoded: encoded))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any])
        XCTAssertEqual(plist["scale-resolutions"] as? [Data], modes)
        XCTAssertTrue(command.contains("DisplayVendorID-610/DisplayProductID-abcd"))
        XCTAssertFalse(command.contains("crisp_hidpi_override.plist"))
        XCTAssertFalse(command.contains(NSTemporaryDirectory()))
        XCTAssertFalse(command.contains("/bin/cp"))
    }

    func testRejectsEmptyOversizedAndMalformedModes() {
        for modes in [[Data](), [Data(repeating: 0, count: 7)], [Data(repeating: 0, count: 9)],
                      Array(repeating: Data(repeating: 0, count: 8), count: 4_097)] {
            XCTAssertThrowsError(try HiDPIOverrideCommand.install(vendor: 1, product: 2, scaledModes: modes))
        }
    }

    func testIdentifiersAreNumericAndCannotSupplyPaths() throws {
        let command = try HiDPIOverrideCommand.install(
            vendor: UInt32.max, product: 0, scaledModes: [Data(repeating: 0, count: 8)])
        XCTAssertTrue(command.contains("DisplayVendorID-ffffffff/DisplayProductID-0"))
    }

    func testAppleScriptLiteralPreservesShellQuotesAndBackslashes() {
        XCTAssertEqual(HiDPIOverrideCommand.appleScriptLiteral("echo \"$stage\" \\"), "echo \\\"$stage\\\" \\\\")
    }

    /// Parse only: never execute the generated installer or request administrator access.
    func testGeneratedShellSyntax() throws {
        let command = try HiDPIOverrideCommand.install(vendor: 1, product: 2, scaledModes: [Data(repeating: 0, count: 8)])
        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n"]
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(command.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testInstallAndUninstallPreserveExistingKeysAndModes() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let vendor = base.appendingPathComponent("DisplayVendorID-1")
        let override = vendor.appendingPathComponent("DisplayProductID-2")
        try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let existingMode = Data(repeating: 1, count: 16)
        let newMode = Data(repeating: 2, count: 8)
        let existing: [String: Any] = ["scale-resolutions": [existingMode], "DisplayProductName": "Monitor"]
        let previous = try PropertyListSerialization.data(fromPropertyList: existing, format: .binary, options: 0)
        try previous.write(to: override)
        let install = try HiDPIOverrideCommand.install(vendor: 1, product: 2, scaledModes: [newMode], previous: previous)
        XCTAssertEqual(try runInScratchDirectory(install, base: base), 0)
        let installed = try Data(contentsOf: override)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: installed, format: nil) as? [String: Any])
        XCTAssertEqual(plist["scale-resolutions"] as? [Data], [existingMode, newMode])
        XCTAssertEqual(plist["DisplayProductName"] as? String, "Monitor")
        let uninstall = try HiDPIOverrideCommand.uninstall(vendor: 1, product: 2, previous: installed)
        let newer = try PropertyListSerialization.data(fromPropertyList: ["DisplayProductName": "New"], format: .xml, options: 0)
        try newer.write(to: override)
        XCTAssertNotEqual(try runInScratchDirectory(uninstall, base: base), 0)
        XCTAssertEqual(try Data(contentsOf: override), newer)
        try installed.write(to: override)
        XCTAssertEqual(try runInScratchDirectory(uninstall, base: base), 0)
        let restored = try PropertyListSerialization.propertyList(from: Data(contentsOf: override), format: nil)
        XCTAssertEqual(restored as? NSDictionary, existing as NSDictionary)
        XCTAssertThrowsError(try HiDPIOverrideCommand.uninstall(vendor: 1, product: 2, previous: previous))
    }

    private func runInScratchDirectory(_ command: String, base: URL) throws -> Int32 {
        let script = command.replacingOccurrences(of: "/Library/Displays/Contents/Resources/Overrides", with: base.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
