import SwiftUI

// MARK: - Theme

/// Design-token namespace for the whole app. Every component reads its colors,
/// spacing, radii, typography, opacities, shadows, and dimensions from here —
/// no magic values in components (Task 7a definition of done).
///
/// Aesthetic: dark camera chrome — near-black backgrounds, white primary text,
/// warm-amber accent, high-contrast overlays designed to sit ON TOP of live video.
enum Theme {

    // MARK: Color tokens

    /// Color palette. Values are documented with their intended hex so a Mac
    /// review can eyeball them; components only ever reference these tokens.
    enum Color {
        /// #0B0B0D — near-black canvas / deepest chrome.
        static let chrome900 = SwiftUI.Color(red: 0.043, green: 0.043, blue: 0.051)
        /// #17171B — raised chrome (bars, gate icon well).
        static let chrome800 = SwiftUI.Color(red: 0.090, green: 0.090, blue: 0.106)
        /// #24242A — recessed controls (dial tracks, dividers).
        static let chrome700 = SwiftUI.Color(red: 0.141, green: 0.141, blue: 0.165)
        /// #37373F — lightest chrome (ghost-button strokes).
        static let chrome600 = SwiftUI.Color(red: 0.216, green: 0.216, blue: 0.247)
        /// Pure white — primary text and highest-contrast overlay elements.
        static let textPrimary = SwiftUI.Color.white
        /// White at 60% — secondary text over chrome or video.
        static let textSecondary = SwiftUI.Color.white.opacity(0.6)
        /// #FFB340 — warm amber accent (selected modes, primary actions).
        static let accent = SwiftUI.Color(red: 1.0, green: 0.702, blue: 0.251)
        /// #FF453A — destructive / error surfaces.
        static let danger = SwiftUI.Color(red: 1.0, green: 0.271, blue: 0.227)
        /// #FF3B30 — recording indicator red (shutter, elapsed dot).
        static let recordingRed = SwiftUI.Color(red: 1.0, green: 0.231, blue: 0.188)
        /// #32D74B — success / confirmation surfaces.
        static let success = SwiftUI.Color(red: 0.196, green: 0.843, blue: 0.294)
    }

    // MARK: Spacing scale

    /// Spacing scale: 4 / 8 / 12 / 16 / 24 / 32.
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: Corner radii

    /// Corner radii: 12 (chips/controls), 20 (large cards), 999 (pill).
    enum Radius {
        static let s: CGFloat = 12
        static let m: CGFloat = 20
        static let pill: CGFloat = 999
    }

    // MARK: Typography

    /// Typography presets on the system font stack (no third-party fonts).
    enum Typography {
        /// HUD caption — monospaced-feel micro text for chips, labels, readouts.
        static let hud = Font.system(.caption2, design: .monospaced).weight(.semibold)
        /// Section / screen titles.
        static let title = Font.system(.title3).weight(.semibold)
        /// Numeric values (elapsed time, zoom factor) — tabular digits.
        static let value = Font.system(.body).weight(.semibold).monospacedDigit()
        /// Running body copy (gate messages, explanations).
        static let body = Font.system(.callout)
    }

    // MARK: Opacity levels

    /// Opacity levels for viewfinder overlays sitting on top of live video.
    enum Opacity {
        /// Edge scrims that fade chrome into the video.
        static let scrim: CGFloat = 0.55
        /// Scrimmed chip / bar fills.
        static let chipBackground: CGFloat = 0.72
        /// Rule-of-thirds grid hairlines.
        static let hairline: CGFloat = 0.3
        /// Disabled or undisclosed content.
        static let dimmed: CGFloat = 0.35
        /// Recording pulse ring bounds.
        static let pulseMin: CGFloat = 0.35
        static let pulseMax: CGFloat = 0.9
    }

    // MARK: Shadows

    /// Shadow token: color, radius, and y-offset for one shadow style.
    struct Shadow {
        let color: SwiftUI.Color
        let radius: CGFloat
        let y: CGFloat

        /// Soft grounding shadow for floating controls (dial handle, shutter).
        static let overlay = Shadow(
            color: SwiftUI.Color.black.opacity(0.4),
            radius: 8,
            y: 2
        )
    }

    // MARK: Animation

    /// Motion constants (stored as plain numbers; animations are constructed at
    /// the use site to stay concurrency-safe under Swift 6).
    enum Animation {
        /// Recording pulse cycle.
        static let pulseDuration: TimeInterval = 1.0
        /// Press-in and selection springs.
        static let pressResponse: CGFloat = 0.3
        static let pressDamping: CGFloat = 0.7
        /// Snap-to-point settle.
        static let snapDuration: TimeInterval = 0.25
        /// HUD label fade in/out.
        static let labelFade: TimeInterval = 0.25
        /// How long a HUD label stays visible before auto-fading.
        static let labelHold: TimeInterval = 1.2
    }

    // MARK: Component dimensions

    /// Control dimensions. Scalars like scales/epsilon live here too so
    /// components stay free of magic numbers.
    enum Dimension {
        // Shutter button
        static let shutterDiameter: CGFloat = 72
        static let shutterInner: CGFloat = 58
        static let shutterRecordingSquare: CGFloat = 30
        static let recordCorner: CGFloat = 10
        static let shutterRingWidth: CGFloat = 4
        static let shutterPressScale: CGFloat = 0.9
        static let pulseScaleMax: CGFloat = 1.18
        static let recDotSize: CGFloat = 8

        // Mode switch bar
        static let modeBarHeight: CGFloat = 48
        static let modeBarIcon: CGFloat = 16
        static let modeDragMinDistance: CGFloat = 12

        // Vertical control dial
        static let dialLength: CGFloat = 176
        static let dialWidth: CGFloat = 40
        static let dialHandle: CGFloat = 36
        static let dialHandleIcon: CGFloat = 15
        static let dialHandleStroke: CGFloat = 1.5
        static let dialTrackWidth: CGFloat = 4
        static let dialSnapThreshold: CGFloat = 0.05
        static let dialHandleDragScale: CGFloat = 1.08
        static let dialAccessibilityStep: CGFloat = 0.05

        // HUD chips / settings pills
        static let chipHeight: CGFloat = 36
        static let chipIconSize: CGFloat = 15
        static let chipChevronSize: CGFloat = 12
        static let chipHPadding: CGFloat = 12

        // Zoom dial
        static let zoomStripHeight: CGFloat = 36
        static let zoomSelectEpsilon: CGFloat = 0.02
        static let digitalStrokeWidth: CGFloat = 1

        // Permission gate
        static let gateIconCircle: CGFloat = 84
        static let gateIconSize: CGFloat = 34
        static let primaryButtonHeight: CGFloat = 52

        // Viewfinder overlay
        static let hairlineWidth: CGFloat = 0.5
        static let scrimHeight: CGFloat = 140
    }

    // MARK: Utilities

    /// Clamps a normalized value into 0...1.
    static func clamp01(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }

    /// Clamps a value into an arbitrary range.
    static func clamp(_ value: CGFloat, _ range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
