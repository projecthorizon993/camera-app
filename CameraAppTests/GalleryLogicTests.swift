import XCTest
import Foundation
import CoreGraphics
import UIKit
@testable import CameraApp

// Task 15 — gallery logic + view-model tests.

private func makeCGImage() -> CGImage {
    let size = CGSize(width: 2, height: 2)
    let renderer = UIGraphicsImageRenderer(size: size)
    let image = renderer.image { ctx in
        UIColor.red.setFill()
        ctx.fill(CGRect(origin: .zero, size: size))
    }
    return image.cgImage!
}

private final class FakeGallerySource: GalleryProviding {
    var denied: Bool = false
    var recentResult: [GalleryItem] = []
    var recentCallCount: Int = 0
    var recentLimit: Int?
    var thumbnailResult: CGImage?
    var thumbnailCalls: [String] = []
    var shareResult: URL?
    var shareCalls: [String] = []
    var deleteResult: Bool = true
    var deleteCalls: [[String]] = []

    func recentAssets(limit: Int) async -> [GalleryItem] {
        recentCallCount += 1
        recentLimit = limit
        return denied ? [] : recentResult
    }

    func thumbnail(for item: GalleryItem, pixelSize: CGSize) async -> CGImage? {
        thumbnailCalls.append(item.id)
        return thumbnailResult
    }

    func shareDataURL(for item: GalleryItem) async -> URL? {
        shareCalls.append(item.id)
        return shareResult
    }

    func delete(ids: [String]) async -> Bool {
        deleteCalls.append(ids)
        return deleteResult
    }
}

@MainActor
final class GalleryLogicTests: XCTestCase {

    // MARK: GalleryItemLogic

    func testIsRAWFilenameDNG() {
        XCTAssertTrue(GalleryItemLogic.isRAWFilename(".dng"))
        XCTAssertTrue(GalleryItemLogic.isRAWFilename("IMG_0001.DNG"))
        XCTAssertFalse(GalleryItemLogic.isRAWFilename("IMG_0001.HEIC"))
        XCTAssertFalse(GalleryItemLogic.isRAWFilename("IMG_0001.jpg"))
    }

    func testDurationText() {
        XCTAssertEqual(GalleryItemLogic.durationText(83.0), "1:23")
        XCTAssertNil(GalleryItemLogic.durationText(nil))
        XCTAssertEqual(GalleryItemLogic.durationText(0), "0:00")
    }

    // MARK: GalleryViewModel

    func testLoadPopulated() async {
        let source = FakeGallerySource()
        let item = GalleryItem(id: "1", isVideo: false, durationSeconds: nil, isRAW: false, capturedAt: nil)
        source.recentResult = [item]
        let vm = GalleryViewModel(source: source)
        await vm.load()
        XCTAssertEqual(vm.status, .loaded)
        XCTAssertEqual(vm.items, [item])
    }

    func testLoadEmpty() async {
        let source = FakeGallerySource()
        let vm = GalleryViewModel(source: source)
        await vm.load()
        XCTAssertEqual(vm.status, .empty)
    }

    func testLoadDenied() async {
        let source = FakeGallerySource()
        source.denied = true
        let vm = GalleryViewModel(source: source)
        await vm.load()
        XCTAssertEqual(vm.status, .denied)
    }

    func testToggleSelectionSymmetric() {
        let source = FakeGallerySource()
        let vm = GalleryViewModel(source: source)
        vm.toggleSelection("x")
        XCTAssertTrue(vm.selected.contains("x"))
        vm.toggleSelection("x")
        XCTAssertFalse(vm.selected.contains("x"))
    }

    func testDeleteSelectedForwardsIdsAndClears() async {
        let source = FakeGallerySource()
        let item = GalleryItem(id: "a", isVideo: false, durationSeconds: nil, isRAW: false, capturedAt: nil)
        source.recentResult = [item]
        let vm = GalleryViewModel(source: source)
        await vm.load()
        vm.toggleSelection("a")
        await vm.deleteSelected()
        XCTAssertEqual(source.deleteCalls.last, ["a"])
        XCTAssertTrue(vm.selected.isEmpty)
    }

    func testEnsureThumbnailCaches() async {
        let source = FakeGallerySource()
        let img = makeCGImage()
        source.thumbnailResult = img
        let item = GalleryItem(id: "t", isVideo: false, durationSeconds: nil, isRAW: false, capturedAt: nil)
        let vm = GalleryViewModel(source: source)
        await vm.ensureThumbnail(for: item)
        await vm.ensureThumbnail(for: item)
        XCTAssertEqual(source.thumbnailCalls.count, 1)
        XCTAssertNotNil(vm.thumbnails["t"])
    }
}
