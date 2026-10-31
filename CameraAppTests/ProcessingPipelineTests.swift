import XCTest
import CoreVideo
@testable import CameraApp

// Pipeline-logic coverage (Foundation + CoreVideo only, no Metal, no AVFoundation):
// stage ordering, missing-stage pass-through, setStage swap reflection, context
// propagation, error propagation with stage id, and HUD stage-list observability.
//
// Buffer choice: real minimal 4×4 BGRA CVPixelBuffers created via
// CVPixelBufferCreate (CoreVideo is linkable for simulator-destination builds).
// Pixel content is irrelevant — stages only track identity and context — but a
// real buffer keeps the tests honest about the CVPixelBuffer-based contract.
final class ProcessingPipelineTests: XCTestCase {

    // MARK: Test doubles

    /// Thread-safe recorder shared by the stages of a single test run.
    private final class CallRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        private var contexts: [ProcessingContext] = []

        func record(_ entry: String) {
            lock.lock(); defer { lock.unlock() }
            entries.append(entry)
        }

        func recordContext(_ context: ProcessingContext) {
            lock.lock(); defer { lock.unlock() }
            contexts.append(context)
        }

        var recordedEntries: [String] {
            lock.lock(); defer { lock.unlock() }
            return entries
        }

        var recordedContexts: [ProcessingContext] {
            lock.lock(); defer { lock.unlock() }
            return contexts
        }
    }

    private enum MockError: Error {
        case aborted
    }

    /// Stage double that records its visit and optionally fails.
    private final class MockStage: ProcessingStageProtocol, @unchecked Sendable {
        let stage: PipelineStage
        let identifier: String
        let fails: Bool
        let recorder: CallRecorder

        init(stage: PipelineStage, identifier: String, fails: Bool = false, recorder: CallRecorder) {
            self.stage = stage
            self.identifier = identifier
            self.fails = fails
            self.recorder = recorder
        }

        func process(_ input: CVPixelBuffer, context: ProcessingContext) async throws -> CVPixelBuffer {
            recorder.record(identifier)
            recorder.recordContext(context)
            if fails {
                throw MockError.aborted
            }
            return input
        }
    }

    /// Minimal pixel buffer for identity/lifetime checks (PixelBox helper).
    private enum PixelBox {
        enum AllocationError: Error {
            case failed(CVReturn)
        }

        static func makeBuffer(width: Int = 4, height: Int = 4) throws -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                nil,
                &buffer
            )
            guard status == kCVReturnSuccess, let buffer else {
                throw AllocationError.failed(status)
            }
            return buffer
        }
    }

    private func makeContext() -> ProcessingContext {
        ProcessingContext(
            orientation: .portrait,
            exif: nil,
            strength: 0.75,
            metadata: ["test": "t6"]
        )
    }

    // MARK: Ordering

    func testRequestedStagesRunInEnumOrder() async throws {
        let pipeline = DefaultProcessingPipeline()
        let recorder = CallRecorder()
        // Register in scrambled order; execution must still follow enum order.
        pipeline.setStage(.look, MockStage(stage: .look, identifier: "look", recorder: recorder))
        pipeline.setStage(.develop, MockStage(stage: .develop, identifier: "develop", recorder: recorder))
        pipeline.setStage(.watermark, MockStage(stage: .watermark, identifier: "watermark", recorder: recorder))

        let buffer = try PixelBox.makeBuffer()
        let result = try await pipeline.run(buffer, stages: [.watermark, .develop, .look], context: makeContext())

        XCTAssertEqual(recorder.recordedEntries, ["develop", "look", "watermark"])
        XCTAssertTrue(result === buffer, "identity pass-through stages must return the input buffer")
    }

    // MARK: Pass-through

    func testMissingStagePassesThrough() async throws {
        let pipeline = DefaultProcessingPipeline()
        let recorder = CallRecorder()
        pipeline.setStage(.look, MockStage(stage: .look, identifier: "look", recorder: recorder))

        let buffer = try PixelBox.makeBuffer()
        let result = try await pipeline.run(buffer, stages: [.develop, .look], context: makeContext())

        XCTAssertEqual(recorder.recordedEntries, ["look"], "unregistered .develop must be skipped")
        XCTAssertTrue(result === buffer)
    }

    func testNoRegisteredStagesReturnsInputUnchanged() async throws {
        let pipeline = DefaultProcessingPipeline()
        let buffer = try PixelBox.makeBuffer()
        let result = try await pipeline.run(buffer, stages: PipelineStage.allCases, context: makeContext())
        XCTAssertTrue(result === buffer)
    }

    // MARK: Slot swap

    func testSetStageSwapIsReflected() async throws {
        let pipeline = DefaultProcessingPipeline()
        let recorder = CallRecorder()
        let buffer = try PixelBox.makeBuffer()
        let context = makeContext()

        pipeline.setStage(.look, MockStage(stage: .look, identifier: "first", recorder: recorder))
        _ = try await pipeline.run(buffer, stages: [.look], context: context)

        pipeline.setStage(.look, nil)
        _ = try await pipeline.run(buffer, stages: [.look], context: context)

        pipeline.setStage(.look, MockStage(stage: .look, identifier: "second", recorder: recorder))
        _ = try await pipeline.run(buffer, stages: [.look], context: context)

        XCTAssertEqual(recorder.recordedEntries, ["first", "second"], "clear then re-set must be reflected per run")
    }

    // MARK: Context propagation

    func testContextIsPropagatedToStages() async throws {
        let pipeline = DefaultProcessingPipeline()
        let recorder = CallRecorder()
        pipeline.setStage(.develop, MockStage(stage: .develop, identifier: "develop", recorder: recorder))
        pipeline.setStage(.look, MockStage(stage: .look, identifier: "look", recorder: recorder))

        let buffer = try PixelBox.makeBuffer()
        _ = try await pipeline.run(buffer, stages: [.develop, .look], context: makeContext())

        let contexts = recorder.recordedContexts
        XCTAssertEqual(contexts.count, 2)
        for context in contexts {
            XCTAssertEqual(context.orientation, .portrait)
            XCTAssertEqual(context.strength, 0.75, accuracy: 1e-9)
            XCTAssertEqual(context.metadata, ["test": "t6"])
            XCTAssertNil(context.exif)
        }
    }

    // MARK: Error propagation

    func testStageErrorPropagatesWithStageID() async throws {
        let pipeline = DefaultProcessingPipeline()
        let recorder = CallRecorder()
        pipeline.setStage(.develop, MockStage(stage: .develop, identifier: "develop", recorder: recorder))
        pipeline.setStage(.look, MockStage(stage: .look, identifier: "look", fails: true, recorder: recorder))

        let buffer = try PixelBox.makeBuffer()
        do {
            _ = try await pipeline.run(buffer, stages: [.develop, .look], context: makeContext())
            XCTFail("expected the failing .look stage to abort the run")
        } catch let error as PipelineError {
            guard case .stageFailed(let stage, let underlying) = error else {
                return XCTFail("unexpected PipelineError case: \(error)")
            }
            XCTAssertEqual(stage, .look, "error must carry the failing stage id")
            XCTAssertTrue(underlying is MockError)
            XCTAssertEqual(recorder.recordedEntries, ["develop", "look"], "chain stops at the failing stage")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: HUD observability

    func testActiveStagesReflectsRegistration() {
        let pipeline = DefaultProcessingPipeline()
        let recorder = CallRecorder()
        XCTAssertTrue(pipeline.activeStages.isEmpty)

        let develop = MockStage(stage: .develop, identifier: "develop", recorder: recorder)
        let look = MockStage(stage: .look, identifier: "look", recorder: recorder)
        pipeline.setStage(.look, look)
        pipeline.setStage(.develop, develop)
        XCTAssertEqual(pipeline.activeStages, [.develop, .look], "list must follow enum order")

        pipeline.setStage(.develop, nil)
        XCTAssertEqual(pipeline.activeStages, [.look])
    }
}
