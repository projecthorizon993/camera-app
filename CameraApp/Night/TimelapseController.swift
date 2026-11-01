import Foundation
import Observation

// Task 18 — thin facade over TimelapseRecorder for the UI.

enum TimelapsePhase: Sendable, Equatable {
    case idle
    case running(framesDone: Int, target: Int)
    case failed(String)
    case done(URL)
}

@MainActor
@Observable
final class TimelapseController {

    private(set) var phase: TimelapsePhase = .idle

    let service: any CameraServiceProtocol
    var captureFormat: CaptureFormat = .jpeg

    private var recorder: TimelapseRecorder?

    init(service: any CameraServiceProtocol) {
        self.service = service
    }

    func start(plan: TimelapsePlan) async {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("Timelapse", isDirectory: true)
            .appendingPathComponent(String(Int(Date().timeIntervalSince1970)), isDirectory: true)
        let recorder = TimelapseRecorder(directory: staging)
        self.recorder = recorder

        phase = .running(framesDone: 0, target: plan.targetFrames)

        do {
            let url = try await recorder.record(
                plan: plan,
                capture: { [weak self] in
                    guard let self else { throw TimelapseError.captureFailed("Controller released") }
                    let format: CaptureFormat = (self.captureFormat == .dng) ? .jpeg : self.captureFormat
                    let settings = PhotoCaptureSettings(
                        format: format,
                        flash: .off,
                        timerSeconds: 0,
                        orientation: .portrait
                    )
                    return try await self.service.capturePhoto(settings)
                },
                onProgress: { [weak self] done, total in
                    Task { @MainActor in
                        self?.phase = .running(framesDone: done, target: total)
                    }
                }
            )
            phase = .done(url)
        } catch {
            if case TimelapseError.cancelled = error {
                phase = .idle
            } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func stop() async {
        recorder?.cancel()
    }
}
