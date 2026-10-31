import Foundation
import Combine

// Task 9 — manual photography engine: the @MainActor state object between the
// pro-controls panel and the real `CameraService`.
//
// CONCURRENCY (binding: T4 review I1 + SE-0461 Approachable Concurrency)
// ---------------------------------------------------------------------
// `applyManualConfig`/`resetToAuto` are SYNCHRONOUS throws that block on the
// camera session queue (`CameraService.onSessionQueue` → `sessionQueue.sync`).
// They must never run on the main actor. This engine therefore hands every
// call to `ManualServiceGate` (below): the @MainActor engine only *enqueues*
// (cheap, non-blocking) and the gate performs the blocking call on its own
// private serial queue, returning the outcome through a checked continuation.
// The serial queue also preserves enqueue order, so the last coalesced slider
// state always wins on the device, and a RESET ALL enqueued after a drag
// cannot be overtaken by it.
//
// Slider drags are coalesced: bindings write the @Published fields instantly
// (fluid UI) and `noteFieldChanged()` commits at most once per
// `throttleInterval` — 0.1 s ≈ 10 Hz, measured on an injectable monotonic
// clock — while `endEditing()` (Slider `onEditingChanged(false)`) commits the
// final value unconditionally.
//
// SE-0461 note: every `ManualServiceGate` member (`apply`, `reset`,
// `loadRanges`) is nonisolated async, so under Approachable Concurrency its
// synchronous prologue runs on the CALLER's actor (main); that prologue only
// creates a continuation and enqueues — the blocking/reading work is confined
// to the gate's queue, which is the point. The engine's `Task { … }`
// follow-ups inherit this @MainActor context's isolation, so `lastError` (and
// every other assignment) is touched only from an isolated context. A
// `nonisolated init` cannot write any isolated state — `ranges` therefore
// starts on a declaration-default placeholder and is assigned by the awaited
// `reloadRanges()` on mount.

@MainActor
final class ManualConfigEngine: ObservableObject {

    /// Throttle window for commits during a drag: 0.1 s ≈ 10 Hz.
    static let throttleInterval: Double = 0.1

    // MARK: - Published manual state (nil = auto)

    @Published var iso: Float?
    @Published var shutterSeconds: Double?
    @Published var lensPosition: Float?
    @Published var kelvin: Float?
    @Published var tint: Float?

    /// Human-readable failure from the last apply/reset; nil after a success.
    @Published var lastError: String?

    /// Slider bounds come from here only — the real values always come from
    /// the service's `supportedManualRanges` (which refreshes them per
    /// lens/format), loaded by the first `reloadRanges()` on mount.
    ///
    /// The declaration default is a neutral placeholder, NOT a hardcoded
    /// range source: CI fix round 2 — a `nonisolated` init may not write
    /// `@MainActor`-isolated state, including `@Published` storage written
    /// directly, so the service snapshot can only be assigned from an
    /// isolated context after construction. The placeholder is visible for
    /// at most one frame pre-mount (the panel renders disabled pre-session
    /// anyway).
    @Published private(set) var ranges = ManualRanges(
        iso: 34...3456,
        exposureSeconds: 0.02...1.0,
        lensPosition: 0...1,
        kelvin: 2500...8000,
        tint: 0...100
    )

    // MARK: - Plumbing

    /// Off-main serial executor for the blocking session-queue calls.
    private let gate: ManualServiceGate

    /// Monotonic seconds; injectable so throttle tests are deterministic.
    private let clock: @Sendable () -> Double

    /// Timestamp (on `clock`) of the last commit; −∞ until the first, so the
    /// first drag tick after mount always commits immediately.
    private var lastCommitAt = -Double.infinity

    /// - Parameters:
    ///   - service: the live camera service (real `CameraService`,
    ///     placeholder, or a test mock). Every apply/reset/range-read flows
    ///     through the gate, which owns the only reference from here on.
    ///   - clock: monotonic seconds; tests inject a controllable clock.
    ///
    /// `nonisolated` so a SwiftUI view may construct it from a nonisolated
    /// init (`StateObject(wrappedValue:)` thunks are evaluated there). It only
    /// initializes the non-isolated dependencies (gate, clock). CI fix
    /// round 2: a nonisolated init cannot write `@MainActor`-isolated state —
    /// not even `@Published` storage directly — so `ranges` keeps its
    /// placeholder declaration default and is loaded by the awaited
    /// `reloadRanges()` on mount.
    nonisolated init(
        service: any CameraServiceProtocol,
        clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.gate = ManualServiceGate(service: service)
        self.clock = clock
    }

    // MARK: - Range refresh (mount / lens switch)

    /// Reads `supportedManualRanges` via the gate (off-main) and re-clamps
    /// any manual values into the fresh ranges (nil fields stay nil). Await
    /// this once at mount — `.task { await engine.reloadRanges() }`; T7
    /// re-mounts the panel on lens switches, which re-fires the hook.
    ///
    /// The service getter is a synchronous, lock-guarded snapshot read, but
    /// the hop keeps even that off the main actor, and the assignments below
    /// happen in this @MainActor context.
    func reloadRanges() async {
        let fresh = await gate.loadRanges()
        ranges = fresh
        iso = iso.map { Self.clamp($0, to: fresh.iso) }
        shutterSeconds = shutterSeconds.map { Self.clamp($0, to: fresh.exposureSeconds) }
        lensPosition = lensPosition.map { Self.clamp($0, to: fresh.lensPosition) }
        kelvin = kelvin.map { Self.clamp($0, to: fresh.kelvin) }
        tint = tint.map { Self.clamp($0, to: fresh.tint) }
    }

    private static func clamp<T: Comparable>(_ value: T, to range: ClosedRange<T>) -> T {
        min(max(value, range.lowerBound), range.upperBound)
    }

    // MARK: - Slider-driven updates (coalescing)

    /// Called by slider bindings after every field write. Fires a commit at
    /// most once per `Self.throttleInterval` (0.1 s ≈ 10 Hz during drags).
    func noteFieldChanged() {
        noteFieldChanged(at: clock())
    }

    /// Testable variant with an explicit timestamp on the injectable clock.
    func noteFieldChanged(at time: Double) {
        guard time - lastCommitAt >= Self.throttleInterval else { return }
        endEditing(at: time)
    }

    /// Drag end (Slider `onEditingChanged(false)`): unconditional final commit
    /// so the last slider value always reaches the device.
    func endEditing() {
        endEditing(at: clock())
    }

    /// Testable variant with an explicit timestamp on the injectable clock.
    func endEditing(at time: Double) {
        lastCommitAt = time
        commit()
    }

    // MARK: - Apply / reset

    /// Builds `ManualCameraConfig` from the current fields and applies it
    /// off-main. Errors surface as `lastError`. An all-nil config is still
    /// sent: it is what moves the device back to auto after a per-section
    /// reset cleared the last manual channel.
    func commit() {
        apply(makeConfig())
    }

    /// Current field state as the frozen config value type (nil = auto).
    func makeConfig() -> ManualCameraConfig {
        ManualCameraConfig(
            iso: iso,
            exposureDurationSeconds: shutterSeconds,
            lensPosition: lensPosition,
            kelvin: kelvin,
            tint: tint
        )
    }

    private func apply(_ config: ManualCameraConfig) {
        let gate = self.gate
        // The Task inherits this @MainActor context's isolation; the await
        // below suspends the main actor while the gate's private queue
        // performs the blocking call — the main thread never blocks.
        Task { [weak self] in
            let message = await gate.apply(config)
            self?.lastError = message
        }
    }

    // MARK: - Per-section reset (back to auto for that channel)

    /// NOTE: `setExposureModeCustom` needs BOTH duration and ISO (device
    /// requirement), so clearing only one of the pair returns the whole
    /// exposure channel to auto — mirrored by the panel footnote.
    func resetISO() { iso = nil; commit() }
    func resetShutter() { shutterSeconds = nil; commit() }
    func resetFocus() { lensPosition = nil; commit() }

    /// White balance resets kelvin and tint together (the service locks them
    /// as a pair).
    func resetWhiteBalance() {
        kelvin = nil
        tint = nil
        commit()
    }

    /// Panel-level "RESET ALL": nils every field and calls `resetToAuto`
    /// off-main.
    func resetAll() {
        iso = nil
        shutterSeconds = nil
        lensPosition = nil
        kelvin = nil
        tint = nil
        let gate = self.gate
        Task { [weak self] in
            let message = await gate.reset()
            self?.lastError = message
        }
    }
}

// MARK: - Off-main executor

/// Private serial-queue executor for the blocking session-queue calls
/// (`applyManualConfig`/`resetToAuto` — T4 review I1: never on the main
/// actor). Enqueue order == apply order, so the last coalesced state wins.
///
/// `@unchecked Sendable`: the frozen `CameraServiceProtocol` is not declared
/// Sendable, yet the blocking calls must run off-main. The real
/// `CameraService` is thread-safe by construction (`@unchecked Sendable`
/// class: lock-guarded snapshot getters + one serial session queue every
/// mutation funnels into), and the unit-test mock is lock-guarded likewise.
/// This box is the single, documented erasure point for that gap.
private final class ManualServiceGate: @unchecked Sendable {

    private let base: any CameraServiceProtocol
    private let queue = DispatchQueue(label: "camera.manual.commit")

    init(service: any CameraServiceProtocol) {
        self.base = service
    }

    /// Reads `supportedManualRanges` on the gate's queue and returns it.
    /// The real service's getter is a synchronous lock-guarded snapshot read
    /// (no session-queue involvement); hopping keeps even that off-main, and
    /// the caller assigns the result from its own `@MainActor` context
    /// (CI fix round 2).
    func loadRanges() async -> ManualRanges {
        await withCheckedContinuation { (continuation: CheckedContinuation<ManualRanges, Never>) in
            queue.async {
                continuation.resume(returning: self.base.supportedManualRanges)
            }
        }
    }

    /// Applies `config` off-main. Returns nil on success, else user-facing
    /// copy. Never throws.
    func apply(_ config: ManualCameraConfig) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            queue.async {
                do {
                    try self.base.applyManualConfig(config)
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: Self.message(for: error))
                }
            }
        }
    }

    /// Calls `resetToAuto` off-main. Returns nil on success, else copy.
    func reset() async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            queue.async {
                do {
                    try self.base.resetToAuto()
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: Self.message(for: error))
                }
            }
        }
    }

    /// Maps service errors to concise UI copy so callers never string-match
    /// against error descriptions.
    static func message(for error: any Error) -> String {
        if let serviceError = error as? CameraServiceError {
            switch serviceError {
            case .sessionNotConfigured:
                return "Camera is not running yet."
            case .manualExposureUnsupported:
                return "Manual exposure is not supported by the active camera format."
            case .manualWhiteBalanceUnsupported:
                return "Manual white balance is not supported by the active camera."
            case .lensUnavailable(let lens):
                return "Lens unavailable: \(lens.rawValue)."
            case .configurationFailed(let detail):
                return "Camera configuration failed: \(detail)"
            default:
                break
            }
        }
        return error.localizedDescription
    }
}
