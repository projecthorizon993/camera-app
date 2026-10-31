import Foundation

// Pure-Foundation capability model. `CGFloat` is provided by CoreFoundation,
// which Foundation re-exports on Darwin (iOS 17+ SDKs) — no CoreGraphics import
// is required here, keeping this file Foundation-only per plan ruling.

/// What the current device's camera system can do. Populated from runtime
/// queries by the camera service (Task 4); used to capability-gate all
/// device-specific UI before/while the session runs.
struct CameraCapabilities: Sendable {
    let hasUltraWide: Bool
    let hasTele: Bool
    let teleFactor: CGFloat
    let zoomRange: ClosedRange<CGFloat>
    let maxShutterSeconds: Double
    let isoRange: ClosedRange<Float>
    let supportsRAW: Bool
    let maxHardwareBracketCount: Int
    let supportsProRes: Bool
    let supports10BitHDR: Bool
    let supports48MP: Bool
    let supportedResolutions: [VideoResolution]
    let maxFPS: Int

    /// Sensible A13 (iPhone 11 Pro Max-class) defaults used as the pre-session
    /// value and as a fallback when runtime queries fail. Pro-style features
    /// (ProRes / 10-bit HDR / 48MP) are off — they are capability-gated.
    static let iPhone11ProMaxFallback: CameraCapabilities = CameraCapabilities(
        hasUltraWide: true,
        hasTele: true,
        teleFactor: 2,
        zoomRange: 0.5...10,
        maxShutterSeconds: 1.0,
        isoRange: 34...3456,
        supportsRAW: true,
        maxHardwareBracketCount: 3,
        supportsProRes: false,
        supports10BitHDR: false,
        supports48MP: false,
        supportedResolutions: [.hd1080, .uhd4K],
        maxFPS: 240
    )
}
