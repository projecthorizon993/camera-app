import Foundation

// MARK: - FeatureFlags
//
// Runtime feature flags for gating v2+ functionality. Add new flags here as
// features are developed; each flag defaults to false (off) so new features
// are opt-in until explicitly enabled.
//
// Flags are intentionally simple (static let Bool) so they can be toggled
// remotely or via UserDefaults in a future release without code changes.

enum FeatureFlags {
    /// Pro mode: manual controls, color looks, RAW+ processing pipeline.
    static let proMode = true

    /// Watermark stage: EXIF signature bar applied to JPEG/HEIF saves.
    static let watermarkStage = true

    /// Super-res engine: Lanczos + unsharp upscale (exposed off-pipeline).
    static let superResStage = true

    /// Night mode: software median-stack capture via T12 merger.
    static let nightMode = true

    /// Timelapse mode: intervalometer + HEVC assembly.
    static let timelapseMode = true

    /// Lens correction: per-lens Brown-Conrady warp (T13).
    static let lensCorrectionStage = true

    /// V2: UI themes (light/dark/system).
    static let v2Themes = false

    /// V2: GPS/location tagging in EXIF.
    static let v2Geotagging = false

    /// V2: Custom LUT import for looks.
    static let v2CustomLuts = false

    /// V2: Manual focus peaking and zebras overlay.
    static let v2AssistOverlays = false

    /// V2: Bracketing HDR merge.
    static let v2HdrMerge = false
}

// MARK: - CapturePreset
//
// Predefined capture configurations for quick setup. Each preset bundles
// format, flash, and pro mode settings for common shooting scenarios.

enum CapturePreset: String, CaseIterable, Sendable {
    case auto   = "Auto"
    case pro    = "Pro"
    case portrait = "Portrait"
    case landscape = "Landscape"
    case night = "Night"
    case video = "Video"

    var format: CaptureFormat {
        switch self {
        case .auto: return .jpeg
        case .pro: return .heif
        case .portrait: return .heif
        case .landscape: return .heif
        case .night: return .jpeg
        case .video: return .heif
        }
    }

    var flashMode: FlashMode {
        switch self {
        case .auto: return .auto
        case .pro: return .off
        case .portrait: return .off
        case .landscape: return .off
        case .night: return .off
        case .video: return .off
        }
    }

    var proMode: Bool {
        switch self {
        case .auto: return false
        case .pro: return true
        case .portrait: return true
        case .landscape: return true
        case .night: return false
        case .video: return false
        }
    }

    var selectedLook: LookID {
        switch self {
        case .auto: return .none
        case .pro: return .authentic
        case .portrait: return .natural
        case .landscape: return .vibrant
        case .night: return .none
        case .video: return .none
        }
    }
}

// MARK: - UserDefaults persistence keys

enum SettingsKeys {
    static let proMode = "settings.proMode"
    static let selectedLook = "settings.selectedLook"
    static let capturePreset = "settings.capturePreset"
    static let watermarkEnabled = "settings.watermarkEnabled"
    static let lensCorrectionEnabled = "settings.lensCorrectionEnabled"
    static let showWatermarkPreview = "settings.showWatermarkPreview"
}
