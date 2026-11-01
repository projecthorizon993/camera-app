import XCTest
import CoreVideo
@testable import CameraApp

final class PipelineStageTests: XCTestCase {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var _stages: [PipelineStage] = []
        func record(_ stage: PipelineStage) {
            lock.lock(); defer { lock.unlock() }
            _stages.append(stage)
        }
        var stages: [PipelineStage] { lock.lock(); defer { lock.unlock() }; return _stages }
    }

    private enum TestError: Error { case boom }

    private final class StubStage: ProcessingStageProtocol, @unchecked Sendable {
        let stage: PipelineStage
        let counter: Counter
        let shouldFail: Bool
        init(stage: PipelineStage, counter: Counter, shouldFail: Bool = false) {
            self.stage = stage
            self.counter = counter
            self.shouldFail = shouldFail
        }
        func process(_ input: CVPixelBuffer, context: ProcessingContext) async throws -> CVPixelBuffer {
            counter.record(stage)
            if shouldFail { throw TestError.boom }
            return input
        }
    }

    private enum PixelBox {
        static func makeBuffer(width: Int = 4, height: Int = 4) throws -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer
            )
            guard status == kCVReturnSuccess, let buffer else {
                throw NSError(domain: "PipelineStageTests", code: Int(status))
            }
            return buffer
        }
    }

    private func makeContext() -> ProcessingContext {
        ProcessingContext(orientation: .portrait, exif: nil, strength: 0.5, metadata: [:])
    }

    // MARK: - Missing stages pass through

    func testMissingStagesPassThroughUnchanged() async throws {
        let pipeline = DefaultProcessingPipeline()
        let counter = Counter()
        pipeline.setStage(.look, StubStage(stage: .look, counter: counter))

        let buffer = try PixelBox.makeBuffer()
        let result = try await pipeline.run(buffer, stages: [.lensCorrection, .look, .watermark], context: makeContext())

        XCTAssertEqual(counter.stages, [.look])
        XCTAssertTrue(result === buffer)
    }

    // MARK: - Enum order regardless of request order

    func testStagesRunInEnumOrderRegardlessOfRequestOrder() async throws {
        let pipeline = DefaultProcessingPipeline()
        let counter = Counter()
        pipeline.setStage(.watermark, StubStage(stage: .watermark, counter: counter))
        pipeline.setStage(.lensCorrection, StubStage(stage: .lensCorrection, counter: counter))
        pipeline.setStage(.look, StubStage(stage: .look, counter: counter))

        let buffer = try PixelBox.makeBuffer()
        let result = try await pipeline.run(buffer, stages: [.watermark, .lensCorrection, .look], context: makeContext())

        XCTAssertEqual(counter.stages, [.lensCorrection, .look, .watermark])
        XCTAssertTrue(result === buffer)
    }

    // MARK: - Failing stage aborts with stage id

    func testFailingStageAbortsAndCarriesStageId() async throws {
        let pipeline = DefaultProcessingPipeline()
        let counter = Counter()
        pipeline.setStage(.lensCorrection, StubStage(stage: .lensCorrection, counter: counter))
        pipeline.setStage(.look, StubStage(stage: .look, counter: counter, shouldFail: true))
        pipeline.setStage(.watermark, StubStage(stage: .watermark, counter: counter))

        let buffer = try PixelBox.makeBuffer()
        do {
            _ = try await pipeline.run(buffer, stages: [.lensCorrection, .look, .watermark], context: makeContext())
            XCTFail("expected failure")
        } catch let error as PipelineError {
            guard case .stageFailed(let stage, _) = error else {
                return XCTFail("unexpected case")
            }
            XCTAssertEqual(stage, .look)
            XCTAssertEqual(counter.stages, [.lensCorrection, .look])
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}