import SwiftUI

// MARK: - HUDChipState

/// Visual state of a HUD chip.
///
/// - `.off`: feature available, not active (white icon on scrim).
/// - `.on`: feature active (accent icon on scrim).
/// - `.undisclosed`: state not yet known / not applicable — dimmed with an
///   outlined capsule.
enum HUDChipState: Equatable {
    case off
    case on
    case undisclosed
}

// MARK: - HUDChip

/// Small toggle chip (icon + optional label) for viewfinder HUD rows: flash,
/// timer, grid, focus peaking, and friends. Stateless by design — the caller
/// owns the state and the tap action.
struct HUDChip: View {

    // MARK: Inputs

    let icon: String
    var label: String? = nil
    let state: HUDChipState
    let action: () -> Void

    // MARK: Body

    var body: some View {
        Button {
            Haptics.light()
            action()
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: Theme.Dimension.chipIconSize, weight: .semibold))
                if let label {
                    Text(label)
                        .font(Theme.Typography.hud)
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, Theme.Dimension.chipHPadding)
            .padding(.vertical, Theme.Spacing.s)
            .frame(minHeight: Theme.Dimension.chipHeight)
            .background(Capsule().fill(Theme.Color.chrome900.opacity(Theme.Opacity.chipBackground)))
            .overlay {
                if state == .undisclosed {
                    Capsule().stroke(
                        Theme.Color.textSecondary,
                        lineWidth: Theme.Dimension.digitalStrokeWidth
                    )
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label ?? icon)
        .accessibilityAddTraits(state == .on ? [.isSelected] : [])
    }

    private var foreground: SwiftUI.Color {
        switch state {
        case .on: return Theme.Color.accent
        case .off: return Theme.Color.textPrimary
        case .undisclosed: return Theme.Color.textSecondary.opacity(Theme.Opacity.dimmed)
        }
    }
}

// MARK: - Previews

#Preview("Chip states") {
    HStack(spacing: Theme.Spacing.m) {
        HUDChip(icon: "bolt.slash.fill", state: .off, action: {})
        HUDChip(icon: "bolt.fill", label: "On", state: .on, action: {})
        HUDChip(icon: "timer", label: "Timer", state: .undisclosed, action: {})
    }
    .padding(Theme.Spacing.xl)
    .background(Theme.Color.chrome900)
}

#Preview("HUD row over video-like backdrop") {
    ZStack {
        LinearGradient(colors: [Theme.Color.chrome700, Theme.Color.chrome900],
                       startPoint: .top, endPoint: .bottom)
        VStack(spacing: Theme.Spacing.l) {
            HStack(spacing: Theme.Spacing.m) {
                HUDChip(icon: "bolt.slash.fill", state: .off, action: {})
                HUDChip(icon: "timer", state: .off, action: {})
                HUDChip(icon: "grid.3x3", label: "Grid", state: .on, action: {})
                HUDChip(icon: "waveform.path.ecg", label: "Peaking", state: .undisclosed, action: {})
            }
        }
    }
    .padding(Theme.Spacing.xl)
}
