import XCTest
import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
@testable import CameraApp

final class ExportPlannerTests: XCTestCase {

    // MARK: - Planner

    func testDngReturnsEmptyEvenAllFlagsTrue() {
        let plan = ExportPlan(format: .dng, wantsCorrection: true, wantsLook: true, wantsWatermark: true)
        XCTAssertEqual(ExportPlanner.stages(plan: plan), [])
    }

    func testJpegFullSetOrdering() {
        XCTAssertEqual(ExportPlanner.stages(plan: ExportPlan(format: .jpeg)),
                       [.lensCorrection, .look, .watermark])
    }

    func testHeifFullSetOrdering() {
        XCTAssertEqual(ExportPlanner.stages(plan: ExportPlan(format: .heif)),
                       [.lensCorrection, .look, .watermark])
    }

    func testCorrectionFlagDropsLensCorrection() {
        var plan = ExportPlan(format: .jpeg)
        plan.wantsCorrection = false
        XCTAssertEqual(ExportPlanner.stages(plan: plan), [.look, .watermark])
    }

    func testLookFlagDropsLook() {
        var plan = ExportPlan(format: .jpeg)
        plan.wantsLook = false
        XCTAssertEqual(ExportPlanner.stages(plan: plan), [.lensCorrection, .watermark])
    }

    func testWatermarkFlagDropsWatermark() {
        var plan = ExportPlan(format: .jpeg)
        plan.wantsWatermark = false
        XCTAssertEqual(ExportPlanner.stages(plan: plan), [.lensCorrection, .look])
    }

    func testShouldApplyCrossCheck() {
        XCTAssertFalse(WatermarkPlanner.shouldApply(format: .dng))
        XCTAssertTrue(WatermarkPlanner.shouldApply(format: .jpeg))
        XCTAssertTrue(WatermarkPlanner.shouldApply(format: .heif))
    }

    // MARK: - PixelBufferDecoding

    func testPixelBufferDecodeDimsAndColor() throws {
        let width = 16
        let height = 16
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = 30      // B
            pixels[i + 1] = 50  // G
            pixels[i + 2] = 200 // R
            pixels[i + 3] = 255 // A
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                     | CGBitmapInfo.byteOrder32Little.rawValue)
        let cgImage = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: bitmapInfo,
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )!

        let mutableData = NSMutableData()
        let dest = CGImageDestinationCreateWithData(mutableData, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let jpegData = mutableData as Data

        let buffer = try PixelBufferDecoding.pixelBuffer(from: jpegData)
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), width)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), height)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let r = base[2]
        let g = base[1]
        let b = base[0]
        XCTAssertGreaterThan(r, 150)
        XCTAssertLessThan(g, 100)
        XCTAssertLessThan(b, 80)
    }

    // MARK: - Fallback

    func testFallbackGarbageBytes() async {
        let processor = ExportProcessor(pipeline: DefaultProcessingPipeline())
        let photo = CapturedPhoto(data: Data("not an image".utf8), format: .jpeg,
                                 width: 4, height: 4, exifSummary: nil)
        let result = await processor.process(photo, plan: ExportPlan(format: .jpeg))
        XCTAssertTrue(result.fellBack)
        XCTAssertEqual(result.stagesApplied, [])
        XCTAssertEqual(result.photo.data, photo.data)
        XCTAssertEqual(result.photo.format, photo.format)
        XCTAssertEqual(result.photo.width, photo.width)
        XCTAssertEqual(result.photo.height, photo.height)
    }

    func testFallbackThrowingPipeline() async {
        let jpeg = makeJPEG()
        let photo = CapturedPhoto(data: jpeg, format: .jpeg, width: 4, height: 4, exifSummary: nil)
        let processor = ExportProcessor(pipeline: ThrowingPipeline())
        let result = await processor.process(photo, plan: ExportPlan(format: .jpeg))
        XCTAssertTrue(result.fellBack)
        XCTAssertEqual(result.stagesApplied, [])
        XCTAssertEqual(result.photo.data, photo.data)
        XCTAssertEqual(result.photo.format, photo.format)
        XCTAssertEqual(result.photo.width, photo.width)
        XCTAssertEqual(result.photo.height, photo.height)
    }

    // MARK: - Helpers

    private func makeJPEG(width: Int = 4, height: Int = 4) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 128, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = 100
            pixels[i + 1] = 150
            pixels[i + 2] = 200
            pixels[i + 3] = 255
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                     | CGBitmapInfo.byteOrder32Little.rawValue)
        let cgImage = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: bitmapInfo,
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )!
        let mutableData = NSMutableData()
        let dest = CGImageDestinationCreateWithData(mutableData, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cgImage, nil)
        _ = CGImageDestinationFinalize(dest)
        return mutableData as Data
    }

    private final class ThrowingPipeline: ProcessingPipelineProtocol, @unchecked Sendable {
        func setStage(_ stage: PipelineStage, _ processor: ProcessingStageProtocol?) {}
        func run(_ input: CVPixelBuffer, stages: [PipelineStage], context: ProcessingContext) async throws -> CVPixelBuffer {
            throw NSError(domain: "ExportPlannerTests", code: 1, userInfo: nil)
        }
    }
}