import SwiftUI

// Task 7 — the live viewfinder screen (brief deliverable 1).
//
// PREVIEW PATH (brief §2 decision)
// -------------------------------
// Frames flow: `CameraService.setPreviewFrameHandler` (video data output →
// `videoOutputQueue`) → `MetalRenderer.submitFrame` (atomic slot swap) →
// `RendererView`/MTKView render thread → screen. The MetalRenderer path is
// chosen over any raw preview layer because T6's `RendererView` usage
// contract names exactly this composition for the viewfinder, and the
// renderer consumes the zero-copy pixel buffer directly. The async
// `ProcessingPipeline` stays the CAPTURE-time path (Task 8): with no preview
// stages registered it would only add per-frame async hops. Grid assist is
// drawn by the kit's SwiftUI `ViewfinderGridOverlay` (toggleable), so the
// renderer's Metal overlay provider is left empty (see AppEnvironment).
//
// LIFECYCLE & CONCURRENCY
// -----------------------
// `.task` connects the frame feed and starts the session; every control is
// disabled/dimmed until `sessionReady` flips (T4 review I1). Sync service
// members run off-main through `CameraControlGate`; `startSession` is an
// async protocol member awaited directly (the service hops internally —
// Contracts.swift concurrency notes). Re-appear after a pushed screen
// re-asserts the session/handler via `beginSession`; hiding only suspends
// the frame feed so returning is instant.
//
// T8 WIRING: the shutter action is `environment.onShutter`, read at tap
// time so Task 8 can assign the hook late (see AppEnvironment).

struct ViewfinderScreen: View {

    // MARK: - Dependencies

    /// Live read for the shutter hook: Task 8 may assign `onShutter` after
    /// this screen is created, so the tap reads the environment at press
    /// time. The environment lives for the whole app run.
    private unowned let environment: AppEnvironment
    private let router: Router
    private let renderer: MetalRenderer?
    private let service: any CameraServiceProtocol

    @State private var hud: CaptureHUDState
    /// Tap-to-focus indicator position (preview-local points); nil when hidden.
    @State private var focusPoint: CGPoint?

    /// - Parameters:
    ///   - service: the app-wide camera service (`environment.cameraService`).
    ///   - renderer: the app-wide preview renderer (`environment.renderer`),
    ///     or nil when Metal is unavailable.
    ///   - router: shared navigation (gallery / settings pills).
    ///   - environment: the app container — read at tap time for the Task 8
    ///     shutter hook.
    init(
        service: any CameraServiceProtocol,
        renderer: MetalRenderer?,
        router: Router,
        environment: AppEnvironment,
        settings: CaptureSettingsModel
    ) {
        self.environment = environment
        self.router = router
        self.renderer = renderer
        self.service = service
        // `settings` is the single capture-truth source (Task 8's
        // `CaptureController.settings`); the HUD's flash/timer/format chips
        // are pass-throughs over it. Constructed here (nonisolated init) so
        // the `State(initialValue:)` thunk runs in a nonisolated context.
        self._hud = State(initialValue: CaptureHUDState(service: service, settings: settings))
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Theme.Color.chrome900.ignoresSafeArea()
            preview

            if !hud.sessionReady {
                startupOverlay
            }
        }
        .viewfinderSlot(.top) { hudRow }
        .viewfinderSlot(.bottom) {
            VStack(spacing: Theme.Spacing.s) {
                // Task 10: manual lens dial — pin row above the controls bar;
                // hidden on the front camera (inside `LensPicker`).
                LensPicker(hud: hud)
                ControlsBar(hud: hud, onShutter: { environment.onShutter() }, router: router)
            }
        }
        .sheet(isPresented: Binding(
            get: { hud.manualPanelVisible },
            set: { hud.manualPanelVisible = $0 }
        )) {
            // T9 mount point (documented surface): the panel reads its
            // manual ranges once per mount, so re-mount on lens changes.
            ManualControlsView(service: service, isReady: hud.sessionReady)
                .id(hud.currentLens)
                .presentationDetents([.medium, .large])
        }
        .task(id: focusPoint) {
            // Fade the focus indicator out after its hold time.
            guard focusPoint != nil else { return }
            try? await Task.sleep(for: .seconds(Theme.Animation.labelHold))
            withAnimation(.easeIn(duration: Theme.Animation.labelFade)) {
                focusPoint = nil
            }
        }
        .task {
            await hud.connectPreview(renderer)
            await hud.beginSession()
        }
        .onAppear {
            // Re-appear after a pushed screen: re-assert the session and the
            // preview handler (idempotent; guarded against double-start).
            Task { await hud.beginSession() }
        }
        .onDisappear {
            Task { await hud.suspendPreview() }
        }
    }

    // MARK: - Preview

    private var preview: some View {
        GeometryReader { geo in
            RendererView(renderer: renderer)
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { point in
                    handleTap(at: point, previewSize: geo.size)
                }
                .pinchToZoom(hud: hud, isEnabled: hud.sessionReady)
                .overlay {
                    ViewfinderGridOverlay(isVisible: hud.gridVisible)
                    if let point = focusPoint {
                        focusIndicator(at: point)
                    }
                }
        }
        .ignoresSafeArea()
    }

    /// Converts the tap through Task 4's static helper and focuses there.
    private func handleTap(at point: CGPoint, previewSize: CGSize) {
        guard hud.sessionReady else { return }
        withAnimation(.easeOut(duration: Theme.Animation.snapDuration)) {
            focusPoint = point
        }
        hud.focus(atViewPoint: point, in: previewSize)
    }

    private func focusIndicator(at point: CGPoint) -> some View {
        RoundedRectangle(cornerRadius: Theme.Radius.s)
            .stroke(Theme.Color.accent, lineWidth: Theme.Dimension.digitalStrokeWidth * 2)
            .frame(width: 72, height: 72)
            .position(point)
            .transition(.opacity.combined(with: .scale(scale: 1.15)))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: - Chrome

    /// Top HUD row: flash / format / timer / grid / manual chips. Flash,
    /// format, and timer are bound to the capture pipeline's single source of
    /// truth (Task 11 — `CaptureSettingsModel` via the HUD pass-throughs);
    /// grid / manual stay UI-local.
    private var hudRow: some View {
        HStack(spacing: Theme.Spacing.m) {
            HUDChip(icon: hud.flashIcon, state: hud.flashMode == .off ? .off : .on) {
                hud.cycleFlash()
            }
            .disabled(hud.format == .dng)
            .opacity(hud.format == .dng ? Theme.Opacity.dimmed : 1)
            // Task 11: format chip — cycles JPEG → HEIF → DNG (wraps) through
            // `hud.selectFormat`, which enforces the RAW/flash exclusivity
            // rule (plan §7): while `.dng` is armed, the flash chip above is
            // dimmed/disabled and `cycleFlash()` is a no-op. Task 12's
            // bracketing inherits the same exclusivity rule via
            // `PackageCaptureSettings` reading these same settings.
            HUDChip(
                icon: "photo",
                label: hud.format == .jpeg ? "JPEG" : (hud.format == .heif ? "HEIF" : "DNG"),
                state: .off
            ) {
                let next: CaptureFormat
                switch hud.format {
                case .jpeg: next = .heif
                case .heif: next = .dng
                case .dng: next = .jpeg
                }
                hud.selectFormat(next)
            }
            .fixedSize()
            HUDChip(
                icon: "timer",
                label: hud.timerSeconds > 0 ? "\(hud.timerSeconds)s" : nil,
                state: hud.timerSeconds > 0 ? .on : .off
            ) {
                hud.cycleTimer()
            }
            HUDChip(icon: "grid.3x3", label: "Grid", state: hud.gridVisible ? .on : .off) {
                hud.gridVisible.toggle()
            }
            HUDChip(
                icon: "slider.horizontal.3",
                label: "Manual",
                state: hud.manualPanelVisible ? .on : .off
            ) {
                hud.manualPanelVisible.toggle()
            }
            Spacer(minLength: 0)
        }
        .disabled(!hud.sessionReady)
        .opacity(hud.sessionReady ? 1 : Theme.Opacity.dimmed)
        .animation(.easeInOut(duration: Theme.Animation.labelFade), value: hud.sessionReady)
    }

    // MARK: - Startup / retry states

    @ViewBuilder
    private var startupOverlay: some View {
        if let errorText = hud.errorText {
            retryCard(message: errorText)
        } else {
            VStack(spacing: Theme.Spacing.m) {
                ProgressView()
                    .tint(Theme.Color.accent)
                Text("Starting camera…")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            .padding(Theme.Spacing.xl)
        }
    }

    /// Failure state with a retry affordance (brief deliverable 1).
    private func retryCard(message: String) -> some View {
        VStack(spacing: Theme.Spacing.l) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: Theme.Dimension.gateIconSize, weight: .medium))
                .foregroundStyle(Theme.Color.danger)
            Text("Camera unavailable")
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Color.textPrimary)
            Text(message)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await hud.beginSession() }
            } label: {
                Text("Retry")
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Color.chrome900)
                    .padding(.horizontal, Theme.Spacing.xxl)
                    .frame(minHeight: Theme.Dimension.primaryButtonHeight)
                    .background(Capsule().fill(Theme.Color.accent))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retry starting the camera")
        }
        .padding(Theme.Spacing.xxl)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.m).fill(Theme.Color.chrome800))
        .padding(Theme.Spacing.xl)
    }
}
