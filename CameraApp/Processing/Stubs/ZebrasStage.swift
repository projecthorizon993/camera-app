import Foundation
import CoreVideo
import os

// MARK: - Zebra constants (Task 20 owns tuning)
//
// Functional stub values; constant pattern, no configuration surface.

enum ZebraConstants {
    /// Overexposure trigger (normalized BT.709 luma 0...1).
    static let lumaThreshold: Float = 0.92
    /// Diagonal stripe period in pixels (45° stripes).
    static let stripePeriodPixels: Float = 16
    /// Stripe blend factor over the base image.
    static let stripeOpacity: Float = 0.85
    /// Stripe color: black — broadcast-style zebras.
    static let stripeColor = SIMD4<Float>(0, 0, 0, 1)
}

/// Mirrors `ZebraParams` in Shaders.metal — uint; float; float; float; float4
/// (stride 32, float4 at offset 16). Do not reorder fields.
private struct ZebraParams {
    var inputIsSinglePlane: UInt32
    var lumaThreshold: Float
    var stripePeriod: Float
    var stripeOpacity: Float
    var stripeColor: SIMD4<Float>
}

// MARK: - ZebrasStage
//
// Exposure-assist stub: luma above a fixed threshold → diagonal-stripe
// overlay (constant pattern, no config).
// Composition contract: the pipeline holds ONE processor per stage, and both
// assists claim the `.develop` slot — T7a/T20 choose the live assist (zebras
// default to disabled; peaking is the enabled default). If both must ever run
// together, compose them manually into a single composite stage.
// Behavior: toggle off or no Metal device → buffer passes through unchanged.

final class ZebrasStage: ProcessingStageProtocol, @unchecked Sendable {

    let stage: PipelineStage = .develop

    private let engine: OverlayKernelEngine?
    private let enabledState = OSAllocatedUnfairLock<Bool>(initialState: false)

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
        // The raw buffer is non-Sendable; it crosses the @concurrent boundary
        // inside the Sendable hand-off box in both directions.
        let boxed = try await applyOffCallerActor(engine, box: PixelBufferBox(buffer: input), context: context)
        return boxed.buffer
    }

    /// Explicit background hop (Approachable Concurrency, SE-0461): the GPU
    /// pass plus its synchronous wait must never run on the caller's actor.
    @concurrent
    private func applyOffCallerActor(_ engine: OverlayKernelEngine, box: PixelBufferBox, context: ProcessingContext) async throws -> PixelBufferBox {
        let input = box.buffer
        var params = ZebraParams(
            inputIsSinglePlane: CVPixelBufferGetPlaneCount(input) == 2 ? 1 : 0,
            lumaThreshold: ZebraConstants.lumaThreshold,
            stripePeriod: ZebraConstants.stripePeriodPixels,
            stripeOpacity: ZebraConstants.stripeOpacity,
            stripeColor: ZebraConstants.stripeColor
        )
        let output = try engine.runKernel(.zebra, input: input) { encoder in
            encoder.setBytes(&params, length: MemoryLayout<ZebraParams>.stride, index: 0)
        }
        return PixelBufferBox(buffer: output)
    }
}
