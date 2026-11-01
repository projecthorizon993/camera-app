import Foundation

enum BitrateLadder {
    static func presets(for resolution: VideoResolution, fps: Int, codec: VideoCodec) -> [Int] {
        let table: [Int]
        switch resolution {
        case .hd1080:
            if fps <= 30 { table = [16, 24, 36] }
            else if fps <= 60 { table = [24, 36, 50] }
            else if fps <= 120 { table = [48, 72, 100] }
            else { table = [72, 100, 130] }
        case .uhd4K:
            if fps <= 30 { table = [36, 50, 70] }
            else { table = [72, 100, 130] }
        }
        if codec == .h264 {
            return Array(table.prefix(2))
        }
        return table
    }

    static func bytesPerMinute(bitrateMbps: Int) -> Int64 {
        let base = Int64(bitrateMbps) * 60 * 1_000_000 / 8
        return Int64(Double(base) * 1.08)
    }
}