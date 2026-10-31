import Foundation

// Pure-Foundation capture models. NO AVFoundation/UIKit imports allowed here
// (plan ruling: pipeline logic must stay unit-testable without hardware).

/// Which physical device the camera service should activate.
enum DevicePosition: Sendable { case back, front }

/// Logical lens identities across both devices.
enum CameraLensID: String, Sendable, CaseIterable { case ultraWide, wide, tele, front }

/// Still-image file format produced by capture.
enum CaptureFormat: String, Sendable, CaseIterable { case jpeg, heif, dng }

/// Still-image flash mode.
enum FlashMode: String, Sendable, CaseIterable { case off, auto, on }

/// Top-level capture mode of the app shell.
enum CaptureMode: String, Sendable, CaseIterable { case photo, video, night, timelapse }

/// Bracketed-capture depth. `.aeb3` is the hardware auto-exposure-bracket burst;
/// the `soft` depths are software sequences merged later (Task 12).
enum BracketDepth: Int, Sendable, CaseIterable {
    case aeb3 = 3, soft5 = 5, soft7 = 7, soft9 = 9
    var frameCount: Int { rawValue }
    var isHardware: Bool { self == .aeb3 }
}

/// Static description of one lens, used for UI dials and watermark text.
struct LensInfo: Sendable {
    let id: CameraLensID
    let displayName: String
    let focalLengthMM: Float
    let aperture: Float
}

/// Manual (pro) exposure configuration. Every `nil` field means "keep auto".
struct ManualCameraConfig: Sendable {
    let iso: Float?                       // nil = auto
    let exposureDurationSeconds: Double?  // nil = auto
    let lensPosition: Float?              // 0...1, nil = auto
    let kelvin: Float?                    // nil = auto
    let tint: Float?
}

/// Runtime-supported manual ranges reported by the camera service.
struct ManualRanges: Sendable {
    let iso: ClosedRange<Float>
    let exposureSeconds: ClosedRange<Double>
    let lensPosition: ClosedRange<Float>
    let kelvin: ClosedRange<Float>
    let tint: ClosedRange<Float>
}

/// Orientation tag applied to still captures.
enum PortraitLandscape: Sendable { case portrait, landscape }

/// Settings for a single still capture.
struct PhotoCaptureSettings: Sendable {
    let format: CaptureFormat
    let flash: FlashMode
    let timerSeconds: Int
    let orientation: PortraitLandscape
}

/// The decoded result of one still capture.
struct CapturedPhoto: Sendable {
    let data: Data
    let format: CaptureFormat
    let width: Int
    let height: Int
    let exifSummary: ExifSummary?
}

/// Compact EXIF snapshot shared across pipeline stages and watermarks.
struct ExifSummary: Sendable {
    let deviceModel: String
    let lensID: CameraLensID?
    let focalMM: Float?
    let aperture: Float?
    let shutterSeconds: Double?
    let iso: Float?
    let capturedAt: Date
}
