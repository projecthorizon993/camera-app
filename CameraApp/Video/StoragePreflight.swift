import Foundation

enum StoragePreflight {
    static func check(bitrateMbps: Int, minimumMinutes: Int = 5) -> Result<Void, VideoError> {
        let needed = BitrateLadder.bytesPerMinute(bitrateMbps: bitrateMbps) * Int64(minimumMinutes)
        guard let free = StorageEstimator.freeBytes(), free >= needed else {
            return .failure(.storageInsufficient)
        }
        return .success(())
    }
}
