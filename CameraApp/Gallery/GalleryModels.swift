import Foundation
import CoreGraphics

// Task 15 — capture gallery models. Pure value types + pure logic, unit-testable.
// PHAsset is not constructible in unit tests, so the value type carries plain
// fields; the live source (GallerySource.swift) maps PHAsset → GalleryItem.

/// One gallery cell. Carries only plain, Sendable fields.
struct GalleryItem: Sendable, Equatable, Identifiable {
    let id: String               // PHAsset.localIdentifier
    let isVideo: Bool
    let durationSeconds: Double? // nil for photos; videos carry it
    let isRAW: Bool              // DNG detection, source-aware
    let capturedAt: Date?
}

/// Pure classification of how a cell should render.
enum GalleryCellKind: Sendable, Equatable {
    case thumbnailOnly
    case rawBadge
    case videoBadge(String) // "mm:ss"
}

/// PURE helpers (unit-tested). Keep scalar, nonisolated, static.
enum GalleryItemLogic {
    /// DNG heuristic: filename ends with ".dng" (case-insensitive).
    static func isRAWFilename(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".dng")
    }

    /// Formats a video duration as "m:ss". Returns nil for nil input.
    /// A zero duration formats as "0:00" (nil-safe, never crashes).
    static func durationText(_ seconds: Double?) -> String? {
        guard let seconds else { return nil }
        let total = max(0, Int(seconds.rounded(.down)))
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}
