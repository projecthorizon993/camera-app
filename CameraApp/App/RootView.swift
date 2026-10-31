import SwiftUI

// MARK: - Root

/// Root of the app shell. Presents a `NavigationStack` driven by the shared
/// `Router`. The viewfinder flow is gated on camera permission through the
/// reusable `.requirePermissions([.camera])` modifier (Task 3); the gallery and
/// settings flows are intentionally left ungated (photo-library READ is not
/// requested in v1).
struct RootView: View {
    @ObservedObject var environment: AppEnvironment
    @ObservedObject var router: Router

    var body: some View {
        NavigationStack(path: $router.path) {
            viewfinder
                .requirePermissions([.camera])
                .navigationDestination(for: AppScreen.self) { screen in
                    destination(for: screen)
                }
        }
    }

    /// The live viewfinder (Task 7). The permission gate stays OUTSIDE/above
    /// (applied at the root of the stack, Task 3) — not duplicated here.
    private var viewfinder: some View {
        ViewfinderScreen(
            service: environment.cameraService,
            renderer: environment.renderer,
            router: router,
            environment: environment
        )
    }

    // MARK: - Navigation destinations

    @ViewBuilder
    private func destination(for screen: AppScreen) -> some View {
        switch screen {
        case .viewfinder:
            // Same screen as the root; camera permission is app-wide and
            // already gated at the root of the stack.
            viewfinder
        case .gallery:
            GalleryPlaceholder()
        case .settings:
            SettingsPlaceholder()
        }
    }
}
