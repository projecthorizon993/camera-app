import Foundation

// MARK: - ExportPlan

/// Per-export switch bundle (NOT frozen models — app-internal feature-level
/// state; user-toggle plumbing is a follow-up, defaults documented).
struct ExportPlan: Sendable, Equatable {
    var format: CaptureFormat
    var wantsCorrection = true   // objective correction is ON by default
    var wantsLook = true         // harmless default: LookEngine no-ops on .none
    var wantsWatermark = true    // v1 default ON — visible feature; future UI opts out
}

// MARK: - ExportPlanner

enum ExportPlanner {
    /// Stage set for one save. Rules:
    ///   • format `.dng` → [] ALWAYS (byte-for-byte ruling; flags ignored).
    ///   • else: include .lensCorrection iff correctionEnabled,
    ///     .look iff lookEnabled, .watermark iff watermarkEnabled AND
    ///     WatermarkPlanner.shouldApply(format:) (belt-and-braces with the
    ///     T16 policy helper — the caller-side skip enforcement).
    ///   • The returned array is in a canonical order (enum order), never
    ///     call order.
    static func stages(plan: ExportPlan) -> [PipelineStage] {
        // DNG is never touched (byte-for-byte ruling).
        if plan.format == .dng { return [] }

        var selected: [PipelineStage] = []
        for stage in PipelineStage.allCases {
            switch stage {
            case .lensCorrection:
                if plan.wantsCorrection { selected.append(stage) }
            case .look:
                if plan.wantsLook { selected.append(stage) }
            case .watermark:
                if plan.wantsWatermark && WatermarkPlanner.shouldApply(format: plan.format) {
                    selected.append(stage)
                }
            default:
                // .develop / .export have no implementations in v1; never request.
                break
            }
        }
        return selected
    }
}