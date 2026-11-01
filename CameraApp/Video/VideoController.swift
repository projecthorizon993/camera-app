import Foundation

@MainActor
final class VideoController {
    private let service: any CameraServiceProtocol
    private let recorder: VideoRecorder
    private let state: RecordingHUDState

    init(service: any CameraServiceProtocol, recorder: VideoRecorder, state: RecordingHUDState) {
        self.service = service
        self.recorder = recorder
        self.state = state
    }

    func toggle() async {
        if state.isRecording {
            await stop()
        } else {
            await start()
        }
    }

    func start() async {
        // Default v1 config: HEVC, highest supported resolution, 30 fps.
        let resolution: VideoResolution = service.capabilities.supportedResolutions.contains(.uhd4K) ? .uhd4K : .hd1080
        let config = VideoRecordingConfig(
            codec: .hevc,
            resolution: resolution,
            fps: 30,
            bitrateMbps: BitrateLadder.presets(for: resolution, fps: 30, codec: .hevc).first ?? 36,
            withAudio: true,
            losslessAudio: false
        )

        switch StoragePreflight.check(bitrateMbps: config.bitrateMbps) {
        case .failure:
            state.setError("Insufficient storage")
            return
        case .success:
            break
        }

        do {
            try service.startVideoRecording(config)
            state.lastConfig = config
            state.startRecording()
        } catch {
            state.setError(String(describing: error))
        }
    }

    func stop() async {
        let url = await service.stopVideoRecording()
        _ = url
        state.stopRecording()
    }
}
