import Foundation
import CoreVideo
import CoreGraphics
import Metal

// MARK: - OverlayKernelEngine
//
// Shared execution engine for the viewfinder-assist stubs (peaking, zebras):
// builds a Metal-compatible BGRA output buffer from a recycling pool, wraps
// input/output planes in CVMetalTextures (zero-copy) and runs one compute pass.
//
// Thread safety: `runKernel` is synchronous and intended to be called from a
// @concurrent (background) context — never from the main actor or the MTKView
// render thread. Internal mutable state (pipeline-state cache, pool) is
// guarded by one unfair lock, never held across an await.

final class OverlayKernelEngine: @unchecked Sendable {

    enum Kernel: String {
        case peaking = "peakingKernel"
        case zebra = "zebraKernel"
    }

    enum OverlayKernelError: Error {
        case setupFailed(String)
        case gpuFailed(String)
    }

    /// 16×16 = 256 threads per threadgroup — within maxTotalThreadsPerThreadgroup
    /// on every iOS GPU. The kernels guard out-of-bounds gid for the ceil-div
    /// edge threadgroups this dispatch produces.
    static let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)

    private struct EngineState {
        let library: MTLLibrary
        var pipelineStates: [Kernel: MTLComputePipelineState] = [:]
        var pool: PixelBufferPool?
        var poolSize: CGSize = .zero
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let stateLock: OSAllocatedUnfairLock<EngineState>

    init?() {
        guard
            let device = MTLCreateSystemDefaultDevice(),
            let commandQueue = device.makeCommandQueue(),
            let library = device.makeDefaultLibrary(),
            let textureCache = PixelBufferBridge.makeMetalTextureCache(device: device)
        else {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue
        self.textureCache = textureCache
        self.stateLock = OSAllocatedUnfairLock(initialState: EngineState(library: library))
    }

    /// Runs one kernel pass over `input` and returns a fresh BGRA output
    /// buffer (never the input). `configure` sets the kernel's params struct
    /// at buffer index 0. Texture slots: 0 = luma/BGRA plane, 1 = chroma
    /// (biplanar only), 2 = BGRA output.
    func runKernel(_ kernel: Kernel, input: CVPixelBuffer, configure: (MTLComputeCommandEncoder) -> Void) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(input)
        let height = CVPixelBufferGetHeight(input)
        let output = try outputBuffer(width: width, height: height)

        let isBiplanar = CVPixelBufferGetPlaneCount(input) == 2
        guard
            let cvLuma = PixelBufferBridge.metalTexture(
                for: input,
                plane: 0,
                cache: textureCache,
                pixelFormat: isBiplanar ? .r8Unorm : .bgra8Unorm
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
            throw OverlayKernelError.setupFailed("Metal texture wrapping failed (unsupported pixel format?)")
        }

        var cvChroma: CVMetalTexture?
        var chromaTexture: MTLTexture?
        if isBiplanar {
            guard
                let wrapped = PixelBufferBridge.metalTexture(
                    for: input,
                    plane: 1,
                    cache: textureCache,
                    pixelFormat: .rg8Unorm
                ),
                let texture = CVMetalTextureGetTexture(wrapped)
            else {
                throw OverlayKernelError.setupFailed("chroma plane wrapping failed")
            }
            cvChroma = wrapped
            chromaTexture = texture
        }

        let pipeline = try computePipelineState(for: kernel)
        guard
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            throw OverlayKernelError.setupFailed("command buffer/encoder unavailable")
        }

        encoder.setComputePipelineState(pipeline)
        configure(encoder)   // params struct at buffer index 0
        encoder.setTexture(lumaTexture, index: 0)
        encoder.setTexture(chromaTexture, index: 1)   // nil → unbound; kernels guard on params
        encoder.setTexture(outputTexture, index: 2)

        let threadgroupSize = Self.threadgroupSize
        let groups = MTLSize(
            width: (width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()   // synchronous on a background thread is acceptable for stubs

        if let gpuError = commandBuffer.error {
            throw OverlayKernelError.gpuFailed("\(gpuError)")
        }
        return output
    }

    // MARK: Internals

    private func computePipelineState(for kernel: Kernel) throws -> MTLComputePipelineState {
        try stateLock.withLock { state -> MTLComputePipelineState in
            if let cached = state.pipelineStates[kernel] {
                return cached
            }
            guard let function = state.library.makeFunction(name: kernel.rawValue) else {
                throw OverlayKernelError.setupFailed("missing kernel function: \(kernel.rawValue)")
            }
            let pipeline = try device.makeComputePipelineState(function: function)
            state.pipelineStates[kernel] = pipeline
            return pipeline
        }
    }

    /// One-entry pool cache: assists run at the source resolution, so the pool
    /// is only rebuilt on resolution changes (rotation, format switch).
    private func outputBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        try stateLock.withLock { state -> CVPixelBuffer in
            let size = CGSize(width: width, height: height)
            if state.poolSize == size, let pool = state.pool, let buffer = pool.buffer() {
                return buffer
            }
            let pool = PixelBufferPool(width: width, height: height, pixelFormat: kCVPixelFormatType_32BGRA)
            guard let buffer = pool.buffer() else {
                throw OverlayKernelError.setupFailed("BGRA output allocation failed (\(width)×\(height))")
            }
            state.pool = pool
            state.poolSize = size
            return buffer
        }
    }
}
