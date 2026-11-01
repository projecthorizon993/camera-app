import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import CameraApp

final class CameraServiceTests: XCTestCase {

    func testDevicePointNormalizesToUnitSquare() {
        let point = CameraService.devicePoint(
            forViewPoint: CGPoint(x: 25, y: 50),
            inPreviewSize: CGSize(width: 100, height: 200)
        )
        XCTAssertEqual(point.x, 0.25, accuracy: 0.0001)
        XCTAssertEqual(point.y, 0.25, accuracy: 0.0001)
    }

    func testDevicePointClampsOutOfBounds() {
        let low = CameraService.devicePoint(
            forViewPoint: CGPoint(x: -40, y: -10),
            inPreviewSize: CGSize(width: 100, height: 200)
        )
        XCTAssertEqual(low.x, 0)
        XCTAssertEqual(low.y, 0)

        let high = CameraService.devicePoint(
            forViewPoint: CGPoint(x: 900, y: 900),
            inPreviewSize: CGSize(width: 100, height: 200)
        )
        XCTAssertEqual(high.x, 1)
        XCTAssertEqual(high.y, 1)
    }

    func testDevicePointUsesCenterForDegenerateSize() {
        let point = CameraService.devicePoint(forViewPoint: .zero, inPreviewSize: .zero)
        XCTAssertEqual(point.x, 0.5)
        XCTAssertEqual(point.y, 0.5)
    }

    func testReasonMapsEveryServiceErrorToExpectedCopy() {
        let cases: [(CameraServiceError, String)] = [
            (.sessionNotConfigured, "The camera session is not running yet."),
            (.deviceUnavailable(.front), "No front camera is available."),
            (.deviceUnavailable(.back), "No back camera is available."),
            (.lensUnavailable(.wide), "The wide lens is unavailable on this device."),
            (.configurationFailed("boom"), "Camera configuration failed: boom."),
            (.zoomOutOfRange(2), "The requested zoom level is out of range."),
            (.focusPointUnsupported, "This camera does not support tap-to-focus."),
            (.manualExposureUnsupported, "Manual exposure is not supported by the active camera format."),
            (.manualWhiteBalanceUnsupported, "Manual white balance is not supported by the active camera format."),
            (.photoDataUnavailable, "The capture produced no image data."),
            (.captureFailed("lens stuck"), "The capture failed: lens stuck."),
            (.rawUnsupported, "RAW (DNG) is not supported by the active camera format."),
            (.videoNotImplemented, "Video recording is not implemented yet."),
            (.unsupportedCapability, "The requested video feature is not supported on this device."),
        ]
        for (error, expected) in cases {
            XCTAssertEqual(CaptureController.reason(for: error), expected, "mismatch for \(error)")
        }
    }

    func testReasonMapsSessionNotConfigured() {
        let reason = CaptureController.reason(for: CameraServiceError.sessionNotConfigured)
        XCTAssertEqual(reason, "The camera session is not running yet.")
    }

    func testCapturePhotoEmptyDataYieldsNoImageDataFailure() async {
        let service = FakeCameraService()
        service.photoToReturn = CapturedPhoto(
            data: Data(),
            format: .jpeg,
            width: 12,
            height: 12,
            exifSummary: nil
        )
        let photo = try? await service.capturePhoto(
            PhotoCaptureSettings(format: .jpeg, flash: .off, timerSeconds: 0, orientation: .portrait)
        )
        XCTAssertNotNil(photo)

        let permission = FakePermissionService(status: .granted)
        let saver = PhotoSaver(permissionService: permission) { _ in }
        let outcome = await saver.save(photo!)
        guard case .failed(let reason) = outcome else {
            return XCTFail("expected .failed, got \(outcome)")
        }
        XCTAssertTrue(reason.lowercased().contains("no image data"), "unexpected reason: \(reason)")
    }

    @MainActor
    func testCaptureCurrentSavesAndPublishesThumbnail() async {
        let service = FakeCameraService()
        let jpeg = makeJPEG()
        service.photoToReturn = CapturedPhoto(
            data: jpeg,
            format: .jpeg,
            width: 4,
            height: 4,
            exifSummary: nil
        )
        let permission = FakePermissionService(status: .granted)
        let controller = CaptureController(
            cameraService: service,
            permissionService: permission,
            saver: PhotoSaver(permissionService: permission) { _ in }
        )

        await controller.captureCurrent()

        guard case .saved(let saved) = controller.lastResult else {
            return XCTFail("expected .saved, got \(String(describing: controller.lastResult))")
        }
        XCTAssertEqual(saved.format, .jpeg)

        let deadline = Date().addingTimeInterval(2)
        while controller.thumbnail.lastThumbnail == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(controller.thumbnail.lastThumbnail, "thumbnail should decode on success")
    }

    private func makeJPEG(width: Int = 4, height: Int = 4) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 128, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = 100
            pixels[i + 1] = 150
            pixels[i + 2] = 200
            pixels[i + 3] = 255
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                     | CGBitmapInfo.byteOrder32Little.rawValue)
        let cgImage = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: bitmapInfo,
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )!
        let mutableData = NSMutableData()
        let dest = CGImageDestinationCreateWithData(mutableData, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cgImage, nil)
        _ = CGImageDestinationFinalize(dest)
        return mutableData as Data
    }
}

private final class FakeCameraService: CameraServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _captured: [PhotoCaptureSettings] = []

    var photoToReturn: CapturedPhoto?
    var captureError: CameraServiceError?

    var startSessionCalls = 0
    var stopSessionCalls = 0
    var selectDeviceCalls: [DevicePosition] = []
    var selectLensCalls: [CameraLensID] = []
    var setZoomCalls: [CGFloat] = []
    var applyManualConfigCalls: [ManualCameraConfig] = []
    var resetToAutoCalls = 0
    var focusCalls: [CGPoint] = []
    var setExposureOffsetCalls: [Float] = []

    var capturedSettings: [PhotoCaptureSettings] { lock.withLock { _captured } }

    var capabilities: CameraCapabilities { .iPhone11ProMaxFallback }
    var availableLenses: [LensInfo] { [] }
    var supportedManualRanges: ManualRanges {
        ManualRanges(iso: 100...3200, exposureSeconds: 0.000125...30.0, lensPosition: 0...1, kelvin: 2000...8000, tint: -150...150)
    }

    func startSession() async throws {
        if let captureError { throw captureError }
        lock.withLock { startSessionCalls += 1 }
    }
    func stopSession() { lock.withLock { stopSessionCalls += 1 } }
    func selectDevice(_ position: DevicePosition) throws {
        lock.withLock { selectDeviceCalls.append(position) }
    }
    func selectLens(_ id: CameraLensID) throws {
        lock.withLock { selectLensCalls.append(id) }
    }
    func setZoom(_ factor: CGFloat) throws {
        lock.withLock { setZoomCalls.append(factor) }
    }
    func applyManualConfig(_ config: ManualCameraConfig) throws {
        lock.withLock { applyManualConfigCalls.append(config) }
    }
    func resetToAuto() throws { lock.withLock { resetToAutoCalls += 1 } }
    func capturePhoto(_ settings: PhotoCaptureSettings) async throws -> CapturedPhoto {
        lock.withLock { _captured.append(settings) }
        if let captureError { throw captureError }
        if let photoToReturn { return photoToReturn }
        return CapturedPhoto(data: Data([0x01, 0x02, 0x03]), format: settings.format, width: 12, height: 12, exifSummary: nil)
    }
    func captureBracket(depth: BracketDepth) async throws -> [CapturedPhoto] { [] }
    func startVideoRecording(_ config: VideoRecordingConfig) throws {}
    func stopVideoRecording() async -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("fake.mov")
    }
    func focus(at point: CGPoint) throws { lock.withLock { focusCalls.append(point) } }
    func setExposureOffset(_ ev: Float) throws { lock.withLock { setExposureOffsetCalls.append(ev) } }
    func setPreviewFrameHandler(_ handler: (@Sendable (CVPixelBuffer) -> Void)?) {}
}

private final class FakePermissionService: CameraPermissionServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let answer: PermissionStatus
    init(status: PermissionStatus) { answer = status }
    func status(of permission: AppPermission) async -> PermissionStatus { answer }
    func request(_ permission: AppPermission) async -> PermissionStatus { answer }
}