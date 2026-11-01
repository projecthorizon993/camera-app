import Foundation
import CoreGraphics
import CoreImage

// Task 11 — develop preview helper for DNG byte streams.
//
// Develops a DNG byte stream into a display CGImage for review/preview using
// `CIImage(data:)` + a per-call `CIContext`. CoreImage applies the DNG's
// embedded OpcodeList2/3 corrections by default, which is exactly the v1
// behavior we want. `CIRAWFilter` tuning (warm-up, neutral ratings) is
// deliberately OUT of scope: Task 15's gallery owns that integration on top
// of this helper.

enum RawDeveloperError: Error {
    case invalidData
    case developmentFailed
}

enum RawDeveloper {

    /// Develops a DNG byte stream into a display `CGImage`.
    ///
    /// Concurrency: `nonisolated async`; the body hops with `Task.detached`
    /// (under SE-0461 a plain nonisolated async runs on the caller's actor),
    /// and returns a Sendable `CGImage` only.
    nonisolated static func previewCGImage(fromDNG data: Data) async throws -> CGImage {
        guard !data.isEmpty else { throw RawDeveloperError.invalidData }
        return try await Task.detached(priority: .userInitiated) {
            guard let ciImage = CIImage(data: data) else {
                throw RawDeveloperError.invalidData
            }
            let context = CIContext()
            guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
                throw RawDeveloperError.developmentFailed
            }
            return cgImage
        }.value
    }
}