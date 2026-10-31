import SwiftUI

// MARK: - Environment plumbing

/// Carries the app's `CameraPermissionServiceProtocol` through the view tree so
/// the `requirePermissions` modifier does not have to be hard-wired to
/// `AppEnvironment`.
private struct PermissionServiceKey: EnvironmentKey {
    /// Fallback for previews / un-injected trees. Fail-closed: it reports
    /// `.notDetermined` so the gate renders and prompts instead of silently
    /// granting access. The running app always injects the real service.
    static var defaultValue: any CameraPermissionServiceProtocol { DefaultPermissionService() }
}

extension EnvironmentValues {
    var permissionService: any CameraPermissionServiceProtocol {
        get { self[PermissionServiceKey.self] }
        set { self[PermissionServiceKey.self] = newValue }
    }
}

/// Previews-only fallback. Never reached in the running app. Deliberately
/// fail-closed: `status` reports `.notDetermined` (never `.granted`) and
/// `request` reports `.denied`, so a forgotten injection surfaces the gate
/// rather than bypassing it.
private final class DefaultPermissionService: CameraPermissionServiceProtocol {
    func status(of permission: AppPermission) async -> PermissionStatus { .notDetermined }
    func request(_ permission: AppPermission) async -> PermissionStatus { .denied }
}

// MARK: - PermissionGateModifier

/// Observes a set of permissions and gates the modified content on all of them
/// being granted. The first non-granted permission (in the supplied order) is
/// presented through `PermissionGateView`. Status is re-checked whenever the
/// scene becomes active, so returning from Settings picks up changes.
@MainActor
struct PermissionGateModifier: ViewModifier {
    let permissions: [AppPermission]

    @Environment(\.permissionService) private var permissionService
    @Environment(\.scenePhase) private var scenePhase

    @State private var statuses: [AppPermission: PermissionStatus] = [:]
    @State private var isReady = false

    func body(content: Content) -> some View {
        Group {
            if !isReady {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let pending = firstUngranted {
                PermissionGateView(
                    permission: pending,
                    status: statuses[pending] ?? .notDetermined,
                    onRequest: { request(pending) }
                ) {
                    content
                }
            } else {
                content
            }
        }
        .task { await refresh() }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await refresh() }
        }
    }

    // MARK: Logic

    private var firstUngranted: AppPermission? {
        permissions.first { (statuses[$0] ?? .notDetermined) != .granted }
    }

    private func refresh() async {
        var updated: [AppPermission: PermissionStatus] = [:]
        for permission in permissions {
            updated[permission] = await permissionService.status(of: permission)
        }
        statuses = updated
        isReady = true
    }

    private func request(_ permission: AppPermission) {
        Task {
            let result = await permissionService.request(permission)
            statuses[permission] = result
        }
    }
}

// MARK: - View API

extension View {
    /// Gates this view on the given permissions being granted.
    @MainActor
    func requirePermissions(_ permissions: [AppPermission]) -> some View {
        modifier(PermissionGateModifier(permissions: permissions))
    }
}
