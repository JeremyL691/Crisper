import CoreGraphics
import XCTest

final class PhysicalDisplayReconnectPolicyTests: XCTestCase {
    private typealias Enumerated = PhysicalDisplayReconnectPolicy.EnumeratedDisplay

    // MARK: - resolveTargetID

    func testMatchesByCoreGraphicsUUIDFirstEvenWhenDisplayIDChanged() {
        let target = PhysicalDisplayReconnectPolicy.resolveTargetID(
            recordDisplayID: 5,
            recordUUID: "UUID-A",
            enumerated: [
                Enumerated(id: 1, cgUUID: "UUID-BUILTIN"),
                Enumerated(id: 9, cgUUID: "UUID-A")
            ],
            onlineIDs: [1],
            otherDisconnectedIDs: [],
            rescuingBlackout: false,
            screensAsleep: false,
            activeDisplayCount: 1
        )
        XCTAssertEqual(target, 9)
    }

    func testUserReconnectFallsBackToSavedIDWhenDisabledDisplayHasNilUUID() {
        let target = PhysicalDisplayReconnectPolicy.resolveTargetID(
            recordDisplayID: 5,
            recordUUID: "UUID-A",
            enumerated: [
                Enumerated(id: 1, cgUUID: "UUID-BUILTIN"),
                Enumerated(id: 5, cgUUID: nil)
            ],
            onlineIDs: [1],
            otherDisconnectedIDs: [],
            rescuingBlackout: false,
            screensAsleep: false,
            activeDisplayCount: 1
        )
        XCTAssertEqual(target, 5)
    }

    func testUserReconnectRejectsAbsentSavedIDWhenDisplayIsUnplugged() {
        let target = PhysicalDisplayReconnectPolicy.resolveTargetID(
            recordDisplayID: 5,
            recordUUID: "UUID-A",
            enumerated: [
                Enumerated(id: 1, cgUUID: "UUID-BUILTIN")
            ],
            onlineIDs: [1],
            otherDisconnectedIDs: [],
            rescuingBlackout: false,
            screensAsleep: false,
            activeDisplayCount: 1
        )
        XCTAssertNil(target)
    }

    func testBlackoutRescueFallsBackWhenEnumeratedWithNilUUID() {
        // e.g. open-lid built-in rescue while Smart Dummy keeps WindowServer out of placeholder collapse
        let target = PhysicalDisplayReconnectPolicy.resolveTargetID(
            recordDisplayID: 1,
            recordUUID: "UUID-BUILTIN",
            enumerated: [
                Enumerated(id: 2, cgUUID: "UUID-SMART-DUMMY"),
                Enumerated(id: 1, cgUUID: nil)
            ],
            onlineIDs: [2],
            otherDisconnectedIDs: [],
            rescuingBlackout: true,
            screensAsleep: false,
            activeDisplayCount: 0
        )
        XCTAssertEqual(target, 1)
    }

    func testBlackoutRescueFallsBackWhenSLSCollapsedToPlaceholder() {
        let target = PhysicalDisplayReconnectPolicy.resolveTargetID(
            recordDisplayID: 1,
            recordUUID: "UUID-BUILTIN",
            enumerated: [
                Enumerated(id: 99, cgUUID: nil)
            ],
            onlineIDs: [],
            otherDisconnectedIDs: [],
            rescuingBlackout: true,
            screensAsleep: false,
            activeDisplayCount: 0
        )
        XCTAssertEqual(target, 1)
    }

    func testBlackoutRescueStandsDownWhenScreensAsleepOrActiveDisplayPresent() {
        let asleep = PhysicalDisplayReconnectPolicy.resolveTargetID(
            recordDisplayID: 1,
            recordUUID: "UUID-BUILTIN",
            enumerated: [Enumerated(id: 1, cgUUID: nil)],
            onlineIDs: [],
            otherDisconnectedIDs: [],
            rescuingBlackout: true,
            screensAsleep: true,
            activeDisplayCount: 0
        )
        XCTAssertNil(asleep)

        let active = PhysicalDisplayReconnectPolicy.resolveTargetID(
            recordDisplayID: 1,
            recordUUID: "UUID-BUILTIN",
            enumerated: [Enumerated(id: 1, cgUUID: nil)],
            onlineIDs: [2],
            otherDisconnectedIDs: [],
            rescuingBlackout: true,
            screensAsleep: false,
            activeDisplayCount: 1
        )
        XCTAssertNil(active)
    }

    func testRejectsSavedIDWhenReassignedToOnlineOrOtherDisplay() {
        // Reassigned to an online display
        XCTAssertNil(PhysicalDisplayReconnectPolicy.resolveTargetID(
            recordDisplayID: 5,
            recordUUID: "UUID-A",
            enumerated: [Enumerated(id: 5, cgUUID: nil)],
            onlineIDs: [5],
            otherDisconnectedIDs: [],
            rescuingBlackout: false,
            screensAsleep: false,
            activeDisplayCount: 1
        ))

        // Claimed by another disconnected record
        XCTAssertNil(PhysicalDisplayReconnectPolicy.resolveTargetID(
            recordDisplayID: 5,
            recordUUID: "UUID-A",
            enumerated: [Enumerated(id: 5, cgUUID: nil)],
            onlineIDs: [1],
            otherDisconnectedIDs: [5],
            rescuingBlackout: false,
            screensAsleep: false,
            activeDisplayCount: 1
        ))

        // Enumerated with a different non-nil CoreGraphics UUID
        XCTAssertNil(PhysicalDisplayReconnectPolicy.resolveTargetID(
            recordDisplayID: 5,
            recordUUID: "UUID-A",
            enumerated: [Enumerated(id: 5, cgUUID: "UUID-OTHER")],
            onlineIDs: [1],
            otherDisconnectedIDs: [],
            rescuingBlackout: false,
            screensAsleep: false,
            activeDisplayCount: 1
        ))

        // Null display ID
        XCTAssertNil(PhysicalDisplayReconnectPolicy.resolveTargetID(
            recordDisplayID: kCGNullDirectDisplay,
            recordUUID: "UUID-A",
            enumerated: [],
            onlineIDs: [],
            otherDisconnectedIDs: [],
            rescuingBlackout: true,
            screensAsleep: false,
            activeDisplayCount: 0
        ))
    }

    // MARK: - resolveStrandedSoftReconnectID

    func testStrandedSoftReconnectMatchesUUIDFirst() {
        let target = PhysicalDisplayReconnectPolicy.resolveStrandedSoftReconnectID(
            markedUUID: "UUID-EXT",
            savedDisplayID: 4,
            enumerated: [
                Enumerated(id: 1, cgUUID: "UUID-BUILTIN"),
                Enumerated(id: 7, cgUUID: "UUID-EXT")
            ],
            onlineIDs: [1]
        )
        XCTAssertEqual(target, 7)
    }

    func testStrandedSoftReconnectFallsBackToSavedIDWhenNilUUID() {
        let target = PhysicalDisplayReconnectPolicy.resolveStrandedSoftReconnectID(
            markedUUID: "UUID-EXT",
            savedDisplayID: 4,
            enumerated: [
                Enumerated(id: 1, cgUUID: "UUID-GUARD"),
                Enumerated(id: 4, cgUUID: nil)
            ],
            onlineIDs: [1]
        )
        XCTAssertEqual(target, 4)
    }

    func testStrandedSoftReconnectRejectsUnpluggedOnlineOrForeignID() {
        // Physically unplugged (absent from SLSGetDisplayList)
        XCTAssertNil(PhysicalDisplayReconnectPolicy.resolveStrandedSoftReconnectID(
            markedUUID: "UUID-EXT",
            savedDisplayID: 4,
            enumerated: [Enumerated(id: 1, cgUUID: "UUID-GUARD")],
            onlineIDs: [1]
        ))

        // Reassigned to another online display
        XCTAssertNil(PhysicalDisplayReconnectPolicy.resolveStrandedSoftReconnectID(
            markedUUID: "UUID-EXT",
            savedDisplayID: 4,
            enumerated: [Enumerated(id: 4, cgUUID: nil)],
            onlineIDs: [4]
        ))

        // Enumerated with a different non-nil UUID
        XCTAssertNil(PhysicalDisplayReconnectPolicy.resolveStrandedSoftReconnectID(
            markedUUID: "UUID-EXT",
            savedDisplayID: 4,
            enumerated: [Enumerated(id: 4, cgUUID: "UUID-OTHER")],
            onlineIDs: []
        ))

        // Legacy marker without savedDisplayID cannot guess
        XCTAssertNil(PhysicalDisplayReconnectPolicy.resolveStrandedSoftReconnectID(
            markedUUID: "UUID-EXT",
            savedDisplayID: nil,
            enumerated: [Enumerated(id: 4, cgUUID: nil)],
            onlineIDs: []
        ))
    }

    // MARK: - PendingSoftReconnect decoding & dual identical attachment fallback

    func testDecodePendingSoftReconnectSupportsCurrentAndLegacyFormats() throws {
        let modern = [PhysicalDisplayReconnectPolicy.PendingSoftReconnect(uuid: "UUID-1", displayID: 7)]
        let data = try JSONEncoder().encode(modern)
        XCTAssertEqual(
            PhysicalDisplayReconnectPolicy.decodePendingSoftReconnects(data: data, legacyUUIDs: nil),
            modern
        )
        XCTAssertEqual(
            PhysicalDisplayReconnectPolicy.decodePendingSoftReconnects(data: nil, legacyUUIDs: ["UUID-LEGACY"]),
            [PhysicalDisplayReconnectPolicy.PendingSoftReconnect(uuid: "UUID-LEGACY", displayID: nil)]
        )
    }

    func testUnclaimedIdenticalAttachmentHandlesDualSerialZeroWithoutLocation() {
        let saved = DDCServiceMatcher.Identity(vendor: 1, product: 2, serial: 0, location: nil)
        let attached: [(name: String?, identity: DDCServiceMatcher.Identity?)] = [
            (name: "Monitor", identity: saved),
            (name: "Monitor", identity: saved)
        ]
        // Both disconnected and attached, 0 online -> reconnectable
        XCTAssertTrue(PhysicalDisplayReconnectPolicy.hasUnclaimedIdenticalAttachment(
            recordName: "Monitor", savedIdentity: saved, attached: attached, onlinePeers: []
        ))
        // 1 attached and 1 online -> unplugged peer is hidden
        XCTAssertFalse(PhysicalDisplayReconnectPolicy.hasUnclaimedIdenticalAttachment(
            recordName: "Monitor", savedIdentity: saved,
            attached: [(name: "Monitor", identity: saved)],
            onlinePeers: [(name: "Monitor", identity: saved)]
        ))
        // Located records with distinct non-nil locations are NOT rescued by the nil-location fallback
        let portA = DDCServiceMatcher.Identity(vendor: 1, product: 2, serial: 0, location: "port-a")
        let portB = DDCServiceMatcher.Identity(vendor: 1, product: 2, serial: 0, location: "port-b")
        XCTAssertFalse(PhysicalDisplayReconnectPolicy.hasUnclaimedIdenticalAttachment(
            recordName: "Monitor", savedIdentity: portA,
            attached: [(name: "Monitor", identity: portB)],
            onlinePeers: []
        ))
    }
}
