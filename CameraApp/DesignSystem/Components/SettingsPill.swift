import SwiftUI

// MARK: - SettingsPill

/// Link-style pill for entry points (Settings, Gallery, …): icon, title, and a
/// subtle chevron inside a scrimmed capsule. Stateless — the caller owns the
/// navigation action.
struct SettingsPill: View {

    // MARK: Inputs

    let icon: String
    let title: String
    let action: () -> Void

    // MARK: Body

    var body: some View {
        Button {
            Haptics.light()
            action()
        } label: {
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: icon)
                    .font(.system(size: Theme.Dimension.chipIconSize, weight: .semibold))
                    .foregroundStyle(Theme.Color.accent)
                Text(title)
                    .font(Theme.Typography.hud)
                    .foregroundStyle(Theme.Color.textPrimary)
                Image(systemName: "chevron.right")
                    .font(.system(size: Theme.Dimension.chipChevronSize, weight: .semibold))
                    .foregroundStyle(Theme.Color.textSecondary.opacity(Theme.Opacity.dimmed))
            }
            .padding(.horizontal, Theme.Dimension.chipHPadding)
            .padding(.vertical, Theme.Spacing.s)
            .frame(minHeight: Theme.Dimension.chipHeight)
            .background(Capsule().fill(Theme.Color.chrome900.opacity(Theme.Opacity.chipBackground)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isLink)
    }
}

// MARK: - Previews

#Preview("Entry-point pills") {
    HStack(spacing: Theme.Spacing.m) {
        SettingsPill(icon: "photo.on.rectangle", title: "Gallery", action: {})
        SettingsPill(icon: "gearshape", title: "Settings", action: {})
    }
    .padding(Theme.Spacing.xl)
    .background(Theme.Color.chrome900)
}
