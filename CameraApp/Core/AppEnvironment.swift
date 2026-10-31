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

    /// T8 WIRING POINT — capture hook. The viewfinder's shutter button calls
    /// this closure (`ViewfinderScreen` reads `environment.onShutter` at tap
    /// time, so a late assignment by Task 8 is picked up). Task 8 assigns
    /// its capture pipeline here; the default is a no-op.
    var onShutter: () -> Void = {}
}
