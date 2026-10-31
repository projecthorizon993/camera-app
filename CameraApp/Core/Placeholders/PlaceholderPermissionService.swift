import Foundation

/// PLACEHOLDER — replaced by Task 3 (real CameraPermissionService).
final class PlaceholderPermissionService: CameraPermissionServiceProtocol {
    func status(of permission: AppPermission) async -> PermissionStatus {
        .notDetermined
    }

    func request(_ permission: AppPermission) async -> PermissionStatus {
        .granted
    }
}
