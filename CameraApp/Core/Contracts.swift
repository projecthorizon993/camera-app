import Foundation
import CoreGraphics
import CoreVideo
import AVFoundation

// FROZEN ARCHITECTURE CONTRACTS — Task 2.
// The member surface below is frozen: later briefs quote it verbatim.
// Members may be added later, but none may be renamed, re-typed, or removed.
//
// Concurrency notes (Swift 6):
// - `async throws` is not by itself a background guarantee — under Approachable
//   Concurrency (SE-0461) a nonisolated async call runs on the caller's actor;
//   hardware/processing implementations must explicitly confine themselves to a
//   background executor (dedicated serial queue or actor). Types crossing actors
//   are Sendable value types.
// - CVPixelBuffer flows through nonisolated call paths only; the project
//   enables Approachable Concurrency (nonisolated async runs on the caller's
//   actor), so @MainActor UI code can await these services directly.

// MARK: - CameraServiceProtocol

/// All camera hardware access in the app goes through this protocol.
protocol CameraServiceProtocol: AnyObject {
    func startSession() async throws
    func stopSession()
    var capabilities: CameraCapabilities { get }
    var availableLenses: [LensInfo] { get }
    func selectDevice(_ position: DevicePosition) throws
    func selectLens(_ id: CameraLensID) throws
    func setZoom(_ factor: CGFloat) throws
    func applyManualConfig(_ config: ManualCameraConfig) throws
    func resetToAuto() throws
    var supportedManualRanges: ManualRanges { get }
    func capturePhoto(_ settings: PhotoCaptureSettings) async throws -> CapturedPhoto
    func captureBracket(depth: BracketDepth) async throws -> [CapturedPhoto]
    func startVideoRecording(_ config: VideoRecordingConfig) throws
    func stopVideoRecording() async -> URL
    func focus(at point: CGPoint) throws
    func setExposureOffset(_ ev: Float) throws
    /// Delivers frames (video data output) into the processing pipeline. Called on a
    /// background queue; implementers must not retain buffers longer than the call.
    func setPreviewFrameHandler(_ handler: (@Sendable (CVPixelBuffer) -> Void)?)
}

// MARK: - ProcessingPipelineProtocol

protocol ProcessingStageProtocol: AnyObject {
    var stage: PipelineStage { get }
    func process(_ input: CVPixelBuffer, context: ProcessingContext) async throws -> CVPixelBuffer
}

protocol ProcessingPipelineProtocol: AnyObject {
    func setStage(_ stage: PipelineStage, _ processor: ProcessingStageProtocol?)
    func run(_ input: CVPixelBuffer, stages: [PipelineStage], context: ProcessingContext) async throws -> CVPixelBuffer
}

// MARK: - Feature protocols (later tasks implement these)

protocol LookEngineProtocol: AnyObject {
    func loadLook(_ id: LookID) throws
    func apply(_ input: CVPixelBuffer, look: LookID, strength: Double) async throws -> CVPixelBuffer
    var availableLooks: [LookID] { get }
}

protocol WatermarkRendererProtocol: AnyObject {
    func render(_ input: CVPixelBuffer, template: WatermarkTemplate, exif: ExifSummary?, position: WatermarkPosition, opacity: Double) async throws -> CVPixelBuffer
    var availableTemplates: [WatermarkTemplate] { get }
}

protocol LensCorrectionProtocol: AnyObject {
    func loadProfile(for lens: CameraLensID) throws
    func apply(_ input: CVPixelBuffer, lens: CameraLensID, mode: LensCorrectionMode, strength: Double) async throws -> CVPixelBuffer
    var hasProfiles: Bool { get }
}

protocol CameraPermissionServiceProtocol: AnyObject {
    func status(of permission: AppPermission) async -> PermissionStatus
    func request(_ permission: AppPermission) async -> PermissionStatus
}
