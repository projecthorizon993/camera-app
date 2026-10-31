import Foundation
import CoreGraphics

/// Every error `CameraService` can surface. Cases are grouped by the protocol
/// member that throws them so callers (Task 5 viewfinder, Task 8 export, …) can
/// map a failure to UI copy without string matching.
///
/// `Sendable` so the value can cross actor boundaries under Swift 6 — for
/// example when an error thrown on the serial session queue is resumed into a
/// `CheckedContinuation` and delivered to a `@MainActor` caller.
enum CameraServiceError: Error, Sendable {

    /// The capture session has not been configured yet (Task 4 configures it in
    /// `startSession`). Every hardware-touching member throws this while the
    /// service is still reporting `CameraCapabilities.iPhone11ProMaxFallback`.
    case sessionNotConfigured

    /// No physical capture device exists for the requested position.
    case deviceUnavailable(DevicePosition)

    /// No physical capture device exists for the requested logical lens.
    case lensUnavailable(CameraLensID)

    /// A session (re)configuration step failed, e.g. an input/output could not be
    /// added or removed. The associated string is a short diagnostic.
    case configurationFailed(String)

    /// `setZoom` was handed a factor outside the supported zoom range.
    case zoomOutOfRange(CGFloat)

    /// The active device does not support locking focus/exposure at a point.
    case focusPointUnsupported

    /// The active format does not support manual (custom) exposure.
    case manualExposureUnsupported

    /// The active format/device does not support a locked white balance.
    case manualWhiteBalanceUnsupported

    /// A still capture completed without producing any image data.
    case photoDataUnavailable

    /// The photo output reported an error for a whole capture (or a bracketed
    /// element failed). The associated string/underlying error is descriptive.
    case captureFailed(String)

    /// RAW (`dng`) was requested but the photo output offers no RAW pixel format
    /// (`availableRawPhotoPixelFormatTypes` is empty).
    case rawUnsupported

    /// Video recording is owned by Task 14; both recording entry points are
    /// intentionally unimplemented here.
    case videoNotImplemented
}
