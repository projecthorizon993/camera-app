import Foundation
import Combine

// Task 8 — the app-layer capture flow: shutter action → photo capture → save
// to Photos, plus the last-shot thumbnail and capture feedback state.
//
// INTEGRATION — the single wiring point for T7's `ViewfinderScreen` (one call):
//
//     ShutterButton action → `await env.captureController.captureCurrent()`
//
// (or `await controller.capture(settings:)` with a hand-built
// `PhotoCaptureSettings`, e.g. if T7's own HUD state object owns the chip
// values). Everything else is binding, not wiring:
//
//   - HUD chips        → `controller.settings` (@Published flashMode /
//                        timerSeconds / format).
//   - Opacity flash    → observe `controller.feedback.shutterFlashID`; it
//                        bumps once per fired shot (right after the frame
//                        lands — press-down animation stays T7's).
//   - Sound toggle     → `controller.feedback.isShutterSoundEnabled`
//                        (persisted; see `ShutterSoundStore`).
//   - Last-shot button → `controller.thumbnail.lastThumbnail` (CGImage?, nil
//                        until the first successful save).
//   - Outcomes         → `controller.lastResult` — `.saved(CapturedPhoto)`,
//                        `.needsPermission` (the gate flow is T3's permission
//                        modifier's job), `.failed(reason)`.
//
// This worktree predates T7's merge: `Features/Capture/ViewfinderScreen.swift`
// does not exist here, so the one-line integration edit is T7's — the module
// is fully decoupled and needs nothing else from the app shell. The controller
// is registered once in `AppEnvironment.captureController`.
//
// CONCURRENCY (binding, SE-0461): `capturePhoto` is a nonisolated async call —
// awaiting it from here runs it on the caller's (main) actor while the service
// internally confines itself to its session queue. The SAVE leg must not stay
// on the main actor, so it is dispatched with an explicit `Task.detached` hop
// (a plain `await` of the nonisolated `PhotoSaver.save` would execute on the
// caller's actor under Approachable Concurrency). All `@MainActor` state is
// mutated only from isolated methods.

// MARK: - CaptureOutcome

/// Terminal state of one shutter press, ready for UI presentation.
enum CaptureOutcome: Sendable {
    /// The shot was captured and saved to the photo library.
    case saved(CapturedPhoto)
    /// Photo-library add access is missing. Access is NOT requested here —
    /// T3's permission-gate modifier owns the prompt flow.
    case needsPermission
    /// The capture or the save failed. The reason is user-presentable copy;
    /// every failure lands here — never a crash, never silence.
    case failed(String)
}

// MARK: - CaptureSettingsModel

/// Flash/timer/format state for the capture HUD. T7's chips bind to these
/// `@Published` properties; the controller turns them into
/// `PhotoCaptureSettings` via `makeSettings(orientation:)`.
@MainActor
final class CaptureSettingsModel: ObservableObject {

    @Published var flashMode: FlashMode = .off

    /// 0 = off; any positive value arms the in-service countdown
    /// (`CameraService.capturePhoto` implements the delay itself).
    @Published var timerSeconds: Int = 0

    @Published var format: CaptureFormat = .jpeg

    /// Sets the capture format, enforcing the platform exclusivity rule
    /// (plan §7): RAW is mutually exclusive with flash. Selecting `.dng`
    /// resets flash to `.off`; other formats leave flash untouched.
    func selectFormat(_ format: CaptureFormat) {
        self.format = format
        if format == .dng { flashMode = .off }
    }

    /// Builds the frozen-contract settings value for one shot.
    func makeSettings(orientation: PortraitLandscape = .portrait) -> PhotoCaptureSettings {
        PhotoCaptureSettings(
            format: format,
            flash: flashMode,
            timerSeconds: timerSeconds,
            orientation: orientation
        )
    }
}

// MARK: - CaptureController

/// The shutter pipeline. One dependency of the viewfinder screen; registered
/// once in `AppEnvironment.captureController`.
@MainActor
final class CaptureController: ObservableObject {

    // MARK: Published state

    /// True from shutter press until the capture + save attempt finish.
    @Published private(set) var isCapturing = false

    /// Terminal outcome of the last shot; nil until the first press.
    @Published private(set) var lastResult: CaptureOutcome?

    /// True while the in-service countdown is running (armed at press when
    /// `settings.timerSeconds > 0`, cleared when the shot lands).
    @Published private(set) var isTimerArmed = false

    // MARK: Bound sub-models (T7 binds these)

    /// HUD chip state (flash / timer / format).
    let settings = CaptureSettingsModel()

    /// Last-shot thumbnail for the viewfinder corner button.
    let thumbnail = LastShotThumbnailModel()

    /// Shutter flash trigger + sound toggle.
    let feedback = ShutterFeedback()

    // MARK: Dependencies

    private let cameraService: any CameraServiceProtocol
    private let saver: PhotoSaver

    /// - Parameters:
    ///   - cameraService: the live service (real T4 type or placeholder).
    ///   - permissionService: injected (Task 3's module), never created here.
    ///   - saver: injectable for tests; defaults to the system photo-library
    ///     saver over the given permission service.
    init(
        cameraService: any CameraServiceProtocol,
        permissionService: any CameraPermissionServiceProtocol,
        saver: PhotoSaver? = nil
    ) {
        self.cameraService = cameraService
        self.saver = saver ?? PhotoSaver(permissionService: permissionService)
    }

    // MARK: Shutter pipeline

    /// The shutter action. The service owns the countdown when
    /// `settings.timerSeconds > 0` — this method only arms/disarms the flag.
    /// The captured payload is handed to `PhotoSaver` on a detached task and
    /// the outcome is published; every failure becomes `CaptureOutcome.failed`.
    func capture(settings: PhotoCaptureSettings) async {
        guard !isCapturing else { return }
        isCapturing = true
        isTimerArmed = settings.timerSeconds > 0
        defer {
            isCapturing = false
            isTimerArmed = false
        }

        do {
            let photo = try await cameraService.capturePhoto(settings)
            // The frame just landed: fire the visual trigger and, when
            // enabled, the system shutter click.
            feedback.shotFired()

            let saveOutcome = await save(photo)
            switch saveOutcome {
            case .saved:
                lastResult = .saved(photo)
                thumbnail.record(photo)
            case .needsPermission:
                lastResult = .needsPermission
            case .failed(let reason):
                lastResult = .failed(reason)
            }
        } catch {
            lastResult = .failed(CaptureController.reason(for: error))
        }
    }

    /// Convenience over `capture(settings:)`: builds the settings value from
    /// the bound `CaptureSettingsModel` (the usual T7 call).
    func captureCurrent(orientation: PortraitLandscape = .portrait) async {
        await capture(settings: settings.makeSettings(orientation: orientation))
    }

    /// Runs the saver OFF the main actor. Under SE-0461 a plain `await` of the
    /// nonisolated `PhotoSaver.save` would execute it on the caller's (main)
    /// actor; `Task.detached` is the explicit hop to the global executor.
    /// `PHPhotoLibrary.performChanges` is async-safe and performs no
    /// main-thread I/O.
    private func save(_ photo: CapturedPhoto) async -> PhotoSaveOutcome {
        let saver = self.saver
        return await Task.detached(priority: .userInitiated) {
            await saver.save(photo)
        }.value
    }

    // MARK: Error surfacing

    /// Maps service errors to short, user-presentable reasons (per the
    /// `CameraServiceError` contract: callers map failures to copy without
    /// string matching). Unknown errors pass through their own description.
    nonisolated static func reason(for error: Error) -> String {
        guard let serviceError = error as? CameraServiceError else {
            return error.localizedDescription
        }
        switch serviceError {
        case .sessionNotConfigured:
            return "The camera session is not running yet."
        case .deviceUnavailable(let position):
            return position == .front
                ? "No front camera is available."
                : "No back camera is available."
        case .lensUnavailable(let lens):
            return "The \(lens.rawValue) lens is unavailable on this device."
        case .configurationFailed(let detail):
            return "Camera configuration failed: \(detail)."
        case .zoomOutOfRange:
            return "The requested zoom level is out of range."
        case .focusPointUnsupported:
            return "This camera does not support tap-to-focus."
        case .manualExposureUnsupported:
            return "Manual exposure is not supported by the active camera format."
        case .manualWhiteBalanceUnsupported:
            return "Manual white balance is not supported by the active camera format."
        case .photoDataUnavailable:
            return "The capture produced no image data."
        case .captureFailed(let detail):
            return "The capture failed: \(detail)."
        case .rawUnsupported:
            return "RAW (DNG) is not supported by the active camera format."
        case .videoNotImplemented:
            return "Video recording is not implemented yet."
        }
    }
}
