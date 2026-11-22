import XCTest

final class SmartVirtualDisplayPolicyTests: XCTestCase {
    func testDefaultConfigAndIdentity() throws {
        let config = SmartVirtualDisplayConfig()
        XCTAssertEqual(config.id.uuidString, "534D4152-5444-554D-4D59-000000000001")
        XCTAssertEqual(config.id, SmartVirtualDisplayConfig.defaultID)
        XCTAssertFalse(config.isEnabled)
        XCTAssertTrue(config.clamshellGuardEnabled)
        XCTAssertEqual(config.name, "Smart Dummy")
        XCTAssertEqual(config.width, 3200)
        XCTAssertEqual(config.height, 2000)
        XCTAssertEqual(config.refreshRate, 60.0)
        XCTAssertTrue(config.hiDPI)
        XCTAssertTrue(config.startsHiDPI)
        XCTAssertTrue(config.supportsHiDPI)
        XCTAssertTrue(config.effectiveStartsHiDPI)
        XCTAssertEqual(config.logicalWidth, 1600)
        XCTAssertEqual(config.logicalHeight, 1000)
        XCTAssertEqual(config.productID, 0x534D4152)
        XCTAssertEqual(config.serialNumber, 0x5444554D)
        XCTAssertEqual(
            config.displayUUID,
            CrispVirtualDisplayIdentity.uuid(productID: 0x534D4152, serialNumber: 0x5444554D)
        )
        XCTAssertEqual(config.displayUUID, "0000EEEE-534D-4152-5444-554D00000000")

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SmartVirtualDisplayConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testLogicalDimensionsFollowStartsHiDPIAndParity() {
        let native1x = SmartVirtualDisplayConfig(width: 2560, height: 1440, hiDPI: true, startsHiDPI: false)
        XCTAssertTrue(native1x.supportsHiDPI)
        XCTAssertFalse(native1x.effectiveStartsHiDPI)
        XCTAssertEqual(native1x.logicalWidth, 2560)
        XCTAssertEqual(native1x.logicalHeight, 1440)

        let hiDPIDisabled = SmartVirtualDisplayConfig(width: 3200, height: 2000, hiDPI: false, startsHiDPI: true)
        XCTAssertFalse(hiDPIDisabled.supportsHiDPI)
        XCTAssertFalse(hiDPIDisabled.effectiveStartsHiDPI)
        XCTAssertEqual(hiDPIDisabled.logicalWidth, 3200)
        XCTAssertEqual(hiDPIDisabled.logicalHeight, 2000)

        let oddBoth = SmartVirtualDisplayConfig(width: 1921, height: 1081, hiDPI: true, startsHiDPI: true)
        XCTAssertFalse(oddBoth.supportsHiDPI)
        XCTAssertFalse(oddBoth.effectiveStartsHiDPI)
        XCTAssertEqual(oddBoth.logicalWidth, 1921)
        XCTAssertEqual(oddBoth.logicalHeight, 1081)

        let oddHeight = SmartVirtualDisplayConfig(width: 2560, height: 1081, hiDPI: true, startsHiDPI: true)
        XCTAssertFalse(oddHeight.supportsHiDPI)
        XCTAssertFalse(oddHeight.effectiveStartsHiDPI)
        XCTAssertEqual(oddHeight.logicalWidth, 2560)
        XCTAssertEqual(oddHeight.logicalHeight, 1081)

        let oddWidth = SmartVirtualDisplayConfig(width: 1921, height: 1080, hiDPI: true, startsHiDPI: true)
        XCTAssertFalse(oddWidth.supportsHiDPI)
        XCTAssertFalse(oddWidth.effectiveStartsHiDPI)
        XCTAssertEqual(oddWidth.logicalWidth, 1921)
        XCTAssertEqual(oddWidth.logicalHeight, 1080)
    }

    func testDisabledPrimarySwitchStaysOffAcrossAllPowerAndTopologyInputs() {
        let config = SmartVirtualDisplayConfig(isEnabled: false, clamshellGuardEnabled: true)
        let expected = SmartVirtualDisplayDecision(
            phase: .disabled,
            shouldMountVirtualDisplay: false,
            shouldDisableClamshellSleep: false,
            shouldHoldSystemSleepAssertion: false,
            shouldHoldDisplaySleepAssertion: false
        )
        let inputs = [
            SmartVirtualDisplayInput(isOnACPower: false, isClamshellClosed: true, activePhysicalExternalCount: 0, activeBuiltinCount: 0),
            SmartVirtualDisplayInput(isOnACPower: true, isClamshellClosed: true, activePhysicalExternalCount: 0, activeBuiltinCount: 0),
            SmartVirtualDisplayInput(isOnACPower: true, isClamshellClosed: true, activePhysicalExternalCount: 1, activeBuiltinCount: 0),
            SmartVirtualDisplayInput(isOnACPower: true, isClamshellClosed: false, activePhysicalExternalCount: 0, activeBuiltinCount: 1)
        ]
        for input in inputs {
            XCTAssertEqual(SmartVirtualDisplayPolicy.evaluate(config: config, input: input), expected)
        }
    }

    func testManualOffNeverAutoRestoresOnBatteryToACTransition() {
        let config = SmartVirtualDisplayConfig(isEnabled: false)
        let onBattery = SmartVirtualDisplayInput(
            isOnACPower: false, isClamshellClosed: true, activePhysicalExternalCount: 0, activeBuiltinCount: 0
        )
        let onAC = SmartVirtualDisplayInput(
            isOnACPower: true, isClamshellClosed: true, activePhysicalExternalCount: 0, activeBuiltinCount: 0
        )
        XCTAssertEqual(SmartVirtualDisplayPolicy.evaluate(config: config, input: onBattery).phase, .disabled)
        let afterPlugIn = SmartVirtualDisplayPolicy.evaluate(config: config, input: onAC)
        XCTAssertEqual(afterPlugIn.phase, .disabled)
        XCTAssertFalse(afterPlugIn.shouldMountVirtualDisplay)
        XCTAssertFalse(afterPlugIn.shouldDisableClamshellSleep)
        XCTAssertFalse(afterPlugIn.shouldHoldSystemSleepAssertion)
        XCTAssertFalse(afterPlugIn.shouldHoldDisplaySleepAssertion)
    }

    func testACToBatterySuspendsAndBatteryToACAutoRestoresHeadlessClamshell() {
        let config = SmartVirtualDisplayConfig(isEnabled: true, clamshellGuardEnabled: true)
        let headlessAC = SmartVirtualDisplayInput(
            isOnACPower: true, isClamshellClosed: true, activePhysicalExternalCount: 0, activeBuiltinCount: 0
        )
        let headlessBattery = SmartVirtualDisplayInput(
            isOnACPower: false, isClamshellClosed: true, activePhysicalExternalCount: 0, activeBuiltinCount: 0
        )

        let active = SmartVirtualDisplayPolicy.evaluate(config: config, input: headlessAC)
        XCTAssertEqual(
            active,
            SmartVirtualDisplayDecision(
                phase: .activeMounted,
                shouldMountVirtualDisplay: true,
                shouldDisableClamshellSleep: true,
                shouldHoldSystemSleepAssertion: true,
                shouldHoldDisplaySleepAssertion: true
            )
        )

        let suspended = SmartVirtualDisplayPolicy.evaluate(config: config, input: headlessBattery)
        XCTAssertEqual(
            suspended,
            SmartVirtualDisplayDecision(
                phase: .suspendedOnBattery,
                shouldMountVirtualDisplay: false,
                shouldDisableClamshellSleep: false,
                shouldHoldSystemSleepAssertion: false,
                shouldHoldDisplaySleepAssertion: false
            )
        )

        let restored = SmartVirtualDisplayPolicy.evaluate(config: config, input: headlessAC)
        XCTAssertEqual(restored, active)
    }

    func testBatteryToACRestoresToArmedStandbyWhenPhysicalDisplayPresent() {
        let config = SmartVirtualDisplayConfig(isEnabled: true, clamshellGuardEnabled: true)
        let batteryWithExternal = SmartVirtualDisplayInput(
            isOnACPower: false, isClamshellClosed: true, activePhysicalExternalCount: 1, activeBuiltinCount: 0
        )
        let acWithExternal = SmartVirtualDisplayInput(
            isOnACPower: true, isClamshellClosed: true, activePhysicalExternalCount: 1, activeBuiltinCount: 0
        )

        XCTAssertEqual(
            SmartVirtualDisplayPolicy.evaluate(config: config, input: batteryWithExternal),
            SmartVirtualDisplayDecision(
                phase: .suspendedOnBattery,
                shouldMountVirtualDisplay: false,
                shouldDisableClamshellSleep: false,
                shouldHoldSystemSleepAssertion: false,
                shouldHoldDisplaySleepAssertion: false
            )
        )
        XCTAssertEqual(
            SmartVirtualDisplayPolicy.evaluate(config: config, input: acWithExternal),
            SmartVirtualDisplayDecision(
                phase: .armedStandby,
                shouldMountVirtualDisplay: false,
                shouldDisableClamshellSleep: true,
                shouldHoldSystemSleepAssertion: true,
                shouldHoldDisplaySleepAssertion: false
            )
        )
    }

    func testAutoYieldOnPhysicalExternalAttachAndMountOnUnplugInClamshell() {
        let config = SmartVirtualDisplayConfig(isEnabled: true, clamshellGuardEnabled: true)
        let headless = SmartVirtualDisplayInput(
            isOnACPower: true, isClamshellClosed: true, activePhysicalExternalCount: 0, activeBuiltinCount: 0
        )
        let externalAttached = SmartVirtualDisplayInput(
            isOnACPower: true, isClamshellClosed: true, activePhysicalExternalCount: 1, activeBuiltinCount: 0
        )

        let mounted = SmartVirtualDisplayPolicy.evaluate(config: config, input: headless)
        XCTAssertEqual(mounted.phase, .activeMounted)
        XCTAssertTrue(mounted.shouldMountVirtualDisplay)
        XCTAssertTrue(mounted.shouldHoldDisplaySleepAssertion)

        let yielded = SmartVirtualDisplayPolicy.evaluate(config: config, input: externalAttached)
        XCTAssertEqual(
            yielded,
            SmartVirtualDisplayDecision(
                phase: .armedStandby,
                shouldMountVirtualDisplay: false,
                shouldDisableClamshellSleep: true,
                shouldHoldSystemSleepAssertion: true,
                shouldHoldDisplaySleepAssertion: false
            )
        )

        let remounted = SmartVirtualDisplayPolicy.evaluate(config: config, input: headless)
        XCTAssertEqual(remounted, mounted)
    }

    func testAutoYieldOnLidOpenWithBuiltinDisplayAndMountOnLidClose() {
        let config = SmartVirtualDisplayConfig(isEnabled: true, clamshellGuardEnabled: true)
        let lidClosedBuiltinReported = SmartVirtualDisplayInput(
            isOnACPower: true, isClamshellClosed: true, activePhysicalExternalCount: 0, activeBuiltinCount: 1
        )
        let lidOpenBuiltin = SmartVirtualDisplayInput(
            isOnACPower: true, isClamshellClosed: false, activePhysicalExternalCount: 0, activeBuiltinCount: 1
        )

        let mounted = SmartVirtualDisplayPolicy.evaluate(config: config, input: lidClosedBuiltinReported)
        XCTAssertEqual(
            mounted,
            SmartVirtualDisplayDecision(
                phase: .activeMounted,
                shouldMountVirtualDisplay: true,
                shouldDisableClamshellSleep: true,
                shouldHoldSystemSleepAssertion: true,
                shouldHoldDisplaySleepAssertion: true
            )
        )

        let yielded = SmartVirtualDisplayPolicy.evaluate(config: config, input: lidOpenBuiltin)
        XCTAssertEqual(
            yielded,
            SmartVirtualDisplayDecision(
                phase: .armedStandby,
                shouldMountVirtualDisplay: false,
                shouldDisableClamshellSleep: false,
                shouldHoldSystemSleepAssertion: false,
                shouldHoldDisplaySleepAssertion: false
            )
        )
    }

    func testOpenLidWithAllPhysicalDisplaysSoftDisconnectedMountsWithoutClamshellSleepDisable() {
        let config = SmartVirtualDisplayConfig(isEnabled: true, clamshellGuardEnabled: true)
        let softDisconnectedAll = SmartVirtualDisplayInput(
            isOnACPower: true, isClamshellClosed: false, activePhysicalExternalCount: 0, activeBuiltinCount: 0
        )

        XCTAssertEqual(
            SmartVirtualDisplayPolicy.evaluate(config: config, input: softDisconnectedAll),
            SmartVirtualDisplayDecision(
                phase: .activeMounted,
                shouldMountVirtualDisplay: true,
                shouldDisableClamshellSleep: false,
                shouldHoldSystemSleepAssertion: true,
                shouldHoldDisplaySleepAssertion: true
            )
        )
    }

    func testOpenLidWithExternalOnlyStaysInStandbyWithoutGuardAssertions() {
        let config = SmartVirtualDisplayConfig(isEnabled: true, clamshellGuardEnabled: true)
        let input = SmartVirtualDisplayInput(
            isOnACPower: true, isClamshellClosed: false, activePhysicalExternalCount: 2, activeBuiltinCount: 0
        )
        XCTAssertEqual(
            SmartVirtualDisplayPolicy.evaluate(config: config, input: input),
            SmartVirtualDisplayDecision(
                phase: .armedStandby,
                shouldMountVirtualDisplay: false,
                shouldDisableClamshellSleep: false,
                shouldHoldSystemSleepAssertion: false,
                shouldHoldDisplaySleepAssertion: false
            )
        )
    }

    func testClamshellGuardOffSuppressesSleepAssertionsInStandbyAndActiveMounted() {
        let config = SmartVirtualDisplayConfig(isEnabled: true, clamshellGuardEnabled: false)
        let clamshellWithExternal = SmartVirtualDisplayInput(
            isOnACPower: true, isClamshellClosed: true, activePhysicalExternalCount: 1, activeBuiltinCount: 0
        )
        let clamshellHeadless = SmartVirtualDisplayInput(
            isOnACPower: true, isClamshellClosed: true, activePhysicalExternalCount: 0, activeBuiltinCount: 0
        )
        let openLidHeadless = SmartVirtualDisplayInput(
            isOnACPower: true, isClamshellClosed: false, activePhysicalExternalCount: 0, activeBuiltinCount: 0
        )

        XCTAssertEqual(
            SmartVirtualDisplayPolicy.evaluate(config: config, input: clamshellWithExternal),
            SmartVirtualDisplayDecision(
                phase: .armedStandby,
                shouldMountVirtualDisplay: false,
                shouldDisableClamshellSleep: false,
                shouldHoldSystemSleepAssertion: false,
                shouldHoldDisplaySleepAssertion: false
            )
        )

        let expectedActiveNoGuard = SmartVirtualDisplayDecision(
            phase: .activeMounted,
            shouldMountVirtualDisplay: true,
            shouldDisableClamshellSleep: false,
            shouldHoldSystemSleepAssertion: false,
            shouldHoldDisplaySleepAssertion: false
        )
        XCTAssertEqual(SmartVirtualDisplayPolicy.evaluate(config: config, input: clamshellHeadless), expectedActiveNoGuard)
        XCTAssertEqual(SmartVirtualDisplayPolicy.evaluate(config: config, input: openLidHeadless), expectedActiveNoGuard)
    }

    func testNegativeDisplayCountsAreTreatedAsNoUsablePhysicalDisplay() {
        let config = SmartVirtualDisplayConfig(isEnabled: true, clamshellGuardEnabled: true)
        let input = SmartVirtualDisplayInput(
            isOnACPower: true, isClamshellClosed: false, activePhysicalExternalCount: -1, activeBuiltinCount: -1
        )
        let decision = SmartVirtualDisplayPolicy.evaluate(config: config, input: input)
        XCTAssertEqual(decision.phase, .activeMounted)
        XCTAssertTrue(decision.shouldMountVirtualDisplay)
    }

    func testResolveExternalPhysicalCountHotPlugFastPathYieldsImmediately() {
        let count = SmartVirtualDisplayPolicy.resolveExternalPhysicalCount(
            cgOnlineExternalCount: 0,
            kernelExternalCount: 1,
            softDisconnectedExternalCount: 0,
            areScreensAsleep: false
        )
        XCTAssertEqual(count, 1)

        let config = SmartVirtualDisplayConfig(isEnabled: true, clamshellGuardEnabled: true)
        let decision = SmartVirtualDisplayPolicy.evaluate(
            config: config,
            input: SmartVirtualDisplayInput(
                isOnACPower: true, isClamshellClosed: true, activePhysicalExternalCount: count, activeBuiltinCount: 0
            )
        )
        XCTAssertEqual(decision.phase, .armedStandby)
        XCTAssertFalse(decision.shouldMountVirtualDisplay)
    }

    func testResolveExternalPhysicalCountHotUnplugFastPathMountsImmediately() {
        let count = SmartVirtualDisplayPolicy.resolveExternalPhysicalCount(
            cgOnlineExternalCount: 1,
            kernelExternalCount: 0,
            softDisconnectedExternalCount: 0,
            areScreensAsleep: false
        )
        XCTAssertEqual(count, 0)

        let config = SmartVirtualDisplayConfig(isEnabled: true, clamshellGuardEnabled: true)
        let decision = SmartVirtualDisplayPolicy.evaluate(
            config: config,
            input: SmartVirtualDisplayInput(
                isOnACPower: true, isClamshellClosed: true, activePhysicalExternalCount: count, activeBuiltinCount: 0
            )
        )
        XCTAssertEqual(decision.phase, .activeMounted)
        XCTAssertTrue(decision.shouldMountVirtualDisplay)
    }

    func testResolveExternalPhysicalCountDPMSSleepPreventsWakeLoop() {
        let count = SmartVirtualDisplayPolicy.resolveExternalPhysicalCount(
            cgOnlineExternalCount: 1,
            kernelExternalCount: 0,
            softDisconnectedExternalCount: 0,
            areScreensAsleep: true
        )
        XCTAssertEqual(count, 1)

        let config = SmartVirtualDisplayConfig(isEnabled: true, clamshellGuardEnabled: true)
        let decision = SmartVirtualDisplayPolicy.evaluate(
            config: config,
            input: SmartVirtualDisplayInput(
                isOnACPower: true, isClamshellClosed: true, activePhysicalExternalCount: count, activeBuiltinCount: 0
            )
        )
        XCTAssertEqual(decision.phase, .armedStandby)
        XCTAssertFalse(decision.shouldMountVirtualDisplay)
        XCTAssertFalse(decision.shouldHoldDisplaySleepAssertion)
    }

    func testResolveExternalPhysicalCountSoftDisconnectedLastExternalAllowsMount() {
        let count = SmartVirtualDisplayPolicy.resolveExternalPhysicalCount(
            cgOnlineExternalCount: 0,
            kernelExternalCount: 1,
            softDisconnectedExternalCount: 1,
            areScreensAsleep: false
        )
        XCTAssertEqual(count, 0)

        let config = SmartVirtualDisplayConfig(isEnabled: true, clamshellGuardEnabled: true)
        let decision = SmartVirtualDisplayPolicy.evaluate(
            config: config,
            input: SmartVirtualDisplayInput(
                isOnACPower: true, isClamshellClosed: true, activePhysicalExternalCount: count, activeBuiltinCount: 0
            )
        )
        XCTAssertEqual(decision.phase, .activeMounted)
        XCTAssertTrue(decision.shouldMountVirtualDisplay)
    }

    func testResolveExternalPhysicalCountNewMonitorPluggedWhileOneSoftDisconnectedYields() {
        let count = SmartVirtualDisplayPolicy.resolveExternalPhysicalCount(
            cgOnlineExternalCount: 0,
            kernelExternalCount: 2,
            softDisconnectedExternalCount: 1,
            areScreensAsleep: false
        )
        XCTAssertEqual(count, 1)

        let config = SmartVirtualDisplayConfig(isEnabled: true, clamshellGuardEnabled: true)
        let decision = SmartVirtualDisplayPolicy.evaluate(
            config: config,
            input: SmartVirtualDisplayInput(
                isOnACPower: true, isClamshellClosed: true, activePhysicalExternalCount: count, activeBuiltinCount: 0
            )
        )
        XCTAssertEqual(decision.phase, .armedStandby)
        XCTAssertFalse(decision.shouldMountVirtualDisplay)
    }

    func testResolveExternalPhysicalCountIntelFallbackAndNegativeClamping() {
        XCTAssertEqual(
            SmartVirtualDisplayPolicy.resolveExternalPhysicalCount(
                cgOnlineExternalCount: 2,
                kernelExternalCount: nil,
                softDisconnectedExternalCount: 1,
                areScreensAsleep: false
            ),
            2
        )
        XCTAssertEqual(
            SmartVirtualDisplayPolicy.resolveExternalPhysicalCount(
                cgOnlineExternalCount: -3,
                kernelExternalCount: nil,
                softDisconnectedExternalCount: -1,
                areScreensAsleep: false
            ),
            0
        )
        XCTAssertEqual(
            SmartVirtualDisplayPolicy.resolveExternalPhysicalCount(
                cgOnlineExternalCount: -2,
                kernelExternalCount: -1,
                softDisconnectedExternalCount: 0,
                areScreensAsleep: false
            ),
            0
        )
        XCTAssertEqual(
            SmartVirtualDisplayPolicy.resolveExternalPhysicalCount(
                cgOnlineExternalCount: -1,
                kernelExternalCount: 0,
                softDisconnectedExternalCount: 0,
                areScreensAsleep: true
            ),
            0
        )
        XCTAssertEqual(
            SmartVirtualDisplayPolicy.resolveExternalPhysicalCount(
                cgOnlineExternalCount: 0,
                kernelExternalCount: 1,
                softDisconnectedExternalCount: 3,
                areScreensAsleep: false
            ),
            0
        )
    }
}
