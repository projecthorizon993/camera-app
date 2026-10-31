import Foundation

// Pure-Foundation processing-pipeline models. The pipeline protocols that
// consume these live in Core/Contracts.swift (they are hardware-bound).

/// Ordered stages of the processing pipeline.
enum PipelineStage: String, Sendable, CaseIterable {
    case develop, lensCorrection, look, watermark, export
}

/// Per-run context handed to every pipeline stage.
struct ProcessingContext: Sendable {
    var orientation: PortraitLandscape
    var exif: ExifSummary?
    var strength: Double          // 0...1 global blend for optional stages
    var metadata: [String: String]
}

/// Which color-look is active. `.none` bypasses the look stage.
enum LookID: String, Sendable, CaseIterable { case none, authentic, vibrant, natural, classicBW }

/// Lens-correction operating mode.
enum LensCorrectionMode: String, Sendable, CaseIterable { case auto, profile, off }
