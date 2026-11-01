import XCTest
@testable import CameraApp

/// Zoom dial surface derivation (Task 7): optical stops from the present
/// lenses and the draggable range per camera position. These drive the
/// dial UI and the clamp applied before every `setZoom` push.
final class ZoomStopPlannerTests: XCTestCase {

    private static let a13Lenses: [LensInfo] = [
        LensInfo(id: .ultraWide, displayName: "0.5x", focalLengthMM: 13, aperture: 2.4),
        LensInfo(id: .wide, displayName: "1x", focalLengthMM: 26, aperture: 1.8),
        LensInfo(id: .tele, displayName: "2x", focalLengthMM: 52, aperture: 2.0),
        LensInfo(id: .front, displayName: "Front", focalLengthMM: 23, aperture: 2.2),
    ]

    func testBackStopsIncludeAllOpticalLenses() {
        let stops = ZoomStopPlanner.opticalStops(lenses: Self.a13Lenses, position: .back, teleFactor: 2)
        XCTAssertEqual(stops, [0.5, 1, 2])
    }

    func testFrontHasSingleStop() {
        let stops = ZoomStopPlanner.opticalStops(lenses: Self.a13Lenses, position: .front, teleFactor: 2)
        XCTAssertEqual(stops, [1])
    }

    func testStopsAscendingWithoutUltraWide() {
        let lenses = Self.a13Lenses.filter { $0.id != .ultraWide }
        let stops = ZoomStopPlanner.opticalStops(lenses: lenses, position: .back, teleFactor: 2.5)
        XCTAssertEqual(stops, [1, 2.5])
    }

    func testTeleStopNeverBelowTwo() {
        let stops = ZoomStopPlanner.opticalStops(lenses: Self.a13Lenses, position: .back, teleFactor: 1.5)
        XCTAssertEqual(stops, [0.5, 1, 2])
    }

    func testBackRangeUsesCapabilities() {
        let range = ZoomStopPlanner.draggableRange(capabilities: .iPhone11ProMaxFallback, position: .back)
        XCTAssertEqual(range, 0.5...10)
    }

    func testFrontRangeRaisesLowerBoundToOne() {
        let range = ZoomStopPlanner.draggableRange(capabilities: .iPhone11ProMaxFallback, position: .front)
        XCTAssertEqual(range.lowerBound, 1)
        XCTAssertEqual(range.upperBound, 10)
    }

    // MARK: - Task 10 — lens optical blocks + optical zoom region

    func testOpticalBlockWideSpansToTeleHandoff() {
        let block = ZoomStopPlanner.opticalBlock(
            lenses: Self.a13Lenses,
            position: .back,
            teleFactor: 2,
            lens: .wide
        )
        guard let block else { return XCTFail("wide optical block must exist on the back camera") }
        XCTAssertEqual(block, 1...2)
    }

    func testOpticalBlockTeleSpansToCapabilityCeiling() {
        let block = ZoomStopPlanner.opticalBlock(
            lenses: Self.a13Lenses,
            position: .back,
            teleFactor: 2,
            lens: .tele
        )
        guard let block else { return XCTFail("tele optical block must exist on the back camera") }
        XCTAssertEqual(block, 2...10)
    }

    func testOpticalBlockUltraWideSpansToWideStop() {
        let block = ZoomStopPlanner.opticalBlock(
            lenses: Self.a13Lenses,
            position: .back,
            teleFactor: 2,
            lens: .ultraWide
        )
        guard let block else { return XCTFail("ultraWide optical block must exist on the back camera") }
        XCTAssertEqual(block, 0.5...1)
    }

    func testOpticalBlockFrontIsNil() {
        let block = ZoomStopPlanner.opticalBlock(
            lenses: Self.a13Lenses,
            position: .back,
            teleFactor: 2,
            lens: .front
        )
        XCTAssertNil(block)
    }

    func testIsOpticalWithinStopsAndFalsePastTopStop() {
        let lenses = Self.a13Lenses
        let position = DevicePosition.back
        let teleFactor = 2
        XCTAssertTrue(ZoomStopPlanner.isOptical(factor: 0.5, lenses: lenses, position: position, teleFactor: teleFactor))
        XCTAssertTrue(ZoomStopPlanner.isOptical(factor: 1, lenses: lenses, position: position, teleFactor: teleFactor))
        XCTAssertTrue(ZoomStopPlanner.isOptical(factor: 1.9, lenses: lenses, position: position, teleFactor: teleFactor))
        XCTAssertTrue(ZoomStopPlanner.isOptical(factor: 2, lenses: lenses, position: position, teleFactor: teleFactor))
        XCTAssertFalse(ZoomStopPlanner.isOptical(factor: 4, lenses: lenses, position: position, teleFactor: teleFactor))
    }
}
