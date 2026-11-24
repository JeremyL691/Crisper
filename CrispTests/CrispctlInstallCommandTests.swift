import Darwin
import XCTest

final class CrispctlInstallCommandTests: XCTestCase {
    private var root: URL!
    private var localDir: URL!
    private var binDir: URL!
    private var linkURL: URL!
    private var bundledBinary: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let tempRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        root = tempRoot.appendingPathComponent("crisperctl-install-\(UUID().uuidString)")
        localDir = root.appendingPathComponent("local")
        binDir = localDir.appendingPathComponent("bin")
        linkURL = binDir.appendingPathComponent("crisperctl")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        bundledBinary = try makeMockBundle(named: "Crisper.app", under: root)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    func testCleanInstallCreatesExactSymlinkWithoutTrailingSlash() throws {
        let target = try XCTUnwrap(CrispctlInstallCommand.validatedBundledPath(bundledBinary.path))
        let script = try XCTUnwrap(CrispctlInstallCommand.installScript(targetPath: target, binDirectory: binDir.path))
        XCTAssertFalse(script.contains("\(binDir.path)/'"))

        XCTAssertEqual(try runShell(script), 0)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path), target)
    }

    func testInstallRefusesExistingRegularFile() throws {
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let original = Data("keep me".utf8)
        try original.write(to: linkURL)

        let target = try XCTUnwrap(CrispctlInstallCommand.validatedBundledPath(bundledBinary.path))
        let script = try XCTUnwrap(CrispctlInstallCommand.installScript(targetPath: target, binDirectory: binDir.path))
        XCTAssertEqual(CrispctlInstallCommand.inspectLink(at: linkURL.path), .blocked)
        XCTAssertNotEqual(try runShell(script), 0)
        XCTAssertEqual(try Data(contentsOf: linkURL), original)
    }

    func testInstallRefusesExistingDirectoryWithoutCreatingNestedLink() throws {
        try FileManager.default.createDirectory(at: linkURL, withIntermediateDirectories: true)

        let target = try XCTUnwrap(CrispctlInstallCommand.validatedBundledPath(bundledBinary.path))
        let script = try XCTUnwrap(CrispctlInstallCommand.installScript(targetPath: target, binDirectory: binDir.path))
        XCTAssertEqual(CrispctlInstallCommand.inspectLink(at: linkURL.path), .blocked)
        XCTAssertNotEqual(try runShell(script), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: linkURL.appendingPathComponent("crisperctl").path))
    }

    func testInstallRefusesForeignLiveAndForeignDanglingSymlinks() throws {
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let foreignFile = root.appendingPathComponent("other-tool")
        try Data("other".utf8).write(to: foreignFile)

        // Foreign live symlink
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: foreignFile.path)
        let target = try XCTUnwrap(CrispctlInstallCommand.validatedBundledPath(bundledBinary.path))
        let script = try XCTUnwrap(CrispctlInstallCommand.installScript(targetPath: target, binDirectory: binDir.path))
        XCTAssertEqual(CrispctlInstallCommand.inspectLink(at: linkURL.path), .blocked)
        XCTAssertNotEqual(try runShell(script), 0)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path), foreignFile.path)

        // Foreign dangling symlink (including lookalike app name)
        try FileManager.default.removeItem(at: linkURL)
        let foreignDangling = root.appendingPathComponent("FakeCrisper.app/Contents/MacOS/crisperctl").path
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: foreignDangling)
        XCTAssertEqual(CrispctlInstallCommand.inspectLink(at: linkURL.path), .blocked)
        XCTAssertNotEqual(try runShell(script), 0)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path), foreignDangling)
    }

    func testInstallReplacesMovedAppDanglingCrisperAndCrispSymlinks() throws {
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let target = try XCTUnwrap(CrispctlInstallCommand.validatedBundledPath(bundledBinary.path))
        let script = try XCTUnwrap(CrispctlInstallCommand.installScript(targetPath: target, binDirectory: binDir.path))

        for oldApp in ["Crisper.app", "Crisp.app"] {
            if FileManager.default.fileExists(atPath: linkURL.path) || isSymlink(linkURL.path) {
                try FileManager.default.removeItem(at: linkURL)
            }
            let movedTarget = root.appendingPathComponent("OldLocation/\(oldApp)/Contents/MacOS/crisperctl").path
            try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: movedTarget)
            XCTAssertEqual(CrispctlInstallCommand.inspectLink(at: linkURL.path), .replaceableDanglingCrisperSymlink, oldApp)
            XCTAssertEqual(try runShell(script), 0, oldApp)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path), target, oldApp)
        }

        // A live symlink pointing to another existing Crisper.app must NOT be overwritten.
        try FileManager.default.removeItem(at: linkURL)
        let otherBundleDir = root.appendingPathComponent("OtherCopy")
        try FileManager.default.createDirectory(at: otherBundleDir, withIntermediateDirectories: true)
        let otherLiveBinary = try makeMockBundle(named: "Crisper.app", under: otherBundleDir)
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: otherLiveBinary.path)
        XCTAssertEqual(CrispctlInstallCommand.inspectLink(at: linkURL.path), .blocked)
        XCTAssertNotEqual(try runShell(script), 0)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path), otherLiveBinary.path)
    }

    func testInstallAndUninstallRejectParentDirectorySymlinkTraversal() throws {
        let decoy = root.appendingPathComponent("decoy")
        try FileManager.default.createDirectory(at: decoy.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let target = try XCTUnwrap(CrispctlInstallCommand.validatedBundledPath(bundledBinary.path))

        // Case 1: parentParent (/usr/local equivalent) is a symlink
        try FileManager.default.createSymbolicLink(atPath: localDir.path, withDestinationPath: decoy.path)
        let install = try XCTUnwrap(CrispctlInstallCommand.installScript(targetPath: target, binDirectory: binDir.path))
        let uninstall = try XCTUnwrap(CrispctlInstallCommand.uninstallScript(
            resolvedTargetPath: target, bundledPath: bundledBinary.path, binDirectory: binDir.path
        ))
        XCTAssertEqual(CrispctlInstallCommand.inspectLink(at: linkURL.path), .blocked)
        XCTAssertNotEqual(try runShell(install), 0)
        XCTAssertFalse(isSymlink(decoy.appendingPathComponent("bin/crisperctl").path))
        try FileManager.default.createSymbolicLink(
            atPath: decoy.appendingPathComponent("bin/crisperctl").path, withDestinationPath: target
        )
        XCTAssertNotEqual(try runShell(uninstall), 0)
        XCTAssertTrue(isSymlink(decoy.appendingPathComponent("bin/crisperctl").path))

        // Case 2: binDir (/usr/local/bin equivalent) is a symlink
        try FileManager.default.removeItem(at: localDir)
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: binDir.path, withDestinationPath: decoy.appendingPathComponent("bin").path
        )
        XCTAssertEqual(CrispctlInstallCommand.inspectLink(at: linkURL.path), .blocked)
        XCTAssertNotEqual(try runShell(install), 0)
        XCTAssertNotEqual(try runShell(uninstall), 0)
        XCTAssertTrue(isSymlink(decoy.appendingPathComponent("bin/crisperctl").path))
    }

    func testUninstallVerifiesTargetAndUsesUnlinkOnlyOnMatchingSymlink() throws {
        let target = try XCTUnwrap(CrispctlInstallCommand.validatedBundledPath(bundledBinary.path))
        let install = try XCTUnwrap(CrispctlInstallCommand.installScript(targetPath: target, binDirectory: binDir.path))
        let uninstall = try XCTUnwrap(CrispctlInstallCommand.uninstallScript(
            resolvedTargetPath: target, bundledPath: bundledBinary.path, binDirectory: binDir.path
        ))
        XCTAssertTrue(uninstall.contains("/bin/unlink"))
        XCTAssertFalse(uninstall.contains("/bin/rm"))

        // Matching symlink is removed cleanly
        XCTAssertEqual(try runShell(install), 0)
        XCTAssertEqual(try runShell(uninstall), 0)
        XCTAssertFalse(isSymlink(linkURL.path))

        // Foreign symlink is left intact
        let other = root.appendingPathComponent("other-target")
        try Data("x".utf8).write(to: other)
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: other.path)
        XCTAssertNotEqual(try runShell(uninstall), 0)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path), other.path)

        // Regular file is refused
        try FileManager.default.removeItem(at: linkURL)
        try Data("file".utf8).write(to: linkURL)
        XCTAssertNotEqual(try runShell(uninstall), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: linkURL.path))
    }

    func testValidationRejectsControlCharactersAndWorldWritableBundleHierarchy() throws {
        let target = try XCTUnwrap(CrispctlInstallCommand.validatedBundledPath(bundledBinary.path))
        XCTAssertEqual(target, bundledBinary.path)

        // Control characters in raw/target paths
        for bad in [
            "/Applications/Crisper\n.app/Contents/MacOS/crisperctl",
            "/Applications/Crisper\r.app/Contents/MacOS/crisperctl",
            "/Applications/Crisper\0.app/Contents/MacOS/crisperctl"
        ] {
            XCTAssertNil(CrispctlInstallCommand.validatedBundledPath(bad))
            XCTAssertNil(CrispctlInstallCommand.installScript(targetPath: bad, binDirectory: binDir.path))
            XCTAssertNil(CrispctlInstallCommand.uninstallScript(
                resolvedTargetPath: target, bundledPath: bad, binDirectory: binDir.path
            ))
            XCTAssertNil(CrispctlInstallCommand.uninstallScript(
                resolvedTargetPath: bad, bundledPath: target, binDirectory: binDir.path
            ))
        }

        // World-writable check across binary, Contents/MacOS, Contents, and .app root
        let macOSDir = bundledBinary.deletingLastPathComponent()
        let contentsDir = macOSDir.deletingLastPathComponent()
        let bundleDir = contentsDir.deletingLastPathComponent()

        for (node, originalMode) in [
            (bundledBinary!, mode_t(0o755)),
            (macOSDir, mode_t(0o755)),
            (contentsDir, mode_t(0o755)),
            (bundleDir, mode_t(0o755))
        ] {
            XCTAssertEqual(Darwin.chmod(node.path, originalMode | 0o002), 0)
            XCTAssertNil(CrispctlInstallCommand.validatedBundledPath(bundledBinary.path), node.path)
            XCTAssertEqual(Darwin.chmod(node.path, originalMode), 0)
            XCTAssertNotNil(CrispctlInstallCommand.validatedBundledPath(bundledBinary.path), node.path)
        }
    }

    private func makeMockBundle(named name: String, under parent: URL) throws -> URL {
        let app = parent.appendingPathComponent(name)
        let contents = app.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        let binary = macOS.appendingPathComponent("crisperctl")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        for dir in [app, contents, macOS] {
            XCTAssertEqual(Darwin.chmod(dir.path, 0o755), 0)
        }
        XCTAssertEqual(Darwin.chmod(binary.path, 0o755), 0)
        return binary
    }

    private func isSymlink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    private func runShell(_ script: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
