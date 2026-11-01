import Foundation
import CoreGraphics
import CoreVideo

// MARK: - WatermarkLayout

/// Pure pixel-space layout for one watermark pass. All rects are in image
/// pixels with a top-left origin (the renderer flips the CG context to match).
struct WatermarkLayout: Sendable, Equatable {
    let blockRect: CGRect
    let lineRects: [CGRect]
    let dividerRect: CGRect?
    let barRect: CGRect?
}

// MARK: - WatermarkPlanner

/// Pure planning + resolution helpers for watermarks. No Metal, no AVFoundation;
/// unit-testable on any host. The renderer (WatermarkRenderer) consumes these.
enum WatermarkPlanner {

    /// Short-edge-based safe margin (3% of the short edge).
    private static func margin(for size: CGSize) -> CGFloat {
        CGFloat(0.03) * min(size.width, size.height)
    }

    /// Converts template geometry (+ position + buffer size) into pixel-space
    /// rects.
    static func layout(template: WatermarkTemplate, position: WatermarkPosition,
                       size: CGSize) -> WatermarkLayout {
        let short = min(size.width, size.height)
        let margin = 0.03 * short
        let blockWidth = max(0, size.width - 4 * margin)

        // Line heights (one rect per template line).
        let lineHeights: [CGFloat] = template.lines.map { line in
            let fontSize = CGFloat(line.relativeFontSize * template.fontScale * Double(short))
            return fontSize * 1.25
        }
        let dividerHeight: CGFloat = template.divider.map {
            CGFloat($0.thicknessFraction) * CGFloat(short)
        } ?? 0
        let dividerSpacing: CGFloat = template.divider == nil ? 0 : margin * 0.25
        let totalLineHeight = lineHeights.reduce(0, +)
        let blockHeight = totalLineHeight + dividerHeight + dividerSpacing

        // Column x.
        let x: CGFloat
        switch position {
        case .topLeft, .midLeft, .bottomLeft:
            x = margin
        case .topCenter, .center, .bottomCenter:
            x = (size.width - blockWidth) / 2
        case .topRight, .midRight, .bottomRight:
            x = size.width - margin - blockWidth
        }

        // Row y (top-left origin).
        let y: CGFloat
        switch position {
        case .topLeft, .topCenter, .topRight:
            y = margin
        case .midLeft, .center, .midRight:
            y = (size.height - blockHeight) / 2
        case .bottomLeft, .bottomCenter, .bottomRight:
            y = size.height - margin - blockHeight
        }

        let blockRect = CGRect(x: x, y: y, width: blockWidth, height: blockHeight)

        // Line rects stacked inside the block.
        var lineRects: [CGRect] = []
        var cursor = blockRect.minY
        for (i, line) in template.lines.enumerated() {
            let h = i < lineHeights.count ? lineHeights[i] : 0
            lineRects.append(CGRect(x: blockRect.minX, y: cursor, width: blockWidth, height: h))
            cursor += h
        }

        // Divider rect (centered in the block).
        let dividerRect: CGRect?
        if let divider = template.divider {
            let dw = CGFloat(divider.widthFraction) * blockWidth
            let dh = CGFloat(divider.thicknessFraction) * CGFloat(short)
            let dx = blockRect.minX + (blockWidth - dw) / 2
            let dy = blockRect.minY + (blockHeight - dh) / 2
            dividerRect = CGRect(x: dx, y: dy, width: dw, height: dh)
        } else {
            dividerRect = nil
        }

        // Background bar (wider than the block by one margin on each side).
        let barRect: CGRect?
        if template.backgroundBar {
            let barWidth = blockWidth + 2 * margin
            let barHeight = blockHeight + 2 * margin
            let barX = blockRect.minX - margin
            let barY: CGFloat
            switch position {
            case .topLeft, .topCenter, .topRight:
                barY = 0
            case .midLeft, .center, .midRight:
                barY = (size.height - barHeight) / 2
            case .bottomLeft, .bottomCenter, .bottomRight:
                barY = size.height - barHeight
            }
            barRect = CGRect(x: barX, y: barY, width: barWidth, height: barHeight)
        } else {
            barRect = nil
        }

        return WatermarkLayout(blockRect: blockRect, lineRects: lineRects,
                               dividerRect: dividerRect, barRect: barRect)
    }

    /// Dynamic-line resolution. Returns nil → line is SKIPPED (not drawn).
    static func resolve(content: WatermarkContent, exif: ExifSummary?,
                        metadata: [String: String]) -> String? {
        switch content {
        case .literal(let s):
            return s
        case .deviceModel:
            return exif?.deviceModel
        case .lensSpec:
            guard let raw = exif?.lensID?.rawValue else { return nil }
            let first = raw.prefix(1).uppercased()
            let rest = raw.dropFirst()
            return first + rest
        case .focalAperture:
            var parts: [String] = []
            if let focal = exif?.focalMM {
                parts.append(String(format: "%gmm", focal))
            }
            if let aperture = exif?.aperture {
                parts.append(String(format: "f/%g", aperture))
            }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        case .shutterISO:
            var parts: [String] = []
            if let shutter = shutterText(seconds: exif?.shutterSeconds) {
                if shutter.hasSuffix("s") {
                    parts.append(shutter)
                } else {
                    parts.append(shutter + " s")
                }
            }
            if let iso = isoText(iso: exif?.iso) {
                parts.append(iso)
            }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        case .timestamp(let fmt):
            guard let date = exif?.capturedAt else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = fmt
            return formatter.string(from: date)
        case .coordinates:
            return metadata["locationText"]
        }
    }

    /// Pure shutter text.
    static func shutterText(seconds: Double?) -> String? {
        guard let t = seconds, t > 0 else { return nil }
        if t >= 1 {
            return String(format: "%.1f s", t)
        }
        let denom = Int(round(1.0 / t))
        guard denom > 0 else { return nil }
        return "1/\(denom)"
    }

    static func isoText(iso: Float?) -> String? {
        guard let iso = iso else { return nil }
        return "ISO \(Int(iso.rounded()))"
    }

    /// "#RRGGBB(AA)" CSS-parser (8/6-digit both valid, case-insensitive,
    /// leading # optional). Returns nil on malformed input.
    static func color(fromHex hex: String) -> CGColor? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8 else { return nil }
        guard s.allSatisfy({ $0.isHexDigit }) else { return nil }

        func byte(_ i: Int) -> UInt8? {
            let start = s.index(s.startIndex, offsetBy: i)
            let end = s.index(start, offsetBy: 2)
            return UInt8(s[start..<end], radix: 16)
        }

        guard let r = byte(0), let g = byte(2), let b = byte(4) else { return nil }
        let a: UInt8
        if s.count == 8 {
            guard let parsed = byte(6) else { return nil }
            a = parsed
        } else {
            a = 255
        }
        let components: [CGFloat] = [CGFloat(r) / 255.0, CGFloat(g) / 255.0,
                                     CGFloat(b) / 255.0, CGFloat(a) / 255.0]
        return CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: components)
    }

    static func shouldApply(format: CaptureFormat) -> Bool {
        format != .dng
    }
}
