import XCTest
import Foundation
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
@testable import CameraApp

final class ExportIntegrationTests: XCTestCase {

    private final class RecordingPipeline: ProcessingPipelineProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var _stages: [PipelineStage] = []
        private var _contexts: [ProcessingContext] = []
        var shouldThrow = false

        var recordedStages: [PipelineStage] { lock.withLock { _stages } }
        var recordedContexts: [ProcessingContext] { lock.withLock { _contexts } }

        func setStage(_ stage: PipelineStage, _ processor: ProcessingStageProtocol?) {}
        func run(_ input: CVPixelBuffer, stages: [PipelineStage], context: ProcessingContext) async throws -> CVPixelBuffer {
            lock.withLock {
                _stages.append(contentsOf: stages)
                _contexts.append(context)
            }
            if shouldThrow {
                throw NSError(domain: "ExportIntegrationTests", code: 1, userInfo: nil)
            }
            return input
        }
    }

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

    // MARK: - stagesApplied matrix

    func testJPEGAppliesAllStages() async {
        let pipeline = RecordingPipeline()
        let processor = ExportProcessor(pipeline: pipeline)
        let photo = CapturedPhoto(data: makeJPEG(), format: .jpeg, width: 4, height: 4, exifSummary: nil)
        let result = await processor.process(photo, plan: ExportPlan(format: .jpeg))

        XCTAssertFalse(result.fellBack)
        XCTAssertEqual(result.stagesApplied, [.lensCorrection, .look, .watermark])
    }

    func testHEIFAppliesAllStages() async {
        let pipeline = RecordingPipeline()
        let processor = ExportProcessor(pipeline: pipeline)
        let photo = CapturedPhoto(data: makeJPEG(), format: .heif, width: 4, height: 4, exifSummary: nil)
        let result = await processor.process(photo, plan: ExportPlan(format: .heif))

        XCTAssertFalse(result.fellBack)
        XCTAssertEqual(result.stagesApplied, [.lensCorrection, .look, .watermark])
    }

    func testDNGHasEmptyStages() async {
        let pipeline = RecordingPipeline()
        let processor = ExportProcessor(pipeline: pipeline)
        let data = Data([0x01, 0x02, 0x03])
        let photo = CapturedPhoto(data: data, format: .dng, width: 4, height: 4, exifSummary: nil)
        let result = await processor.process(photo, plan: ExportPlan(format: .dng))

        XCTAssertFalse(result.fellBack)
        XCTAssertEqual(result.stagesApplied, [])
    }

    // MARK: - Throwing pipeline fallback

    func testThrowingPipelineFallsBackAndPhotoUnchanged() async {
        let pipeline = RecordingPipeline()
        pipeline.shouldThrow = true
        let processor = ExportProcessor(pipeline: pipeline)
        let photo = CapturedPhoto(data: makeJPEG(), format: .jpeg, width: 4, height: 4, exifSummary: nil)
        let result = await processor.process(photo, plan: ExportPlan(format: .jpeg))

        XCTAssertTrue(result.fellBack)
        XCTAssertEqual(result.stagesApplied, [])
        XCTAssertEqual(result.photo.data, photo.data)
        XCTAssertEqual(result.photo.format, photo.format)
        XCTAssertEqual(result.photo.width, photo.width)
        XCTAssertEqual(result.photo.height, photo.height)
    }

    // MARK: - DNG passed through untouched

    func testDNGPassedThroughUntouched() async {
        let pipeline = RecordingPipeline()
        let processor = ExportProcessor(pipeline: pipeline)
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let photo = CapturedPhoto(data: data, format: .dng, width: 4, height: 4, exifSummary: nil)
        let result = await processor.process(photo, plan: ExportPlan(format: .dng))

        XCTAssertEqual(result.stagesApplied, [])
        XCTAssertEqual(result.photo.data, photo.data)
        XCTAssertFalse(result.fellBack)
    }

    // MARK: - Context recording

    func testPipelineRecordsContextWithExifAndStrength() async {
        let pipeline = RecordingPipeline()
        let processor = ExportProcessor(pipeline: pipeline)
        let exif = ExifSummary(
            deviceModel: "iPhone",
            lensID: .wide,
            focalMM: 26,
            aperture: 1.8,
            shutterSeconds: 0.01,
            iso: 100,
            capturedAt: Date()
        )
        let photo = CapturedPhoto(data: makeJPEG(), format: .jpeg, width: 4, height: 4, exifSummary: exif)
        _ = await processor.process(photo, plan: ExportPlan(format: .jpeg))

        XCTAssertEqual(pipeline.recordedContexts.count, 1)
        guard let ctx = pipeline.recordedContexts.first else {
            XCTFail("no context recorded"); return
        }
        XCTAssertEqual(ctx.strength, 1.0, accuracy: 1e-9)
        XCTAssertEqual(ctx.exif?.deviceModel, exif.deviceModel)
        XCTAssertEqual(ctx.exif?.lensID, exif.lensID)
    }
}