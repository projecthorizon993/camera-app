import Foundation

// MARK: - Module header
//
// CameraApp/Bracketing — Task 12 multi-frame capture engines.
//
// Rulings carried forward:
//   • M2 (portrait-orientation-only): bracket capture is portrait-orientation-only
//     in v1. `captureBracket` (service) hardcodes `orientation: .portrait` for
//     software brackets; this module does not attempt landscape bracket merges.
//   • M5 (partial return): software brackets may return 1..N frames; every frame
//     count >= 2 merges with normalized weights, a single frame passes through.
//   • M1 (EXIF): merged output stamps `kCGImagePropertyExifDateTimeOriginal`
//     from the source frame's `exifSummary.capturedAt`.

// MARK: - MergeMode

/// How a bracket's frames are combined into one photo.
public enum MergeMode: Sendable { case fusion, nightStack }

// MARK: - BracketPlan

/// Pure planning value for one bracket run.
public struct BracketPlan: Sendable, Equatable {
    public let frameCount: Int   // 1...9
    public let mode: MergeMode

    public init(frameCount: Int, mode: MergeMode) {
        self.frameCount = min(max(frameCount, 1), 9)
        self.mode = mode
    }
}

// MARK: - BracketPlanner

/// Pure planning math for a bracket run. No hardware, no Metal.
public enum BracketPlanner {

    /// EV span (in EV) per bracket depth, mirroring the service's span table
    /// (hardware AEB-3 = 4 EV; software = 6/7/8 EV for 5/7/9).
    public static func span(for depth: BracketDepth) -> Double {
        switch depth {
        case .aeb3:  return 4.0
        case .soft5: return 6.0
        case .soft7: return 7.0
        case .soft9: return 8.0
        }
    }

    /// EV ladder for a bracket depth (−half…+half, evenly stepped).
    /// Used only for planning/validation + tests; the service owns actual exposure.
    public static func evLadder(depth: BracketDepth) -> [Double] {
        let count = depth.frameCount
        guard count > 1 else { return [0.0] }
        let span = Self.span(for: depth)
        let step = span / Double(count - 1)
        let half = span / 2.0
        return (0..<count).map { index in -half + Double(index) * step }
    }

    /// Mertens-style per-frame weight for one pixel.
    /// Inputs are normalized 0...1; `lightness` is the pixel luminance,
    /// `contrast` and `saturation` are per-pixel estimates. Returns the
    /// (unnormalized) weight. Mid-gray luminance outperforms extremes because
    /// the exposure term peaks at 0.5.
    public static func mertensWeight(lightness: Float, contrast: Float, saturation: Float) -> Float {
        let sigma: Float = 0.2
        let exposure = expf(-((lightness - 0.5) * (lightness - 0.5)) / (2.0 * sigma * sigma))
        return max(contrast, 0) * max(saturation, 0) * exposure
    }

    /// Fusion weight normalization: divide each weight by the per-position sum.
    /// All-frames-identical edge case (sum == 0) → uniform weights.
    public static func normalize(_ weights: [Float]) -> [Float] {
        guard !weights.isEmpty else { return [] }
        let sum = weights.reduce(0, +)
        if sum <= 0 {
            let uniform = 1.0 / Float(weights.count)
            return Array(repeating: uniform, count: weights.count)
        }
        return weights.map { $0 / sum }
    }
}
