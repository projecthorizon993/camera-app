import Foundation
import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO

// MARK: - MergedCaptureWriter

/// Converts bracket frames (`CapturedPhoto`) into one merged `CapturedPhoto`,
/// carrying the T4-review M1 EXIF timestamp onto the merged output.
final class MergedCaptureWriter: @unchecked Sendable {

    private let merger = BracketMerger()

    init() {}

    func mergedPhoto(frames: [CapturedPhoto], mode: MergeMode) async throws -> CapturedPhoto {
        guard !frames.isEmpty else { throw BracketError.insufficientFrames }
        let buffers = try frames.map { try Self.pixelBuffer(from: $0) }
        let merged = try await merger.merge(frames: buffers, mode: mode, orientation: .portrait)

        let outputFormat = Self.outputFormat(for: frames.first?.format ?? .jpeg)
        let capturedAt = frames.first?.exifSummary?.capturedAt
        let data = try Self.encode(buffer: merged, format: outputFormat, capturedAt: capturedAt)

        return CapturedPhoto(
            data: data,
            format: outputFormat,
            width: CVPixelBufferGetWidth(merged),
            height: CVPixelBufferGetHeight(merged),
            exifSummary: frames.first?.exifSummary
        )
    }

    // MARK: - Helpers

    private static func outputFormat(for format: CaptureFormat) -> CaptureFormat {
        switch format {
        case .jpeg, .heif: return format
        case .dng: return .jpeg
        }
    }

    private static func pixelBuffer(from photo: CapturedPhoto) throws -> CVPixelBuffer {
        guard let source = CGImageSourceCreateWithData(photo.data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw BracketError.fuseFailed
        }
        let width  = photo.width  > 0 ? photo.width  : cgImage.width
        let height = photo.height > 0 ? photo.height : cgImage.height

        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attrs as CFDictionary, &buffer
        )
        guard status == kCVReturnSuccess, let buffer else { throw BracketError.fuseFailed }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { throw BracketError.fuseFailed }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private static func encode(buffer: CVPixelBuffer, format: CaptureFormat,
                               capturedAt: Date?) throws -> Data {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            throw BracketError.fuseFailed
        }
        let typeID: String = (format == .heif) ? "public.heic" : "public.jpeg"
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, typeID as CFString, 1, nil) else {
            throw BracketError.fuseFailed
        }
        var props: [String: Any] = [:]
        if let date = capturedAt {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            let exif: [String: Any] = [
                kCGImagePropertyExifDateTimeOriginal as String: formatter.string(from: date)
            ]
            props[kCGImagePropertyExifDictionary as String] = exif
        }
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw BracketError.fuseFailed }
        return data as Data
    }
}
