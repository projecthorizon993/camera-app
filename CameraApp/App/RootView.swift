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
            ViewfinderPlaceholder(router: router)
                .requirePermissions([.camera])
                .navigationDestination(for: AppScreen.self) { screen in
                    destination(for: screen)
                }
        }
    }

    // MARK: - Navigation destinations

    @ViewBuilder
    private func destination(for screen: AppScreen) -> some View {
        switch screen {
        case .viewfinder:
            ViewfinderPlaceholder(router: router)
                .requirePermissions([.camera])
        case .gallery:
            GalleryPlaceholder()
        case .settings:
            SettingsPlaceholder()
        }
    }
}
