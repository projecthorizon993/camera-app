import Foundation
import Observation

// Task 18 — Night mode capture controller.
//
// Night is a SOFTWARE stack: N sequential captures at stepped exposures,
// fused via `MergedCaptureWriter` (`MergeMode.nightStack`, median, no optical
// flow). It never uses `captureBracket` (hardware bracket) — the two are
// mutually exclusive, mirroring the RAW-exclusion rule.
//
// NIGHT = PORTRAIT-ONLY (M2 ruling): every frame is captured with
// `.portrait` orientation and the merge is requested with `.portrait`.
//
// Concurrency: @MainActor @Observable owns UI state; capture/merge/save hop
// off-main via Task.detached at each boundary (SE-0461).

enum NightPhase: Sendable, Equatable {
    case idle
    case capturing(framesDone: Int, total: Int)
    case merging
    case failed(String)
    case done
}

enum NightError: Error, Sendable {
    case serviceUnavailable
    case captureFailed(String)
    case mergeFailed
}

@MainActor
@Observable
final class NightCaptureController {

    let service: any CameraServiceProtocol

    private(set) var phase: NightPhase = .idle
    private(set) var lastMessage: String?

    // MARK: - Dependencies (optional, with safe defaults)

    private let permissionService: (any CameraPermissionServiceProtocol)?
    private let saveAsset: PhotoSaver.SaveAsset

    private var merger: MergedCaptureWriter = MergedCaptureWriter()
    private var cancelled: Bool = false

    init(
        service: any CameraServiceProtocol,
        permissionService: (any CameraPermissionServiceProtocol)? = nil,
        saveAsset: @escaping PhotoSaver.SaveAsset = { @Sendable photo in
            let uti: String
            switch photo.format {
            case .jpeg: uti = UTType.jpeg.identifier
            case .heif: uti = UTType.heif.identifier
            case .dng:  uti = "com.adobe.raw-image"
            }
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = uti
                request.addResource(with: .photo, data: photo.data, options: options)
            }
        }
    ) {
        self.service = service
        self.permissionService = permissionService
        self.saveAsset = saveAsset
    }

    func cancel() {
        cancelled = true
    }

    func capture() async {
        cancelled = false
        phase = .idle
        lastMessage = nil

        // Basis: CameraServiceProtocol exposes no auto-exposure-basis getter
        // (`captureExposureBasisLocked` is internal to CameraService), so v1
        // uses a neutral basis. The exposure ladder still runs and is capped
        // by the device maximum. Deviation documented in the task report.
        let basisSeconds: Double = 1.0 / 30.0
        let basisISO: Float = service.supportedManualRanges.iso.lowerBound
        let maxSeconds: Double = service.capabilities.maxShutterSeconds

        let plan = NightExposurePlanner.plan(
            basisSeconds: basisSeconds,
            maxSeconds: maxSeconds,
            frameCount: 8
        )

        var frames: [CapturedPhoto] = []
        frames.reserveCapacity(plan.frameCount)

        do {
            // Lock to the basis exposure first (soft, sequential — never
            // `captureBracket`).
            try service.applyManualConfig(ManualCameraConfig(
                iso: basisISO,
                exposureDurationSeconds: basisSeconds,
                lensPosition: nil,
                kelvin: nil,
                tint: nil
            ))

            phase = .capturing(framesDone: 0, total: plan.frameCount)

            for index in 0..<plan.frameCount {
                if cancelled {
                    throw NightError.captureFailed("Cancelled")
                }
                let duration = plan.exposureSeconds[index]
                do {
                    try service.applyManualConfig(ManualCameraConfig(
                        iso: basisISO,
                        exposureDurationSeconds: duration,
                        lensPosition: nil,
                        kelvin: nil,
                        tint: nil
                    ))
                } catch {
                    throw NightError.captureFailed("Could not set exposure: \(error.localizedDescription)")
                }

                let settings = PhotoCaptureSettings(
                    format: .jpeg,
                    flash: .off,
                    timerSeconds: 0,
                    orientation: .portrait
                )
                let photo: CapturedPhoto
                do {
                    photo = try await service.capturePhoto(settings)
                } catch {
                    throw NightError.captureFailed("Frame \(index + 1) failed: \(error.localizedDescription)")
                }
                frames.append(photo)
                phase = .capturing(framesDone: frames.count, total: plan.frameCount)

                if index < plan.frameCount - 1 && plan.gapSeconds > 0 {
                    try await Task.sleep(nanoseconds: UInt64(plan.gapSeconds * 1_000_000_000))
                }
            }

            // Restore auto exposure regardless of downstream outcome.
            try? service.resetToAuto()

            if cancelled {
                phase = .failed("Cancelled")
                lastMessage = "Cancelled"
                return
            }

            phase = .merging
            let merged: CapturedPhoto
            do {
                merged = try await merger.mergedPhoto(frames: frames, mode: .nightStack)
            } catch {
                throw NightError.mergeFailed
            }

            // Save via the same saver path the capture flow uses.
            let outcome: PhotoSaveOutcome
            if let saver = permissionService.map({ PhotoSaver(permissionService: $0, saveAsset: saveAsset) }) {
                let capturedSaver = saver
                outcome = await Task.detached(priority: .userInitiated) {
                    await capturedSaver.save(merged)
                }.value
            } else {
                let capturedSaveAsset = saveAsset
                outcome = await Task.detached(priority: .userInitiated) {
                    do {
                        try await capturedSaveAsset(merged)
                        return .saved
                    } catch {
                        return .failed("Could not save to Photos: \(error.localizedDescription)")
                    }
                }.value
            }

            switch outcome {
            case .saved:
                phase = .done
                lastMessage = "Saved"
            case .needsPermission:
                phase = .failed("Photo library permission required.")
                lastMessage = "Needs permission"
            case .failed(let reason):
                phase = .failed(reason)
                lastMessage = reason
            }
        } catch let error as NightError {
            try? service.resetToAuto()
            switch error {
            case .serviceUnavailable:
                phase = .failed("Camera service unavailable.")
            case .captureFailed(let detail):
                phase = .failed(detail)
            case .mergeFailed:
                phase = .failed("Merge failed.")
            }
            lastMessage = phaseMessage(phase)
        } catch {
            try? service.resetToAuto()
            phase = .failed(error.localizedDescription)
            lastMessage = error.localizedDescription
        }
    }

    private func phaseMessage(_ phase: NightPhase) -> String? {
        if case .failed(let message) = phase { return message }
        return nil
    }
}

// MARK: - Imports needed for the default save closure

import Photos
import UniformTypeIdentifiers
