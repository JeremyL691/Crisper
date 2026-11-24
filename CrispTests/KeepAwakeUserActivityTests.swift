import XCTest

/// Declaring user activity powers the display on, so it must follow a real restore, never
/// the power-source notifications IOKit also posts for battery percentage changes or DarkWakes.
final class KeepAwakeUserActivityTests: XCTestCase {
    private let active = KeepAwakeDecision(phase: .active, shouldHoldAssertion: true)

    private func declares(
        from previous: KeepAwakePhase,
        to decision: KeepAwakeDecision,
        onAC: Bool = true,
        trigger: KeepAwakeEvaluationTrigger
    ) -> Bool {
        KeepAwakePolicy.shouldDeclareUserActivity(
            previousPhase: previous,
            decision: decision,
            isOnACPower: onAC,
            trigger: trigger
        )
    }

    func testChargeLevelChangeWhileActiveOnACDoesNotWakeDisplay() {
        XCTAssertFalse(declares(from: .active, to: active, trigger: .powerSourceChange))
    }

    func testOnACPowerBatteryToACTransitionResumesAndWakesDisplay() {
        let config = KeepAwakeConfig(isEnabled: true, mode: .onACPower)
        let onBattery = KeepAwakePolicy.evaluate(config: config, isOnACPower: false)
        XCTAssertEqual(onBattery, KeepAwakeDecision(phase: .suspendedOnBattery, shouldHoldAssertion: false))

        let onAC = KeepAwakePolicy.evaluate(config: config, isOnACPower: true)
        XCTAssertEqual(onAC, active)
        XCTAssertTrue(declares(from: onBattery.phase, to: onAC, onAC: true, trigger: .powerSourceChange))
    }

    func testAlwaysAwakeBatteryToACTransitionDoesNotWakeDisplay() {
        // Always Awake never released its assertions on battery, so plugging in restores nothing.
        let config = KeepAwakeConfig(isEnabled: true, mode: .alwaysAwake)
        let onBattery = KeepAwakePolicy.evaluate(config: config, isOnACPower: false)
        XCTAssertEqual(onBattery, active)

        let onAC = KeepAwakePolicy.evaluate(config: config, isOnACPower: true)
        XCTAssertEqual(onAC, active)
        XCTAssertFalse(declares(from: onBattery.phase, to: onAC, onAC: true, trigger: .powerSourceChange))
    }

    func testDarkWakePowerWakeTriggerDoesNotPromoteToLitDisplay() {
        // Kernel power-wake callbacks (syncForPowerWake) use .powerSourceChange so DarkWakes
        // re-arm assertions without lighting the screen on either mode.
        for mode in KeepAwakeMode.allCases {
            let config = KeepAwakeConfig(isEnabled: true, mode: mode)
            let onAC = KeepAwakePolicy.evaluate(config: config, isOnACPower: true)
            XCTAssertFalse(declares(from: onAC.phase, to: onAC, onAC: true, trigger: .powerSourceChange))
        }
        let alwaysAwakeBattery = KeepAwakePolicy.evaluate(
            config: KeepAwakeConfig(isEnabled: true, mode: .alwaysAwake),
            isOnACPower: false
        )
        XCTAssertFalse(declares(from: alwaysAwakeBattery.phase, to: alwaysAwakeBattery, onAC: false, trigger: .powerSourceChange))
    }

    func testSystemWakeOnACWakesDisplay() {
        XCTAssertTrue(declares(from: .active, to: active, trigger: .systemWake))
    }

    func testSystemWakeOnBatteryDoesNotWakeDisplay() {
        XCTAssertFalse(declares(from: .active, to: active, onAC: false, trigger: .systemWake))
    }

    func testControlChangesDoNotWakeDisplayUnlessResumingFromBattery() {
        XCTAssertFalse(declares(from: .disabled, to: active, trigger: .control))
        XCTAssertFalse(declares(from: .active, to: active, trigger: .control))
        XCTAssertTrue(declares(from: .suspendedOnBattery, to: active, onAC: false, trigger: .control))
    }

    func testNoDeclarationWithoutHeldAssertions() {
        let suspended = KeepAwakeDecision(phase: .suspendedOnBattery, shouldHoldAssertion: false)
        let disabled = KeepAwakeDecision(phase: .disabled, shouldHoldAssertion: false)
        for trigger in [KeepAwakeEvaluationTrigger.control, .powerSourceChange, .systemWake] {
            XCTAssertFalse(declares(from: .active, to: suspended, onAC: false, trigger: trigger))
            XCTAssertFalse(declares(from: .suspendedOnBattery, to: disabled, trigger: trigger))
        }
    }
}
