import SwiftUI
import UIKit

// MARK: - PermissionGateView

/// Reusable, full-screen permission gate for a single `AppPermission`.
///
/// - `.notDetermined`: explainer plus an "Allow" button that triggers the
///   system request (the owner re-evaluates afterwards).
/// - `.denied`: explanation plus a primary "Open Settings" button.
/// - `.granted`: renders the supplied content.
///
/// NOTE: styling is intentionally plain/neutral for now — Task 7a replaces this
/// with the DesignSystem `PermissionGateView` look once that module lands.
@MainActor
struct PermissionGateView<Content: View>: View {
    let permission: AppPermission
    let status: PermissionStatus
    let onRequest: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        switch status {
        case .granted:
            content()
        case .notDetermined:
            gate(message: permission.gateMessage) {
                Button("Allow") { onRequest() }
                    .buttonStyle(.borderedProminent)
            }
        case .denied:
            gate(message: permission.deniedMessage) {
                Button("Open Settings") { openSettings() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: Subviews

    @ViewBuilder
    private func gate<Actions: View>(message: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 16) {
            Image(systemName: permission.systemImage)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(permission.gateTitle)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            actions()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Permission copy

/// Display copy for each permission, owned by the permissions module (adds
/// members only; the frozen `AppPermission` case set is untouched).
extension AppPermission {
    var displayName: String {
        switch self {
        case .camera: return "Camera"
        case .microphone: return "Microphone"
        case .photoLibraryAdd: return "Photo Library"
        case .location: return "Location"
        }
    }

    var systemImage: String {
        switch self {
        case .camera: return "camera.fill"
        case .microphone: return "mic.fill"
        case .photoLibraryAdd: return "photo.badge.plus"
        case .location: return "location.fill"
        }
    }

    var gateTitle: String {
        return "\(displayName) Access Needed"
    }

    /// Shown while the permission is still `.notDetermined`.
    var gateMessage: String {
        switch self {
        case .camera:
            return "CameraApp needs access to the camera to capture photos and video."
        case .microphone:
            return "CameraApp needs access to the microphone to record audio with video."
        case .photoLibraryAdd:
            return "CameraApp needs permission to add captured photos and videos to your library."
        case .location:
            return "CameraApp can geotag your captures with your location if you allow it."
        }
    }

    /// Shown when the permission is `.denied`.
    var deniedMessage: String {
        switch self {
        case .camera:
            return "Camera access is turned off. Open Settings and enable Camera for CameraApp to use the viewfinder."
        case .microphone:
            return "Microphone access is turned off. Open Settings and enable Microphone for CameraApp to record audio."
        case .photoLibraryAdd:
            return "CameraApp cannot add to your photo library. Open Settings and allow Photos access."
        case .location:
            return "Location access is turned off. Open Settings and enable Location to geotag captures."
        }
    }
}
