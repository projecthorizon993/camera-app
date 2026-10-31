import SwiftUI

// MARK: - ModeSwitchBar

/// Horizontal pill bar of capture modes (photo / video / night / timelapse).
///
/// The selected mode is highlighted with a filled accent capsule (warm amber,
/// stock-camera style); drag left/right or tap to switch. A light haptic fires
/// per detent. Modes listed in `disabledModes` render dimmed and stay inert
/// ("coming soon" handling lives with the consumer).
struct ModeSwitchBar: View {

    // MARK: Inputs

    let modes: [CaptureMode]
    @Binding var selected: CaptureMode
    var disabledModes: Set<CaptureMode> = []

    // MARK: Body

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: Theme.Spacing.xs) {
                ForEach(modes, id: \.self) { mode in
                    item(for: mode)
                }
            }
            .padding(Theme.Spacing.xs)
            .frame(width: geo.size.width, height: geo.size.height)
            .background(Capsule().fill(Theme.Color.chrome900.opacity(Theme.Opacity.chipBackground)))
            .contentShape(Capsule())
            .gesture(dragGesture(width: geo.size.width))
        }
        .frame(height: Theme.Dimension.modeBarHeight)
    }

    // MARK: Items

    private func item(for mode: CaptureMode) -> some View {
        let isSelected = mode == selected
        let isDisabled = disabledModes.contains(mode)
        return Button {
            guard !isDisabled, mode != selected else { return }
            Haptics.light()
            withAnimation(.spring(
                response: Theme.Animation.pressResponse,
                dampingFraction: Theme.Animation.pressDamping
            )) {
                selected = mode
            }
        } label: {
            VStack(spacing: Theme.Spacing.xs) {
                Image(systemName: mode.symbolName)
                    .font(.system(size: Theme.Dimension.modeBarIcon, weight: .semibold))
                Text(mode.displayTitle)
                    .font(Theme.Typography.hud)
            }
            .foregroundStyle(foreground(isSelected: isSelected, isDisabled: isDisabled))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if isSelected {
                    Capsule().fill(Theme.Color.accent)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(mode.displayTitle)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func foreground(isSelected: Bool, isDisabled: Bool) -> SwiftUI.Color {
        if isSelected { return Theme.Color.chrome900 }
        if isDisabled { return Theme.Color.textSecondary.opacity(Theme.Opacity.dimmed) }
        return Theme.Color.textPrimary
    }

    // MARK: Drag to switch

    /// Horizontal drag picks the detent whose slot the gesture ended over:
    /// translation is divided by the per-item slot width, so one slot-width of
    /// drag moves one detent.
    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: Theme.Dimension.modeDragMinDistance)
            .onEnded { value in
                let slotWidth = width / CGFloat(max(modes.count, 1))
                let steps = Int(((-value.translation.width / slotWidth).rounded()))
                guard steps != 0 else { return }
                guard let currentIndex = modes.firstIndex(of: selected) else { return }
                let nextIndex = min(max(currentIndex + steps, 0), modes.count - 1)
                let target = modes[nextIndex]
                guard target != selected, !disabledModes.contains(target) else { return }
                Haptics.light()
                withAnimation(.spring(
                    response: Theme.Animation.pressResponse,
                    dampingFraction: Theme.Animation.pressDamping
                )) {
                    selected = target
                }
            }
    }
}

// MARK: - CaptureMode display info

/// Display copy for capture modes. File-private on purpose: this only adds
/// members (the frozen `CaptureMode` case set in Core is untouched).
private extension CaptureMode {
    var displayTitle: String {
        switch self {
        case .photo: return "Photo"
        case .video: return "Video"
        case .night: return "Night"
        case .timelapse: return "Timelapse"
        }
    }

    var symbolName: String {
        switch self {
        case .photo: return "camera.fill"
        case .video: return "video.fill"
        case .night: return "moon.stars.fill"
        case .timelapse: return "timer"
        }
    }
}

// MARK: - Previews

/// Host providing interactive state for previews.
private struct ModeSwitchBarPreviewHost: View {
    @State private var selected: CaptureMode = .photo
    let disabledModes: Set<CaptureMode>

    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            ModeSwitchBar(
                modes: CaptureMode.allCases,
                selected: $selected,
                disabledModes: disabledModes
            )
            Text("Selected: \(selected.rawValue)")
                .font(Theme.Typography.hud)
                .foregroundStyle(Theme.Color.textSecondary)
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Color.chrome900)
    }
}

#Preview("All enabled") {
    ModeSwitchBarPreviewHost(disabledModes: [])
}

#Preview("Video disabled (soon)") {
    ModeSwitchBarPreviewHost(disabledModes: [.video, .night, .timelapse])
}
