import SwiftUI

// PLACEHOLDER — replaced by Task 4+ (live viewfinder + capture controls).
//
// Root screen of the shell. Confirms the permission gate opened and offers
// navigation into the gallery and settings screens.

struct ViewfinderPlaceholder: View {
    @ObservedObject var router: Router

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("Viewfinder")
                .font(.largeTitle.bold())
            Text("Under construction")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Camera")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    router.push(.gallery)
                } label: {
                    Label("Gallery", systemImage: "photo.on.rectangle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    router.push(.settings)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
    }
}
