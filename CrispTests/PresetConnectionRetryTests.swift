import XCTest

final class PresetConnectionRetryTests: XCTestCase {
    func testRetryPlansOnlyRemainingChangesAfterPartialApply() {
        let preset = DisplayPreset(name: "Desk", icon: "display", displays: [
            DisplayPresetEntry(displayUUID: "TARGET", connected: true),
            DisplayPresetEntry(displayUUID: "FIRST", connected: false),
            DisplayPresetEntry(displayUUID: "SECOND", connected: false)
        ])

        let initial = preset.connectionPlan(online: ["FIRST", "SECOND"], disconnected: ["TARGET"])
        XCTAssertEqual(initial.reconnect, ["TARGET"])
        XCTAssertEqual(initial.disconnect, ["FIRST", "SECOND"])

        // After TARGET reconnects and FIRST disconnects, retrying only schedules SECOND.
        let retry = preset.connectionPlan(online: ["TARGET", "SECOND"], disconnected: ["FIRST"])
        XCTAssertTrue(retry.reconnect.isEmpty)
        XCTAssertEqual(retry.disconnect, ["SECOND"])

        // Once SECOND also disconnects, re-applying plans no further connection changes.
        let settled = preset.connectionPlan(online: ["TARGET"], disconnected: ["FIRST", "SECOND"])
        XCTAssertEqual(settled, PresetConnectionPlan())
    }

    func testRetryAfterInputRestoreWarningDoesNotRequeueOnlineDisplay() {
        // When reconnect brings the framebuffer online and removes it from `disconnected`
        // (returning .inputRestoreFailed only as a DDC warning), retrying must not re-queue it.
        let preset = DisplayPreset(name: "Studio", icon: "display", displays: [
            DisplayPresetEntry(displayUUID: "EXT", connected: true),
            DisplayPresetEntry(displayUUID: "BUILTIN", connected: false)
        ])

        let retry = preset.connectionPlan(online: ["EXT", "BUILTIN"], disconnected: [])
        XCTAssertTrue(retry.reconnect.isEmpty)
        XCTAssertEqual(retry.disconnect, ["BUILTIN"])
    }

    func testRefusedLastDisplayDisconnectRetriesOnlyWhenFallbackIsOnline() {
        let preset = DisplayPreset(name: "Clamshell", icon: "display", displays: [
            DisplayPresetEntry(displayUUID: "EXT", connected: true),
            DisplayPresetEntry(displayUUID: "BUILTIN", connected: false)
        ])

        // Undocked: EXT is unplugged (not in online or disconnected), BUILTIN is the sole online screen.
        let undocked = preset.connectionPlan(online: ["BUILTIN"], disconnected: [])
        XCTAssertTrue(undocked.reconnect.isEmpty)
        XCTAssertEqual(undocked.disconnect, ["BUILTIN"])

        // Once docked with EXT online, retrying still plans disconnecting BUILTIN.
        let docked = preset.connectionPlan(online: ["EXT", "BUILTIN"], disconnected: [])
        XCTAssertTrue(docked.reconnect.isEmpty)
        XCTAssertEqual(docked.disconnect, ["BUILTIN"])
    }

    func testNilConnectionEntriesAreNeverScheduledDuringRetry() {
        let preset = DisplayPreset(name: "Mixed", icon: "display", displays: [
            DisplayPresetEntry(displayUUID: "EXT", brightness: 0.7),
            DisplayPresetEntry(displayUUID: "BUILTIN", connected: false)
        ])

        let plan = preset.connectionPlan(online: ["BUILTIN"], disconnected: ["EXT"])
        XCTAssertTrue(plan.reconnect.isEmpty)
        XCTAssertEqual(plan.disconnect, ["BUILTIN"])
    }
}
