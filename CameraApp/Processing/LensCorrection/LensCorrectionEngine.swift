import Foundation
import CoreVideo
import os
import Metal

// Task 13 — lens-correction engine (frozen-contract `LensCorrectionProtocol`
// implementation + pipeline stage conformance).
//
// Concurrency model (binding, Swift 6 + SE-0461 / SWIFT_APPROACHABLE_CONCURRENCY):
//   • This engine is NOT actor-isolated (pipeline stages run on a background
//     executor context; the pipeline host calls process()/apply() on its own hop).
//   • `apply(_:lens:mode:strength:)` is the nonisolated async protocol witness —
//     under Approachable Concurrency it would run on the CALLER's actor, so all
//     GPU work happens inside the `@concurrent` helper (explicit hop onto the
//     shared background executor; mirrors `BracketMerger`/`PeakingStage` style).
//   • Engine mutable state (pipeline cache + profiles) is guarded by one
//     `OSAllocatedUnfairLock`; the lock is never held across an await.
//   • The raw buffer is non-Sendable → crosses the @concurrent boundary inside
//     the Sendable hand-off box (`PixelBufferBox`).

final class LensCorrectionEngine: LensCorrectionProtocol, ProcessingStageProtocol, @unchecked Sendable {

    // MARK: Errors

    enum LensCorrectionError: Error, Sendable {
        case metalUnavailable(String)
        case profileNotLoaded(CameraLensID)
        case warpFailed(String)
    }

    // MARK: State

    private struct EngineState: @unchecked Sendable {
        var library: MTLLibrary?
        var pipelineState: MTLComputePipelineState?
        var pool: PixelBufferPool?
        var poolSize: CGSize = .zero
        var profiles: [CameraLensID: LensProfile] = [:]
    }

    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?
    private let state = OSAllocatedUnfairLock(initialState: EngineState())

    let stage: PipelineStage = .lensCorrection

    init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        self.device = device
        if let device = device {
            self.commandQueue = device.makeCommandQueue()
            if let commandQueue = commandQueue {
                self.textureCache = PixelBufferBridge.makeMetalTextureCache(device: device)
                let library = device.makeDefaultLibrary()
                state.withLock { state -> Void in
                    state.library = library
                }
            }
        }
        // v1: load the compiled-in bundled profiles (wide-neutral identity).
        for profile in LensProfileStore.bundledProfiles() {
            state.withLock { state -> Void in
                state.profiles[profile.lensID] = profile
            }
        }
    }

    // MARK: LensCorrectionProtocol

    func loadProfile(for lens: CameraLensID) throws {
        if storedProfile(for: lens) == nil {
            guard let profile = LensProfileStore.mergedProfiles().first(where: { $0.lensID == lens }) else {
                throw LensCorrectionError.profileNotLoaded(lens)
            }
            state.withLock { state -> Void in
                state.profiles[lens] = profile
            }
        }
    }

    var hasProfiles: Bool {
        state.withLock { state -> Bool in
            !state.profiles.isEmpty
        }
    }

    func apply(_ input: CVPixelBuffer, lens: CameraLensID, mode: LensCorrectionMode, strength: Double) async throws -> CVPixelBuffer {
        var profile: LensProfile? = nil
        switch mode {
        case .off:
            // Identity: the protocol allows returning the same buffer when
            // nothing changed — zero-copy passthrough, no GPU work.
            return input
        case .auto:
            // Auto with no loaded profile (or lens without one) → pass-through.
            guard hasProfiles else { return input }
            profile = storedProfile(for: lens)
        case .profile:
            profile = try storedProfileOrThrow(for: lens)
        }
        guard let profile = profile, strength > 0 else { return input }
        // applyOffCallerActor hands the result back inside the box; unwrap it
        // for the public CVPixelBuffer-returning contract.
        return try await applyOffCallerActor(PixelBufferBox(buffer: input), profile: profile, strength: strength).buffer
    }

    // MARK: ProcessingStageProtocol

    func process(_ input: CVPixelBuffer, context: ProcessingContext) async throws -> CVPixelBuffer {
        let lens = context.exif?.lensID ?? CameraLensID.wide
        return try await apply(input, lens: lens, mode: .auto, strength: context.strength)
    }

    // MARK: Internals

    private func storedProfile(for lens: CameraLensID) -> LensProfile? {
        state.withLock { state -> LensProfile? in
            state.profiles[lens]
        }
    }

    private func storedProfileOrThrow(for lens: CameraLensID) throws -> LensProfile {
        guard let profile = storedProfile(for: lens) else {
            throw LensCorrectionError.profileNotLoaded(lens)
        }
        return profile
    }

    /// Explicit background hop (Approachable Concurrency, SE-0461): the GPU pass
    /// plus its synchronous wait must never run on the caller's actor.
    @concurrent
    private func applyOffCallerActor(_ box: PixelBufferBox, profile: LensProfile, strength: Double) async throws -> PixelBufferBox {
        let input = box.buffer
        let width = CVPixelBufferGetWidth(input)
        let height = CVPixelBufferGetHeight(input)
        let output = try outputBuffer(width: width, height: height)

        let hasChroma = CVPixelBufferGetPlaneCount(input) == 2
        guard let device = self.device,
              let commandQueue = self.commandQueue,
              let textureCache = self.textureCache
        else {
            throw LensCorrectionError.metalUnavailable("lens correction: Metal device/command queue/texture cache unavailable")
        }

        guard
            let cvLuma = PixelBufferBridge.metalTexture(
                for: input,
                plane: 0,
                cache: textureCache,
                pixelFormat: hasChroma ? .r8Unorm : .bgra8Unorm
            ),
            let lumaTexture = CVMetalTextureGetTexture(cvLuma),
            let cvOutput = PixelBufferBridge.metalTexture(
                for: output,
                plane: 0,
                cache: textureCache,
                pixelFormat: .bgra8Unorm
            ),
            let outputTexture = CVMetalTextureGetTexture(cvOutput)
        else {
            throw LensCorrectionError.warpFailed("Metal texture wrapping failed (unsupported pixel format?)")
        }

        var cvChroma: CVMetalTexture?
        var chromaTexture: MTLTexture?
        if hasChroma {
            guard
                let wrapped = PixelBufferBridge.metalTexture(
                    for: input,
                    plane: 1,
                    cache: textureCache,
                    pixelFormat: .rg8Unorm
                ),
                let texture = CVMetalTextureGetTexture(wrapped)
            else {
                throw LensCorrectionError.warpFailed("chroma plane wrapping failed")
            }
            cvChroma = wrapped
            chromaTexture = texture
        }

        let pipeline = try computePipelineState()
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            throw LensCorrectionError.warpFailed("command buffer/encoder unavailable")
        }

        encoder.setComputePipelineState(pipeline)
        // Named sub-expressions: the inline literal row below exceeded the
        // type-checker's expression-timeout budget (LD007) when written as
        // one 9-argument call with mixed Float/Double coercions.
        let k1 = Float(Double(profile.distortion.k1) * strength)
        let k2 = Float(Double(profile.distortion.k2) * strength)
        let k3 = Float(Double(profile.distortion.k3) * strength)
        let ca = Float(Double(profile.caOffsets) * strength)
        let vignetteGain = Float(Double(profile.vignetteGain) * strength)
        let strengthF = Float(strength)
        let hasChromaFlag: UInt32 = hasChroma ? 1 : 0
        var params = FusedWarpParams(
            k1: k1,
            k2: k2,
            k3: k3,
            ca: ca,
            vignetteGain: vignetteGain,
            strength: strengthF,
            centerX: Float(profile.principalPointX),
            centerY: Float(profile.principalPointY),
            hasChroma: hasChromaFlag
        )
        encoder.setBytes(&params, length: MemoryLayout<FusedWarpParams>.stride, index: 0)
        encoder.setTexture(lumaTexture, index: 0)
        if let chromaTexture = chromaTexture {
            encoder.setTexture(chromaTexture, index: 1)
        }
        encoder.setTexture(outputTexture, index: 2)

        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(
            width: (width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()

        commandBuffer.commit()
        // waitUntilCompleted is unavailable from async contexts (Swift 6);
        // the overlay's async completed() is the scoped Awaitable replacement
        // (resolves the former TODO — no manual continuation needed).
        await commandBuffer.completed()

        if let gpuError = commandBuffer.error {
            throw LensCorrectionError.warpFailed("\(gpuError)")
        }
        return PixelBufferBox(buffer: output)
    }

    private struct FusedWarpParams {
        var k1: Float
        var k2: Float
        var k3: Float
        var ca: Float
        var vignetteGain: Float
        var strength: Float
        var centerX: Float
        var centerY: Float
        var hasChroma: UInt32
    }

    private func computePipelineState() throws -> MTLComputePipelineState {
        try state.withLockUnchecked { state -> MTLComputePipelineState in
            if let cached = state.pipelineState {
                return cached
            }
            guard let library = state.library,
                  let device = self.device,
                  let commandQueue = self.commandQueue else {
                throw LensCorrectionError.metalUnavailable("lens correction: Metal device/command queue/library unavailable")
            }
            guard let function = library.makeFunction(name: "lc_fused_correct") else {
                throw LensCorrectionError.warpFailed("missing kernel function: lc_fused_correct")
            }
            let pipeline = try device.makeComputePipelineState(function: function)
            state.pipelineState = pipeline
            return pipeline
        }
    }

    private func outputBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        try state.withLockUnchecked { state -> CVPixelBuffer in
            let size = CGSize(width: width, height: height)
            if state.poolSize == size, let pool = state.pool, let buffer = pool.buffer() {
                return buffer
            }
            let pool = PixelBufferPool(width: width, height: height, pixelFormat: kCVPixelFormatType_32BGRA)
            guard let buffer = pool.buffer() else {
                throw LensCorrectionError.warpFailed("BGRA output allocation failed (\(width)×\(height))")
            }
            state.pool = pool
            state.poolSize = size
            return buffer
        }
    }
}
