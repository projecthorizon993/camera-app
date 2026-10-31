import XCTest
@testable import CameraApp

/// Sanity checks on the pre-session A13 fallback capabilities. These values
/// drive capability gating across the app, so regressions must fail the build.
final class CameraCapabilitiesTests: XCTestCase {

    private let capabilities = CameraCapabilities.iPhone11ProMaxFallback

    func testFallbackSanity() {
        XCTAssertEqual(capabilities.maxShutterSeconds, 1.0)
        XCTAssertFalse(capabilities.supportsProRes)
        XCTAssertTrue(capabilities.zoomRange.contains(1.0))
    }

    func testFallbackLenses() {
        XCTAssertTrue(capabilities.hasUltraWide)
        XCTAssertTrue(capabilities.hasTele)
        XCTAssertEqual(capabilities.teleFactor, 2)
        XCTAssertEqual(capabilities.zoomRange.lowerBound, 0.5)
        XCTAssertEqual(capabilities.zoomRange.upperBound, 10)
    }

    func testProFeaturesAreGatedOff() {
        XCTAssertFalse(capabilities.supports10BitHDR)
        XCTAssertFalse(capabilities.supports48MP)
    }

    func testStillCapabilities() {
        XCTAssertTrue(capabilities.supportsRAW)
        XCTAssertEqual(capabilities.maxHardwareBracketCount, 3)
        XCTAssertEqual(capabilities.isoRange, 34...3456)
    }

    func testVideoCapabilities() {
        XCTAssertEqual(capabilities.supportedResolutions, [.hd1080, .uhd4K])
        XCTAssertEqual(capabilities.maxFPS, 240)
    }
}
