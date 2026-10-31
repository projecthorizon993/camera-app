import Foundation
import CoreVideo

// PLACEHOLDER — replaced by Task 6 (Metal renderer + real stage-slot pipeline).
//
// Passes buffers through unchanged, optionally invoking registered stages in
// the requested order so callers can already exercise the stage contract.

final class PlaceholderPipeline: ProcessingPipelineProtocol {
    private var stages: [PipelineStage: ProcessingStageProtocol] = [:]

    func setStage(_ stage: PipelineStage, _ processor: ProcessingStageProtocol?) {
        stages[stage] = processor
    }

    func run(_ input: CVPixelBuffer, stages requestedStages: [PipelineStage], context: ProcessingContext) async throws -> CVPixelBuffer {
        var buffer = input
        for stage in requestedStages {
            if let processor = self.stages[stage] {
                buffer = try await processor.process(buffer, context: context)
            }
        }
        return buffer
    }
}
