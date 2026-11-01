import Foundation
import CoreGraphics
import CoreVideo
import ImageIO
import CoreImage
import UniformTypeIdentifiers

// MARK: - Errors

enum PixelBufferDecodingError: Error, Sendable {
    case decodeFailed
    case encodeFailed
}

// MARK: - PixelBufferDecoding

/// Shared decode bridge for byte streams → pixel buffers. Replaces the private
/// CGImage→CVPixelBuffer path Night/ carried (dedup ruling) and backs the
/// export processor.
enum PixelBufferDecoding {

    /// Decodes image bytes (JPEG/HEIF/DNG — anything CGImageSource reads) to a
    /// 32BGRA CVPixelBuffer of the image's dimensions. Off-actor heavy work is
    /// the CALLER's responsibility; this is a pure sync primitive. Metal/Core
    /// Video overlay enum cases only (the C #defines do not import).
    static func pixelBuffer(from data: Data,
                            pixelFormat: OSType = kCVPixelFormatType_32BGRA) throws -> CVPixelBuffer {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PixelBufferDecodingError.decodeFailed
        }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else {
            throw PixelBufferDecodingError.decodeFailed
        }

        var buffer: CVPixelBuffer?
        let attrs = PixelBufferPool.pixelBufferAttributes as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, pixelFormat, attrs, &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw PixelBufferDecodingError.decodeFailed
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw PixelBufferDecodingError.decodeFailed
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    /// Encodes a buffer back to JPEG bytes, carrying the source metadata (EXIF
    /// etc.) from the ORIGINAL capture byte stream so DateTimeOriginal/GPS/ISO
    /// survive re-encoding. Source metadata comes from `sourceData` (the
    /// pre-pipeline bytes) via the `sourceMetadata` image source.
    static func jpegData(from buffer: CVPixelBuffer,
                         sourceMetadata: CGImageSource?) throws -> Data {
        try encode(buffer: buffer,
                   typeIdentifier: UTType.jpeg.identifier,
                   sourceMetadata: sourceMetadata)
    }

    /// Encodes a buffer back to HEIF bytes, carrying source metadata (see
    /// `jpegData(from:sourceMetadata:)`).
    static func heifData(from buffer: CVPixelBuffer,
                         sourceMetadata: CGImageSource?) throws -> Data {
        try encode(buffer: buffer,
                   typeIdentifier: UTType.heif.identifier,
                   sourceMetadata: sourceMetadata)
    }

    // MARK: - Private

    private static func encode(buffer: CVPixelBuffer,
                              typeIdentifier: String,
                              sourceMetadata: CGImageSource?) throws -> Data {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            throw PixelBufferDecodingError.encodeFailed
        }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, typeIdentifier as CFString, 1, nil
        ) else {
            throw PixelBufferDecodingError.encodeFailed
        }

        var props: [String: Any] = [:]
        if let source = sourceMetadata,
           let all = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            let keys: [CFString] = [
                kCGImagePropertyExifDictionary,
                kCGImagePropertyGPSDictionary,
                kCGImagePropertyTIFFDictionary
            ]
            for key in keys {
                if let value = all[key as String] {
                    props[key as String] = value
                }
            }
        }

        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw PixelBufferDecodingError.encodeFailed
        }
        return data as Data
    }
}