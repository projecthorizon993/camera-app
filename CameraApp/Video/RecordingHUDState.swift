import Foundation
import SwiftUI

@MainActor
@Observable
final class RecordingHUDState {
    private(set) var isRecording: Bool = false
    private(set) var elapsedSeconds: Double = 0
    var lastConfig: VideoRecordingConfig?
    private(set) var lastError: String?
    private(set) var statusText: String?

    private var startUptime: Double?
    private var tickerTask: Task<Void, Never>?

    var durationText: String {
        let total = Int(elapsedSeconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    func startRecording() {
        isRecording = true
        elapsedSeconds = 0
        startUptime = ProcessInfo.processInfo.systemUptime
        statusText = nil
        tickerTask?.cancel()
        tickerTask = Task { @MainActor in
            while !Task.isCancelled && self.isRecording {
                if let start = self.startUptime {
                    self.elapsedSeconds = ProcessInfo.processInfo.systemUptime - start
                }
                try? await Task.sleep(for: .seconds(0.25))
            }
        }
    }

    func stopRecording() {
        tickerTask?.cancel()
        tickerTask = nil
        isRecording = false
        statusText = "Saved Video"
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if self.statusText == "Saved Video" {
                self.statusText = nil
            }
        }
    }

    func setError(_ message: String?) {
        lastError = message
    }
}
