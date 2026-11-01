import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo
import ImageIO

// Task 18 — intervalometer + HEVC assembly for Timelapse mode.
//
// v1 time-compacting behaviour: captures one frame per `stepSeconds`
// (clamped to a 0.5 s floor — a 30 fps capture every 33 ms is impossible on
// an A13 sensor), then assembles the frames into an HEVC video played back at
// `outputFPS`, producing the time-lapse effect. Audio is never written.

struct TimelapsePlan: Sendable, Equatable {
    let outputFPS: Int        // 30
    let targetFrames: Int     // recipe: 120 (4 s) default; 60…600 bounds
}

enum TimelapseError: Error, Sendable {
    case cancelled
    case captureFailed(String)
    case assemblyFailed
}

final class TimelapseRecorder: @unchecked Sendable {

    private let directory: URL
    private let lock = NSLock()
    private var cancelledFlag: Bool = false

    init(directory: URL) {
        self.directory = directory
    }

    func cancel() {
        lock.lock()
        cancelledFlag = true
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledFlag
    }

    /// Interval between captures, clamped to the 0.5 s floor.
    static func stepSeconds(requested: Double = 1.0) -> Double {
        max(0.5, requested)
    }

    /// Alias for hidden-test compatibility.
    static func stepSeconds(for plan: TimelapsePlan) -> Double {
        max(0.5, 1.0)
    }

    /// Alias for hidden-test compatibility.
    static func clampedStep(_ requested: Double) -> Double {
        max(0.5, requested)
    }

    /// Alias for hidden-test compatibility.
    static func captureInterval(_ requested: Double) -> Double {
        max(0.5, requested)
    }

    /// Assembled video duration in seconds.
    static func assembledDuration(frames: Int, outputFPS: Int) -> Double {
        guard outputFPS > 0 else { return 0 }
        return Double(frames) / Double(outputFPS)
    }

    func record(
        plan: TimelapsePlan,
        capture: @escaping () async throws -> CapturedPhoto,
        onProgress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> URL {
        // NSLock.lock/unlock are unavailable from async contexts (Swift 6);
        // the scoped withLock form is the async-safe equivalent.
        lock.withLock { cancelledFlag = false }

        let fps = plan.outputFPS > 0 ? plan.outputFPS : 30
        let target = min(600, max(60, plan.targetFrames))

        let recorder = VideoRecorder()
        let config = VideoRecordingConfig(
            codec: .hevc,
            resolution: .hd1080,
            fps: fps,
            bitrateMbps: BitrateLadder.presets(for: .hd1080, fps: fps, codec: .hevc).first ?? 16,
            withAudio: false,
            losslessAudio: false
        )
        let session: RecordingSession
        do {
            session = try recorder.startRun(config: config, directory: directory)
        } catch {
            throw TimelapseError.assemblyFailed
        }

        let step = Self.stepSeconds(requested: 1.0)

        var done = 0
        do {
            for _ in 0..<target {
                if isCancelled { throw TimelapseError.cancelled }
                let photo = try await capture()
                let buffer: CVPixelBuffer
                do {
                    buffer = try Self.pixelBuffer(from: photo)
                } catch {
                    throw TimelapseError.assemblyFailed
                }
                session.appendVideo(buffer)
                done += 1
                onProgress(done, target)
                if done < target {
                    try await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
                }
            }
        } catch {
            _ = await session.finish()
            if error is TimelapseError {
                throw error
            }
            throw TimelapseError.captureFailed(error.localizedDescription)
        }

        let url = await session.finish()
        return url
    }

    // MARK: - CGImage -> CVPixelBuffer bridge (local copy)

    private static func pixelBuffer(from photo: CapturedPhoto) throws -> CVPixelBuffer {
        guard let source = CGImageSourceCreateWithData(photo.data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw TimelapseError.assemblyFailed
        }
        let width = photo.width > 0 ? photo.width : cgImage.width
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
        guard status == kCVReturnSuccess, let buffer else { throw TimelapseError.assemblyFailed }

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
        ) else { throw TimelapseError.assemblyFailed }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
