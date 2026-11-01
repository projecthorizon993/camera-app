import Foundation
import Photos
import CoreGraphics

// Task 15 — gallery data source. A non-PH protocol so the view model can be
// unit-tested with a fake, plus the live Photos-backed implementation.
//
// CONCURRENCY: `LiveGallerySource` is `@unchecked Sendable` — PHPhotoLibrary /
// PHImageManager are thread-safe shared objects and per-call state stays
// method-local. Every PhotosKit completion is bridged to a checked
// continuation and the heavy work runs OFF the caller's actor via
// `Task.detached` (SE-0461 makes a plain `await` run on the caller's actor).
// CGImage crosses the task/actor boundary inside a private `@unchecked
// Sendable` envelope — copy of the proven precedent in
// `Capture/LastShotThumbnail.swift` (`DecodedThumbnail`).

/// Non-PH protocol so the view model can be unit-tested with a fake.
protocol GalleryProviding: AnyObject {
    var denied: Bool { get }
    func recentAssets(limit: Int) async -> [GalleryItem]
    func thumbnail(for item: GalleryItem, pixelSize: CGSize) async -> CGImage?
    /// Exports the ORIGINAL bytes (DNG stays DNG) to a temp file URL for share.
    func shareDataURL(for item: GalleryItem) async -> URL?
    func delete(ids: [String]) async -> Bool
}

extension GalleryProviding {
    /// Default: not denied. Keeps conformance optional for test fakes.
    var denied: Bool { false }
}

/// Private Sendable envelope for CGImage hops (see header / LastShotThumbnail).
private struct GalleryThumbnailEnvelope: @unchecked Sendable {
    let image: CGImage?
}

/// Private Sendable envelope for URL hops.
private struct GalleryURLEnvelope: @unchecked Sendable {
    let url: URL?
}

/// @unchecked Sendable: PHPhotoLibrary/PHImageManager are thread-safe shared
/// objects; per-call state stays method-local.
final class LiveGallerySource: GalleryProviding, @unchecked Sendable {

    var denied: Bool {
        let status = PhotoLibraryAccess.authorizationState()
        return status == .denied || status == .restricted
    }

    // MARK: - recentAssets

    func recentAssets(limit: Int) async -> [GalleryItem] {
        await Task.detached(priority: .userInitiated) { () -> [GalleryItem] in
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.includeAllBursts = false
            if limit > 0 { options.fetchLimit = limit * 2 }
            let result = PHAsset.fetchAssets(with: options)
            var items: [GalleryItem] = []
            result.enumerateObjects { asset, _, stop in
                guard asset.mediaType == .image || asset.mediaType == .video else { return }
                if items.count >= limit {
                    stop.pointee = true
                    return
                }
                items.append(LiveGallerySource.map(asset))
            }
            return items
        }.value
    }

    private static func map(_ asset: PHAsset) -> GalleryItem {
        GalleryItem(
            id: asset.localIdentifier,
            isVideo: asset.mediaType == .video,
            durationSeconds: asset.mediaType == .video ? asset.duration : nil,
            isRAW: LiveGallerySource.isRAW(asset: asset),
            capturedAt: asset.creationDate
        )
    }

    private static func isRAW(asset: PHAsset) -> Bool {
        guard asset.mediaType == .image else { return false }
        let resources = PHAssetResource.assetResources(for: asset)
        for resource in resources {
            if resource.uniformTypeIdentifier.lowercased() == "com.adobe.raw-image" {
                return true
            }
            if GalleryItemLogic.isRAWFilename(resource.originalFilename) {
                return true
            }
        }
        return false
    }

    // MARK: - thumbnail

    func thumbnail(for item: GalleryItem, pixelSize: CGSize) async -> CGImage? {
        guard let asset = fetchAsset(id: item.id) else { return nil }
        let safeSize = pixelSize.width > 0 && pixelSize.height > 0
            ? pixelSize : CGSize(width: 300, height: 300)
        let envelope = await Task.detached(priority: .userInitiated) { () -> GalleryThumbnailEnvelope in
            await withCheckedContinuation { (cont: CheckedContinuation<GalleryThumbnailEnvelope, Never>) in
                let manager = PHImageManager.default()
                let options = PHImageRequestOptions()
                options.deliveryMode = .fastFormat
                options.isNetworkAccessAllowed = true
                options.isSynchronous = false
                var handled = false
                _ = manager.requestImage(
                    for: asset,
                    targetSize: safeSize,
                    contentMode: .aspectFill,
                    options: options
                ) { image, _ in
                    guard !handled else { return }
                    handled = true
                    cont.resume(returning: GalleryThumbnailEnvelope(image: image?.cgImage))
                }
            }
        }.value
        return envelope.image
    }

    // MARK: - shareDataURL

    func shareDataURL(for item: GalleryItem) async -> URL? {
        guard let asset = fetchAsset(id: item.id) else { return nil }
        let envelope = await Task.detached(priority: .userInitiated) { () -> GalleryURLEnvelope in
            let resources = PHAssetResource.assetResources(for: asset)
            let resource: PHAssetResource?
            if item.isVideo {
                resource = resources.first(where: { $0.type == .video }) ?? resources.first
            } else {
                resource = resources.first(where: { $0.type == .photo }) ?? resources.first
            }
            guard let r = resource else {
                return GalleryURLEnvelope(url: nil)
            }
            let ext = (r.originalFilename as NSString).pathExtension
            let finalExt = ext.isEmpty ? "dat" : ext
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("GalleryShare", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000)).\(finalExt)")
            try? FileManager.default.removeItem(at: url)

            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            let ok: Bool = await withCheckedContinuation { cont in
                PHAssetResourceManager.default().writeData(for: r, toFile: url, options: options) { error in
                    cont.resume(returning: error == nil)
                }
            }
            return GalleryURLEnvelope(url: ok ? url : nil)
        }.value
        return envelope.url
    }

    // MARK: - delete

    func delete(ids: [String]) async -> Bool {
        guard !ids.isEmpty else { return true }
        return await Task.detached(priority: .userInitiated) { () -> Bool in
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            guard assets.count > 0 else { return false }
            return await withCheckedContinuation { cont in
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.deleteAssets(assets as NSFastEnumeration)
                }) { success, _ in
                    cont.resume(returning: success)
                }
            }
        }.value
    }

    // MARK: - helpers

    private func fetchAsset(id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }
}

// MARK: - PhotoLibraryAccess

/// Authorization helpers (in this file, used by the view model). Do NOT modify
/// PermissionGateView / AppPermission / Task-3 service.
enum PhotoLibraryAccess {
    static func authorizationState() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    static func requestReadWrite() async -> Bool {
        await withCheckedContinuation { cont in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                cont.resume(returning: status == .authorized || status == .limited)
            }
        }
    }
}
