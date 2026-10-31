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

    /// Hardware camera facade. // PLACEHOLDER — replaced by Task 4 (real AVCaptureSession service).
    lazy var cameraService: CameraServiceProtocol = PlaceholderCameraService()

    /// GPU/image processing facade. // Task 6: real stage-slot pipeline.
    lazy var pipeline: ProcessingPipelineProtocol = DefaultProcessingPipeline()

    /// Capture flow (Task 8): shutter → capture → save to Photos, plus the
    /// last-shot thumbnail and shutter feedback. Reads `cameraService` at
    /// first touch — T7's `AppEnvironment` swap of the placeholder for the
    /// real T4 service flows into this controller automatically.
    lazy var captureController: CaptureController = CaptureController(
        cameraService: cameraService,
        permissionService: permissionService
    )
}
