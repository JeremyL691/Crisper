import Foundation
import os.log

enum PrivilegedHelperError: LocalizedError, Equatable, Sendable {
    case disallowedCommand
    case authorizationCancelled
    case authorizationFailed(String)
    case notAuthorized
    case executionFailed(exitCode: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .disallowedCommand:
            return String(localized: "Blocked unauthorized privileged command.")
        case .authorizationCancelled:
            return String(localized: "Administrator authorization was canceled.")
        case let .authorizationFailed(message):
            return String(localized: "Administrator authorization failed: \(message)")
        case .notAuthorized:
            return String(localized: "One-time administrator authorization is required.")
        case let .executionFailed(exitCode, message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return String(localized: "Privileged command failed with exit status \(exitCode).")
            }
            return trimmed
        }
    }
}

/// Manages one-time administrator authorization via a strictly allowlisted per-UID sudoers drop-in
/// (`/etc/sudoers.d/crisper-power-<uid>`) and runs both `/usr/bin/osascript` and `/usr/bin/sudo -n`
/// off `@MainActor` so modal auth prompts never stall `BrightnessKeyService`'s key tap.
@MainActor
final class PrivilegedHelperService: ObservableObject {
    static let shared = PrivilegedHelperService()

    @Published private(set) var isAuthorized: Bool = false
    @Published private(set) var isBusy: Bool = false
    @Published var lastError: String? = nil

    private var busyCount = 0
    private nonisolated static let log = Logger(subsystem: "com.crisp.app", category: "privileged")

    private init() {
        refreshStatus()
    }

    private func beginBusy() {
        busyCount += 1
        if !isBusy { isBusy = true }
    }

    private func endBusy() {
        busyCount = max(0, busyCount - 1)
        if busyCount == 0, isBusy { isBusy = false }
    }

    /// Re-checks whether the managed per-UID sudoers drop-in is present on disk.
    func refreshStatus() {
        let authorized = FileManager.default.fileExists(atPath: PrivilegedHelperCommand.sudoersFilePath)
        if isAuthorized != authorized {
            isAuthorized = authorized
        }
    }

    /// Starts one-time authorization off `@MainActor`. Returns `false` if another operation is busy.
    @discardableResult
    func installAuthorization() -> Bool {
        guard !isBusy else { return false }
        beginBusy()
        lastError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.finishInstallAuthorization()
        }
        return true
    }

    /// Installs `/etc/sudoers.d/crisper-power-<uid>` via `/usr/bin/osascript` off `@MainActor`.
    @discardableResult
    func installAuthorizationAsync() async -> Bool {
        guard !isBusy else { return false }
        beginBusy()
        lastError = nil
        return await finishInstallAuthorization()
    }

    /// Starts authorization removal off `@MainActor`. Returns `false` if another operation is busy.
    @discardableResult
    func uninstallAuthorization() -> Bool {
        guard !isBusy else { return false }
        beginBusy()
        lastError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.finishUninstallAuthorization()
        }
        return true
    }

    /// Removes `/etc/sudoers.d/crisper-power-<uid>` via `/usr/bin/osascript` off `@MainActor`.
    @discardableResult
    func uninstallAuthorizationAsync() async -> Bool {
        guard !isBusy else { return false }
        beginBusy()
        lastError = nil
        return await finishUninstallAuthorization()
    }

    /// Executes an allowlisted privileged action via `/usr/bin/sudo -n` off the main thread.
    /// If not yet authorized and `promptIfNeeded` is true, installs authorization once and executes.
    func execute(
        _ action: PrivilegedAction,
        promptIfNeeded: Bool = true
    ) async -> Result<Void, PrivilegedHelperError> {
        guard PrivilegedHelperCommand.isAllowedAction(action.executablePath, arguments: action.arguments) else {
            lastError = PrivilegedHelperError.disallowedCommand.localizedDescription
            return .failure(.disallowedCommand)
        }

        beginBusy()
        lastError = nil
        defer { endBusy() }

        refreshStatus()
        var installedThisCall = false

        if !isAuthorized {
            guard promptIfNeeded else {
                lastError = PrivilegedHelperError.notAuthorized.localizedDescription
                return .failure(.notAuthorized)
            }
            if case let .failure(authError) = await performInstall() {
                lastError = authError == .authorizationCancelled ? nil : authError.localizedDescription
                return .failure(authError)
            }
            installedThisCall = true
        }

        let firstResult = await Self.runSudoNonInteractive(arguments: action.sudoArguments)
        if case .success = firstResult {
            return .success(())
        }

        // If the sudoers file existed on disk but was stale/unmatched, re-install once when allowed.
        if case let .failure(error) = firstResult,
           promptIfNeeded,
           !installedThisCall,
           Self.indicatesMissingPasswordlessGrant(error) {
            if case let .failure(authError) = await performInstall() {
                lastError = authError == .authorizationCancelled ? nil : authError.localizedDescription
                return .failure(authError)
            }
            let retryResult = await Self.runSudoNonInteractive(arguments: action.sudoArguments)
            if case let .failure(retryError) = retryResult {
                lastError = retryError.localizedDescription
            }
            return retryResult
        }

        if case let .failure(error) = firstResult {
            lastError = error.localizedDescription
        }
        return firstResult
    }

    // MARK: - Private Helpers

    private func finishInstallAuthorization() async -> Bool {
        defer { endBusy() }
        let result = await performInstall()
        switch result {
        case .success:
            return true
        case let .failure(error):
            lastError = error == .authorizationCancelled ? nil : error.localizedDescription
            return false
        }
    }

    private func finishUninstallAuthorization() async -> Bool {
        defer { endBusy() }
        let result = await runAppleScript(PrivilegedHelperCommand.uninstallShellScript())
        refreshStatus()
        switch result {
        case .success:
            return !isAuthorized
        case let .failure(error):
            lastError = error == .authorizationCancelled ? nil : error.localizedDescription
            return false
        }
    }

    private func performInstall() async -> Result<Void, PrivilegedHelperError> {
        let result = await runAppleScript(PrivilegedHelperCommand.installShellScript())
        refreshStatus()
        switch result {
        case .success:
            return isAuthorized
                ? .success(())
                : .failure(.authorizationFailed(String(localized: "Helper authorization file was not installed.")))
        case let .failure(error):
            return .failure(error)
        }
    }

    private func runAppleScript(_ shellScript: String) async -> Result<Void, PrivilegedHelperError> {
        let escaped = PrivilegedHelperCommand.appleScriptLiteral(shellScript)
        let source = "do shell script \"\(escaped)\" with administrator privileges\n"

        // Suppress panel auto-dismiss while the system authentication sheet holds key focus,
        // mirroring HiDPIService's generation-guarded suppression window.
        PanelOpenGuard.suppressAutoDismiss = true
        let generation = PanelOpenGuard.suppressGeneration
        defer {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                if PanelOpenGuard.suppressGeneration == generation {
                    PanelOpenGuard.suppressAutoDismiss = false
                }
            }
        }

        return await Self.runOsascriptOffMain(source: source)
    }

    private nonisolated static func runOsascriptOffMain(
        source: String
    ) async -> Result<Void, PrivilegedHelperError> {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-"]
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

            do {
                try process.run()
            } catch {
                return .failure(.authorizationFailed(error.localizedDescription))
            }

            stdinPipe.fileHandleForWriting.write(Data(source.utf8))
            try? stdinPipe.fileHandleForWriting.close()

            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            _ = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                return .success(())
            }
            let message = (String(data: stderrData, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if message.contains("(-128)") || message.localizedCaseInsensitiveContains("cancel") {
                return .failure(.authorizationCancelled)
            }
            let display = message.isEmpty
                ? String(localized: "Exit status \(process.terminationStatus)")
                : message
            Self.log.error("Administrator script failed: \(display, privacy: .public)")
            return .failure(.authorizationFailed(display))
        }.value
    }

    private nonisolated static func indicatesMissingPasswordlessGrant(_ error: PrivilegedHelperError) -> Bool {
        guard case let .executionFailed(_, message) = error else { return false }
        return message.localizedCaseInsensitiveContains("password is required")
            || message.localizedCaseInsensitiveContains("not allowed to execute")
    }

    private nonisolated static func runSudoNonInteractive(
        arguments: [String]
    ) async -> Result<Void, PrivilegedHelperError> {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            let stderrPipe = Pipe()
            let stdoutPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

            do {
                try process.run()
            } catch {
                return .failure(.executionFailed(exitCode: -1, message: error.localizedDescription))
            }

            // Drain pipes before waiting so a chatty subprocess can never fill the pipe buffer.
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            _ = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                return .success(())
            }
            let message = String(data: stderrData, encoding: .utf8) ?? ""
            Self.log.error("sudo -n failed (\(process.terminationStatus)): \(message, privacy: .public)")
            return .failure(.executionFailed(exitCode: process.terminationStatus, message: message))
        }.value
    }
}
