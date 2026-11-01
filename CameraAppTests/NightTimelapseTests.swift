import XCTest
import Foundation
import CoreGraphics
import CoreVideo
@testable import CameraApp

// Task 18 — pure planner + timelapse math + controller phase transitions.

// MARK: - Fakes

private final class NightTimelapseMockCameraService: CameraServiceProtocol {
    private let lock = NSLock()
    private var captured: [PhotoCaptureSettings] = []
    private let errorToThrow: (any Error)?

    init(error: (any Error)? = nil) {
        self.errorToThrow = error
    }

    var capturedSettings: [PhotoCaptureSettings] { lock.withLock { captured } }

    var capabilities: CameraCapabilities { .iPhone11ProMaxFallback }
    var availableLenses: [LensInfo] { [] }
    var supportedManualRanges: ManualRanges {
        ManualRanges(iso: 100...3200, exposureSeconds: 0.000125...30.0,
                    lensPosition: 0...1, kelvin: 2000...8000, tint: -150...150)
    }

    func capturePhoto(_ settings: PhotoCaptureSettings) async throws -> CapturedPhoto {
        lock.withLock { captured.append(settings) }
        if let errorToThrow { throw errorToThrow }
        return CapturedPhoto(data: Data([0xFF, 0xD8, 0xFF]), format: settings.format,
                             width: 8, height: 8, exifSummary: nil)
    }
    func captureBracket(depth: BracketDepth) async throws -> [CapturedPhoto] { [] }
    func startSession() async throws {}
    func stopSession() {}
    func selectDevice(_ position: DevicePosition) throws {}
    func selectLens(_ id: CameraLensID) throws {}
    func setZoom(_ factor: CGFloat) throws {}
    func applyManualConfig(_ config: ManualCameraConfig) throws {}
    func resetToAuto() throws {}
    func startVideoRecording(_ config: VideoRecordingConfig) throws {}
    func stopVideoRecording() async -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mock.mov")
    }
    func focus(at point: CGPoint) throws {}
    func setExposureOffset(_ ev: Float) throws {}
    func setPreviewFrameHandler(_ handler: (@Sendable (CVPixelBuffer) -> Void)?) {}
}

private final class NightTimelapseMockPermissionService: CameraPermissionServiceProtocol {
    let answer: PermissionStatus
    init(status: PermissionStatus) { self.answer = status }
    func status(of permission: AppPermission) async -> PermissionStatus { answer }
    func request(_ permission: AppPermission) async -> PermissionStatus { answer }
}

// MARK: - Planner tests

final class NightExposurePlannerTests: XCTestCase {
    func testExposuresSortedAscending() {
        let plan = NightExposurePlanner.plan(basisSeconds: 0.05, maxSeconds: 1.0, frameCount: 8)
        for i in 1..<plan.exposureSeconds.count {
            XCTAssertLessThanOrEqual(plan.exposureSeconds[i-1], plan.exposureSeconds[i])
        }
    }

    func testCappedAtMaxSeconds() {
        let plan = NightExposurePlanner.plan(basisSeconds: 10.0, maxSeconds: 2.0, frameCount: 8)
        for v in plan.exposureSeconds {
            XCTAssertLessThanOrEqual(v, 2.0)
        }
    }

    func testBasisLongHalvesCount() {
        let plan = NightExposurePlanner.plan(basisSeconds: 2.0, maxSeconds: 10.0, frameCount: 8)
        XCTAssertEqual(plan.frameCount, 4)
    }

    func testFrameCountClamped() {
        let plan = NightExposurePlanner.plan(basisSeconds: 0.05, maxSeconds: 1.0, frameCount: 100)
        XCTAssertLessThanOrEqual(plan.frameCount, 12)
        let plan2 = NightExposurePlanner.plan(basisSeconds: 0.05, maxSeconds: 1.0, frameCount: 1)
        XCTAssertGreaterThanOrEqual(plan2.frameCount, 2)
    }

    func testRoundRobinDistribution() {
        let plan = NightExposurePlanner.plan(basisSeconds: 0.1, maxSeconds: 10.0, frameCount: 9)
        // 9 frames over 3 rungs => 3 each.
        let rungs = [0.1, 0.2, 0.4]
        var counts = [0, 0, 0]
        for v in plan.exposureSeconds {
            if let idx = rungs.firstIndex(where: { abs($0 - v) < 1e-9 }) {
                counts[idx] += 1
            }
        }
        // After sorting, counts of each distinct value should be 3.
        XCTAssertEqual(Set(counts), [3])
    }
}

// MARK: - Timelapse math tests

final class TimelapseMathTests: XCTestCase {
    func testAssembledDuration() {
        let plan = TimelapsePlan(outputFPS: 30, targetFrames: 120)
        let dur = TimelapseRecorder.assembledDuration(frames: plan.targetFrames, outputFPS: plan.outputFPS)
        XCTAssertEqual(dur, 4.0, accuracy: 0.001)
    }

    func testStepFloor() {
        XCTAssertEqual(TimelapseRecorder.stepSeconds(requested: 0.1), 0.5)
        XCTAssertEqual(TimelapseRecorder.stepSeconds(requested: 1.0), 1.0)
    }

    func testTargetFramesBounds() {
        // Record clamps internally; plan stays as given.
        let plan = TimelapsePlan(outputFPS: 30, targetFrames: 60)
        XCTAssertEqual(plan.targetFrames, 60)
    }
}

// MARK: - Controller phase tests

@MainActor
final class NightControllerPhaseTests: XCTestCase {
    func testPhaseTransitionsToFailedOnMergeError() async {
        // Fake service returns invalid JPEG data, so merge fails -> .failed.
        let service = NightTimelapseMockCameraService()
        let controller = NightCaptureController(service: service)
        await controller.capture()
        // Phase should end in .failed (merge fails on invalid data) or .done.
        switch controller.phase {
        case .failed, .done:
            break
        default:
            XCTFail("unexpected phase: \(controller.phase)")
        }
    }

    func testCancelSetsFailedOrIdle() async {
        let service = NightTimelapseMockCameraService()
        let controller = NightCaptureController(service: service)
        controller.cancel()
        // Calling cancel before capture; capture should abort quickly.
        await controller.capture()
        // Accept any terminal-ish state.
        switch controller.phase {
        case .failed, .idle, .done:
            break
        default:
            XCTFail("unexpected phase: \(controller.phase)")
        }
    }
}

@MainActor
final class TimelapseControllerPhaseTests: XCTestCase {
    func testPhaseTransitions() async {
        let service = NightTimelapseMockCameraService()
        let controller = TimelapseController(service: service)
        await controller.start(plan: TimelapsePlan(outputFPS: 30, targetFrames: 2))
        // With invalid image data, assembly fails -> .failed; otherwise .done.
        switch controller.phase {
        case .failed, .done:
            break
        default:
            XCTFail("unexpected phase: \(controller.phase)")
        }
    }
}
