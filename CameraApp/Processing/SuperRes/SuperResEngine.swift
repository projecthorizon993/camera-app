import Foundation
import CoreGraphics
import CoreImage
import CoreVideo
import Metal

// MARK: - SuperResError

enum SuperResError: Error {
    case tooLarge
    case scalerFailed(String)
}

// MARK: - SuperResEngineProtocol

protocol SuperResEngineProtocol: AnyObject {
    var hasEngine: Bool { get }
    func apply(_ input: CVPixelBuffer, scale: Double) async throws -> CVPixelBuffer
}

// MARK: - SuperResEngine

/// v1 super-resolution engine (clean-room): CoreImage Lanczos 2× scale followed
/// by a single Metal unsharp pass. No neural weights / model files.
///
/// Concurrency: `@unchecked Sendable`; heavy work hops off the caller's actor via
/// `Task.detached` (SE-0461). CVPixelBuffer crosses the boundary only inside
/// `PixelBufferBox`.
final class SuperResEngine: SuperResEngineProtocol, @unchecked Sendable {

    // MARK: State

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let textureCache: CVMetalTextureCache?
    private let computePipelineState: (any MTLComputePipelineState)?

    init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        self.device = device
        if let resolved = device {
            self.commandQueue = resolved.makeCommandQueue()
            self.textureCache = PixelBufferBridge.makeMetalTextureCache(device: resolved)
            if let library = resolved.makeDefaultLibrary(),
               let function = library.makeFunction(name: "sr_unsharp") {
                self.computePipelineState = try? resolved.makeComputePipelineState(function: function)
            } else {
                self.computePipelineState = nil
            }
        } else {
            self.commandQueue = nil
            self.textureCache = nil
            self.computePipelineState = nil
        }
    }

    var hasEngine: Bool {
        device != nil
    }

    // MARK: Apply

    func apply(_ input: CVPixelBuffer, scale: Double) async throws -> CVPixelBuffer {
        let effectiveScale = SuperResPlanner.sanitize(scale: scale)
        let inputSize = CGSize(width: Double(CVPixelBufferGetWidth(input)),
                              height: Double(CVPixelBufferGetHeight(input)))
        let tier = SuperResPlanner.tier(inputSize: inputSize, requestedScale: scale)

        // Fast paths: documented passthrough.
        if scale == 1.0 || effectiveScale == 1.0 || tier == .passthrough || tier != .lanZZos2x {
            return input
        }

        // Capture immutable engine state for the detached hop.
        let device = self.device
        let queue = self.commandQueue
        let cache = self.textureCache
        let pipeline = self.computePipelineState

        let inputBox = PixelBufferBox(buffer: input)

        let resultBox = try await Task.detached(priority: .userInitiated) { () throws -> PixelBufferBox in
            let src = inputBox.buffer
            let srcW = CVPixelBufferGetWidth(src)
            let srcH = CVPixelBufferGetHeight(src)

            let outW = Int((Double(srcW) * effectiveScale).rounded())
            let outH = Int((Double(srcH) * effectiveScale).rounded())

            guard outW <= SuperResPlanner.maxOutputDimension,
                  outH <= SuperResPlanner.maxOutputDimension else {
                throw SuperResError.tooLarge
            }

            // Fresh 32BGRA output buffer for the Lanczos render.
            var lanczosBuffer: CVPixelBuffer?
            let attrs = PixelBufferPool.pixelBufferAttributes as CFDictionary
            let allocStatus = CVPixelBufferCreate(
                kCFAllocatorDefault, outW, outH, kCVPixelFormatType_32BGRA, attrs, &lanczosBuffer
            )
            guard allocStatus == kCVReturnSuccess, let lanczosOut = lanczosBuffer else {
                throw SuperResError.scalerFailed("could not allocate Lanczos output buffer")
            }

            let context = PixelBufferBridge.makeImageContext(device: device)
            let ciInput = CIImage(cvPixelBuffer: src)

            guard let lanczosFilter = CIFilter(name: "CILanczosScaleTransform") else {
                throw SuperResError.scalerFailed("CILanczosScaleTransform unavailable")
            }
            lanczosFilter.setValue(ciInput, forKey: kCIInputImageKey)
            lanczosFilter.setValue(NSNumber(value: effectiveScale), forKey: "inputScale")
            lanczosFilter.setValue(NSNumber(value: 1.0), forKey: "inputAspectRatio")

            guard let scaled = lanczosFilter.outputImage else {
                throw SuperResError.scalerFailed("CILanczosScaleTransform produced no output")
            }

            PixelBufferBridge.render(scaled, into: lanczosOut, context: context)

            // Sharpen pass (Metal, once). Skipped when Metal is unavailable or
            // the kernel could not be loaded — Lanczos-only output stays valid.
            var finalBuffer = lanczosOut
            if let device = device,
               let queue = queue,
               let cache = cache,
               let pipeline = pipeline {
                var sharpenedBuffer: CVPixelBuffer?
                let sharpenAlloc = CVPixelBufferCreate(
                    kCFAllocatorDefault, outW, outH, kCVPixelFormatType_32BGRA, attrs, &sharpenedBuffer
                )
                if sharpenAlloc == kCVReturnSuccess, let sharpenedOut = sharpenedBuffer {
                    var usedSharpened = false
                    if let inCV = PixelBufferBridge.metalTexture(
                        for: lanczosOut, plane: 0, cache: cache, pixelFormat: .bgra8Unorm
                    ),
                       let inTex = CVMetalTextureGetTexture(inCV),
                       let outCV = PixelBufferBridge.metalTexture(
                        for: sharpenedOut, plane: 0, cache: cache, pixelFormat: .bgra8Unorm
                       ),
                       let outTex = CVMetalTextureGetTexture(outCV) {
                        if let commandBuffer = queue.makeCommandBuffer(),
                           let encoder = commandBuffer.makeComputeCommandEncoder() {
                            encoder.setComputePipelineState(pipeline)
                            encoder.setTexture(inTex, index: 0)
                            encoder.setTexture(outTex, index: 1)
                            let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
                            let threadgroupCount = MTLSize(
                                width: (outW + 15) / 16,
                                height: (outH + 15) / 16,
                                depth: 1
                            )
                            encoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
                            encoder.endEncoding()
                            commandBuffer.commit()
                            // waitUntilCompleted is unavailable from async contexts
                            // (Swift 6) — the overlay's async completed() is the
                            // Awaitable replacement; the status check is equivalent.
                            await commandBuffer.completed()
                            if commandBuffer.status == .completed {
                                usedSharpened = true
                            }
                        }
                    }
                    if usedSharpened {
                        finalBuffer = sharpenedOut
                    }
                }
            }

            return PixelBufferBox(buffer: finalBuffer)
        }.value

        return resultBox.buffer
    }
}