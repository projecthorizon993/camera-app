import Foundation
import Photos

// Task 8 — the photo-library save leg of the capture flow. Authorization is
// checked FIRST (`.addOnly`, via the injected Task 3 permission service); the
// save itself uses `PHAssetCreationRequest` with raw `Data` so DNG payloads
// are stored byte-for-byte untouched.
//
// The gate flow is NOT owned here: a non-granted status yields
// `.needsPermission` and the permission-gate modifier (Task 3) handles
// prompting. `PhotoSaver` never requests access itself.
//
// CONCURRENCY: the type is a plain `struct` marked `@unchecked Sendable` —
// both stored properties are immutable, the save closure is `@Sendable`, and
// the injected permission service is a shared app-wide dependency whose state
// is confined by its own isolation (the real `CameraPermissionService` is
// `@MainActor`). Callers run `save(_:)` on a background task (the controller
// detaches; see `CaptureController.save`) — `PHPhotoLibrary.performChanges`
// is async-safe and performs no main-thread I/O.

// MARK: - PhotoSaveOutcome

/// Terminal result of one save attempt (pure value, unit-testable).
enum PhotoSaveOutcome: Equatable, Sendable {
    case saved
    /// Photo-library add access is missing; the gate flow belongs to Task 3's
    /// permission modifier.
    case needsPermission
    case failed(String)
}

// MARK: - PhotoSaver

struct PhotoSaver: @unchecked Sendable {

    /// Injected asset-save step; the default writes into `PHPhotoLibrary`.
    typealias SaveAsset = @Sendable (Data) async throws -> Void

    private let permissionService: any CameraPermissionServiceProtocol
    private let saveAsset: SaveAsset

    /// - Parameters:
    ///   - permissionService: injected, never created here (Task 3 owns the
    ///     permission module; `NSPhotoLibraryAddUsageDescription` is already
    ///     declared by the app target).
    ///   - saveAsset: override point for tests; the default performs
    ///     `PHAssetCreationRequest.forAsset().addResource(with: .photo,
    ///     data:)` so DNG data saves untouched.
    init(
        permissionService: any CameraPermissionServiceProtocol,
        saveAsset: @escaping SaveAsset = PhotoSaver.systemPhotoLibrarySave
    ) {
        self.permissionService = permissionService
        self.saveAsset = saveAsset
    }

    /// Authorization check FIRST, then the save. Never throws; every failure
    /// becomes a `PhotoSaveOutcome` (never crashes, never silent).
    func save(_ photo: CapturedPhoto) async -> PhotoSaveOutcome {
        let status = await permissionService.status(of: .photoLibraryAdd)
        guard status == .granted else { return .needsPermission }
        guard !photo.data.isEmpty else {
            // A zero-byte asset in the library would be worse than a reported
            // failure (e.g. the placeholder service hands back empty data).
            return .failed("The capture produced no image data to save.")
        }
        do {
            try await saveAsset(photo.data)
            return .saved
        } catch {
            return .failed("Could not save to Photos: \(error.localizedDescription)")
        }
    }

    /// The real save. The change block runs inside `PHPhotoLibrary`'s own
    /// internal queue — never on the caller's thread.
    private static let systemPhotoLibrarySave: SaveAsset = { data in
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
        }
    }
}
