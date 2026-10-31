import Foundation

// Pure-Foundation video recording models.

/// Video encoder family. `proRes422` is capability-gated at runtime.
enum VideoCodec: String, Sendable, CaseIterable { case h264, hevc, proRes422 }

/// Recording resolutions offered by the mode picker.
enum VideoResolution: String, Sendable { case hd1080, uhd4K }

/// Full configuration for one video recording session.
struct VideoRecordingConfig: Sendable {
    let codec: VideoCodec
    let resolution: VideoResolution
    let fps: Int
    let bitrateMbps: Int
    let withAudio: Bool
    let losslessAudio: Bool
}
