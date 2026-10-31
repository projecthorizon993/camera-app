import Foundation

// Pure-Foundation watermark models (template geometry + typography).
// The renderer protocol consuming these lives in Core/Contracts.swift.

/// 9-slot grid for watermark placement.
enum WatermarkPosition: Sendable, CaseIterable {
    case topLeft, topCenter, topRight
    case midLeft, center, midRight
    case bottomLeft, bottomCenter, bottomRight
}

/// Horizontal text alignment inside the watermark block.
enum WatermarkAlignment: String, Sendable { case left, center, right }

/// One line of watermark text. Dynamic cases are resolved from EXIF/context
/// at render time; `literal` and `timestamp` carry their own payload.
enum WatermarkContent: Sendable, Equatable {
    case literal(String)
    case deviceModel
    case lensSpec
    case focalAperture
    case shutterISO
    case timestamp(String) // date format string
    case coordinates
}

/// A thin divider drawn between watermark lines.
struct WatermarkDivider: Sendable, Equatable {
    let thicknessFraction: Double  // of image height
    let widthFraction: Double      // of image width
    let colorHex: String
}

/// One line item of a watermark template.
struct WatermarkLine: Sendable, Equatable {
    let content: WatermarkContent
    let relativeFontSize: Double
}

/// A complete watermark template (geometry only; rendering is Task 16).
struct WatermarkTemplate: Sendable, Identifiable, Equatable {
    let id: String
    let displayName: String
    let lines: [WatermarkLine]
    let divider: WatermarkDivider?
    let alignment: WatermarkAlignment
    let fontScale: Double          // fraction of image width
    let textColorHex: String
    let backgroundBar: Bool
}
