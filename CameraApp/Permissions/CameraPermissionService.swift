import Foundation
import AVFoundation
import Photos
import CoreLocation
import os

// MARK: - Pure mapping (unit-tested)

/// Frameworks-free snapshot of a system authorization state.
///
/// `mapPermissionStatus(_:for:)` is the pure, unit-testable core of the
/// permissions module: OS enums are converted to `PermissionRawStatus` at the
/// edges, and that value is mapped to the app's three-state `PermissionStatus`
/// deterministically. Declared at file scope (not nested in the `@MainActor`
/// service) so it is unambiguously nonisolated and callable from the test target.
enum PermissionRawStatus: Sendable, Equatable, CaseIterable {
    case notDetermined
    case authorized
    case limited
    case denied
    case restricted
    case unknown
}

/// Deterministic, framework-free mapping from a raw system state to the app's
/// `PermissionStatus`. Unexpected inputs map to `.denied` (never crashes).
///
/// - Note: `permission` is part of the signature so per-permission policy can
///   diverge later; all four permissions currently share one policy.
func mapPermissionStatus(_ raw: PermissionRawStatus, for permission: AppPermission) -> PermissionStatus {
    switch raw {
    case .authorized, .limited:
        return .granted
    case .notDetermined:
        return .notDetermined
    case .denied, .restricted, .unknown:
        return .denied
    }
}

// MARK: - CameraPermissionService

/// Real, system-backed permission service (Task 3).
///
/// Main-actor isolated on purpose: the only mutable state is the in-flight
/// location delegate, so confining the type to the main actor keeps that state
/// race-free (review findings I1/M1). The protocol requirements are `async`, and
/// `SWIFT_APPROACHABLE_CONCURRENCY` enables isolated-conformance inference
/// (SE-0470), so a `@MainActor` witness is a legal — and intended — conformance
/// to `CameraPermissionServiceProtocol`.
@MainActor
final class CameraPermissionService: CameraPermissionServiceProtocol {

    private let logger = Logger(subsystem: "com.jaca.CameraApp", category: "Permissions")

    private let locationManager = CLLocationManager()

    /// Retained for the duration of a delegate-based location request so the
    /// delegate outlives the call that kicks off the system prompt.
    private var locationDelegate: LocationAuthorizationDelegate?

    // MARK: CameraPermissionServiceProtocol

    func status(of permission: AppPermission) async -> PermissionStatus {
        // The protocol witness is `nonisolated(nonsending)` under SE-0461, so
        // hop to the main actor for the `@MainActor`-isolated state read.
        let raw = await currentRawStatus(of: permission)
        return mapPermissionStatus(raw, for: permission)
    }

    func request(_ permission: AppPermission) async -> PermissionStatus {
        switch permission {
        case .camera:
            _ = await AVCaptureDevice.requestAccess(for: .video)
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .photoLibraryAdd:
            _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        case .location:
            await requestLocationAuthorization()
        }
        return await status(of: permission)
    }

    // MARK: Raw state

    private func currentRawStatus(of permission: AppPermission) -> PermissionRawStatus {
        let raw: PermissionRawStatus
        switch permission {
        case .camera:
            raw = Self.raw(from: AVCaptureDevice.authorizationStatus(for: .video))
        case .microphone:
            raw = Self.raw(from: AVCaptureDevice.authorizationStatus(for: .audio))
        case .photoLibraryAdd:
            raw = Self.raw(from: PHPhotoLibrary.authorizationStatus(for: .addOnly))
        case .location:
            raw = Self.raw(from: locationManager.authorizationStatus)
        }
        if raw == .unknown {
            logger.error("Unexpected authorization status for \(permission.rawValue, privacy: .public); mapping to .denied")
        }
        return raw
    }

    private static func raw(from status: AVAuthorizationStatus) -> PermissionRawStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unknown
        }
    }

    private static func raw(from status: PHAuthorizationStatus) -> PermissionRawStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .limited: return .limited
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unknown
        }
    }

    private static func raw(from status: CLAuthorizationStatus) -> PermissionRawStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorizedAlways, .authorizedWhenInUse: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unknown
        }
    }

    // MARK: Location

    private func requestLocationAuthorization() async {
        // Only prompt while still undetermined; a determined state cannot be
        // changed from inside the app.
        guard locationManager.authorizationStatus == .notDetermined else { return }

        let delegate = LocationAuthorizationDelegate()
        locationDelegate = delegate
        _ = await delegate.requestAuthorization(manager: locationManager)
        locationDelegate = nil
    }
}

// MARK: - LocationAuthorizationDelegate

/// Bridges `CLLocationManager`'s delegate-based authorization callback into an
/// `async` call.
///
/// `CLLocationManagerDelegate` is a *nonisolated* protocol, so the conformance
/// is marked `@preconcurrency`: the type (and its stored continuation) stays
/// main-actor confined while the delegate requirement is satisfied. Core
/// Location delivers these callbacks on the run loop of the thread that created
/// the manager — and the manager is created on the main actor — so the
/// main-actor assumption holds at runtime.
@MainActor
private final class LocationAuthorizationDelegate: NSObject, @preconcurrency CLLocationManagerDelegate {

    private var continuation: CheckedContinuation<CLAuthorizationStatus, Never>?

    func requestAuthorization(manager: CLLocationManager) async -> CLAuthorizationStatus {
        await withCheckedContinuation { (continuation: CheckedContinuation<CLAuthorizationStatus, Never>) in
            self.continuation = continuation
            manager.delegate = self
            manager.requestWhenInUseAuthorization()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        // Core Location invokes this once with the current (undetermined) state
        // when the delegate is first set; wait for a real decision.
        guard status != .notDetermined else { return }
        guard let continuation = self.continuation else { return }
        self.continuation = nil
        manager.delegate = nil
        continuation.resume(returning: status)
    }
}
