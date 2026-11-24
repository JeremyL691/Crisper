import XCTest

/// Declaring user activity powers the display on, so it must follow a real restore, never
/// the power-source notifications IOKit also posts for battery percentage changes.
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

    func testPluggingInAfterBatterySuspensionWakesDisplay() {
        XCTAssertTrue(declares(from: .suspendedOnBattery, to: active, trigger: .powerSourceChange))
    }

    func testAlwaysAwakePluggingInDoesNotWakeDisplay() {
        // Always Awake never released its assertions on battery, so nothing is being restored.
        XCTAssertFalse(declares(from: .active, to: active, trigger: .powerSourceChange))
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
