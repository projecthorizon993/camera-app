import SwiftUI

// Task 7 — bottom chrome of the viewfinder (brief deliverable 2): zoom dial
// region, capture-mode bar (photo live, the rest "soon" and inert), and the
// shutter row (gallery pill / shutter / flip chip / settings pill).
//
// Everything here is disabled AND dimmed until `sessionReady` flips (T4
// review I1: the sync service members behind these controls block on the
// camera session queue, so they must never be reachable pre-session).
// The shutter action is the injected Task 8 hook — see `AppEnvironment.onShutter`.

struct ControlsBar: View {

    let hud: CaptureHUDState
    /// T8 wiring point: called by the shutter button (read live from
    /// `environment.onShutter` by the screen).
    let onShutter: () -> Void
    let router: Router

    /// Only photo is wired for now; the rest render dimmed and stay inert
    /// ("coming soon" handling lives with the consumer, per the kit doc).
    private static let soonModes: Set<CaptureMode> = [.video, .night, .timelapse]

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            if let message = hud.controlErrorText {
                Text(message)
                    .font(Theme.Typography.hud)
                    .foregroundStyle(Theme.Color.danger)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }

            zoomDial

            ModeSwitchBar(
                modes: CaptureMode.allCases,
                selected: Binding(
                    get: { hud.captureMode },
                    set: { hud.captureMode = $0 }
                ),
                disabledModes: Self.soonModes
            )

            shutterRow
        }
        .disabled(!hud.sessionReady)
        .opacity(hud.sessionReady ? 1 : Theme.Opacity.dimmed)
        .animation(.easeInOut(duration: Theme.Animation.labelFade), value: hud.sessionReady)
        .task(id: hud.controlErrorText) {
            // Auto-clear the transient control-error caption.
            guard hud.controlErrorText != nil else { return }
            try? await Task.sleep(for: .seconds(Theme.Animation.labelHold * 2))
            withAnimation(.easeIn(duration: Theme.Animation.labelFade)) {
                hud.clearControlError()
            }
        }
    }

    // MARK: - Zoom dial region

    /// Continuous zoom: the dial's binding streams through the HUD state's
    /// throttled push (`setZoomFactor`), and a drag end / stop tap commits
    /// unconditionally (`commitZoom`). Pinch feeds the same path — see
    /// `pinchToZoom` in ZoomDialBinding.swift.
    private var zoomDial: some View {
        ZoomDial(
            stops: hud.zoomStops,
            range: hud.zoomRange,
            factor: Binding(
                get: { hud.zoomFactor },
                set: { hud.setZoomFactor($0) }
            ),
            onCommit: { hud.commitZoom() }
        )
    }

    // MARK: - Shutter row

    private var shutterRow: some View {
        HStack(spacing: Theme.Spacing.m) {
            SettingsPill(icon: "photo.on.rectangle", title: "Gallery") {
                router.push(.gallery)
            }
            Spacer(minLength: 0)
            ShutterButton(mode: .photo, action: onShutter)
            Spacer(minLength: 0)
            HUDChip(icon: "arrow.triangle.2.circlepath.camera", state: .off) {
                hud.flipCamera()
            }
            SettingsPill(icon: "gearshape", title: "Settings") {
                router.push(.settings)
            }
        }
    }
}
