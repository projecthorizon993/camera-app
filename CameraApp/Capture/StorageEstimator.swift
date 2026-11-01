import Foundation

// Task 11 — per-shot payload estimates for the viewfinder's "shots remaining"
// readout. Pure Foundation, unit-testable; no hardware, no AVFoundation.
//
// These are documented APPROXIMATIONS (sensor data + codec variance) for a
// 12 MP A13-class back camera. They exist to surface "roughly how many shots
// fit" in the UI — never as promises.

enum StorageEstimator {

    /// Approximate per-shot byte cost.
    ///   .jpeg ≈ 4 MB, .heif ≈ 2 MB, .dng ≈ 14 MB (Bayer, unprocessed).
    static func estimatePerShotBytes(_ format: CaptureFormat) -> Int64 {
        switch format {
        case .jpeg: return 4 * 1024 * 1024
        case .heif: return 2 * 1024 * 1024
        case .dng:  return 14 * 1024 * 1024
        }
    }

    /// `floor(freeBytes / perShot)`; 0 when `freeBytes <= 0`.
    static func remainingShots(freeBytes: Int64, for format: CaptureFormat) -> Int {
        guard freeBytes > 0 else { return 0 }
        let perShot = estimatePerShotBytes(format)
        guard perShot > 0 else { return 0 }
        return Int(freeBytes / perShot)
    }

    /// Free space of the app's Documents volume via
    /// `FileManager.attributesOfFileSystem(forPath:)` → `.systemFreeSize`.
    /// Returns nil when the probe fails. Callers run this OFF the main actor.
    nonisolated static func freeBytes() -> Int64? {
        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path
            ?? NSHomeDirectory()
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: path)
            if let size = attrs[.systemFreeSize] as? NSNumber {
                return size.int64Value
            }
            if let size = attrs[.systemFreeSize] as? Int64 {
                return size
            }
            return nil
        } catch {
            return nil
        }
    }
}