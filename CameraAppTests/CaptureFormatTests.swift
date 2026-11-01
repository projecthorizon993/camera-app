import XCTest
@testable import CameraApp

/// Pure-logic coverage for capture formats and watermark template value
/// semantics. No hardware and no AVFoundation.
final class CaptureFormatTests: XCTestCase {

    func testRawValueRoundTrip() {
        for format in CaptureFormat.allCases {
            XCTAssertEqual(CaptureFormat(rawValue: format.rawValue), format)
        }
        XCTAssertEqual(CaptureFormat(rawValue: "jpeg"), .jpeg)
        XCTAssertEqual(CaptureFormat(rawValue: "heif"), .heif)
        XCTAssertEqual(CaptureFormat(rawValue: "dng"), .dng)
        XCTAssertNil(CaptureFormat(rawValue: "tiff"))
    }

    func testCaseSet() {
        XCTAssertEqual(Set(CaptureFormat.allCases).count, 3)
    }

    func testWatermarkTemplateEquatable() {
        let lines: [WatermarkLine] = [
            WatermarkLine(content: .deviceModel, relativeFontSize: 0.06),
            WatermarkLine(content: .focalAperture, relativeFontSize: 0.045),
        ]
        let divider = WatermarkDivider(thicknessFraction: 0.002, widthFraction: 0.6, colorHex: "#FFFFFF")

        let a = WatermarkTemplate(
            id: "classic", displayName: "Classic", lines: lines, divider: divider,
            alignment: .left, fontScale: 0.05, textColorHex: "#FFFFFF", backgroundBar: true
        )
        let b = WatermarkTemplate(
            id: "classic", displayName: "Classic", lines: lines, divider: divider,
            alignment: .left, fontScale: 0.05, textColorHex: "#FFFFFF", backgroundBar: true
        )
        let c = WatermarkTemplate(
            id: "minimal", displayName: "Minimal", lines: lines, divider: nil,
            alignment: .right, fontScale: 0.04, textColorHex: "#000000", backgroundBar: false
        )

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testWatermarkContentEquatable() {
        XCTAssertEqual(WatermarkContent.literal("ISO"), .literal("ISO"))
        XCTAssertEqual(WatermarkContent.timestamp("yyyy-MM-dd"), .timestamp("yyyy-MM-dd"))
        XCTAssertNotEqual(WatermarkContent.literal("ISO"), .deviceModel)
    }

    // MARK: - StorageEstimator

    func testStorageEstimatorPerShotBytesPositive() {
        for format in CaptureFormat.allCases {
            XCTAssertGreaterThan(StorageEstimator.estimatePerShotBytes(format), 0)
        }
    }

    func testStorageEstimatorRemainingShots() {
        XCTAssertEqual(StorageEstimator.remainingShots(freeBytes: 10 * 1024 * 1024, for: .dng), 0)
        XCTAssertEqual(StorageEstimator.remainingShots(freeBytes: 30 * 1024 * 1024, for: .jpeg), 7)
        // No free space (or a negative sentinel from a failed probe) yields
        // zero remaining shots for EVERY format.
        for format in CaptureFormat.allCases {
            XCTAssertEqual(StorageEstimator.remainingShots(freeBytes: 0, for: format), 0)
            XCTAssertEqual(StorageEstimator.remainingShots(freeBytes: -1, for: format), 0)
        }
    }

    // MARK: - CaptureSettingsModel selectFormat exclusivity

    @MainActor
    func testSelectFormatDngResetsFlash() {
        let model = CaptureSettingsModel()
        model.flashMode = .on
        model.selectFormat(.dng)
        XCTAssertEqual(model.format, .dng)
        XCTAssertEqual(model.flashMode, .off)
    }
}
