import Foundation

// PLACEHOLDER — replaced by Task 3 (real permission service with system
// dialogs, denied-state handling and Settings deep-link).
//
// Grants everything so the permission gate opens and the app runs
// end-to-end before the real module lands. State is @MainActor-isolated
// (the service is only reached through the main-actor UI stack).

@MainActor
final class PlaceholderPermissionService: CameraPermissionServiceProtocol {
    private var statuses: [AppPermission: PermissionStatus] = [:]

    func status(of permission: AppPermission) async -> PermissionStatus {
        statuses[permission] ?? .notDetermined
    }

    func request(_ permission: AppPermission) async -> PermissionStatus {
        let status: PermissionStatus = .granted
        statuses[permission] = status
        return status
    }
}
