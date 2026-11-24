import XCTest

final class DDCInputSourceParsingRegressionTests: XCTestCase {
    func testNegativeDecimalAndHexAreRejected() {
        for input in ["-17", "-0x11", " \t-17\n", "0x-11", "1-7", "−17"] {
            XCTAssertNil(DDCInputSource.value(from: input), input)
        }
    }

    func testHyphenatedConnectorNamesStillResolve() {
        XCTAssertEqual(DDCInputSource.value(from: "usb-c"), 0x1B)
        XCTAssertEqual(DDCInputSource.value(from: "Display-Port 1"), 0x0F)
        XCTAssertEqual(DDCInputSource.value(from: "display-port-2"), 0x10)
    }
}
