import SwiftUI
import UIKit

// Task 15 — full-screen viewer.

struct GalleryViewer: View {
    let item: GalleryItem
    let model: GalleryViewModel
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Theme.Color.chrome900.ignoresSafeArea()
            if let cg = image {
                Image(uiImage: UIImage(cgImage: cg))
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
                    .tint(Theme.Color.textPrimary)
            }
        }
        .task {
            image = await model.ensureFullImage(for: item)
        }
    }
}
