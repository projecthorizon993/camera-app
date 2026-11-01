import Foundation
import CoreVideo

// MARK: - LookStageAdapter

/// Adapter exposing a `LookEngine` as a `ProcessingStageProtocol` for the
/// `.look` pipeline slot (mirrors the in-tree stage adapter shape).
final class LookStageAdapter: ProcessingStageProtocol, @unchecked Sendable {

    let stage: PipelineStage = .look

    private let engine: LookEngine

    init(engine: LookEngine) {
        self.engine = engine
    }

    func process(_ input: CVPixelBuffer, context: ProcessingContext) async throws -> CVPixelBuffer {
        let look = engine.currentLook
        return try await engine.apply(input, look: look, strength: context.strength)
    }
}
