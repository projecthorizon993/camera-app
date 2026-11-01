import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import os

enum VideoError: Error, Sendable {
    case writerUnavailable
    case pixelSinkFailed
    case audioSinkFailed
    case storageInsufficient
    case finalizeFailed(reason: String)
}

final class VideoRecorder: @unchecked Sendable {

    nonisolated func startRun(config: VideoRecordingConfig, directory: URL) throws -> RecordingSession {
        Logger.session("video startRun: codec=\(config.codec) resolution=\(config.resolution) fps=\(config.fps) audio=\(config.withAudio)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileName = Self.makeFileName(losslessAudio: config.losslessAudio)
        let url = directory.appendingPathComponent(fileName)

        let fileType: AVFileType = config.losslessAudio ? .mov : .mp4

        guard let writer = try? AVAssetWriter(url: url, fileType: fileType) else {
            throw VideoError.writerUnavailable
        }

        let dims = Self.dimensions(for: config.resolution)
        let bitrate = config.bitrateMbps * 1_000_000

        let codecType: AVVideoCodecType
        switch config.codec {
        case .h264: codecType = .h264
        case .hevc: codecType = .hevc
        case .proRes422: codecType = .proRes422
        }

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
        ]
        if codecType == .h264 || codecType == .hevc {
            // AVVideoProfileLevelHEVCMainAutoLevel does not resolve on this
            // SDK surface; the constant is documented as the string constant
            // "HEVCMainAutoLevel" (every AVVideoProfileLevel* constant is a
            // bare string), so the literal fixes lookup without behavior drift.
            compression[AVVideoProfileLevelKey] = (codecType == .h264) ? AVVideoProfileLevelH264HighAutoLevel : "HEVCMainAutoLevel"
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codecType,
            AVVideoWidthKey: dims.width,
            AVVideoHeightKey: dims.height,
            AVVideoCompressionPropertiesKey: compression,
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        let sourceAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: dims.width,
            kCVPixelBufferHeightKey as String: dims.height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: sourceAttrs
        )

        guard writer.canAdd(videoInput) else { throw VideoError.writerUnavailable }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if config.withAudio {
            let audioSettings: [String: Any]
            if config.losslessAudio {
                audioSettings = [
                    AVFormatIDKey: kAudioFormatAppleLossless,
                    AVSampleRateKey: 48000,
                    AVNumberOfChannelsKey: 2,
                ]
            } else {
                audioSettings = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 192000,
                ]
            }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw VideoError.audioSinkFailed }
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else {
            throw VideoError.writerUnavailable
        }
        writer.startSession(atSourceTime: .zero)

        return RecordingSession(
            url: url,
            writer: writer,
            videoInput: videoInput,
            pixelAdaptor: adaptor,
            audioInput: audioInput,
            fps: config.fps,
            withAudio: config.withAudio
        )
    }

    private static func dimensions(for resolution: VideoResolution) -> (width: Int, height: Int) {
        switch resolution {
        case .hd1080: return (1920, 1080)
        case .uhd4K: return (3840, 2160)
        }
    }

    private static func makeFileName(losslessAudio: Bool) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = formatter.string(from: Date())
        return losslessAudio ? "video_\(stamp).mov" : "video_\(stamp).mp4"
    }
}

final class RecordingSession: @unchecked Sendable {
    let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?
    private let fps: Int

    private let lock = NSLock()
    private var frameIndex: Int64 = 0
    private var finished = false

    init(url: URL, writer: AVAssetWriter, videoInput: AVAssetWriterInput,
         pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor, audioInput: AVAssetWriterInput?,
         fps: Int, withAudio: Bool) {
        self.url = url
        self.writer = writer
        self.videoInput = videoInput
        self.pixelAdaptor = pixelAdaptor
        self.audioInput = audioInput
        self.fps = fps
    }

    nonisolated func appendVideo(_ buffer: CVPixelBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        guard videoInput.isReadyForMoreMediaData else { return }
        let pts = CMTime(value: frameIndex, timescale: CMTimeScale(fps))
        frameIndex += 1
        _ = pixelAdaptor.append(buffer, withPresentationTime: pts)
    }

    nonisolated func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        guard let audioInput, audioInput.isReadyForMoreMediaData else { return }
        _ = audioInput.append(sampleBuffer)
    }

    nonisolated func finish() async -> URL {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                lock.lock()
                if finished {
                    lock.unlock()
                    continuation.resume(returning: url)
                    return
                }
                finished = true
                lock.unlock()

                Logger.session("video finish: \(url.lastPathComponent)")
                videoInput.markAsFinished()
                audioInput?.markAsFinished()

                writer.finishWriting {
                    continuation.resume(returning: self.url)
                }
            }
        }
    }
}
