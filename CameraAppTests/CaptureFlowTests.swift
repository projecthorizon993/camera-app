import XCTest
import Foundation
import CoreGraphics
import CoreVideo
import Combine
@testable import CameraApp

// Task 8 — coverage for the capture flow: `CaptureSettingsModel` defaults and
// mutations, `PhotoSaver` permission gating with a mocked permission service +
// injected save closure, `CaptureController` outcome mapping against a mock
// `CameraServiceProtocol`, thumbnail nil-failure paths, and the shutter-sound
// persistence wrapper.
//
// Foundation-only in the sense that matters here: no UIKit, no Photos, no
// AudioToolbox (the real save/sound/decode paths are injected away or tested
// via pure helpers). The `CoreGraphics`/`CoreVideo` imports are type-only and
// forced by the frozen protocol surface — same note as `ManualConfigTests`.
// `Combine` is used only to observe `@Published` publication.

// MARK: - Mocks

/// Lock-guarded camera-service mock: records capture calls, can throw, and can
/// run a mid-capture hook (used to observe controller state while a shot is in
/// flight — the hook hops to the main actor itself, per the project's SE-0461
/// hop rule).
private final class CaptureFlowMockCameraService: CameraServiceProtocol {

    private let lock = NSLock()
    private var captured: [PhotoCaptureSettings] = []

    private let errorToThrow: (any Error)?
    private let duringCapture: (@Sendable () async -> Void)?

    init(
        error: (any Error)? = nil,
        duringCapture: (@Sendable () async -> Void)? = nil
    ) {
        self.errorToThrow = error
        self.duringCapture = duringCapture
    }

    var capturedSettings: [PhotoCaptureSettings] { lock.withLock { captured } }

    // MARK: CameraServiceProtocol

    var capabilities: CameraCapabilities { .iPhone11ProMaxFallback }
    var availableLenses: [LensInfo] { [] }
    var supportedManualRanges: ManualRanges {
        ManualRanges(
            iso: 100...3200,
            exposureSeconds: 0.000125...30.0,
            lensPosition: 0...1,
            kelvin: 2000...8000,
            tint: -150...150
        )
    }

    func capturePhoto(_ settings: PhotoCaptureSettings) async throws -> CapturedPhoto {
        lock.lock()
        captured.append(settings)
        lock.unlock()
        if let duringCapture { await duringCapture() }
        if let errorToThrow { throw errorToThrow }
        return CapturedPhoto(data: Data([0x01, 0x02, 0x03]), format: settings.format, width: 12, height: 12, exifSummary: nil)
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
        FileManager.default.temporaryDirectory.appendingPathComponent("capture-flow-mock.mov")
    }
    func focus(at point: CGPoint) throws {}
    func setExposureOffset(_ ev: Float) throws {}
    func setPreviewFrameHandler(_ handler: (@Sendable (CVPixelBuffer) -> Void)?) {}
}

/// Lock-guarded permission-service mock. Never prompts — the answers are fixed
/// at init so the gating logic is deterministic.
private final class CaptureFlowMockPermissionService: CameraPermissionServiceProtocol {

    private let lock = NSLock()
    private let answer: PermissionStatus
    private var statusCalls = 0
    private var requestCalls = 0

    init(status: PermissionStatus) {
        self.answer = status
    }

    var statusCallCount: Int { lock.withLock { statusCalls } }
    var requestCallCount: Int { lock.withLock { requestCalls } }

    func status(of permission: AppPermission) async -> PermissionStatus {
        lock.withLock { statusCalls += 1 }
        return answer
    }

    func request(_ permission: AppPermission) async -> PermissionStatus {
        lock.withLock { requestCalls += 1 }
        return answer
    }
}

/// Lock-guarded recorder standing in for the photo-library save.
private final class CaptureFlowSaveRecorder: @unchecked Sendable {

    static let saveError = NSError(domain: "CaptureFlowTests.save", code: 42)

    private let lock = NSLock()
    private var payloads: [Data] = []

    var savedPayloads: [Data] { lock.withLock { payloads } }
    var saveCallCount: Int { lock.withLock { payloads.count } }

    func record(_ data: Data) {
        lock.withLock { payloads.append(data) }
    }
}

/// Lock-guarded Sendable box for cross-actor assertions.
private final class CaptureFlowBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ initial: T) {
        value = initial
    }

    var current: T { lock.withLock { value } }
    func set(_ newValue: T) {
        lock.withLock { value = newValue }
    }
}

// MARK: - Tests

@MainActor
final class CaptureFlowTests: XCTestCase {

    // MARK: Harness

    private func makePhoto(
        data: Data = Data([0xFF, 0xD8, 0xFF, 0x00, 0x01, 0x02]),
        format: CaptureFormat = .jpeg
    ) -> CapturedPhoto {
        CapturedPhoto(data: data, format: format, width: 64, height: 64, exifSummary: nil)
    }

    private func makeController(
        camera: CaptureFlowMockCameraService,
        permission: CaptureFlowMockPermissionService,
        saveAsset: @escaping PhotoSaver.SaveAsset = { _ in }
    ) -> CaptureController {
        CaptureController(
            cameraService: camera,
            permissionService: permission,
            saver: PhotoSaver(permissionService: permission, saveAsset: saveAsset)
        )
    }

    // MARK: CaptureSettingsModel

    func testSettingsModelDefaults() {
        let model = CaptureSettingsModel()
        XCTAssertEqual(model.flashMode, .off)
        XCTAssertEqual(model.timerSeconds, 0)
        XCTAssertEqual(model.format, .jpeg)

        let built = model.makeSettings()
        XCTAssertEqual(built.format, .jpeg)
        XCTAssertEqual(built.flash, .off)
        XCTAssertEqual(built.timerSeconds, 0)
        XCTAssertEqual(built.orientation, .portrait)
    }

    func testSettingsModelMutationsRoundTrip() {
        let model = CaptureSettingsModel()
        model.flashMode = .on
        model.timerSeconds = 10
        model.format = .dng

        let built = model.makeSettings(orientation: .landscape)
        XCTAssertEqual(built.flash, .on)
        XCTAssertEqual(built.timerSeconds, 10)
        XCTAssertEqual(built.format, .dng)
        XCTAssertEqual(built.orientation, .landscape)
    }

    // MARK: PhotoSaver permission gating

    func testSaverSavesWhenPermissionGranted() async {
        let permissions = CaptureFlowMockPermissionService(status: .granted)
        let recorder = CaptureFlowSaveRecorder()
        let saver = PhotoSaver(permissionService: permissions) { data in
            recorder.record(data)
        }

        let photo = makePhoto()
        let outcome = await saver.save(photo)

        XCTAssertEqual(outcome, .saved)
        XCTAssertEqual(permissions.statusCallCount, 1, "the authorization check must come first")
        XCTAssertEqual(permissions.requestCallCount, 0, "PhotoSaver must never request access itself")
        XCTAssertEqual(recorder.saveCallCount, 1)
        XCTAssertEqual(recorder.savedPayloads.first, photo.data)
    }

    func testSaverGatesOnNotDeterminedPermission() async {
        let permissions = CaptureFlowMockPermissionService(status: .notDetermined)
        let recorder = CaptureFlowSaveRecorder()
        let saver = PhotoSaver(permissionService: permissions) { data in
            recorder.record(data)
        }

        let outcome = await saver.save(makePhoto())

        XCTAssertEqual(outcome, .needsPermission)
        XCTAssertEqual(recorder.saveCallCount, 0)
        XCTAssertEqual(permissions.requestCallCount, 0)
    }

    func testSaverGatesOnDeniedPermission() async {
        let permissions = CaptureFlowMockPermissionService(status: .denied)
        let recorder = CaptureFlowSaveRecorder()
        let saver = PhotoSaver(permissionService: permissions) { data in
            recorder.record(data)
        }

        let outcome = await saver.save(makePhoto())

        XCTAssertEqual(outcome, .needsPermission)
        XCTAssertEqual(recorder.saveCallCount, 0)
    }

    func testSaverReportsFailureWhenSaveThrows() async {
        let permissions = CaptureFlowMockPermissionService(status: .granted)
        let saver = PhotoSaver(permissionService: permissions) { _ in
            throw CaptureFlowSaveRecorder.saveError
        }

        let outcome = await saver.save(makePhoto())

        guard case .failed(let reason) = outcome else {
            return XCTFail("expected .failed, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("Photos"), "unexpected reason: \(reason)")
    }

    func testSaverRejectsEmptyPayload() async {
        let permissions = CaptureFlowMockPermissionService(status: .granted)
        let recorder = CaptureFlowSaveRecorder()
        let saver = PhotoSaver(permissionService: permissions) { data in
            recorder.record(data)
        }

        let outcome = await saver.save(makePhoto(data: Data()))

        guard case .failed = outcome else {
            return XCTFail("expected .failed, got \(outcome)")
        }
        XCTAssertEqual(recorder.saveCallCount, 0, "must not create a zero-byte asset")
    }

    // MARK: CaptureController pipeline

    func testCaptureSavesAndPublishesSavedOutcome() async {
        let camera = CaptureFlowMockCameraService()
        let permissions = CaptureFlowMockPermissionService(status: .granted)
        let recorder = CaptureFlowSaveRecorder()
        let controller = makeController(camera: camera, permission: permissions) { data in
            recorder.record(data)
        }

        let settings = PhotoCaptureSettings(format: .jpeg, flash: .on, timerSeconds: 0, orientation: .portrait)
        await controller.capture(settings: settings)

        guard case .saved = controller.lastResult else {
            return XCTFail("expected .saved, got \(String(describing: controller.lastResult))")
        }
        XCTAssertFalse(controller.isCapturing, "isCapturing must reset when the shot completes")
        XCTAssertFalse(controller.isTimerArmed)
        XCTAssertEqual(camera.capturedSettings.count, 1)
        XCTAssertEqual(camera.capturedSettings.first?.flash, .on, "settings must pass through untouched")
        XCTAssertEqual(recorder.saveCallCount, 1)
        XCTAssertEqual(controller.feedback.shutterFlashID, 1, "one flash trigger per fired shot")
    }

    func testCapturePublishesNeedsPermissionWithoutSaving() async {
        let camera = CaptureFlowMockCameraService()
        let permissions = CaptureFlowMockPermissionService(status: .denied)
        let recorder = CaptureFlowSaveRecorder()
        let controller = makeController(camera: camera, permission: permissions) { data in
            recorder.record(data)
        }

        await controller.captureCurrent()

        guard case .needsPermission = controller.lastResult else {
            return XCTFail("expected .needsPermission, got \(String(describing: controller.lastResult))")
        }
        XCTAssertEqual(recorder.saveCallCount, 0)
        XCTAssertEqual(camera.capturedSettings.first?.timerSeconds, 0)
    }

    func testCaptureFailureBecomesFailedOutcome() async {
        let camera = CaptureFlowMockCameraService(error: CameraServiceError.photoDataUnavailable)
        let permissions = CaptureFlowMockPermissionService(status: .granted)
        let controller = makeController(camera: camera, permission: permissions)

        await controller.captureCurrent()

        guard case .failed(let reason) = controller.lastResult else {
            return XCTFail("expected .failed, got \(String(describing: controller.lastResult))")
        }
        XCTAssertTrue(reason.contains("image data"), "unexpected reason: \(reason)")
        XCTAssertFalse(controller.isCapturing, "isCapturing must reset even on failure")
    }

    func testCaptureSaveFailureBecomesFailedOutcome() async {
        let camera = CaptureFlowMockCameraService()
        let permissions = CaptureFlowMockPermissionService(status: .granted)
        let controller = makeController(camera: camera, permission: permissions) { _ in
            throw CaptureFlowSaveRecorder.saveError
        }

        await controller.captureCurrent()

        guard case .failed(let reason) = controller.lastResult else {
            return XCTFail("expected .failed, got \(String(describing: controller.lastResult))")
        }
        XCTAssertTrue(reason.contains("Photos"), "unexpected reason: \(reason)")
    }

    func testTimerArmedDuringCountdownAndClearedAfter() async {
        // The hook runs inside `capturePhoto` while the in-service countdown
        // is active; it hops to the main actor to read the controller state
        // (project CI rule: never touch @MainActor state from a nonisolated
        // context without a hop).
        let controllerBox = CaptureFlowBox<CaptureController?>(nil)
        let armedDuringBox = CaptureFlowBox<Bool?>(nil)
        let camera = CaptureFlowMockCameraService(duringCapture: {
            if let controller = controllerBox.current {
                let armed = await MainActor.run { controller.isTimerArmed }
                armedDuringBox.set(armed)
            }
        })
        let permissions = CaptureFlowMockPermissionService(status: .granted)
        let controller = makeController(camera: camera, permission: permissions)
        controllerBox.set(controller)

        let settings = PhotoCaptureSettings(format: .jpeg, flash: .off, timerSeconds: 3, orientation: .portrait)
        await controller.capture(settings: settings)

        XCTAssertEqual(armedDuringBox.current, true, "isTimerArmed must be true while the countdown runs")
        XCTAssertFalse(controller.isTimerArmed, "the timer flag must clear once the shot lands")
        XCTAssertFalse(controller.isCapturing)
        XCTAssertEqual(camera.capturedSettings.first?.timerSeconds, 3, "the controller passes settings through; the service owns the countdown")
    }

    // MARK: CaptureOutcome mapping

    func testReasonMapsServiceErrorsToPresentableCopy() {
        XCTAssertFalse(CaptureController.reason(for: CameraServiceError.sessionNotConfigured).isEmpty)
        XCTAssertTrue(CaptureController.reason(for: CameraServiceError.photoDataUnavailable).contains("image data"))
        XCTAssertTrue(CaptureController.reason(for: CameraServiceError.captureFailed("lens stuck")).contains("lens stuck"))
        XCTAssertTrue(CaptureController.reason(for: CameraServiceError.deviceUnavailable(.front)).contains("front"))
        XCTAssertTrue(CaptureController.reason(for: CameraServiceError.rawUnsupported).contains("RAW"))
        XCTAssertTrue(CaptureController.reason(for: CameraServiceError.lensUnavailable(.tele)).contains("tele"))

        // Non-service errors pass through their own description.
        let generic = CaptureController.reason(for: CaptureFlowSaveRecorder.saveError)
        XCTAssertFalse(generic.isEmpty)
    }

    // MARK: LastShotThumbnailModel

    func testThumbnailNilForInvalidData() {
        XCTAssertNil(LastShotThumbnailModel.makeThumbnail(from: Data(), maxPixelSize: 64))
        let garbage = Data("not an image at all".utf8)
        XCTAssertNil(LastShotThumbnailModel.makeThumbnail(from: garbage, maxPixelSize: 64))
    }

    func testRecordInvalidDataPublishesNilThumbnail() async {
        let model = LastShotThumbnailModel(maxPixelSize: 64)
        var publications: [CGImage?] = []
        let cancellable = model.$lastThumbnail.sink { publications.append($0) }

        model.record(makePhoto(data: Data("garbage".utf8)))

        // Wait for the detached decode to hop back and publish (initial nil +
        // one publication). Suspension yields the main actor so the publish
        // hop can run.
        let deadline = Date().addingTimeInterval(2)
        while publications.count < 2 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        cancellable.cancel()

        XCTAssertEqual(publications.count, 2, "expected the initial value plus one publication")
        if publications.count >= 2 {
            XCTAssertNil(publications[1], "a failed decode must publish nil, no error")
        }
    }

    // MARK: ShutterFeedback persistence

    func testShutterSoundStoreDefaultsToEnabledAndPersists() throws {
        let suite = "CaptureFlowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ShutterSoundStore(defaults: defaults)
        XCTAssertTrue(store.isSoundEnabled, "an unset key must default to enabled")

        store.isSoundEnabled = false
        XCTAssertFalse(store.isSoundEnabled)
        XCTAssertFalse(
            defaults.bool(forKey: ShutterSoundStore.soundEnabledKey),
            "the wrapper must write the same key an @AppStorage binding would read"
        )
    }

    func testShutterFeedbackWritesThroughAndFiresFlash() throws {
        let suite = "CaptureFlowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ShutterSoundStore(defaults: defaults)
        let feedback = ShutterFeedback(store: store)
        XCTAssertTrue(feedback.isShutterSoundEnabled, "initial value must come from the store")

        feedback.isShutterSoundEnabled = false
        XCTAssertFalse(store.isSoundEnabled, "the toggle must write through to the store")

        let before = feedback.shutterFlashID
        feedback.fireFlash()
        XCTAssertEqual(feedback.shutterFlashID, before + 1)
    }
}
