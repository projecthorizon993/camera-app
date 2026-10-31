import Foundation
import CoreGraphics
import CoreVideo

// PLACEHOLDER — replaced by Task 4 (real AVCaptureSession camera service).
//
// Reports the A13 fallback capabilities and accepts every call without
// touching hardware, so viewfinder/manual/video UI can be built and run
// end-to-end before the hardware layer exists.

final class PlaceholderCameraService: CameraServiceProtocol {
    /// Stored so the contract round-trips; no frames are produced here.
    // PLACEHOLDER — replaced by Task 4 (frame delivery from video data output).
    private var previewFrameHandler: (@Sendable (CVPixelBuffer) -> Void)?

    var capabilities: CameraCapabilities { .iPhone11ProMaxFallback }

    var availableLenses: [LensInfo] {
        [
            LensInfo(id: .ultraWide, displayName: "0.5x Ultra Wide", focalLengthMM: 13, aperture: 2.4),
            LensInfo(id: .wide, displayName: "1x Wide", focalLengthMM: 26, aperture: 1.8),
            LensInfo(id: .tele, displayName: "2x Telephoto", focalLengthMM: 52, aperture: 2.0),
            LensInfo(id: .front, displayName: "Front", focalLengthMM: 23, aperture: 2.2),
        ]
    }

    var supportedManualRanges: ManualRanges {
        ManualRanges(
            iso: capabilities.isoRange,
            exposureSeconds: 0.000125...capabilities.maxShutterSeconds,
            lensPosition: 0.0...1.0,
            kelvin: 2000...8000,
            tint: -150...150
        )
    }

    func startSession() async throws {
        // No-op: no hardware session in the placeholder.
    }

    func stopSession() {
        // No-op: no hardware session in the placeholder.
    }

    func selectDevice(_ position: DevicePosition) throws {
        // Accepted unconditionally in the placeholder.
    }

    func selectLens(_ id: CameraLensID) throws {
        // Accepted unconditionally in the placeholder.
    }

    func setZoom(_ factor: CGFloat) throws {
        // Accepted unconditionally in the placeholder.
    }

    func applyManualConfig(_ config: ManualCameraConfig) throws {
        // Accepted unconditionally in the placeholder.
    }

    func resetToAuto() {
        // No-op in the placeholder.
    }

    func capturePhoto(_ settings: PhotoCaptureSettings) async throws -> CapturedPhoto {
        // Empty payload placeholder — real encoder output lands with Task 4/8.
        CapturedPhoto(data: Data(), format: settings.format, width: 0, height: 0, exifSummary: nil)
    }

    func captureBracket(depth: BracketDepth) async throws -> [CapturedPhoto] {
        var photos: [CapturedPhoto] = []
        photos.reserveCapacity(depth.frameCount)
        let settings = PhotoCaptureSettings(format: .jpeg, flash: .off, timerSeconds: 0, orientation: .portrait)
        for _ in 0..<depth.frameCount {
            photos.append(try await capturePhoto(settings))
        }
        return photos
    }

    func startVideoRecording(_ config: VideoRecordingConfig) throws {
        // No-op in the placeholder.
    }

    func stopVideoRecording() async -> URL {
        // Placeholder path; no file is produced until Task 14.
        FileManager.default.temporaryDirectory.appendingPathComponent("placeholder-recording.mov")
    }

    func focus(at point: CGPoint) throws {
        // Accepted unconditionally in the placeholder.
    }

    func setExposureOffset(_ ev: Float) throws {
        // Accepted unconditionally in the placeholder.
    }

    func setPreviewFrameHandler(_ handler: (@Sendable (CVPixelBuffer) -> Void)?) {
        previewFrameHandler = handler
    }
}
