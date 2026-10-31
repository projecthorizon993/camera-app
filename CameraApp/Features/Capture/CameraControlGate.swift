import Foundation
import CoreGraphics
import CoreVideo

// MARK: - CameraSessionSnapshot

/// Sendable snapshot of the service's lock-guarded state, returned after a
/// device/lens switch so the @MainActor HUD can re-derive zoom bounds.
struct CameraSessionSnapshot: Sendable {
    let capabilities: CameraCapabilities
    let lenses: [LensInfo]
}

// MARK: - CameraServiceMessages

/// Error → UI copy mapping for the capture UI. Nonisolated so gate-queue
/// closures may call it (a static member of the @MainActor HUD state would
/// be main-isolated and unreachable from the gate's queue).
enum CameraServiceMessages {

    static func message(for error: any Error) -> String {
        if let serviceError = error as? CameraServiceError {
            switch serviceError {
            case .sessionNotConfigured:
                return "Camera is not running yet."
            case .deviceUnavailable(let position):
                return "No camera available on the \(position == .front ? "front" : "back")."
            case .lensUnavailable(let lens):
                return "Lens unavailable: \(lens.rawValue)."
            case .zoomOutOfRange:
                return "Zoom level out of range."
            case .focusPointUnsupported:
                return "Tap-to-focus is not supported by the active camera."
            case .configurationFailed(let detail):
                return "Camera configuration failed: \(detail)"
            default:
                break
            }
        }
        return error.localizedDescription
    }
}

// MARK: - CameraControlGate

/// Off-main serial executor for the SYNCHRONOUS `CameraServiceProtocol`
/// members the viewfinder uses (`setZoom`/`focus`/`selectDevice`/
/// `selectLens`/`setPreviewFrameHandler`).
///
/// Binding review finding I1 (T4): these members block on the camera
/// service's session queue, so they must never run on the main actor. This
/// gate is the capture-UI sibling of `ManualServiceGate` (Task 9): the
/// @MainActor caller only enqueues (cheap, non-blocking) and the gate
/// performs the blocking call on its own private serial queue, returning the
/// outcome through a checked continuation.
///
/// The serial queue also preserves enqueue order, so zoom scrub ticks and
/// commit pushes apply in gesture order — the last value always wins on the
/// device.
///
/// `@unchecked Sendable`: the frozen `CameraServiceProtocol` is not declared
/// Sendable, yet the blocking calls must run off-main. The real
/// `CameraService` is thread-safe by construction (`@unchecked Sendable`
/// class: lock-guarded snapshot getters + one serial session queue every
/// mutation funnels into). This box is the single, documented erasure point
/// for that gap in the capture UI.
final class CameraControlGate: @unchecked Sendable {

    private let base: any CameraServiceProtocol
    private let queue = DispatchQueue(label: "camera.controls")

    init(service: any CameraServiceProtocol) {
        self.base = service
    }

    /// Pushes a continuous zoom factor. Returns nil on success, else UI copy.
    func setZoom(_ factor: CGFloat) async -> String? {
        await run { try self.base.setZoom(factor) }
    }

    /// Focuses/exposes at a capture-device point (convert first with
    /// `CameraService.devicePoint(forViewPoint:inPreviewSize:)`).
    /// Returns nil on success, else UI copy.
    func focus(at point: CGPoint) async -> String? {
        await run { try self.base.focus(at: point) }
    }

    /// Switches the active device and returns the fresh capability snapshot.
    func selectDevice(_ position: DevicePosition) async -> Result<CameraSessionSnapshot, String> {
        await runWithSnapshot { try self.base.selectDevice(position) }
    }

    /// Switches the active logical lens and returns the fresh snapshot.
    func selectLens(_ id: CameraLensID) async -> Result<CameraSessionSnapshot, String> {
        await runWithSnapshot { try self.base.selectLens(id) }
    }

    /// Installs (or clears) the preview frame handler. The setter itself is
    /// a non-blocking lock-guarded assignment; routing it through the same
    /// queue keeps it ordered against zoom/focus traffic.
    func setPreviewFrameHandler(_ handler: (@Sendable (CVPixelBuffer) -> Void)?) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.base.setPreviewFrameHandler(handler)
                continuation.resume()
            }
        }
    }

    // MARK: - Plumbing

    private func run(_ operation: @escaping @Sendable () throws -> Void) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            queue.async {
                do {
                    try operation()
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: CameraServiceMessages.message(for: error))
                }
            }
        }
    }

    private func runWithSnapshot(
        _ operation: @escaping @Sendable () throws -> Void
    ) async -> Result<CameraSessionSnapshot, String> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<CameraSessionSnapshot, String>, Never>) in
            queue.async {
                do {
                    try operation()
                    // Snapshot getters are lock-guarded reads (no
                    // session-queue involvement) — safe from this queue.
                    continuation.resume(returning: .success(CameraSessionSnapshot(
                        capabilities: self.base.capabilities,
                        lenses: self.base.availableLenses
                    )))
                } catch {
                    continuation.resume(returning: .failure(CameraServiceMessages.message(for: error)))
                }
            }
        }
    }
}
