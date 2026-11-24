import AppKit
import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import os.log

private func keepAwakePowerSourceCallback(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let service = Unmanaged<KeepAwakeService>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated {
        service.syncForPowerSourceChange()
    }
}

/// Manages dual-mode IOKit power assertions (`Always Awake` and `On AC Power`) that keep
/// the display and system awake on demand and release cleanly on battery unplug when in
/// `On AC Power` mode.
@MainActor
final class KeepAwakeService: ObservableObject {
    static let shared = KeepAwakeService()

    private static let log = Logger(subsystem: "com.crisper.app", category: "keep-awake")
    private static let configKey = "crisper.KeepAwakeConfig"

    @Published private(set) var config: KeepAwakeConfig
    @Published private(set) var phase: KeepAwakePhase = .disabled
    @Published private(set) var isOnACPower: Bool
    @Published private(set) var isActive: Bool = false

    var isEnabled: Bool { config.isEnabled }
    var mode: KeepAwakeMode { config.mode }

    private var displayAssertion: IOPMAssertionID = 0
    private var systemAssertion: IOPMAssertionID = 0
    private var wakeTickleAssertion: IOPMAssertionID = 0
    private var monitoringStarted = false
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var wakeObserver: NSObjectProtocol?

    private init() {
        let initialConfig = Self.loadConfig()
        let onAC = PowerAndTopologyMonitor.readIsOnACPower()
        config = initialConfig
        isOnACPower = onAC
        phase = KeepAwakePolicy.evaluate(
            config: initialConfig,
            isOnACPower: onAC,
            isDisabledByPolicy: Self.isDisabledByPolicy
        ).phase
    }

    /// True when a configuration profile sets `crisp.disableKeepAwake` = true; managed
    /// values outrank the user's own, so a `defaults write` cannot switch it back on.
    static var isDisabledByPolicy: Bool {
        UserDefaults.standard.bool(forKey: "crisp.disableKeepAwake")
    }

    // MARK: - Lifecycle

    func startMonitoring() {
        guard !monitoringStarted else { return }
        monitoringStarted = true

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource(keepAwakePowerSourceCallback, ctx)?.takeRetainedValue() {
            powerSourceRunLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncForSystemWake(reason: "WorkspaceDidWake")
            }
        }

        evaluate(reason: "Startup")
    }

    /// Releases all active assertions and unregisters power/wake monitors without
    /// altering persisted `config`.
    func shutdown() {
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            wakeObserver = nil
        }
        if let source = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            powerSourceRunLoopSource = nil
        }
        monitoringStarted = false
        releaseAllAssertions()
        isActive = false
        phase = .disabled
    }

    // MARK: - Controls

    func setEnabled(_ enabled: Bool) {
        if enabled && Self.isDisabledByPolicy {
            evaluate(reason: "DisabledByPolicy")
            return
        }
        guard config.isEnabled != enabled else {
            evaluate(reason: "SetEnabledSync")
            return
        }
        config.isEnabled = enabled
        persistConfig()
        evaluate(reason: enabled ? "UserEnabled" : "UserDisabled")
    }

    func setActive(_ on: Bool) {
        setEnabled(on)
    }

    func setMode(_ mode: KeepAwakeMode) {
        guard config.mode != mode else { return }
        config.mode = mode
        persistConfig()
        evaluate(reason: "ModeChanged")
    }

    func selectMode(_ mode: KeepAwakeMode) {
        if Self.isDisabledByPolicy {
            evaluate(reason: "DisabledByPolicy")
            return
        }
        config.mode = mode
        config.isEnabled = true
        persistConfig()
        evaluate(reason: "ModeSelected")
    }

    func syncForPowerSourceChange() {
        evaluate(reason: "PowerSourceChange", trigger: .powerSourceChange)
    }

    func syncForSystemWake(reason: String) {
        evaluate(reason: reason, trigger: .systemWake)
    }

    // MARK: - Evaluation & Assertions

    private func evaluate(reason: String, trigger: KeepAwakeEvaluationTrigger = .control) {
        let onAC = PowerAndTopologyMonitor.readIsOnACPower()
        isOnACPower = onAC

        let previousPhase = phase
        let decision = KeepAwakePolicy.evaluate(
            config: config,
            isOnACPower: onAC,
            isDisabledByPolicy: Self.isDisabledByPolicy
        )
        phase = decision.phase

        if previousPhase != decision.phase {
            Self.log.notice(
                "[\(reason, privacy: .public)] keep-awake \(previousPhase.rawValue, privacy: .public) -> \(decision.phase.rawValue, privacy: .public) (mode=\(self.config.mode.rawValue, privacy: .public), ac=\(onAC, privacy: .public))"
            )
        }

        if decision.shouldHoldAssertion {
            ensureAssertion(
                id: &displayAssertion,
                type: kIOPMAssertionTypePreventUserIdleDisplaySleep as String,
                name: "Crisper Keep Awake Display"
            )
            ensureAssertion(
                id: &systemAssertion,
                type: kIOPMAssertionTypePreventUserIdleSystemSleep as String,
                name: "Crisper Keep Awake System"
            )
            isActive = (displayAssertion != 0 || systemAssertion != 0)

            if KeepAwakePolicy.shouldDeclareUserActivity(
                previousPhase: previousPhase,
                decision: decision,
                isOnACPower: onAC,
                trigger: trigger
            ) {
                declareWakeUserActivity()
            }
        } else {
            releaseAllAssertions()
            isActive = false
        }
    }

    private func ensureAssertion(id: inout IOPMAssertionID, type: String, name: String) {
        guard id == 0 else { return }
        let properties: [String: Any] = [
            kIOPMAssertionTypeKey as String: type,
            kIOPMAssertionNameKey as String: name,
            kIOPMAssertionLevelKey as String: kIOPMAssertionLevelOn,
            "SensorsActive": true
        ]
        var createdID: IOPMAssertionID = 0
        let rc = IOPMAssertionCreateWithProperties(properties as CFDictionary, &createdID)
        if rc == kIOReturnSuccess {
            id = createdID
        } else {
            Self.log.error("IOPMAssertionCreateWithProperties(\(type, privacy: .public)) failed: \(rc, privacy: .public)")
        }
    }

    private func declareWakeUserActivity() {
        releaseAssertion(&wakeTickleAssertion)
        _ = IOPMAssertionDeclareUserActivity(
            "Crisper Keep Awake AC Resume" as CFString,
            kIOPMUserActiveLocal,
            &wakeTickleAssertion
        )
    }

    private func releaseAllAssertions() {
        releaseAssertion(&displayAssertion)
        releaseAssertion(&systemAssertion)
        releaseAssertion(&wakeTickleAssertion)
    }

    private func releaseAssertion(_ id: inout IOPMAssertionID) {
        guard id != 0 else { return }
        IOPMAssertionRelease(id)
        id = 0
    }

    // MARK: - Persistence

    private static func loadConfig() -> KeepAwakeConfig {
        guard let data = UserDefaults.standard.data(forKey: configKey),
              let decoded = try? JSONDecoder().decode(KeepAwakeConfig.self, from: data) else {
            return KeepAwakeConfig()
        }
        return decoded
    }

    private func persistConfig() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: Self.configKey)
    }
}
