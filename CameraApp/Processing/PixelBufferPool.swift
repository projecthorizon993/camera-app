import Foundation
import CoreVideo
import CoreImage
import Metal

// MARK: - Zero-copy contract
//
// Buffers flow AVFoundation → Metal → CoreImage → CoreML as CVPixelBuffer
// references. Nothing in this file copies pixel bytes:
//
//   • Metal interop wraps the SAME IOSurface backing store in a CVMetalTexture
//     (CVMetalTextureCacheCreateTextureFromImage) — no CPU upload, no download.
//   • CoreImage reads/writes the SAME buffer via CIImage(cvPixelBuffer:) and
//     CIContext.render(_:to:) — no intermediate bitmaps.
//   • The pool recycles IOSurface-backed buffers so no per-frame allocation
//     happens on the camera delivery or render queues.
//
// For Metal compatibility every buffer this pool hands out is created with
// kCVPixelBufferMetalCompatibilityKey and IOSurface backing. Buffers arriving
// from AVCaptureVideoDataOutput already satisfy both.

// MARK: - PixelBufferPool

/// CVPixelBufferPool-backed recycling pool sized from a source buffer
/// (typically the image buffer of a CMSampleBuffer). Thread-safe: `buffer()`
/// may be called from the camera queue and the processing queue concurrently.
///
/// Usage from a sample buffer:
///     guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { ... }
///     let pool = PixelBufferPool(matching: imageBuffer)
final class PixelBufferPool: @unchecked Sendable {

    let width: Int
    let height: Int
    let pixelFormat: OSType

    /// Shared attributes applied to every fallback allocation as well.
    static let pixelBufferAttributes: [String: Any] = [
        kCVPixelBufferMetalCompatibilityKey as String: true,
        // Empty IOSurface properties dict enables IOSurface backing, which the
        // CVMetalTextureCache requires for zero-copy GPU access.
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]

    private let pool: CVPixelBufferPool?

    /// Creates a pool for one fixed size/format. The underlying CVPixelBufferPool
    /// recycles buffers as their last reference is released; when it is exhausted
    /// (kCVReturnWouldExceedAllocationThreshold) `buffer()` falls back to a
    /// direct allocation so the pipeline never stalls.
    init(width: Int, height: Int, pixelFormat: OSType) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat

        let attributes: [String: Any] = [
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
        ].merging(Self.pixelBufferAttributes) { current, _ in current }

        var created: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            nil,
            attributes as CFDictionary,
            &created
        )
        self.pool = status == kCVReturnSuccess ? created : nil
    }

    /// Convenience: match the attributes of a source buffer (e.g. the image
    /// buffer of a sample buffer arriving from AVCaptureVideoDataOutput).
    convenience init?(matching source: CVPixelBuffer) {
        self.init(
            width: CVPixelBufferGetWidth(source),
            height: CVPixelBufferGetHeight(source),
            pixelFormat: CVPixelBufferGetPixelFormatType(source)
        )
    }

    /// Returns a recyclable buffer. Never blocks for long and never returns nil
    /// unless the system cannot allocate at all.
    func buffer() -> CVPixelBuffer? {
        if let pool {
            var recycled: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &recycled)
            if status == kCVReturnSuccess, let recycled {
                return recycled
            }
        }
        // Pool unavailable or exhausted → direct allocation with identical
        // (Metal-compatible) attributes.
        var direct: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            Self.pixelBufferAttributes as CFDictionary,
            &direct
        )
        return status == kCVReturnSuccess ? direct : nil
    }
}

// MARK: - PixelBufferBridge

/// CVPixelBuffer ⇄ CVMetalTexture and CVPixelBuffer ⇄ CIImage interop helpers.
/// All conversions are zero-copy views over the buffer's IOSurface.
enum PixelBufferBridge {

    /// Creates a CVMetalTextureCache. One cache per consumer (renderer or
    /// stage); the cache internally recycles Metal textures so repeated
    /// per-frame wrapping does not allocate.
    static func makeMetalTextureCache(device: MTLDevice) -> CVMetalTextureCache? {
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &cache
        )
        return status == kCVReturnSuccess ? cache : nil
    }

    /// Wraps one plane of a pixel buffer as a sampled Metal texture.
    /// The returned CVMetalTexture must stay alive until the command buffer
    /// using it has completed (it owns the Metal texture).
    static func metalTexture(
        for buffer: CVPixelBuffer,
        plane: Int,
        cache: CVMetalTextureCache,
        pixelFormat: MTLPixelFormat
    ) -> CVMetalTexture? {
        let planeCount = CVPixelBufferGetPlaneCount(buffer)
        guard planeCount == 0 || plane < planeCount else { return nil }
        let width = planeCount > 0 ? CVPixelBufferGetWidthOfPlane(buffer, plane) : CVPixelBufferGetWidth(buffer)
        let height = planeCount > 0 ? CVPixelBufferGetHeightOfPlane(buffer, plane) : CVPixelBufferGetHeight(buffer)

        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            buffer,
            nil,
            pixelFormat,
            width,
            height,
            plane,
            &texture
        )
        return status == kCVReturnSuccess ? texture : nil
    }

    /// CVPixelBuffer → CIImage: a lazy, zero-copy view of the buffer.
    static func ciImage(from buffer: CVPixelBuffer) -> CIImage {
        CIImage(cvPixelBuffer: buffer)
    }

    /// CIImage → CVPixelBuffer: renders (on the GPU for a Metal-backed context)
    /// directly into the buffer's memory. No intermediate image is produced.
    static func render(_ image: CIImage, into buffer: CVPixelBuffer, context: CIContext) {
        context.render(image, to: buffer, bounds: image.extent, colorSpace: nil)
    }

    /// Shared CoreImage context. Prefers the given Metal device so CI work
    /// stays on the GPU; falls back to a software context on machines without
    /// Metal (tests, headless CI).
    static func makeImageContext(device: MTLDevice? = nil) -> CIContext {
        if let resolved = device ?? MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: resolved)
        }
        return CIContext()
    }
}
