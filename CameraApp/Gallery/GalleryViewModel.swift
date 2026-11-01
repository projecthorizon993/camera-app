import Foundation
import CoreGraphics
import ImageIO
import Observation

// Task 15 — gallery view model. @MainActor @Observable; owns mutable UI state.

enum GalleryStatus: Sendable, Equatable { case loading, empty, denied, loaded }

@MainActor
@Observable
final class GalleryViewModel {
    let source: any GalleryProviding
    private let limit: Int

    private(set) var items: [GalleryItem] = []
    private(set) var thumbnails: [String: CGImage] = [:]
    private(set) var status: GalleryStatus = .loading
    private(set) var selectionMode: Bool = false
    private(set) var selected: Set<String> = []
    private(set) var lastActionMessage: String? = nil

    private var fullImages: [String: CGImage] = [:]
    private var thumbnailAttempted: Set<String> = []

    init(source: any GalleryProviding, limit: Int = 500) {
        self.source = source
        self.limit = limit
    }

    func load() async {
        if source.denied {
            status = .denied
            items = []
            return
        }
        let authState = PhotoLibraryAccess.authorizationState()
        if authState == .denied || authState == .restricted {
            status = .denied
            items = []
            return
        }
        status = .loading
        let fetched = await source.recentAssets(limit: limit)
        items = fetched
        status = fetched.isEmpty ? .empty : .loaded
    }

    func refresh() async {
        await load()
    }

    func ensureThumbnail(for item: GalleryItem) async {
        if thumbnailAttempted.contains(item.id) { return }
        thumbnailAttempted.insert(item.id)
        if let image = await source.thumbnail(for: item, pixelSize: CGSize(width: 300, height: 300)) {
            thumbnails[item.id] = image
        }
    }

    func ensureFullImage(for item: GalleryItem) async -> CGImage? {
        if let cached = fullImages[item.id] { return cached }
        var image: CGImage?
        if item.isRAW, let url = await source.shareDataURL(for: item) {
            image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4096,
                ]
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
            }.value
        }
        if image == nil {
            image = await source.thumbnail(for: item, pixelSize: CGSize(width: 2048, height: 2048))
        }
        if let image { fullImages[item.id] = image }
        return image
    }

    func toggleSelection(_ id: String) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
    }

    func setSelectionMode(_ on: Bool) {
        selectionMode = on
        if !on {
            selected.removeAll()
        }
    }

    func deleteSelected() async {
        guard !selected.isEmpty else { return }
        let ids = selected.sorted()
        let ok = await source.delete(ids: ids)
        if ok {
            selected.removeAll()
            selectionMode = false
            await refresh()
            lastActionMessage = "Deleted \(ids.count)"
        } else {
            lastActionMessage = "Delete failed"
        }
    }

    func shareURL(for item: GalleryItem) async -> URL? {
        await source.shareDataURL(for: item)
    }

    func requestAccess() async {
        if source.denied {
            status = .denied
            items = []
            return
        }
        let state = PhotoLibraryAccess.authorizationState()
        if state == .denied || state == .restricted {
            status = .denied
            items = []
            return
        }
        if state == .notDetermined {
            let granted = await PhotoLibraryAccess.requestReadWrite()
            if !granted {
                status = .denied
                items = []
                return
            }
        }
        await load()
    }
}
