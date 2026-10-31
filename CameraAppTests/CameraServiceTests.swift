import XCTest
import CoreGraphics
@testable import CameraApp

/// Pure-logic coverage for `CameraService`. The service itself needs hardware;
/// only the side-effect-free geometry helper is unit-testable off-device, but it
/// is the shared conversion Task 5's preview layer will call, so pin it down.
final class CameraServiceTests: XCTestCase {

    func testDevicePointNormalizesToUnitSquare() {
        let point = CameraService.devicePoint(
            forViewPoint: CGPoint(x: 25, y: 50),
            inPreviewSize: CGSize(width: 100, height: 200)
        )
        XCTAssertEqual(point.x, 0.25, accuracy: 0.0001)
        XCTAssertEqual(point.y, 0.25, accuracy: 0.0001)
    }

    func testDevicePointClampsOutOfBounds() {
        let low = CameraService.devicePoint(
            forViewPoint: CGPoint(x: -40, y: -10),
            inPreviewSize: CGSize(width: 100, height: 200)
        )
        XCTAssertEqual(low.x, 0)
        XCTAssertEqual(low.y, 0)

        let high = CameraService.devicePoint(
            forViewPoint: CGPoint(x: 900, y: 900),
            inPreviewSize: CGSize(width: 100, height: 200)
        )
        XCTAssertEqual(high.x, 1)
        XCTAssertEqual(high.y, 1)
    }

    func testDevicePointUsesCenterForDegenerateSize() {
        let point = CameraService.devicePoint(forViewPoint: .zero, inPreviewSize: .zero)
        XCTAssertEqual(point.x, 0.5)
        XCTAssertEqual(point.y, 0.5)
    }
}
