import XCTest

final class PresetConnectionRetryTests: XCTestCase {
    func testRetryPlansOnlyTheRemainingChangesAfterPartialApply() {
        let preset = DisplayPreset(name: "Desk", icon: "display", displays: [
            DisplayPresetEntry(displayUUID: "TARGET", connected: true),
            DisplayPresetEntry(displayUUID: "FIRST", connected: false),
            DisplayPresetEntry(displayUUID: "SECOND", connected: false)
        ])

        let initial = preset.connectionPlan(online: ["FIRST", "SECOND"], disconnected: ["TARGET"])
        XCTAssertEqual(initial.reconnect, ["TARGET"])
        XCTAssertEqual(initial.disconnect, ["FIRST", "SECOND"])

        let retry = preset.connectionPlan(online: ["TARGET", "SECOND"], disconnected: ["FIRST"])
        XCTAssertTrue(retry.reconnect.isEmpty)
        XCTAssertEqual(retry.disconnect, ["SECOND"])
    }
}
