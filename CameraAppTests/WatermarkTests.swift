import XCTest
import CoreGraphics
@testable import CameraApp

final class WatermarkTests: XCTestCase {

    // MARK: color(fromHex:)

    func testColorFromHexBasic() {
        let c = WatermarkPlanner.color(fromHex: "#FF0000")
        XCTAssertNotNil(c)
        let comp = c!.components!
        XCTAssertEqual(comp[0], 1.0, accuracy: 0.001)
        XCTAssertEqual(comp[1], 0.0, accuracy: 0.001)
        XCTAssertEqual(comp[2], 0.0, accuracy: 0.001)
        XCTAssertEqual(comp[3], 1.0, accuracy: 0.001)
    }

    func testColorFromHexNoHashAndAlpha() {
        let c1 = WatermarkPlanner.color(fromHex: "ff0000")
        XCTAssertNotNil(c1)
        let c2 = WatermarkPlanner.color(fromHex: "FF000080")
        XCTAssertNotNil(c2)
        let comp2 = c2!.components!
        XCTAssertEqual(comp2[3], 0x80 / 255.0, accuracy: 0.001)
    }

    func testColorFromHexMalformed() {
        XCTAssertNil(WatermarkPlanner.color(fromHex: ""))
        XCTAssertNil(WatermarkPlanner.color(fromHex: "GGG"))
        XCTAssertNil(WatermarkPlanner.color(fromHex: "#12"))
    }

    // MARK: shutterText

    func testShutterText() {
        XCTAssertNil(WatermarkPlanner.shutterText(seconds: nil))
        XCTAssertEqual(WatermarkPlanner.shutterText(seconds: 1.0 / 125.0), "1/125")
        XCTAssertEqual(WatermarkPlanner.shutterText(seconds: 2.0), "2.0 s")
        XCTAssertEqual(WatermarkPlanner.shutterText(seconds: 0.5), "1/2")
    }

    // MARK: isoText

    func testIsoText() {
        XCTAssertEqual(WatermarkPlanner.isoText(iso: 125), "ISO 125")
        XCTAssertNil(WatermarkPlanner.isoText(iso: nil))
    }

    // MARK: resolve

    func testResolveLiteral() {
        XCTAssertEqual(WatermarkPlanner.resolve(content: .literal("hi"),
                                                exif: nil, metadata: [:]), "hi")
    }

    func testResolveTimestamp() {
        let date = Date(timeIntervalSince1970: 0)
        let exif = ExifSummary(deviceModel: "M", lensID: nil, focalMM: nil,
                               aperture: nil, shutterSeconds: nil, iso: nil,
                               capturedAt: date)
        let result = WatermarkPlanner.resolve(content: .timestamp("yyyy-MM-dd HH:mm"),
                                             exif: exif, metadata: [:])
        XCTAssertEqual(result, "1970-01-01 00:00")
    }

    func testResolveDeviceModel() {
        let exif = ExifSummary(deviceModel: "Device X", lensID: nil, focalMM: nil,
                               aperture: nil, shutterSeconds: nil, iso: nil,
                               capturedAt: Date())
        XCTAssertEqual(WatermarkPlanner.resolve(content: .deviceModel, exif: exif,
                                                metadata: [:]), "Device X")
        XCTAssertNil(WatermarkPlanner.resolve(content: .deviceModel, exif: nil,
                                              metadata: [:]))
    }

    func testResolveCoordinates() {
        XCTAssertEqual(WatermarkPlanner.resolve(content: .coordinates, exif: nil,
                                                metadata: ["locationText": "37.0, -122.0"]),
                       "37.0, -122.0")
        XCTAssertNil(WatermarkPlanner.resolve(content: .coordinates, exif: nil,
                                              metadata: [:]))
    }

    // MARK: shouldApply

    func testShouldApply() {
        XCTAssertFalse(WatermarkPlanner.shouldApply(format: .dng))
        XCTAssertTrue(WatermarkPlanner.shouldApply(format: .heif))
        XCTAssertTrue(WatermarkPlanner.shouldApply(format: .jpeg))
    }

    // MARK: layout

    func testLayoutAllPositionsInBounds() {
        let template = WatermarkLibrary.builtins[0]
        let size = CGSize(width: 1000, height: 800)
        for pos in WatermarkPosition.allCases {
            let layout = WatermarkPlanner.layout(template: template, position: pos, size: size)
            XCTAssertTrue(layout.blockRect.minX >= 0, "\(pos)")
            XCTAssertTrue(layout.blockRect.minY >= 0, "\(pos)")
            XCTAssertTrue(layout.blockRect.maxX <= size.width, "\(pos)")
            XCTAssertTrue(layout.blockRect.maxY <= size.height, "\(pos)")
        }
    }

    func testLayoutBottomCenterBarAnchored() {
        let template = WatermarkLibrary.builtins[0]
        let size = CGSize(width: 1000, height: 800)
        let layout = WatermarkPlanner.layout(template: template, position: .bottomCenter, size: size)
        XCTAssertNotNil(layout.barRect)
        XCTAssertEqual(layout.barRect!.maxY, size.height, accuracy: 0.001)
        XCTAssertGreaterThan(layout.barRect!.width, layout.blockRect.width)
    }

    func testLayoutFontScaleZeroZeroHeight() {
        let base = WatermarkLibrary.builtins[0]
        let template = WatermarkTemplate(id: base.id, displayName: base.displayName,
                                        lines: base.lines, divider: base.divider,
                                        alignment: base.alignment, fontScale: 0,
                                        textColorHex: base.textColorHex,
                                        backgroundBar: base.backgroundBar)
        let size = CGSize(width: 1000, height: 800)
        let layout = WatermarkPlanner.layout(template: template, position: .bottomCenter, size: size)
        for r in layout.lineRects {
            XCTAssertEqual(r.height, 0, accuracy: 0.001)
        }
    }

    // MARK: library

    func testLibraryIds() {
        let ids = WatermarkLibrary.builtins.map(\.id)
        XCTAssertEqual(Set(ids), Set(["signature-bar", "corner-stamp", "location-strip"]))
    }

    func testLibraryNoTrademarks() {
        for t in WatermarkLibrary.builtins {
            let lower = (t.id + " " + t.displayName).lowercased()
            XCTAssertFalse(lower.contains("canon"))
            XCTAssertFalse(lower.contains("nikon"))
            XCTAssertFalse(lower.contains("sony"))
            XCTAssertFalse(lower.contains("apple"))
        }
    }

    // MARK: renderer

    func testRendererAvailableTemplates() {
        let r = WatermarkRenderer()
        XCTAssertEqual(r.availableTemplates.count, 3)
    }
}
