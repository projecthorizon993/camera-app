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

    /// GPU/image processing facade. // PLACEHOLDER — replaced by Task 6 (Metal pipeline).
    lazy var pipeline: ProcessingPipelineProtocol = PlaceholderPipeline()
}
