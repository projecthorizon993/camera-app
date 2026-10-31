import SwiftUI

// PLACEHOLDER — replaced by Task 17 (capture gallery / filmstrip).

struct GalleryPlaceholder: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Gallery")
                .font(.largeTitle.bold())
            Text("Under construction")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Gallery")
    }
}
