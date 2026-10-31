import SwiftUI

/// App entry point. Owns the single `AppEnvironment` for the process and
/// injects it (and its router) into the root view, alongside the permission
/// service used by the `requirePermissions` gate.
@main
struct CameraApp: App {
    @StateObject private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView(environment: environment, router: environment.router)
                .environment(\.permissionService, environment.permissionService)
        }
    }
}
