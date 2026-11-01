import Foundation
import CoreVideo
import ImageIO

// MARK: - ProcessedExport

/// Result of one processed export (unit-testable value).
struct ProcessedExport: Sendable {
    let photo: CapturedPhoto        // what to save (input identity when .dng or fallback)
    let stagesApplied: [PipelineStage]
    let fellBack: Bool              // true when processing failed → original passed through
}

// MARK: - ExportProcessor

final class ExportProcessor: @unchecked Sendable {
    private let pipeline: ProcessingPipelineProtocol

    /// super-res is deliberately NOT consulted in v1 (ruling in brief header).
    init(pipeline: ProcessingPipelineProtocol) {
        self.pipeline = pipeline
    }

    /// NEVER throws; never loses the shot: any decode/run/encode failure
    /// returns ProcessedExport(photo: input, stagesApplied: [], fellBack: true).
    /// .dng and empty-data inputs short-circuit to (input, [], false).
    func process(_ photo: CapturedPhoto, plan: ExportPlan) async -> ProcessedExport {
        // Whole body hops off the caller's actor (SE-0461): decode/run/encode
        // are sync CPU bursts; pipeline.run hops internally via @concurrent.
        await Task.detached(priority: .userInitiated) { [self, photo, plan] in
            // Short-circuits (byte-for-byte / no-data).
            if photo.format == .dng || photo.data.isEmpty {
                return ProcessedExport(photo: photo, stagesApplied: [], fellBack: false)
            }

            let stages = ExportPlanner.stages(plan: plan)
            do {
                let buffer = try PixelBufferDecoding.pixelBuffer(from: photo.data)
                let processedBuffer: CVPixelBuffer
                if stages.isEmpty {
                    processedBuffer = buffer
                } else {
                    processedBuffer = try await self.pipeline.run(
                        buffer,
                        stages: stages,
                        context: ProcessingContext(
                            orientation: .portrait,
                            exif: photo.exifSummary,
                            strength: 1.0,
                            metadata: [:]
                        )
                    )
                }

                let source = CGImageSourceCreateWithData(photo.data as CFData, nil)
                let data: Data
                switch photo.format {
                case .jpeg:
                    data = try PixelBufferDecoding.jpegData(from: processedBuffer, sourceMetadata: source)
                case .heif:
                    data = try PixelBufferDecoding.heifData(from: processedBuffer, sourceMetadata: source)
                case .dng:
                    data = photo.data
                }

                let resultPhoto = CapturedPhoto(
                    data: data,
                    format: photo.format,
                    width: photo.width,
                    height: photo.height,
                    exifSummary: photo.exifSummary
                )
                return ProcessedExport(photo: resultPhoto, stagesApplied: stages, fellBack: false)
            } catch {
                return ProcessedExport(photo: photo, stagesApplied: [], fellBack: true)
            }
        }.value
    }
}