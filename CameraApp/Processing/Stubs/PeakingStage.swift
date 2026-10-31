import Foundation
import CoreVideo
import os

// MARK: - Peaking constants (Task 20 owns tuning)
//
// Functional stub values; single source so tuning never touches shader code.

enum PeakingConstants {
    /// Sobel magnitude (normalized 0...1) that starts showing an edge.
    static let edgeThreshold: Float = 0.15
    /// Transition band above the threshold (anti-flicker softness).
    static let edgeSoftness: Float = 0.08
    /// Overlay blend factor before `ProcessingContext.strength` scaling.
    static let blendStrength: Float = 0.9
    /// Focus-assist color: green.
    static let edgeColor = SIMD4<Float>(0, 1, 0, 1)
}

/// Mirrors `PeakingParams` in Shaders.metal — uint; float; float; float; float4
/// (stride 32, float4 at offset 16). Do not reorder fields.
private struct PeakingParams {
    var inputIsSinglePlane: UInt32
    var threshold: Float
    var softness: Float
    var strength: Float
    var edgeColor: SIMD4<Float>
}

// MARK: - PeakingStage
//
// Focus-assist stub: Metal sobel edge magnitude → green overlay blend.
// Composition contract: the pipeline holds ONE processor per stage, and both
// assists claim the `.develop` slot — T7a/T20 choose the live assist (peaking
// is the enabled-by-default one). If both must ever run together, compose them
// manually into a single composite stage.
// Behavior: toggle off or no Metal device → buffer passes through unchanged.

final class PeakingStage: ProcessingStageProtocol, @unchecked Sendable {

    let stage: PipelineStage = .develop

    private let engine: OverlayKernelEngine?
    private let enabledState = OSAllocatedUnfairLock<Bool>(initialState: true)

    /// Assist toggle (viewfinder settings / Task 20 tuning).
    var isEnabled: Bool {
        get { enabledState.withLock { $0 } }
        set { enabledState.withLock { $0 = newValue } }
    }

    /// Pass an engine to share GPU resources across assists; by default one is
    /// created lazily (nil when no Metal device is available → pass-through).
    init(engine: OverlayKernelEngine? = nil) {
        if let engine {
            self.engine = engine
        } else {
            self.engine = OverlayKernelEngine()
        }
    }

    func process(_ input: CVPixelBuffer, context: ProcessingContext) async throws -> CVPixelBuffer {
        guard isEnabled, let engine else { return input }
        return try await applyOffCallerActor(engine, input: input, context: context)
    }

    /// Explicit background hop (Approachable Concurrency, SE-0461): the GPU
    /// pass plus its synchronous wait must never run on the caller's actor.
    @concurrent
    private func applyOffCallerActor(_ engine: OverlayKernelEngine, input: CVPixelBuffer, context: ProcessingContext) async throws -> CVPixelBuffer {
        var params = PeakingParams(
            inputIsSinglePlane: CVPixelBufferGetPlaneCount(input) == 2 ? 1 : 0,
            threshold: PeakingConstants.edgeThreshold,
            softness: PeakingConstants.edgeSoftness,
            strength: PeakingConstants.blendStrength * Float(context.strength),
            edgeColor: PeakingConstants.edgeColor
        )
        return try engine.runKernel(.peaking, input: input) { encoder in
            encoder.setBytes(&params, length: MemoryLayout<PeakingParams>.stride, index: 0)
        }
    }
}
