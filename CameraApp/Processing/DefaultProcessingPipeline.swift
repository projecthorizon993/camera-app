import Foundation
import CoreVideo
import os

// MARK: - Errors

/// Pipeline error surface. Stage failures always carry the failing stage id
/// (contract: "stage errors propagate with stage id").
enum PipelineError: Error, Sendable {
    case stageFailed(stage: PipelineStage, underlying: any Error)
}

// MARK: - HUD observability

/// Observability surface for the debug HUD. Not part of the frozen contract —
/// provided by `DefaultProcessingPipeline` and consumed by `DebugHUDHost`.
protocol PipelineStageListProviding: AnyObject {
    var activeStages: [PipelineStage] { get }
}

// MARK: - DefaultProcessingPipeline

/// The real stage-slot pipeline (replaces `PlaceholderPipeline`).
///
/// Concurrency model (binding review finding I1):
///   • Under Approachable Concurrency (SE-0461) a bare nonisolated `async`
///     method runs on the CALLER's actor — awaiting `run(_:)` from the
///     @MainActor UI would otherwise execute the whole chain on main.
///   • `run(_:)` therefore immediately delegates to a `@concurrent` helper,
///     which is the explicit hop onto the shared background executor.
///   • Stage slots are guarded by an unfair lock; the lock is never held
///     across an await (slot lookups are synchronous).
///   • The class is `@unchecked Sendable` because its only mutable state
///     (the slot dictionary) is lock-protected.
final class DefaultProcessingPipeline: ProcessingPipelineProtocol, PipelineStageListProviding, @unchecked Sendable {

    private typealias SlotState = [PipelineStage: ProcessingStageProtocol]

    private let stateLock = OSAllocatedUnfairLock<SlotState>(initialState: SlotState())

    // MARK: Stage slots

    /// Installs or clears (nil) the processor for a stage slot. Thread-safe.
    func setStage(_ stage: PipelineStage, _ processor: ProcessingStageProtocol?) {
        stateLock.withLock { slots in
            slots[stage] = processor
        }
    }

    /// Registered stages in pipeline order — debug HUD "active stage list".
    var activeStages: [PipelineStage] {
        stateLock.withLock { slots in
            PipelineStage.allCases.filter { slots[$0] != nil }
        }
    }

    // MARK: ProcessingPipelineProtocol

    /// Chains the buffer through the requested stages in enum order
    /// (develop, lensCorrection, look, watermark, export) on a background
    /// executor. Missing stages pass through; a failing stage aborts the run
    /// with `PipelineError.stageFailed` carrying its id.
    func run(_ input: CVPixelBuffer, stages requestedStages: [PipelineStage], context: ProcessingContext) async throws -> CVPixelBuffer {
        try await runOffCallerActor(input, requestedStages: requestedStages, context: context)
    }

    /// Explicit background hop. Under Approachable Concurrency a plain
    /// nonisolated `async` method would inherit the caller's actor (main when
    /// awaited from UI code); `@concurrent` is what actually guarantees the
    /// chain executes on the shared background executor, never on main.
    @concurrent
    private func runOffCallerActor(_ input: CVPixelBuffer, requestedStages: [PipelineStage], context: ProcessingContext) async throws -> CVPixelBuffer {
        // Enum order wins over the caller's request order.
        let ordered = PipelineStage.allCases.filter { requestedStages.contains($0) }
        var buffer = input
        for stage in ordered {
            guard let processor = processor(for: stage) else {
                continue   // missing stage → pass through
            }
            do {
                buffer = try await processor.process(buffer, context: context)
            } catch {
                throw PipelineError.stageFailed(stage: stage, underlying: error)
            }
        }
        return buffer
    }

    private func processor(for stage: PipelineStage) -> ProcessingStageProtocol? {
        stateLock.withLock { slots in
            slots[stage]
        }
    }
}
