import XCTest
import Foundation
@testable import CameraApp

final class PhotoSaverTests: XCTestCase {

    // MARK: - SaveAsset receives photo unchanged

    func testSaveAssetReceivesPhotoUnchanged() async {
        let permission = FakePermissionService(status: .granted)
        let recorder = PhotoRecorder()
        let saver = PhotoSaver(permissionService: permission) { photo in
            recorder.record(photo)
        }

        let data = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00]) // DNG-ish bytes
        let photo = CapturedPhoto(data: data, format: .dng, width: 4, height: 4, exifSummary: nil)

        let outcome = await saver.save(photo)
        XCTAssertEqual(outcome, .saved)
        XCTAssertEqual(recorder.saved?.data, data)
        XCTAssertEqual(recorder.saved?.format, .dng)
        XCTAssertEqual(recorder.saved?.width, 4)
        XCTAssertEqual(recorder.saved?.height, 4)
    }

    func testSaveAssetDataBytesMatchForJPEG() async {
        let permission = FakePermissionService(status: .granted)
        let recorder = PhotoRecorder()
        let saver = PhotoSaver(permissionService: permission) { photo in
            recorder.record(photo)
        }

        let data = Data(repeating: 0xAB, count: 64)
        let photo = CapturedPhoto(data: data, format: .jpeg, width: 8, height: 8, exifSummary: nil)

        let outcome = await saver.save(photo)
        XCTAssertEqual(outcome, .saved)
        XCTAssertEqual(recorder.saved?.data, photo.data)
        XCTAssertEqual(recorder.saved?.format, photo.format)
    }

    // MARK: - Permission gating

    func testDeniedPermissionReturnsNeedsPermissionAndDoesNotTouchSave() async {
        let permission = FakePermissionService(status: .denied)
        let called = FlagBox()
        let saver = PhotoSaver(permissionService: permission) { _ in
            called.set(true)
        }

        let outcome = await saver.save(CapturedPhoto(data: Data([1, 2, 3]), format: .jpeg, width: 4, height: 4, exifSummary: nil))
        XCTAssertEqual(outcome, .needsPermission)
        XCTAssertFalse(called.current, "save closure must not be invoked when permission denied")
    }

    func testNotDeterminedPermissionReturnsNeedsPermission() async {
        let permission = FakePermissionService(status: .notDetermined)
        let called = FlagBox()
        let saver = PhotoSaver(permissionService: permission) { _ in
            called.set(true)
        }

        let outcome = await saver.save(CapturedPhoto(data: Data([1, 2, 3]), format: .jpeg, width: 4, height: 4, exifSummary: nil))
        XCTAssertEqual(outcome, .needsPermission)
        XCTAssertFalse(called.current)
    }

    // MARK: - Empty data

    func testEmptyDataReturnsFailedNoImageData() async {
        let permission = FakePermissionService(status: .granted)
        let called = FlagBox()
        let saver = PhotoSaver(permissionService: permission) { _ in
            called.set(true)
        }

        let outcome = await saver.save(CapturedPhoto(data: Data(), format: .jpeg, width: 4, height: 4, exifSummary: nil))
        guard case .failed(let reason) = outcome else {
            return XCTFail("expected .failed, got \(outcome)")
        }
        XCTAssertTrue(reason.lowercased().contains("no image data"), "unexpected reason: \(reason)")
        XCTAssertFalse(called.current, "save closure must not be invoked for empty data")
    }

    // MARK: - Save throws

    func testSaveThrowsMapsToFailed() async {
        let permission = FakePermissionService(status: .granted)
        let saver = PhotoSaver(permissionService: permission) { _ in
            throw NSError(domain: "PhotoSaverTests", code: 7, userInfo: nil)
        }

        let outcome = await saver.save(CapturedPhoto(data: Data([1, 2, 3]), format: .jpeg, width: 4, height: 4, exifSummary: nil))
        guard case .failed(let reason) = outcome else {
            return XCTFail("expected .failed, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("Photos"), "unexpected reason: \(reason)")
    }
}

// MARK: - Fakes

private final class FakePermissionService: CameraPermissionServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let answer: PermissionStatus
    init(status: PermissionStatus) { answer = status }
    func status(of permission: AppPermission) async -> PermissionStatus { answer }
    func request(_ permission: AppPermission) async -> PermissionStatus { answer }
}

private final class PhotoRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _saved: CapturedPhoto?
    var saved: CapturedPhoto? { lock.withLock { _saved } }
    func record(_ photo: CapturedPhoto) { lock.withLock { _saved = photo } }
}

private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var current: Bool { lock.withLock { _value } }
    func set(_ newValue: Bool) { lock.withLock { _value = newValue } }
}