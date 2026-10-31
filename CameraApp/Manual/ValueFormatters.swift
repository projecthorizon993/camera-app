import Foundation

// Task 9 — pure, Foundation-only formatting helpers for the manual pro panel.
// No SwiftUI, no AVFoundation, no camera types: trivially unit-testable, and
// the engine/panel layer owns no formatting logic of its own.
//
// Ranges are never assumed here — callers format values they already clamped
// to `ManualRanges`. Formatters are display-only (lossy is fine, e.g. 0.75 s
// renders as "0.8s"); `parseShutter` round-trips the canonical outputs of
// `shutter(seconds:)`.

enum ValueFormatters {

    /// ISO as an integer string: 799.6 → "800", 100 → "100".
    static func iso(_ value: Float) -> String {
        String(Int(value.rounded()))
    }

    /// Shutter as a photographic fraction for sub-second exposures
    /// (1/120 → "1/120", 0.000125 → "1/8000", sub-millisecond 0.0001 →
    /// "1/10000") and decimal seconds at or above one second (1.0 → "1s",
    /// never "1/1"; 2.5 → "2.5s"). Non-positive input renders as "—".
    static func shutter(seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        if seconds >= 1.0 {
            return decimalSeconds(seconds)
        }
        // Sub-second: reduce to the nearest 1/N fraction. A value whose
        // reciprocal rounds to 1 (just under 1 s) has no useful fraction, so
        // it falls back to decimal seconds.
        let denominator = Int((1.0 / seconds).rounded())
        guard denominator > 1 else { return decimalSeconds(seconds) }
        return "1/\(denominator)"
    }

    /// Inverse of `shutter(seconds:)` for its canonical outputs:
    /// "1/120" → 1/120, "2.5s" → 2.5, "1s" → 1.0. Returns nil for anything
    /// else (including "—").
    static func parseShutter(_ text: String) -> Double? {
        if text.hasSuffix("s") {
            return Double(text.dropLast())
        }
        let parts = text.split(separator: "/")
        guard parts.count == 2,
              let numerator = Double(parts[0]),
              let denominator = Double(parts[1]),
              denominator > 0 else { return nil }
        return numerator / denominator
    }

    /// Kelvin as "5600K" (rounded to the nearest integer).
    static func kelvin(_ value: Float) -> String {
        "\(Int(value.rounded()))K"
    }

    /// Normalized lens position (0…1) as a percentage: 0.25 → "25%".
    static func lensPosition(_ value: Float) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    /// Tint with an explicit sign: 10 → "+10", −5 → "-5", 0 → "0".
    static func tint(_ value: Float) -> String {
        let rounded = value.rounded()
        return rounded > 0 ? "+\(Int(rounded))" : "\(Int(rounded))"
    }

    /// Decimal seconds: whole values drop the fraction ("10s"), otherwise one
    /// decimal place ("2.5s").
    private static func decimalSeconds(_ seconds: Double) -> String {
        if seconds == seconds.rounded() {
            return "\(Int(seconds))s"
        }
        return String(format: "%.1fs", seconds)
    }
}
