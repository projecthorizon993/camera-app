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
    /// T14: recording HUD state (optional; drives record button style + status).
    let recordingHUD: RecordingHUDState?
    /// T8 wiring point: called by the shutter button (read live from
    /// `environment.onShutter` by the screen).
    let onShutter: () -> Void
    /// T14: video shutter tap.
    let onVideoShutter: () -> Void
    /// Task 18: night shutter tap.
    var onNightShutter: () -> Void = {}
    /// Task 18: timelapse shutter tap.
    var onTimelapseShutter: () -> Void = {}
    /// Task 18: optional controllers for progress display.
    var nightController: NightCaptureController? = nil
    var timelapseController: TimelapseController? = nil
    let router: Router

    /// Only photo is wired for now; the rest render dimmed and stay inert
    /// ("coming soon" handling lives with the consumer, per the kit doc).
    private static let soonModes: Set<CaptureMode> = []

    let environment: AppEnvironment

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            if let message = hud.controlErrorText {
                Text(message)
                    .font(Theme.Typography.hud)
                    .foregroundStyle(Theme.Color.danger)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
            if let status = recordingHUD?.statusText {
                Text(status)
                    .font(Theme.Typography.hud)
                    .foregroundStyle(Theme.Color.accent)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
            if hud.captureMode == .night, case .capturing(let done, let total) = nightController?.phase {
                Text("Night \(done)/\(total)")
                    .font(Theme.Typography.hud)
                    .foregroundStyle(Theme.Color.accent)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
            if hud.captureMode == .timelapse, case .running(let done, let total) = timelapseController?.phase {
                Text("Timelapse \(done)/\(total)")
                    .font(Theme.Typography.hud)
                    .foregroundStyle(Theme.Color.accent)
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
            if environment.captureController.settings.proMode {
                LookChip(look: environment.captureController.settings.selectedLook) { newLook in
                    environment.captureController.settings.selectedLook = newLook
                    try? environment.lookEngine.loadLook(newLook)
                }
            }
            Spacer(minLength: 0)
            if hud.captureMode == .video {
                let shutterMode: ShutterButton.Mode = (recordingHUD?.isRecording == true)
                    ? .recording(elapsed: recordingHUD?.elapsedSeconds ?? 0)
                    : .recordIdle
                ShutterButton(mode: shutterMode, action: onVideoShutter)
            } else if hud.captureMode == .night {
                ShutterButton(mode: .photo, action: onNightShutter)
            } else if hud.captureMode == .timelapse {
                let isRunning: Bool = {
                    if case .running = timelapseController?.phase { return true }
                    return false
                }()
                let shutterMode: ShutterButton.Mode = isRunning ? .recording(elapsed: 0) : .recordIdle
                ShutterButton(mode: shutterMode, action: onTimelapseShutter)
            } else {
                ShutterButton(mode: .photo, action: onShutter)
            }
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

// MARK: - LookChip

/// Small pill showing the current color look; tapping cycles to the next look.
private struct LookChip: View {
    let look: LookID
    let onChange: (LookID) -> Void

    @State private var isPressed = false

    var body: some View {
        Button {
            let all = LookID.allCases
            if let idx = all.firstIndex(of: look) {
                let next = all[(idx + 1) % all.count]
                onChange(next)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(lookColor)
                Text(look.displayName)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.6))
                    .overlay(Capsule().stroke(Color.white.opacity(0.3), lineWidth: 1))
            )
            .scaleEffect(isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: isPressed)
        }
        .buttonStyle(PlainButtonStyle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }

    private var lookColor: Color {
        switch look {
        case .none: return Color.gray
        case .authentic: return Color.orange
        case .vibrant: return Color.purple
        case .natural: return Color.green
        case .classicBW: return Color.white
        }
    }
}
