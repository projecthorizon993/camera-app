import Foundation
import CoreVideo
import Metal
import MetalKit
import QuartzCore
import os
import simd

// MARK: - Overlay geometry

/// One overlay line in unit coordinates (0...1, origin top-left). The renderer
/// expands it into a screen-space quad during the overlay pass.
struct RenderOverlayLine: Sendable {
    var start: SIMD2<Float>
    var end: SIMD2<Float>
    var color: SIMD4<Float>
}

/// Overlay content provider. Called once per frame on the render thread; must
/// be cheap and allocation-light (Task 7a's viewfinder overlay supplies real
/// grid/level content).
typealias RenderOverlayProvider = @Sendable () -> [RenderOverlayLine]

enum RenderOverlayDefaults {
    static let gridColor = SIMD4<Float>(0.85, 0.85, 0.85, 0.55)

    /// Internal default until Task 7a's viewfinder overlay lands: a simple 3×3 grid.
    static let threeByThreeGrid: RenderOverlayProvider = { RenderOverlayDefaults.gridLines }

    private static let gridLines: [RenderOverlayLine] = [
        RenderOverlayLine(start: SIMD2<Float>(1.0 / 3.0, 0), end: SIMD2<Float>(1.0 / 3.0, 1), color: gridColor),
        RenderOverlayLine(start: SIMD2<Float>(2.0 / 3.0, 0), end: SIMD2<Float>(2.0 / 3.0, 1), color: gridColor),
        RenderOverlayLine(start: SIMD2<Float>(0, 1.0 / 3.0), end: SIMD2<Float>(1, 1.0 / 3.0), color: gridColor),
        RenderOverlayLine(start: SIMD2<Float>(0, 2.0 / 3.0), end: SIMD2<Float>(1, 2.0 / 3.0), color: gridColor),
    ]
}

// MARK: - MetalRenderer

/// MTKView-driven renderer. Owns the textured-quad pass (video frame) and the
/// overlay pass (grid/HUD lines).
///
/// Threading model (binding review finding I1):
///   • `submitFrame(_:)` is called on the camera delivery queue — it only
///     performs an atomic pointer-swap into the pending slot (an unfair lock
///     held for the swap; effectively lock-free for the producer) and never
///     blocks or touches Metal.
///   • `draw(in:)` runs on MTKView's dedicated render thread. All mutable GPU
///     state below (`lastDrawnFrame`, overlay buffer, frame timing) is
///     render-thread-confined and therefore touched without synchronization.
///   • `currentStats()` is safe from any thread (locked stats snapshot).
final class MetalRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {

    // MARK: Public surface

    struct RenderStats: Sendable {
        var fps: Double = 0
        var droppedFrameCount = 0
    }

    let device: MTLDevice

    /// Enqueues the latest camera buffer. Non-blocking; safe from any queue.
    /// A frame still pending in the slot when a new one arrives is counted as
    /// dropped (it never reached the GPU).
    func submitFrame(_ pixelBuffer: CVPixelBuffer) {
        let sequence = sequenceCounter.withLock { counter -> UInt64 in
            counter += 1
            return counter
        }
        // withLockUnchecked: the closure must carry the incoming CVPixelBuffer;
        // `withLock` would additionally demand `CVPixelBuffer: Sendable` (not
        // guaranteed by the SDK). The PendingFrame box is already `@unchecked
        // Sendable`, and access still happens under the lock.
        let displaced = pendingFrameSlot.withLockUnchecked { slot -> PendingFrame? in
            let displaced = slot
            slot = PendingFrame(sequence: sequence, pixelBuffer: pixelBuffer)
            return displaced
        }
        if displaced != nil {
            incrementDroppedFrameCount()
        }
    }

    /// Thread-safe stats snapshot for the debug HUD.
    func currentStats() -> RenderStats {
        statsLock.withLock { $0 }
    }

    // MARK: Frame plumbing

    struct PendingFrame: @unchecked Sendable {
        let sequence: UInt64
        let pixelBuffer: CVPixelBuffer
    }

    /// Drawn-frame record. The CVMetalTexture wrappers must outlive the GPU
    /// work, so they are retained alongside their MTLTextures until the next
    /// frame replaces them (render-thread confined).
    private struct DrawnFrame {
        let sequence: UInt64
        let lumaTexture: MTLTexture
        let chromaTexture: MTLTexture?
        let cvLumaTexture: CVMetalTexture
        let cvChromaTexture: CVMetalTexture?
        let isBiplanar: Bool
    }

    // MARK: Immutable GPU state (set up in init)

    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let bgraPipelineState: MTLRenderPipelineState
    private let yuvPipelineState: MTLRenderPipelineState
    private let overlayPipelineState: MTLRenderPipelineState
    /// Sampler for the textured-quad pass. Optional because
    /// `makeSamplerState(descriptor:)` returns an optional; a fallback is
    /// created lazily at bind time (render-thread confined). When none can be
    /// created the frame pass is skipped for that frame.
    private var samplerState: (any MTLSamplerState)?
    private let overlayProvider: RenderOverlayProvider

    // MARK: Cross-thread state

    private let pendingFrameSlot = OSAllocatedUnfairLock<PendingFrame?>(initialState: nil)
    private let sequenceCounter = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    private let statsLock = OSAllocatedUnfairLock<RenderStats>(initialState: RenderStats())

    // MARK: Render-thread-confined state

    private var lastDrawnFrame: DrawnFrame?
    private var lastDrawnSequence: UInt64 = 0
    private var lastFrameTimestamp: Double = 0
    private var overlayVertexBuffer: MTLBuffer?

    // MARK: Layout constants (must mirror Shaders.metal)

    private struct TexturedQuadVertex {   // ⇄ TexturedQuadVertexIn { float2; float2 }
        var position: SIMD2<Float>
        var texCoord: SIMD2<Float>
    }

    struct OverlayVertex {                // ⇄ OverlayVertexIn { float2; float4 }, stride 32
        var position: SIMD2<Float>
        var color: SIMD4<Float>
    }

    private static let quadVertices: [TexturedQuadVertex] = [
        TexturedQuadVertex(position: SIMD2<Float>(-1, 1), texCoord: SIMD2<Float>(0, 0)),   // top-left
        TexturedQuadVertex(position: SIMD2<Float>(1, 1), texCoord: SIMD2<Float>(1, 0)),    // top-right
        TexturedQuadVertex(position: SIMD2<Float>(-1, -1), texCoord: SIMD2<Float>(0, 1)),  // bottom-left
        TexturedQuadVertex(position: SIMD2<Float>(1, -1), texCoord: SIMD2<Float>(1, 1)),   // bottom-right
    ]

    /// Metal's inline (setVertexBytes) vertex data limit is 4 KB.
    private static let maxInlineVertexBytes = 4096
    private static let overlayLineWidthUnits: Float = 0.0025

    // MARK: Init

    /// Fails when no Metal device is available; `RendererView` presents a
    /// graceful fallback view in that case.
    init?(overlayProvider: RenderOverlayProvider? = nil) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "texturedQuadVertex"),
              let bgraFragmentFunction = library.makeFunction(name: "texturedQuadFragment"),
              let yuvFragmentFunction = library.makeFunction(name: "texturedQuadYUVFragment"),
              let overlayVertexFunction = library.makeFunction(name: "overlayVertex"),
              let overlayFragmentFunction = library.makeFunction(name: "overlayFragment"),
              let textureCache = PixelBufferBridge.makeMetalTextureCache(device: device)
        else {
            return nil
        }

        let bgraDescriptor = MTLRenderPipelineDescriptor()
        bgraDescriptor.vertexFunction = vertexFunction
        bgraDescriptor.fragmentFunction = bgraFragmentFunction
        bgraDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm   // must match RendererView

        let yuvDescriptor = MTLRenderPipelineDescriptor()
        yuvDescriptor.vertexFunction = vertexFunction
        yuvDescriptor.fragmentFunction = yuvFragmentFunction
        yuvDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        let overlayDescriptor = MTLRenderPipelineDescriptor()
        overlayDescriptor.vertexFunction = overlayVertexFunction
        overlayDescriptor.fragmentFunction = overlayFragmentFunction
        overlayDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        guard let bgraPipelineState = try? device.makeRenderPipelineState(descriptor: bgraDescriptor),
              let yuvPipelineState = try? device.makeRenderPipelineState(descriptor: yuvDescriptor),
              let overlayPipelineState = try? device.makeRenderPipelineState(descriptor: overlayDescriptor)
        else {
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue
        self.textureCache = textureCache
        self.bgraPipelineState = bgraPipelineState
        self.yuvPipelineState = yuvPipelineState
        self.overlayPipelineState = overlayPipelineState
        // Optional: `makeSamplerState(descriptor:)` returns an optional. A
        // fallback is created lazily at bind time if this is nil.
        self.samplerState = device.makeSamplerState(descriptor: Self.makeSamplerDescriptor())
        self.overlayProvider = overlayProvider ?? RenderOverlayDefaults.threeByThreeGrid
        super.init()
    }

    // MARK: Sampler

    private static func makeSamplerDescriptor() -> MTLSamplerDescriptor {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .notMipmapped
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        return descriptor
    }

    /// Shared sampler, created lazily on first use (render thread). Nil when the
    /// device cannot create one — callers then skip the frame pass for that
    /// frame rather than binding an invalid sampler.
    private func resolvedSamplerState() -> (any MTLSamplerState)? {
        if let samplerState {
            return samplerState
        }
        guard let created = device.makeSamplerState(descriptor: Self.makeSamplerDescriptor()) else {
            return nil
        }
        samplerState = created
        return created
    }

    // MARK: Frame ingestion (camera queue)

    private func incrementDroppedFrameCount() {
        statsLock.withLock { stats in
            stats.droppedFrameCount += 1
        }
    }

    // MARK: MTKViewDelegate (render thread)

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Drawable size follows the view automatically; nothing to do.
    }

    func draw(in view: MTKView) {
        updateFrameTiming()

        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            return
        }

        if let pending = takePendingFrame() {
            if pending.sequence <= lastDrawnSequence {
                // Swap-in of a frame older than the last drawn one → dropped.
                incrementDroppedFrameCount()
            } else if let drawn = makeDrawnFrame(from: pending) {
                lastDrawnFrame = drawn
                lastDrawnSequence = pending.sequence
            } else {
                // Pending frame could not be wrapped as a Metal texture
                // (unsupported format / cache failure) → count it as dropped so
                // HUD numbers stay consistent with the submit-side displacement
                // path.
                incrementDroppedFrameCount()
            }
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        encodeFramePass(into: encoder, view: view)
        encodeOverlayPass(into: encoder, view: view)
        encoder.endEncoding()   // must end before present/commit

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: Pass 1 — textured quad

    private func encodeFramePass(into encoder: MTLRenderCommandEncoder, view: MTKView) {
        guard let frame = lastDrawnFrame,                          // nothing captured yet → clear color only
              let sampler = resolvedSamplerState() else { return }  // no sampler available → skip this frame

        encoder.setRenderPipelineState(frame.isBiplanar ? yuvPipelineState : bgraPipelineState)

        var quad = Self.quadVertices
        encoder.setVertexBytes(
            &quad,
            length: MemoryLayout<TexturedQuadVertex>.stride * quad.count,
            index: 0
        )
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentTexture(frame.lumaTexture, index: 0)
        if let chroma = frame.chromaTexture {
            encoder.setFragmentTexture(chroma, index: 1)
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    // MARK: Pass 2 — overlay lines

    private func encodeOverlayPass(into encoder: MTLRenderCommandEncoder, view: MTKView) {
        let lines = overlayProvider()
        guard !lines.isEmpty else { return }

        let vertices = Self.overlayVertices(
            from: lines,
            lineWidthUnits: Self.overlayLineWidthUnits
        )
        guard !vertices.isEmpty else { return }

        encoder.setRenderPipelineState(overlayPipelineState)
        bindOverlayVertices(vertices, to: encoder)

        var viewport = SIMD2<Float>(
            Float(view.drawableSize.width),
            Float(view.drawableSize.height)
        )
        encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)

        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
    }

    private func bindOverlayVertices(_ vertices: [OverlayVertex], to encoder: MTLRenderCommandEncoder) {
        let byteCount = vertices.count * MemoryLayout<OverlayVertex>.stride
        if byteCount <= Self.maxInlineVertexBytes {
            var inline = vertices
            encoder.setVertexBytes(&inline, length: byteCount, index: 0)
            return
        }
        // Larger overlays go through a growable shared MTLBuffer instead of
        // the 4 KB inline path.
        guard let buffer = ensureOverlayBuffer(byteCount: byteCount) else { return }
        vertices.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(buffer.contents(), base, byteCount)
        }
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
    }

    private func ensureOverlayBuffer(byteCount: Int) -> MTLBuffer? {
        if let buffer = overlayVertexBuffer, buffer.length >= byteCount {
            return buffer
        }
        let buffer = device.makeBuffer(length: max(byteCount, 4096), options: .storageModeShared)
        overlayVertexBuffer = buffer
        return buffer
    }

    /// Expands lines into two triangles each. Line width is expressed in unit
    /// space relative to the smaller viewport axis; slight aspect distortion of
    /// hairline thickness is acceptable for grid/assist content.
    static func overlayVertices(from lines: [RenderOverlayLine], lineWidthUnits: Float) -> [OverlayVertex] {
        var vertices: [OverlayVertex] = []
        vertices.reserveCapacity(lines.count * 6)
        for line in lines {
            let delta = line.end - line.start
            let lengthSquared = delta.x * delta.x + delta.y * delta.y
            guard lengthSquared > 1e-12 else { continue }
            let inverseLength = 1.0 / (lengthSquared).squareRoot()
            let half = lineWidthUnits * 0.5
            let normal = SIMD2<Float>(-delta.y, delta.x) * inverseLength * half

            let p0 = line.start + normal
            let p1 = line.end + normal
            let p2 = line.end - normal
            let p3 = line.start - normal
            vertices.append(OverlayVertex(position: p0, color: line.color))
            vertices.append(OverlayVertex(position: p1, color: line.color))
            vertices.append(OverlayVertex(position: p2, color: line.color))
            vertices.append(OverlayVertex(position: p0, color: line.color))
            vertices.append(OverlayVertex(position: p2, color: line.color))
            vertices.append(OverlayVertex(position: p3, color: line.color))
        }
        return vertices
    }

    // MARK: Frame timing / stats

    private func updateFrameTiming() {
        // MTKView has no frame-timestamp property; the render thread's own clock
        // (QuartzCore) is the per-frame timestamp source for the fps EMA.
        let timestamp = CACurrentMediaTime()
        defer { lastFrameTimestamp = timestamp }
        guard lastFrameTimestamp > 0 else { return }
        let delta = timestamp - lastFrameTimestamp
        guard delta > 0 else { return }
        let instantFPS = 1.0 / delta
        statsLock.withLock { stats in
            stats.fps = stats.fps == 0 ? instantFPS : stats.fps * 0.9 + instantFPS * 0.1
        }
    }

    // MARK: Slot swap helpers

    private func takePendingFrame() -> PendingFrame? {
        pendingFrameSlot.withLock { slot -> PendingFrame? in
            let frame = slot
            slot = nil
            return frame
        }
    }

    /// Wraps the pending buffer's planes as Metal textures (zero-copy).
    private func makeDrawnFrame(from frame: PendingFrame) -> DrawnFrame? {
        let isBiplanar = CVPixelBufferGetPlaneCount(frame.pixelBuffer) == 2

        guard
            let cvLuma = PixelBufferBridge.metalTexture(
                for: frame.pixelBuffer,
                plane: 0,
                cache: textureCache,
                pixelFormat: isBiplanar ? .r8Unorm : .bgra8Unorm
            ),
            let luma = CVMetalTextureGetTexture(cvLuma)
        else {
            return nil
        }

        var cvChroma: CVMetalTexture?
        var chroma: MTLTexture?
        if isBiplanar {
            guard
                let wrapped = PixelBufferBridge.metalTexture(
                    for: frame.pixelBuffer,
                    plane: 1,
                    cache: textureCache,
                    pixelFormat: .rg8Unorm
                ),
                let texture = CVMetalTextureGetTexture(wrapped)
            else {
                return nil
            }
            cvChroma = wrapped
            chroma = texture
        }

        return DrawnFrame(
            sequence: frame.sequence,
            lumaTexture: luma,
            chromaTexture: chroma,
            cvLumaTexture: cvLuma,
            cvChromaTexture: cvChroma,
            isBiplanar: isBiplanar
        )
    }
}
