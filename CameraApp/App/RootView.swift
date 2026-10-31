import SwiftUI

// MARK: - Root

/// Root of the app shell. Gates the UI on camera permission, then presents a
/// `NavigationStack` driven by the shared `Router`. The permission check runs
/// once when the view appears and requests access if it is still undetermined.
struct RootView: View {
    @ObservedObject var environment: AppEnvironment
    @ObservedObject var router: Router

    @State private var cameraPermission: PermissionStatus = .notDetermined

    var body: some View {
        NavigationStack(path: $router.path) {
            content
                .navigationDestination(for: AppScreen.self) { screen in
                    destination(for: screen)
                }
        }
        .task {
            await refreshCameraPermission()
        }
    }

    // MARK: - Permission-gated content

    @ViewBuilder
    private var content: some View {
        switch cameraPermission {
        case .granted:
            ViewfinderPlaceholder(router: router)
        case .denied:
            deniedView
        case .notDetermined:
            ProgressView("Requesting camera access...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var deniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Camera Access Needed")
                .font(.title2.bold())
            Text("Enable camera access to use the viewfinder.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Request Again") {
                Task { @MainActor in
                    await refreshCameraPermission()
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Navigation destinations

    @ViewBuilder
    private func destination(for screen: AppScreen) -> some View {
        switch screen {
        case .viewfinder:
            ViewfinderPlaceholder(router: router)
        case .gallery:
            GalleryPlaceholder()
        case .settings:
            SettingsPlaceholder()
        }
    }

    // MARK: - Permission

    @MainActor
    private func refreshCameraPermission() async {
        let service = environment.permissionService
        let current = await service.status(of: .camera)
        if current == .notDetermined {
            cameraPermission = await service.request(.camera)
        } else {
            cameraPermission = current
        }
    }
}
