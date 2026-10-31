import Foundation
import Combine
import CoreGraphics
import ImageIO

// Task 8 — last-shot thumbnail. After each successful save, decode a small
// thumbnail from the captured payload (ImageIO only — no UIKit) and publish it
// for the viewfinder's last-shot button. Cosmetic by contract: any decode
// failure simply publishes nil — no error is surfaced anywhere.
//
// Disposable by design: if T15's gallery supersedes this model, delete this
// file and drop `CaptureController.thumbnail`; nothing else references it.
//
// CONCURRENCY: the decode (a 48 MP DNG is far too large for the main actor)
// runs on the global executor via `Task.detached`, then hops back to the main
// actor to publish. The image crosses that boundary inside a private
// `@unchecked Sendable` envelope — `CGImage` is immutable and thread-safe by
// contract, and the envelope keeps the strict-concurrency hop compiling
// regardless of how the SDK annotates the type.

/// Private Sendable envelope for the decode → main-actor hop (see header).
private struct DecodedThumbnail: @unchecked Sendable {
    let image: CGImage?
}

@MainActor
final class LastShotThumbnailModel: ObservableObject {

    /// Longest-edge pixel cap for the decode (~200 pt at the iPhone 11 Pro
    /// Max's 3× scale).
    static let defaultMaxPixelSize = 600

    /// The most recent decoded thumbnail; nil until the first successful save
    /// and after a failed decode (cosmetic reset, per contract).
    @Published private(set) var lastThumbnail: CGImage?

    private let maxPixelSize: Int

    /// Publication-order guard: shots can land faster than decodes finish, so
    /// only the most recently scheduled decode may publish.
    private var generation = 0

    init(maxPixelSize: Int = LastShotThumbnailModel.defaultMaxPixelSize) {
        self.maxPixelSize = maxPixelSize
    }

    /// Called by the capture controller after each successful save.
    func record(_ photo: CapturedPhoto) {
        generation += 1
        let scheduledGeneration = generation
        let data = photo.data
        let maxPixelSize = self.maxPixelSize
        Task.detached(priority: .utility) { [weak self] in
            let thumbnail = LastShotThumbnailModel.makeThumbnail(from: data, maxPixelSize: maxPixelSize)
            guard let self else { return }
            await self.publish(DecodedThumbnail(image: thumbnail), generation: scheduledGeneration)
        }
    }

    // MARK: Publication (main actor)

    private func publish(_ thumbnail: DecodedThumbnail, generation scheduledGeneration: Int) {
        guard scheduledGeneration == generation else { return }
        lastThumbnail = thumbnail.image
    }

    // MARK: Decode (pure, nonisolated, unit-tested)

    /// Pure ImageIO thumbnail decode: `CGImageSourceCreateThumbnailAtIndex`
    /// with a `kCGImageSourceThumbnailMaxPixelSize` cap. Returns nil for
    /// undecodable payloads (empty buffers, invalid data) — never throws,
    /// never crashes.
    nonisolated static func makeThumbnail(from data: Data, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
