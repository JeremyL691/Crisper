import XCTest

final class KeepAwakePolicyTests: XCTestCase {
    func testDefaultsAndCodableRoundTrip() throws {
        let defaultConfig = KeepAwakeConfig()
        XCTAssertFalse(defaultConfig.isEnabled)
        XCTAssertEqual(defaultConfig.mode, .onACPower)
        XCTAssertEqual(KeepAwakeMode.allCases, [.alwaysAwake, .onACPower])
        XCTAssertEqual(KeepAwakeMode.alwaysAwake.id, "alwaysAwake")
        XCTAssertEqual(KeepAwakeMode.onACPower.id, "onACPower")

        let custom = KeepAwakeConfig(isEnabled: true, mode: .alwaysAwake)
        let decoded = try JSONDecoder().decode(KeepAwakeConfig.self, from: JSONEncoder().encode(custom))
        XCTAssertEqual(decoded, custom)

        for phase in [KeepAwakePhase.disabled, .suspendedOnBattery, .active] {
            let roundTripped = try JSONDecoder().decode(KeepAwakePhase.self, from: JSONEncoder().encode(phase))
            XCTAssertEqual(roundTripped, phase)
        }
    }

    func testDisabledStaysOffAcrossModesAndPowerStates() {
        let expected = KeepAwakeDecision(phase: .disabled, shouldHoldAssertion: false)
        for mode in KeepAwakeMode.allCases {
            let config = KeepAwakeConfig(isEnabled: false, mode: mode)
            XCTAssertEqual(KeepAwakePolicy.evaluate(config: config, isOnACPower: true), expected)
            XCTAssertEqual(KeepAwakePolicy.evaluate(config: config, isOnACPower: false), expected)
        }
    }

    func testManualOffNeverAutoRestoresOnBatteryToACTransition() {
        for mode in KeepAwakeMode.allCases {
            let config = KeepAwakeConfig(isEnabled: false, mode: mode)
            let onBattery = KeepAwakePolicy.evaluate(config: config, isOnACPower: false)
            let onAC = KeepAwakePolicy.evaluate(config: config, isOnACPower: true)
            XCTAssertEqual(onBattery, KeepAwakeDecision(phase: .disabled, shouldHoldAssertion: false))
            XCTAssertEqual(onAC, KeepAwakeDecision(phase: .disabled, shouldHoldAssertion: false))
        }
    }

    func testAlwaysAwakeHoldsAssertionOnACAndBattery() {
        let config = KeepAwakeConfig(isEnabled: true, mode: .alwaysAwake)
        let expected = KeepAwakeDecision(phase: .active, shouldHoldAssertion: true)
        XCTAssertEqual(KeepAwakePolicy.evaluate(config: config, isOnACPower: true), expected)
        XCTAssertEqual(KeepAwakePolicy.evaluate(config: config, isOnACPower: false), expected)
    }

    func testOnACPowerSuspendsOnBatteryAndRestoresImmediatelyOnAC() {
        let config = KeepAwakeConfig(isEnabled: true, mode: .onACPower)
        let onAC = KeepAwakePolicy.evaluate(config: config, isOnACPower: true)
        XCTAssertEqual(onAC, KeepAwakeDecision(phase: .active, shouldHoldAssertion: true))

        let onBattery = KeepAwakePolicy.evaluate(config: config, isOnACPower: false)
        XCTAssertEqual(onBattery, KeepAwakeDecision(phase: .suspendedOnBattery, shouldHoldAssertion: false))

        let restored = KeepAwakePolicy.evaluate(config: config, isOnACPower: true)
        XCTAssertEqual(restored, KeepAwakeDecision(phase: .active, shouldHoldAssertion: true))
    }

    func testModeSwitchOnBatteryTogglesSuspendedAndActive() {
        let onACPower = KeepAwakeConfig(isEnabled: true, mode: .onACPower)
        let alwaysAwake = KeepAwakeConfig(isEnabled: true, mode: .alwaysAwake)
        XCTAssertEqual(
            KeepAwakePolicy.evaluate(config: onACPower, isOnACPower: false),
            KeepAwakeDecision(phase: .suspendedOnBattery, shouldHoldAssertion: false)
        )
        XCTAssertEqual(
            KeepAwakePolicy.evaluate(config: alwaysAwake, isOnACPower: false),
            KeepAwakeDecision(phase: .active, shouldHoldAssertion: true)
        )
    }

    func testManagedPolicyOverrideDisablesBothModesOnACAndBattery() {
        let expected = KeepAwakeDecision(phase: .disabled, shouldHoldAssertion: false)
        for mode in KeepAwakeMode.allCases {
            let config = KeepAwakeConfig(isEnabled: true, mode: mode)
            XCTAssertEqual(
                KeepAwakePolicy.evaluate(config: config, isOnACPower: true, isDisabledByPolicy: true),
                expected
            )
            XCTAssertEqual(
                KeepAwakePolicy.evaluate(config: config, isOnACPower: false, isDisabledByPolicy: true),
                expected
            )
        }
    }
}
