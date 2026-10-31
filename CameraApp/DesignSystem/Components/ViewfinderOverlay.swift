import SwiftUI

// MARK: - ViewfinderZone

/// Documented layout zones of the viewfinder chrome.
///
/// - `.top`: HUD chips row (flash / timer / grid / peaking).
/// - `.trailing`: dial column (exposure-style ControlDials).
/// - `.bottom`: mode bar + shutter row.
enum ViewfinderZone {
    case top
    case trailing
    case bottom
}

// MARK: - ViewfinderOverlay

/// Layout skeleton for the live viewfinder chrome (not content): a
/// safe-area-aware overlay container with the three documented zones —
/// top (HUD chips row), trailing (dial column), bottom (mode bar + shutter
/// row) — plus edge scrims and a toggleable 3x3 rule-of-thirds grid.
///
/// Consumers pass slot views; the container owns all padding/placement. For
/// composition on an existing base (e.g. the Metal renderer view), prefer the
/// `.viewfinderSlot(_:content:)` modifiers below, which place content into the
/// same zones without re-doing layout.
struct ViewfinderOverlay<Top: View, Trailing: View, Bottom: View>: View {

    // MARK: Inputs

    /// Shows the 3x3 rule-of-thirds grid.
    var showsGrid: Bool = false
    @ViewBuilder let top: () -> Top
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let bottom: () -> Bottom

    // MARK: Init

    init(showsGrid: Bool = false,
         @ViewBuilder top: @escaping () -> Top,
         @ViewBuilder trailing: @escaping () -> Trailing,
         @ViewBuilder bottom: @escaping () -> Bottom) {
        self.showsGrid = showsGrid
        self.top = top
        self.trailing = trailing
        self.bottom = bottom
    }

    // MARK: Body

    var body: some View {
        ZStack {
            ViewfinderGridOverlay(isVisible: showsGrid)
            edgeScrims
            slots
        }
    }

    // MARK: Slots

    private var slots: some View {
        VStack(spacing: 0) {
            top()
                .padding(.top, Theme.Spacing.m)
                .padding(.horizontal, Theme.Spacing.m)
            Spacer(minLength: 0)
            HStack(alignment: .bottom) {
                Spacer(minLength: 0)
                trailing()
                    .padding(.trailing, Theme.Spacing.m)
                    .padding(.bottom, Theme.Spacing.m)
            }
            bottom()
                .padding(.bottom, Theme.Spacing.l)
                .padding(.horizontal, Theme.Spacing.l)
        }
    }

    /// Top/bottom scrims that fade chrome into the video. Non-interactive.
    private var edgeScrims: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [Theme.Color.chrome900.opacity(Theme.Opacity.scrim), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: Theme.Dimension.scrimHeight)
            Spacer(minLength: 0)
            LinearGradient(
                colors: [.clear, Theme.Color.chrome900.opacity(Theme.Opacity.scrim)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: Theme.Dimension.scrimHeight)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Slot modifiers

/// Places `slot` into a documented viewfinder zone on top of any base view,
/// with the same padding the container uses. Chain multiple modifiers (one per
/// zone) to assemble the chrome without re-doing layout.
struct ViewfinderSlotModifier<Slot: View>: ViewModifier {
    let zone: ViewfinderZone
    @ViewBuilder let slot: () -> Slot

    func body(content: Content) -> some View {
        switch zone {
        case .top:
            content.overlay(alignment: .top) {
                slot()
                    .padding(.top, Theme.Spacing.m)
                    .padding(.horizontal, Theme.Spacing.m)
            }
        case .trailing:
            content.overlay(alignment: .trailing) {
                slot()
                    .padding(.trailing, Theme.Spacing.m)
                    .padding(.bottom, Theme.Spacing.m)
            }
        case .bottom:
            content.overlay(alignment: .bottom) {
                slot()
                    .padding(.bottom, Theme.Spacing.l)
                    .padding(.horizontal, Theme.Spacing.l)
            }
        }
    }
}

extension View {
    /// Places content into a viewfinder zone (top chips row, trailing dial
    /// column, or bottom controls row) on top of this view.
    func viewfinderSlot<Slot: View>(
        _ zone: ViewfinderZone,
        @ViewBuilder _ slot: @escaping () -> Slot
    ) -> some View {
        modifier(ViewfinderSlotModifier(zone: zone, slot: slot))
    }
}

// MARK: - ViewfinderGridOverlay

/// 3x3 rule-of-thirds grid. Fades in/out with `isVisible`; never intercepts
/// touches.
struct ViewfinderGridOverlay: View {

    let isVisible: Bool

    var body: some View {
        GeometryReader { geo in
            Path { path in
                let width = geo.size.width
                let height = geo.size.height
                for index in 1...2 {
                    let x = width * CGFloat(index) / 3
                    let y = height * CGFloat(index) / 3
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: height))
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: width, y: y))
                }
            }
            .stroke(
                Theme.Color.textPrimary.opacity(Theme.Opacity.hairline),
                lineWidth: Theme.Dimension.hairlineWidth
            )
        }
        .opacity(isVisible ? 1 : 0)
        .animation(.easeInOut(duration: Theme.Animation.labelFade), value: isVisible)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Previews

/// Host providing interactive grid state for previews.
private struct ViewfinderOverlayPreviewHost: View {
    @State private var showsGrid = true

    /// Explicit init: private stored properties make the synthesized
    /// memberwise initializer private, which #Preview expansion cannot call.
    init(showsGrid: Bool = true) {
        self.showsGrid = showsGrid
    }

    var body: some View {
        ViewfinderOverlay(showsGrid: showsGrid) {
            HStack(spacing: Theme.Spacing.m) {
                HUDChip(icon: "bolt.slash.fill", state: .off, action: {})
                HUDChip(icon: "grid.3x3", label: "Grid", state: .on, action: {
                    showsGrid.toggle()
                })
            }
        } trailing: {
            ControlDial(icon: "sun.max.fill", title: "Exposure", value: .constant(0.6))
        } bottom: {
            VStack(spacing: Theme.Spacing.m) {
                ZoomDial(stops: [0.5, 1, 2], range: 0.5...6, factor: .constant(1))
                HStack {
                    SettingsPill(icon: "photo.on.rectangle", title: "Gallery", action: {})
                    Spacer()
                    ShutterButton(mode: .photo, action: {})
                    Spacer()
                    SettingsPill(icon: "gearshape", title: "Settings", action: {})
                }
            }
        }
        .background(Theme.Color.chrome700)
    }
}

#Preview("Viewfinder skeleton (interactive grid toggle)") {
    ViewfinderOverlayPreviewHost()
}

#Preview("Slot modifiers on a custom base") {
    Rectangle()
        .fill(Theme.Color.chrome800)
        .viewfinderSlot(.top) {
            HUDChip(icon: "timer", label: "Timer", state: .off, action: {})
        }
        .viewfinderSlot(.trailing) {
            ControlDial(icon: "camera.aperture", title: "ISO", value: .constant(0.25))
        }
        .viewfinderSlot(.bottom) {
            ModeSwitchBar(modes: CaptureMode.allCases,
                          selected: .constant(.photo))
        }
}
