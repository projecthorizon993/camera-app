import XCTest
@testable import CameraApp

/// Pure-logic coverage for the bracketed-capture depth model. No hardware.
final class BracketDepthTests: XCTestCase {

    func testRawValues() {
        XCTAssertEqual(BracketDepth.aeb3.rawValue, 3)
        XCTAssertEqual(BracketDepth.soft5.rawValue, 5)
        XCTAssertEqual(BracketDepth.soft7.rawValue, 7)
        XCTAssertEqual(BracketDepth.soft9.rawValue, 9)
    }

    func testFrameCountMatchesRawValue() {
        for depth in BracketDepth.allCases {
            XCTAssertEqual(depth.frameCount, depth.rawValue)
        }
        XCTAssertEqual(BracketDepth.aeb3.frameCount, 3)
        XCTAssertEqual(BracketDepth.soft5.frameCount, 5)
        XCTAssertEqual(BracketDepth.soft7.frameCount, 7)
        XCTAssertEqual(BracketDepth.soft9.frameCount, 9)
    }

    func testOnlyAEB3IsHardware() {
        for depth in BracketDepth.allCases {
            XCTAssertEqual(depth.isHardware, depth == .aeb3, "unexpected hardware flag for \(depth)")
        }
        XCTAssertTrue(BracketDepth.aeb3.isHardware)
        XCTAssertFalse(BracketDepth.soft5.isHardware)
        XCTAssertFalse(BracketDepth.soft7.isHardware)
        XCTAssertFalse(BracketDepth.soft9.isHardware)
    }

    func testCaseSet() {
        XCTAssertEqual(BracketDepth.allCases.count, 4)
    }
}
