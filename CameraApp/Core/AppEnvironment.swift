import Foundation
import Combine

/// Main-actor dependency container. Owns the router and the lazy, single
/// instances of the app-wide services. Placeholder implementations are wired
/// here until the real feature tasks land; swap points are the lazy initializers.
@MainActor
final class AppEnvironment: ObservableObject {
    /// Navigation state shared by all screens.
    let router = Router()

    /// Permissions facade. Real system-backed service (Task 3); supersedes
    /// `PlaceholderPermissionService`.
    lazy var permissionService: CameraPermissionServiceProtocol = CameraPermissionService()

    /// Hardware camera facade. Real AVCaptureSession service (Task 4) —
    /// supersedes `PlaceholderCameraService`.
    lazy var cameraService: CameraServiceProtocol = CameraService()

    /// GPU preview renderer for the viewfinder: frames flow
    /// `cameraService.setPreviewFrameHandler` → `renderer.submitFrame` →
    /// `RendererView` (Task 6). Owned here (single instance) so Task 8's
    /// capture flow and a debug HUD can read the same instance's stats.
    /// nil when Metal is unavailable — `RendererView` shows its fallback.
    /// The overlay provider is empty on purpose: grid assist is drawn by the
    /// kit's SwiftUI `ViewfinderGridOverlay` (toggleable), while the Metal
    /// overlay pass stays reserved for future peaking/zebra content.
    lazy var renderer: MetalRenderer? = MetalRenderer(overlayProvider: { [] })

    /// GPU/image processing facade. // Task 6: real stage-slot pipeline.
    lazy var pipeline: ProcessingPipelineProtocol = DefaultProcessingPipeline()

    /// Capture flow (Task 8): shutter → capture → save to Photos, plus the
    /// last-shot thumbnail and shutter feedback. Reads `cameraService` at
    /// first touch — T7's swap of the placeholder for the real T4 service
    /// flows into this controller automatically.
    lazy var captureController: CaptureController = CaptureController(
        cameraService: cameraService,
        permissionService: permissionService
    )

    /// T8 WIRING POINT — capture hook. The viewfinder's shutter button calls
    /// this closure (`ViewfinderScreen` reads `environment.onShutter` at tap
    /// time, so a late assignment by Task 8 is picked up). Assigned once here
    /// to the Task 8 capture pipeline: one press = one captureCurrent() run
    /// (the controller owns busy-guarding, feedback, and outcome state).
    /// Capture params (flash/timer/format) flow from `captureController.settings`
    /// until the HUD chips are rebound onto them (Task 11).
    var onShutter: () -> Void = {}

    init() {
        // The closure must capture `self` weakly: AppEnvironment lives for the
        // whole app run, but the lazy controllers are created on first touch.
        // Strong-capturing here would retain `self` from its own init path.
        // The explicit @MainActor Task hop keeps the capture pipeline on the
        // main actor (SE-0461 — plain Task{} would inherit the closure's
        // nonisolated context... which is the main actor here, but explicit
        // is better than implicit for an @MainActor pipeline).
        onShutter = { [weak self] in
            Task { @MainActor in
                await self?.captureController.captureCurrent()
            }
        }
    }
}
