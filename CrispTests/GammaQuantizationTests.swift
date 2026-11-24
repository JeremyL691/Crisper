import XCTest

final class GammaQuantizationTests: XCTestCase {
    func testTwoLevelsPreserveDimmedAndBoostedCeilings() {
        let adjustment = GammaAdjustment(quantizationLevels: 2)
        for ceiling in [0.05, 0.5, 1.0, 1.6] {
            let steps = Set((0...256).map {
                adjustment.quantized(Double($0) / 256 * ceiling, lower: 0, upper: ceiling)
            })
            XCTAssertEqual(steps, [0, ceiling])
        }
    }

    func testQuantizationPreservesBlackOffsetAndFlatChannels() {
        let adjustment = GammaAdjustment(quantizationLevels: 2)
        XCTAssertEqual(adjustment.quantized(0.1, lower: 0.1, upper: 0.5), 0.1)
        XCTAssertEqual(adjustment.quantized(0.5, lower: 0.1, upper: 0.5), 0.5)
        XCTAssertEqual(adjustment.quantized(0.25, lower: 0.25, upper: 0.25), 0.25)
    }
}
