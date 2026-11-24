import XCTest

/// CPU ticks and disk byte counters are cumulative; a rate must only span two consecutive
/// samples, never a period in which polling was paused.
final class CounterBaselineTests: XCTestCase {
    func testFirstReadingOnlyArmsBaseline() {
        var baseline = CounterBaseline<UInt64>()
        XCTAssertFalse(baseline.isArmed)
        XCTAssertNil(baseline.advance(to: 100))
        XCTAssertTrue(baseline.isArmed)
    }

    func testConsecutiveReadingsPairWithPredecessor() throws {
        var baseline = CounterBaseline<UInt64>()
        _ = baseline.advance(to: 100)
        let first = try XCTUnwrap(baseline.advance(to: 150))
        XCTAssertEqual(first.previous, 100)
        XCTAssertEqual(first.current, 150)
        let second = try XCTUnwrap(baseline.advance(to: 175))
        XCTAssertEqual(second.previous, 150)
        XCTAssertEqual(second.current, 175)
    }

    func testResetDropsReadingTakenBeforePause() throws {
        var baseline = CounterBaseline<UInt64>()
        _ = baseline.advance(to: 100)
        baseline.reset()
        XCTAssertFalse(baseline.isArmed)
        XCTAssertNil(baseline.advance(to: 90_000), "the reading after a pause re-arms instead of spanning the pause")
        let pair = try XCTUnwrap(baseline.advance(to: 90_040))
        XCTAssertEqual(pair.previous, 90_000)
    }

    func testDiskSnapshotWithThroughputKeepsCapacityFields() {
        let volume = VolumeInfo(
            id: "data", name: "Data", mountPath: "/Volumes/Data", fileSystem: "apfs",
            usedBytes: 1_500, totalBytes: 2_000, isInternal: false, usedFraction: 0.75
        )
        let snapshot = DiskSnapshot(
            name: "Macintosh HD", usedBytes: 600, totalBytes: 1_000, readBytesPerSec: 0, writeBytesPerSec: 0,
            temperatureC: 41, volumes: [volume], usedFraction: 0.6
        )
        let updated = snapshot.withThroughput(readBytesPerSec: 12, writeBytesPerSec: 34)
        XCTAssertEqual(updated.readBytesPerSec, 12)
        XCTAssertEqual(updated.writeBytesPerSec, 34)
        XCTAssertEqual(
            updated.withThroughput(readBytesPerSec: 0, writeBytesPerSec: 0),
            snapshot
        )
    }
}
