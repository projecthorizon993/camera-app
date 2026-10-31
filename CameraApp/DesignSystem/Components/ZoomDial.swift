import SwiftUI

// MARK: - ZoomDial

/// Inline zoom selector in the stock-camera pebble style: optical stops as
/// equal-width buttons inside a scrimmed strip, plus continuous horizontal
/// drag to scrub between and beyond the stops.
///
/// Pure UI: takes `stops` (optical factors, ascending), the full draggable
/// `range` (which may extend past the last optical stop), and a `factor`
/// binding. Factors past the largest stop are the digital-zoom region and are
/// visually distinguished (accent label + outlined badge).
struct ZoomDial: View {

    // MARK: Inputs

    /// Optical stop factors, ascending (e.g. [0.5, 1, 2]).
    let stops: [CGFloat]
    /// Full draggable range, possibly beyond the optical stops (digital zoom).
    let range: ClosedRange<CGFloat>
    /// Current zoom factor binding.
    @Binding var factor: CGFloat
    /// Called when a scrub drag ends or a stop is tapped (commit semantics).
    var onCommit: (() -> Void)? = nil

    // MARK: State

    @State private var dragBase: CGFloat?

    // MARK: Body

    var body: some View {
        VStack(spacing: Theme.Spacing.s) {
            Text(Self.formatFactor(factor))
                .font(Theme.Typography.value)
                .foregroundStyle(isDigital ? Theme.Color.accent : Theme.Color.textPrimary)
                .accessibilityHidden(true)

            GeometryReader { geo in
                HStack(spacing: Theme.Spacing.xs) {
                    ForEach(stops, id: \.self) { stop in
                        stopButton(stop)
                    }
                    if isDigital {
                        digitalBadge
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .padding(.horizontal, Theme.Spacing.s)
                .background(Capsule().fill(Theme.Color.chrome900.opacity(Theme.Opacity.chipBackground)))
                .contentShape(Capsule())
                .gesture(scrubGesture(width: geo.size.width))
            }
            .frame(height: Theme.Dimension.zoomStripHeight)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Region state

    /// True while the factor sits beyond the largest optical stop.
    private var isDigital: Bool {
        guard let maxStop = stops.max() else { return false }
        return factor > maxStop + Theme.Dimension.zoomSelectEpsilon
    }

    private func isSelectedStop(_ stop: CGFloat) -> Bool {
        abs(factor - stop) <= Theme.Dimension.zoomSelectEpsilon
    }

    // MARK: Stop buttons

    private func stopButton(_ stop: CGFloat) -> some View {
        let isSelected = isSelectedStop(stop)
        return Button {
            Haptics.light()
            withAnimation(.easeOut(duration: Theme.Animation.snapDuration)) {
                factor = Theme.clamp(stop, range)
            }
            onCommit?()
        } label: {
            Text(Self.formatFactor(stop))
                .font(Theme.Typography.value)
                .foregroundStyle(isSelected ? Theme.Color.chrome900 : Theme.Color.textPrimary)
                .padding(.vertical, Theme.Spacing.s)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    if isSelected {
                        Capsule().fill(Theme.Color.textPrimary)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Zoom \(Self.formatFactor(stop))")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Outlined badge for the digital-zoom region showing the live factor.
    private var digitalBadge: some View {
        Text(Self.formatFactor(factor))
            .font(Theme.Typography.hud)
            .foregroundStyle(Theme.Color.accent)
            .padding(.horizontal, Theme.Spacing.s)
            .overlay(
                Capsule().stroke(Theme.Color.accent, lineWidth: Theme.Dimension.digitalStrokeWidth)
            )
            .accessibilityLabel("Digital zoom \(Self.formatFactor(factor))")
    }

    // MARK: Continuous scrub

    /// Drag maps full-strip translation across the whole range; drag right =
    /// zoom in. The binding updates live so the consumer can stream factor
    /// changes; `onCommit` fires on drag end.
    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: Theme.Dimension.modeDragMinDistance)
            .onChanged { gesture in
                if dragBase == nil { dragBase = factor }
                let span = range.upperBound - range.lowerBound
                guard span > 0 else { return }
                let perPoint = span / max(width, 1)
                factor = Theme.clamp((dragBase ?? factor) + gesture.translation.width * perPoint, range)
            }
            .onEnded { _ in
                dragBase = nil
                onCommit?()
            }
    }

    // MARK: Formatting

    /// "0.5×", "1×", "2×", "2.7×" — %g drops trailing zeros.
    static func formatFactor(_ factor: CGFloat) -> String {
        String(format: "%g×", factor)
    }
}

// MARK: - Previews

/// Host providing interactive state for previews.
private struct ZoomDialPreviewHost: View {
    @State private var factor: CGFloat
    let stops: [CGFloat]
    let range: ClosedRange<CGFloat>

    /// Explicit init (internal by default): private stored properties make the
    /// synthesized memberwise initializer private, which #Preview expansion
    /// cannot call; parameters lead with the binding like the component.
    init(factor: CGFloat, stops: [CGFloat], range: ClosedRange<CGFloat>) {
        self.factor = factor
        self.stops = stops
        self.range = range
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            ZoomDial(stops: stops, range: range, factor: $factor, onCommit: nil)
            Text("factor: \(ZoomDial.formatFactor(factor))")
                .font(Theme.Typography.hud)
                .foregroundStyle(Theme.Color.textSecondary)
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Color.chrome900)
    }
}

#Preview("Optical stops") {
    ZoomDialPreviewHost(factor: 1, stops: [0.5, 1, 2], range: 0.5...6)
}

#Preview("Digital region") {
    ZoomDialPreviewHost(factor: 3.4, stops: [0.5, 1, 2], range: 0.5...6)
}
