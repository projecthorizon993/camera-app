import SwiftUI
import CoreGraphics
import CoreVideo

// Task 7 — single source of truth for the viewfinder HUD.
//
// CONCURRENCY (binding: T4 review I1 + SE-0461 Approachable Concurrency)
// ---------------------------------------------------------------------
// All UI state is @MainActor. Two service-access paths, both off the main
// thread's hot path:
//   • Async protocol members (`startSession`) are awaited directly: under
//     Approachable Concurrency they run on the caller's actor, and the real
//     service's implementation only *enqueues* onto its private session
//     queue via a continuation — the main thread never blocks (see the
//     concurrency notes in Core/Contracts.swift).
//   • Synchronous members (`setZoom`/`focus`/`selectDevice`/`selectLens`) are
//     handed to `CameraControlGate`, which runs them on a private serial
//     queue off-main, preserving enqueue order.
//
// Zoom pushes are throttled to 10 Hz during scrubbing (mirroring T9's
// manual-config commit throttle), with an unconditional commit when a drag
// or stop tap ends so the final value always lands.

@MainActor
@Observable
final class CaptureHUDState {

    // MARK: - Session lifecycle

    /// True only after `startSession()` succeeded. Every control interaction
    /// is gated on this (disabled + dimmed until ready).
    private(set) var sessionReady = false

    /// Failure copy from the last session start; drives the retry card.
    private(set) var errorText: String?

    /// Transient copy for failed control calls (lens switch, …); the screen
    /// auto-clears it a couple of seconds after it appears.
    private(set) var controlErrorText: String?

    // MARK: - HUD toggles (state only — capture wiring is Task 8)

    var flashMode: FlashMode = .off
    var timerSeconds: Int = 0
    var gridVisible = false
    var manualPanelVisible = false
    var captureMode: CaptureMode = .photo

    // MARK: - Zoom / lens state

    private(set) var zoomFactor: CGFloat = 1
    private(set) var currentLens: CameraLensID = .wide
    private(set) var position: DevicePosition = .back
    private(set) var capabilities: CameraCapabilities = .iPhone11ProMaxFallback
    private(set) var lenses: [LensInfo] = []

    // MARK: - Plumbing

    /// Async protocol members only (`startSession`) — awaiting from
    /// @MainActor never blocks main (the service hops internally).
    private let service: any CameraServiceProtocol

    /// Sync members, executed off-main by the gate.
    private let controls: CameraControlGate

    /// Renderer the preview frames feed; set by `connectPreview` and
    /// re-asserted by `beginSession` after (re)starts.
    private var previewRenderer: MetalRenderer?

    /// Re-entrancy guard for `beginSession` (`.task` and `.onAppear` may
    /// both fire on mount).
    private var isBeginning = false

    /// Monotonic seconds; injectable so throttle behaviour is testable.
    private let clock: @Sendable () -> Double

    /// Timestamp of the last throttled zoom push; −∞ until the first, so the
    /// first change always pushes immediately.
    private var lastZoomPushAt = -Double.infinity

    /// Zoom-commit throttle window during scrubbing: 0.1 s ≈ 10 Hz.
    static let zoomPushInterval: Double = 0.1

    /// - Parameters:
    ///   - service: the live camera service (real `CameraService`, or a test
    ///     mock).
    ///   - clock: monotonic seconds; tests inject a controllable clock.
    ///
    /// `nonisolated` so a SwiftUI view may construct it from a nonisolated
    /// init (`State(initialValue:)` thunks evaluate there). Only
    /// non-isolated dependencies are initialized here; all UI state keeps
    /// its declaration defaults (same shape as `ManualConfigEngine` — a
    /// nonisolated init may not write isolated state).
    nonisolated init(
        service: any CameraServiceProtocol,
        clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.service = service
        self.controls = CameraControlGate(service: service)
        self.clock = clock
    }

    // MARK: - Derived zoom surface

    /// Optical stops shown on the dial, ascending, from the present lenses.
    var zoomStops: [CGFloat] {
        ZoomStopPlanner.opticalStops(
            lenses: lenses,
            position: position,
            teleFactor: capabilities.teleFactor
        )
    }

    /// Full draggable zoom range for the current position.
    var zoomRange: ClosedRange<CGFloat> {
        ZoomStopPlanner.draggableRange(capabilities: capabilities, position: position)
    }

    /// Top-row icon for the current flash mode.
    var flashIcon: String {
        switch flashMode {
        case .off: return "bolt.slash.fill"
        case .auto: return "bolt.badge.a.fill"
        case .on: return "bolt.fill"
        }
    }

    // MARK: - Session lifecycle

    /// Installs the preview frame feed into the given renderer. Call once at
    /// mount; `beginSession` re-asserts the handler after (re)starts.
    func connectPreview(_ renderer: MetalRenderer?) async {
        previewRenderer = renderer
        let handler: (@Sendable (CVPixelBuffer) -> Void)?
        if let renderer {
            handler = { buffer in renderer.submitFrame(buffer) }
        } else {
            handler = nil
        }
        await controls.setPreviewFrameHandler(handler)
    }

    /// Clears the service-side frame handler (screen hidden). The session
    /// itself keeps running so returning to the viewfinder is instant;
    /// `beginSession` re-installs the handler on re-appear.
    func suspendPreview() async {
        await controls.setPreviewFrameHandler(nil)
    }

    /// Starts (or re-asserts) the capture session, snapshots capabilities and
    /// lenses into UI state, and re-installs the preview frame handler if one
    /// was connected. Idempotent — the service guards reconfiguration and
    /// `startRunning` internally.
    func beginSession() async {
        guard !isBeginning else { return }
        isBeginning = true
        defer { isBeginning = false }
        do {
            try await service.startSession()
            // Lock-guarded snapshot getters — cheap reads, safe on main.
            capabilities = service.capabilities
            lenses = service.availableLenses
            errorText = nil
            sessionReady = true
            if let previewRenderer {
                await controls.setPreviewFrameHandler { previewRenderer.submitFrame($0) }
            }
        } catch {
            errorText = CameraServiceMessages.message(for: error)
            sessionReady = false
        }
    }

    // MARK: - Tap to focus

    /// Converts a tap in preview-local points to capture-device coordinates
    /// via the static helper Task 4 exposed, then focuses there off-main.
    func focus(atViewPoint point: CGPoint, in previewSize: CGSize) {
        let devicePoint = CameraService.devicePoint(forViewPoint: point, inPreviewSize: previewSize)
        let controls = self.controls
        Task {
            let message = await controls.focus(at: devicePoint)
            applyControlError(message)
        }
    }

    // MARK: - Zoom

    /// Binding entry: clamps into the current range, updates UI state
    /// immediately (fluid dial), and throttled-pushes to the device.
    func setZoomFactor(_ candidate: CGFloat) {
        let clamped = min(max(candidate, zoomRange.lowerBound), zoomRange.upperBound)
        zoomFactor = clamped
        pushZoomThrottled()
    }

    /// Drag end / stop tap: unconditional push so the final value lands.
    func commitZoom() {
        lastZoomPushAt = clock()
        pushZoom(zoomFactor)
    }

    private func pushZoomThrottled() {
        let now = clock()
        guard now - lastZoomPushAt >= Self.zoomPushInterval else { return }
        lastZoomPushAt = now
        pushZoom(zoomFactor)
    }

    private func pushZoom(_ factor: CGFloat) {
        let controls = self.controls
        Task {
            _ = await controls.setZoom(factor)
        }
    }

    // MARK: - Device switching

    /// Front/back switch. Resets zoom to 1× (stock behaviour — the service
    /// resets the new device's video zoom factor on input swap) and adopts
    /// the fresh capability snapshot (zoom bounds differ per position).
    func flipCamera() {
        let target: DevicePosition = (position == .back) ? .front : .back
        let controls = self.controls
        Task { [weak self] in
            guard let self else { return }
            let result = await controls.selectDevice(target)
            switch result {
            case .success(let snapshot):
                applySnapshot(snapshot)
                position = target
                currentLens = (target == .front) ? .front : .wide
                zoomFactor = 1
            case .failure(let message):
                controlErrorText = message
            }
        }
    }

    private func applySnapshot(_ snapshot: CameraSessionSnapshot) {
        capabilities = snapshot.capabilities
        lenses = snapshot.lenses
    }

    // MARK: - HUD cycles (state only)

    /// off → auto → on → off.
    func cycleFlash() {
        switch flashMode {
        case .off: flashMode = .auto
        case .auto: flashMode = .on
        case .on: flashMode = .off
        }
    }

    /// 0 s → 3 s → 10 s → 0 s.
    func cycleTimer() {
        switch timerSeconds {
        case 0: timerSeconds = 3
        case 3: timerSeconds = 10
        default: timerSeconds = 0
        }
    }

    /// Clears the transient control-error caption.
    func clearControlError() {
        controlErrorText = nil
    }

    private func applyControlError(_ message: String?) {
        controlErrorText = message
    }
}
