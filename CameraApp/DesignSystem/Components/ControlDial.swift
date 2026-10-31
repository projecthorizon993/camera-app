import SwiftUI

// MARK: - ControlDial

/// Vertical drag slider in the stock-camera exposure/focus style: a slim track
/// with an icon handle that drags up/down and adjusts a normalized 0...1 value
/// (up = higher). Optional snap points settle to the nearest detent with a
/// haptic; a value label shows while dragging and auto-fades.
///
/// Pure UI and reusable — Task 9 targets this control for ISO / shutter /
/// white-balance / focus by passing a custom icon and a value formatter.
struct ControlDial: View {

    // MARK: Inputs

    /// SF Symbol drawn in the handle (e.g. "sun.max.fill" for exposure).
    let icon: String
    /// Optional accessibility/readout title (e.g. "Exposure").
    var title: String? = nil
    /// Normalized 0...1 binding; up = higher.
    @Binding var value: CGFloat
    /// Optional normalized detents to snap to on drag end.
    var snapPoints: [CGFloat] = []
    /// Optional formatter for the drag label; default shows whole percentages.
    var valueLabel: ((CGFloat) -> String)? = nil
    /// Called once when a drag ends (commit semantics for service calls).
    var onCommit: (() -> Void)? = nil

    // MARK: State

    @State private var dragStart: CGFloat?
    @State private var isDragging = false
    @State private var labelVisible = false

    // MARK: Body

    var body: some View {
        VStack(spacing: Theme.Spacing.s) {
            valueText
                .font(Theme.Typography.value)
                .foregroundStyle(Theme.Color.textPrimary)
                .opacity(labelVisible ? 1 : 0)
                .animation(.easeInOut(duration: Theme.Animation.labelFade), value: labelVisible)
                .accessibilityHidden(true)

            GeometryReader { geo in
                ZStack(alignment: .top) {
                    track(height: geo.size.height)
                    handle
                        .position(x: geo.size.width / 2, y: handleY(height: geo.size.height))
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(height: geo.size.height))
            }
            .frame(width: Theme.Dimension.dialWidth, height: Theme.Dimension.dialLength)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title ?? icon)
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                value = Theme.clamp01(value + Theme.Dimension.dialAccessibilityStep)
            case .decrement:
                value = Theme.clamp01(value - Theme.Dimension.dialAccessibilityStep)
            @unknown default:
                break
            }
        }
    }

    // MARK: Track + handle

    private func track(height: CGFloat) -> some View {
        Capsule()
            .fill(Theme.Color.chrome700)
            .frame(width: Theme.Dimension.dialTrackWidth,
                   height: max(height - Theme.Spacing.l, 0))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var handle: some View {
        Circle()
            .fill(Theme.Color.chrome900)
            .overlay(
                Circle().stroke(Theme.Color.textPrimary, lineWidth: Theme.Dimension.dialHandleStroke)
            )
            .overlay(
                Image(systemName: icon)
                    .font(.system(size: Theme.Dimension.dialHandleIcon, weight: .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
            )
            .frame(width: Theme.Dimension.dialHandle, height: Theme.Dimension.dialHandle)
            .shadow(color: Theme.Shadow.overlay.color,
                    radius: Theme.Shadow.overlay.radius,
                    y: Theme.Shadow.overlay.y)
            .scaleEffect(isDragging ? Theme.Dimension.dialHandleDragScale : 1.0)
            .animation(.spring(
                response: Theme.Animation.pressResponse,
                dampingFraction: Theme.Animation.pressDamping
            ), value: isDragging)
    }

    /// Handle center Y for the current value: value 1 pins to the top inset,
    /// value 0 to the bottom inset.
    private func handleY(height: CGFloat) -> CGFloat {
        let inset = Theme.Dimension.dialHandle / 2 + Theme.Spacing.s
        let usable = max(height - inset * 2, 1)
        return inset + (1 - Theme.clamp01(value)) * usable
    }

    // MARK: Drag

    private func dragGesture(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if dragStart == nil {
                    dragStart = value
                    isDragging = true
                    labelVisible = true
                    Haptics.light()
                }
                let inset = Theme.Dimension.dialHandle / 2 + Theme.Spacing.s
                let usable = max(height - inset * 2, 1)
                let delta = -gesture.translation.height / usable
                value = Theme.clamp01((dragStart ?? value) + delta)
            }
            .onEnded { _ in
                dragStart = nil
                isDragging = false
                applySnap()
                onCommit?()
                fadeLabelAfterDelay()
            }
    }

    private func applySnap() {
        guard !snapPoints.isEmpty else { return }
        let threshold = Theme.Dimension.dialSnapThreshold
        guard let nearest = snapPoints.min(by: { abs($0 - value) < abs($1 - value) }),
              abs(nearest - value) <= threshold else { return }
        Haptics.light()
        withAnimation(.easeOut(duration: Theme.Animation.snapDuration)) {
            value = nearest
        }
    }

    private func fadeLabelAfterDelay() {
        withAnimation(.easeIn(duration: Theme.Animation.labelFade)
            .delay(Theme.Animation.labelHold)) {
            labelVisible = false
        }
    }

    // MARK: Label

    private var valueText: Text {
        Text(valueLabel?(value) ?? String(format: "%.0f%%", Theme.clamp01(value) * 100))
    }
}

// MARK: - Previews

/// Host providing interactive state for previews.
private struct ControlDialPreviewHost: View {
    @State private var value: CGFloat = 0.5
    let icon: String
    let title: String
    let snapPoints: [CGFloat]
    let label: ((CGFloat) -> String)?

    var body: some View {
        HStack(spacing: Theme.Spacing.xxl) {
            ControlDial(
                icon: icon,
                title: title,
                value: $value,
                snapPoints: snapPoints,
                valueLabel: label,
                onCommit: nil
            )
        }
        .padding(Theme.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Color.chrome900)
    }
}

#Preview("Exposure (percent label)") {
    ControlDialPreviewHost(
        icon: "sun.max.fill",
        title: "Exposure",
        snapPoints: [0.5],
        label: nil
    )
}

#Preview("ISO (custom label + detents)") {
    ControlDialPreviewHost(
        icon: "camera.aperture",
        title: "ISO",
        snapPoints: [0.0, 0.25, 0.5, 0.75, 1.0],
        label: { value in
            let iso = Int(50 + value * (6400 - 50))
            return "ISO \(iso)"
        }
    )
}
