import XCTest
import Foundation
import CoreGraphics
import CoreVideo
@testable import CameraApp

// Task 9 — coverage for the manual pro controls: `ValueFormatters` (pure) and
// `ManualConfigEngine` coalescing / apply / reset semantics against a mock
// `CameraServiceProtocol`.
//
// The mock is Foundation-only in the sense that matters here: no AVFoundation
// and no hardware. The `CoreGraphics`/`CoreVideo` imports are type-only and
// forced by the frozen protocol surface (`CGFloat`, `CGPoint`, `CVPixelBuffer`
// in `setPreviewFrameHandler`) — the same imports Task 2's
// `PlaceholderCameraService` needed for the same reason.

/// Lock-guarded mock: `applyManualConfig`/`resetToAuto` calls arrive on the
/// engine's private commit queue, never on the test thread, so all recorded
/// state is read/written under an `NSLock`.
private final class MockCameraService: CameraServiceProtocol {

    private let lock = NSLock()
    private var applied: [ManualCameraConfig] = []
    private var resets = 0

    private let rangeAnswer: ManualRanges
    private let errorToThrow: (any Error)?

    /// - Parameters:
    ///   - ranges: what `supportedManualRanges` reports.
    ///   - error: thrown by apply/reset when non-nil (set at init; immutable).
    init(ranges: ManualRanges, error: (any Error)? = nil) {
        self.rangeAnswer = ranges
        self.errorToThrow = error
    }

    // MARK: Recording surface

    var applyCallCount: Int { lock.withLock { applied.count } }
    var resetCallCount: Int { lock.withLock { resets } }
    var appliedConfigs: [ManualCameraConfig] { lock.withLock { applied } }
    var lastAppliedConfig: ManualCameraConfig? { lock.withLock { applied.last } }

    // MARK: CameraServiceProtocol

    var supportedManualRanges: ManualRanges { rangeAnswer }
    var capabilities: CameraCapabilities { .iPhone11ProMaxFallback }
    var availableLenses: [LensInfo] { [] }

    func startSession() async throws {}
    func stopSession() {}
    func selectDevice(_ position: DevicePosition) throws {}
    func selectLens(_ id: CameraLensID) throws {}
    func setZoom(_ factor: CGFloat) throws {}

    func applyManualConfig(_ config: ManualCameraConfig) throws {
        if let errorToThrow { throw errorToThrow }
        lock.lock()
        applied.append(config)
        lock.unlock()
    }

    func resetToAuto() throws {
        if let errorToThrow { throw errorToThrow }
        lock.lock()
        resets += 1
        lock.unlock()
    }

    func capturePhoto(_ settings: PhotoCaptureSettings) async throws -> CapturedPhoto {
        CapturedPhoto(data: Data(), format: settings.format, width: 0, height: 0, exifSummary: nil)
    }

    func captureBracket(depth: BracketDepth) async throws -> [CapturedPhoto] { [] }

    func startVideoRecording(_ config: VideoRecordingConfig) throws {}

    func stopVideoRecording() async -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("manual-mock.mov")
    }

    func focus(at point: CGPoint) throws {}
    func setExposureOffset(_ ev: Float) throws {}
    func setPreviewFrameHandler(_ handler: (@Sendable (CVPixelBuffer) -> Void)?) {}
}

/// Controllable monotonic clock for deterministic throttle tests.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: Double = 0

    var time: Double { lock.withLock { seconds } }
    func advance(_ delta: Double) { lock.withLock { seconds += delta } }
}

/// Stand-in ranges for the mock service (Sendable value type).
private let testRanges = ManualRanges(
    iso: 100...3200,
    exposureSeconds: 0.000125...30.0,
    lensPosition: 0...1,
    kelvin: 2000...8000,
    tint: -150...150
)

@MainActor
final class ManualConfigTests: XCTestCase {

    // MARK: - Harness

    private func makeEngine(
        ranges: ManualRanges = testRanges,
        error: (any Error)? = nil
    ) -> (engine: ManualConfigEngine, mock: MockCameraService, clock: TestClock) {
        let clock = TestClock()
        let mock = MockCameraService(ranges: ranges, error: error)
        let engine = ManualConfigEngine(service: mock, clock: { clock.time })
        return (engine: engine, mock: mock, clock: clock)
    }

    /// Polls a queue-delivered condition (engine commits are fire-and-forget)
    /// without blocking the main actor, so the engine's pending @MainActor
    /// tasks make progress between suspensions.
    private func waitUpTo(
        for condition: @autoclosure () -> Bool,
        timeout: Double = 2
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return condition()
    }

    // MARK: - ValueFormatters

    func testISOFormatsAsInteger() {
        XCTAssertEqual(ValueFormatters.iso(800), "800")
        XCTAssertEqual(ValueFormatters.iso(799.6), "800")
        XCTAssertEqual(ValueFormatters.iso(100), "100")
        XCTAssertEqual(ValueFormatters.iso(3072), "3072")
    }

    func testShutterFractionalBelowOneSecond() {
        XCTAssertEqual(ValueFormatters.shutter(seconds: 1.0 / 120.0), "1/120")
        XCTAssertEqual(ValueFormatters.shutter(seconds: 0.5), "1/2")
        XCTAssertEqual(ValueFormatters.shutter(seconds: 0.000125), "1/8000")
    }

    func testShutterDecimalAtAndAboveOneSecond() {
        XCTAssertEqual(ValueFormatters.shutter(seconds: 1.0), "1s")
        XCTAssertEqual(ValueFormatters.shutter(seconds: 2.5), "2.5s")
        XCTAssertEqual(ValueFormatters.shutter(seconds: 10.0), "10s")
    }

    func testShutterSubMillisecond() {
        XCTAssertEqual(ValueFormatters.shutter(seconds: 0.0001), "1/10000")
        XCTAssertEqual(ValueFormatters.shutter(seconds: 0.00005), "1/20000")
    }

    func testShutterNonPositiveRendersPlaceholder() {
        XCTAssertEqual(ValueFormatters.shutter(seconds: 0), "—")
        XCTAssertEqual(ValueFormatters.shutter(seconds: -2), "—")
    }

    func testShutterRoundTrip() {
        let values: [Double] = [0.000125, 0.00005, 1.0 / 120.0, 0.5, 1.0, 2.5, 10.0, 30.0]
        for value in values {
            let text = ValueFormatters.shutter(seconds: value)
            let parsed = ValueFormatters.parseShutter(text)
            XCTAssertNotNil(parsed, "unparseable output for \(value): \(text)")
            XCTAssertEqual(
                parsed!,
                value,
                accuracy: max(value * 0.001, 1e-9),
                "round-trip failed for \(value) via \(text)"
            )
        }
    }

    func testParseShutterRejectsGarbage() {
        XCTAssertNil(ValueFormatters.parseShutter("—"))
        XCTAssertNil(ValueFormatters.parseShutter("abc"))
        XCTAssertNil(ValueFormatters.parseShutter("1/0"))
    }

    func testKelvinFormatsAsKelvinString() {
        XCTAssertEqual(ValueFormatters.kelvin(5600), "5600K")
        XCTAssertEqual(ValueFormatters.kelvin(2999.6), "3000K")
    }

    func testLensPositionFormatsAsPercentage() {
        XCTAssertEqual(ValueFormatters.lensPosition(0.25), "25%")
        XCTAssertEqual(ValueFormatters.lensPosition(0), "0%")
        XCTAssertEqual(ValueFormatters.lensPosition(0.999), "100%")
    }

    func testTintFormatsWithSign() {
        XCTAssertEqual(ValueFormatters.tint(10), "+10")
        XCTAssertEqual(ValueFormatters.tint(-5), "-5")
        XCTAssertEqual(ValueFormatters.tint(0), "0")
    }

    // MARK: - ManualConfigEngine: config building

    func testMakeConfigMirrorsFields() {
        let context = makeEngine()
        context.engine.iso = 800
        context.engine.shutterSeconds = 0.01
        context.engine.lensPosition = 0.25
        context.engine.kelvin = 5600
        context.engine.tint = 10
        let config = context.engine.makeConfig()
        XCTAssertEqual(config.iso, Float(800))
        XCTAssertEqual(config.exposureDurationSeconds, 0.01)
        XCTAssertEqual(config.lensPosition, Float(0.25))
        XCTAssertEqual(config.kelvin, Float(5600))
        XCTAssertEqual(config.tint, Float(10))
    }

    func testMakeConfigLeavesUntouchedFieldsNil() {
        let context = makeEngine()
        context.engine.iso = 400
        let config = context.engine.makeConfig()
        XCTAssertEqual(config.iso, Float(400))
        XCTAssertNil(config.exposureDurationSeconds)
        XCTAssertNil(config.lensPosition)
        XCTAssertNil(config.kelvin)
        XCTAssertNil(config.tint)
    }

    // MARK: - ManualConfigEngine: ranges

    /// CI fix round 2: the engine starts on a neutral placeholder (a
    /// nonisolated init may not write `@Published` storage, not even
    /// directly); the service values arrive on the first awaited
    /// `reloadRanges()` at mount.
    func testRangesLoadedFromServiceOnReload() async {
        let context = makeEngine()
        await context.engine.reloadRanges()
        let ranges = context.mock.supportedManualRanges
        XCTAssertEqual(context.engine.ranges.iso, ranges.iso)
        XCTAssertEqual(context.engine.ranges.exposureSeconds, ranges.exposureSeconds)
        XCTAssertEqual(context.engine.ranges.lensPosition, ranges.lensPosition)
        XCTAssertEqual(context.engine.ranges.kelvin, ranges.kelvin)
        XCTAssertEqual(context.engine.ranges.tint, ranges.tint)
    }

    func testPlaceholderRangesBeforeFirstReload() {
        let context = makeEngine()
        // Placeholder until mount — sane, non-degenerate bounds so slider
        // rendering never divides by zero; the service snapshot replaces it.
        XCTAssertEqual(context.engine.ranges.lensPosition, 0.0...1.0)
    }

    func testReloadRangesReReadsAndClamps() async {
        let context = makeEngine()
        context.engine.iso = 9999        // outside the service range
        context.engine.shutterSeconds = 0.02
        await context.engine.reloadRanges()
        XCTAssertEqual(context.engine.ranges.iso, 100.0...3200.0)
        XCTAssertEqual(context.engine.iso, Float(3200))
        XCTAssertEqual(context.engine.shutterSeconds, 0.02)  // inside → untouched
        // Nil fields stay nil (auto).
        XCTAssertNil(context.engine.lensPosition)
        XCTAssertNil(context.engine.kelvin)
    }

    // MARK: - ManualConfigEngine: coalescing

    func testBurstWithinWindowProducesSingleApply() async {
        let context = makeEngine()
        // Ten field writes inside one 0.1 s throttle window → exactly one
        // commit, carrying the LAST field state.
        for index in 0..<10 {
            context.engine.iso = Float(100 + index)
            context.engine.noteFieldChanged(at: context.clock.time)
        }
        let settled = await waitUpTo(for: context.mock.applyCallCount == 1)
        XCTAssertTrue(settled, "expected exactly one apply within the window")
        XCTAssertEqual(context.mock.applyCallCount, 1)
        // The coalesced commit carries one of the burst-written states; the
        // exact value depends on scheduler timing, so assert range membership
        // rather than a single pinned number.
        let appliedIso = context.mock.lastAppliedConfig?.iso
        XCTAssertNotNil(appliedIso)
        XCTAssertTrue((100...109).contains(appliedIso!), "coalesced iso \(appliedIso ?? -1) outside burst range")
    }

    func testSecondWindowProducesSecondApply() async {
        let context = makeEngine()
        context.engine.iso = 200
        context.engine.noteFieldChanged(at: 0)       // commit 1 at t=0
        context.clock.advance(0.15)                  // beyond the 0.1 s window
        context.engine.iso = 400
        context.engine.noteFieldChanged()            // commit 2 (injectable clock)
        let settled = await waitUpTo(for: context.mock.applyCallCount == 2)
        XCTAssertTrue(settled, "expected the second window to commit")
        XCTAssertEqual(context.mock.applyCallCount, 2)
        XCTAssertEqual(context.mock.lastAppliedConfig?.iso, Float(400))
    }

    func testEndEditingCommitsUnconditionallyAfterSuppressedWindow() async {
        let context = makeEngine()
        context.engine.iso = 100
        context.engine.noteFieldChanged(at: 0)       // commit 1
        context.engine.iso = 150
        context.engine.noteFieldChanged(at: 0.05)    // suppressed (same window)
        context.engine.endEditing(at: 0.06)          // drag end — always commits
        let settled = await waitUpTo(for: context.mock.applyCallCount == 2)
        XCTAssertTrue(settled, "drag end must commit the final value")
        XCTAssertEqual(context.mock.applyCallCount, 2)
        XCTAssertEqual(context.mock.lastAppliedConfig?.iso, Float(150))
    }

    // MARK: - ManualConfigEngine: apply / reset

    func testResetAllNilsFieldsAndCallsResetToAuto() async {
        let context = makeEngine()
        context.engine.iso = 800
        context.engine.shutterSeconds = 0.02
        context.engine.lensPosition = 0.4
        context.engine.kelvin = 5600
        context.engine.tint = 12
        context.engine.resetAll()
        XCTAssertNil(context.engine.iso)
        XCTAssertNil(context.engine.shutterSeconds)
        XCTAssertNil(context.engine.lensPosition)
        XCTAssertNil(context.engine.kelvin)
        XCTAssertNil(context.engine.tint)
        let settled = await waitUpTo(for: context.mock.resetCallCount == 1)
        XCTAssertTrue(settled, "resetAll must call resetToAuto off-main")
        XCTAssertEqual(context.mock.resetCallCount, 1)
        XCTAssertEqual(context.mock.applyCallCount, 0)
    }

    func testWhiteBalanceResetAppliesClearedPair() async {
        let context = makeEngine()
        context.engine.kelvin = 5600
        context.engine.tint = 10
        context.engine.resetWhiteBalance()
        XCTAssertNil(context.engine.kelvin)
        XCTAssertNil(context.engine.tint)
        let settled = await waitUpTo(for: context.mock.applyCallCount == 1)
        XCTAssertTrue(settled)
        XCTAssertNil(context.mock.lastAppliedConfig?.kelvin)
        XCTAssertNil(context.mock.lastAppliedConfig?.tint)
    }

    func testApplyErrorSurfacesAsLastError() async {
        let context = makeEngine(error: CameraServiceError.manualExposureUnsupported)
        context.engine.iso = 800
        context.engine.commit()
        let settled = await waitUpTo(for: context.engine.lastError != nil)
        XCTAssertTrue(settled, "the apply failure must surface as lastError")
        XCTAssertTrue(context.engine.lastError?.contains("Manual exposure") ?? false)
        XCTAssertEqual(context.mock.applyCallCount, 0)  // the call threw before recording
    }

    func testSuccessfulApplyKeepsLastErrorNil() async {
        let context = makeEngine()
        context.engine.iso = 800
        context.engine.commit()
        _ = await waitUpTo(for: context.mock.applyCallCount == 1)
        XCTAssertNil(context.engine.lastError)
    }
}
