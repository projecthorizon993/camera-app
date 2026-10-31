import Foundation
import Combine

/// Main-actor dependency container. Owns the router and the lazy, single
/// instances of the app-wide services. Placeholder implementations are wired
/// here until the real feature tasks land; swap points are the lazy initializers.
@MainActor
final class AppEnvironment: ObservableObject {
    /// Navigation state shared by all screens.
    let router = Router()

    /// Permissions facade. // PLACEHOLDER — replaced by Task 3 (real permission service).
    lazy var permissionService: CameraPermissionServiceProtocol = PlaceholderPermissionService()

    /// Hardware camera facade. // PLACEHOLDER — replaced by Task 4 (real AVCaptureSession service).
    lazy var cameraService: CameraServiceProtocol = PlaceholderCameraService()

    /// GPU/image processing facade. // Task 6: real stage-slot pipeline.
    lazy var pipeline: ProcessingPipelineProtocol = DefaultProcessingPipeline()
}
