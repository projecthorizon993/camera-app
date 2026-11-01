import SwiftUI
import UIKit

// Task 15 — a single gallery grid cell.

struct GalleryCell: View {
    let item: GalleryItem
    let thumbnail: CGImage?
    let isSelected: Bool
    let selectionMode: Bool

    var body: some View {
        ZStack {
            if let cg = thumbnail {
                Image(uiImage: UIImage(cgImage: cg))
                    .resizable()
                    .scaledToFill()
            } else {
                Theme.Color.chrome700
            }

            VStack {
                Spacer()
                HStack {
                    if item.isRAW {
                        badge("DNG", alignment: .leading)
                    }
                    Spacer()
                    if item.isVideo, let text = GalleryItemLogic.durationText(item.durationSeconds) {
                        badge(text, alignment: .trailing)
                    }
                }
            }
            .padding(Theme.Spacing.xs)

            if selectionMode && isSelected {
                ZStack {
                    Circle()
                        .stroke(Theme.Color.accent, lineWidth: 3)
                        .frame(width: 24, height: 24)
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.Color.accent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(Theme.Spacing.xs)
            }
        }
        .aspectRatio(4.0 / 3.0, contentMode: .fill)
        .clipped()
        .background(Theme.Color.chrome800)
    }

    @ViewBuilder
    private func badge(_ text: String, alignment: Alignment) -> some View {
        Text(text)
            .font(Theme.Typography.hud)
            .foregroundStyle(Theme.Color.textPrimary)
            .padding(.horizontal, Theme.Spacing.xs)
            .padding(.vertical, 2)
            .background(Theme.Color.chrome900.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.s / 2))
    }
}
