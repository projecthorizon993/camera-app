import Foundation

// MARK: - WatermarkLibrary

/// Built-in watermark templates. Clean-room: generic names, pure text only —
/// no trademarks, brand glyphs, or stock-image logos.
enum WatermarkLibrary {
    static let builtins: [WatermarkTemplate] = [
        WatermarkTemplate(
            id: "signature-bar",
            displayName: "Signature Bar",
            lines: [
                WatermarkLine(content: .deviceModel, relativeFontSize: 1.0),
                WatermarkLine(content: .focalAperture, relativeFontSize: 0.85),
                WatermarkLine(content: .shutterISO, relativeFontSize: 0.85),
                WatermarkLine(content: .timestamp("yyyy-MM-dd HH:mm"), relativeFontSize: 0.8),
            ],
            divider: WatermarkDivider(thicknessFraction: 0.0015, widthFraction: 0.6,
                                     colorHex: "#FFFFFF"),
            alignment: .center,
            fontScale: 0.04,
            textColorHex: "#FFFFFF",
            backgroundBar: true
        ),
        WatermarkTemplate(
            id: "corner-stamp",
            displayName: "Corner Stamp",
            lines: [
                WatermarkLine(content: .shutterISO, relativeFontSize: 0.9),
                WatermarkLine(content: .focalAperture, relativeFontSize: 0.9),
            ],
            divider: nil,
            alignment: .left,
            fontScale: 0.03,
            textColorHex: "#FFFFFF",
            backgroundBar: false
        ),
        WatermarkTemplate(
            id: "location-strip",
            displayName: "Location Strip",
            lines: [
                WatermarkLine(content: .deviceModel, relativeFontSize: 1.0),
                WatermarkLine(content: .timestamp("MMM d, yyyy"), relativeFontSize: 0.85),
                WatermarkLine(content: .coordinates, relativeFontSize: 0.8),
            ],
            divider: nil,
            alignment: .center,
            fontScale: 0.04,
            textColorHex: "#FFFFFF",
            backgroundBar: true
        ),
    ]
}
