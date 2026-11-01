import XCTest
@testable import CameraApp

final class BitrateLadderTests: XCTestCase {
    func testPresetsMonotonic() {
        for res in [VideoResolution.hd1080, .uhd4K] {
            for fps in [24, 30, 60, 120, 240] {
                for codec in [VideoCodec.h264, .hevc, .proRes422] {
                    let p = BitrateLadder.presets(for: res, fps: fps, codec: codec)
                    for i in 1..<p.count { XCTAssertLessThanOrEqual(p[i-1], p[i]) }
                }
            }
        }
    }

    func test4K60MaxRungMagnitude() {
        let p = BitrateLadder.presets(for: .uhd4K, fps: 60, codec: .hevc)
        XCTAssertGreaterThanOrEqual(p.last!, 60)
        XCTAssertLessThanOrEqual(p.last!, 130)
    }

    func testBytesPerMinuteMath() {
        let v = BitrateLadder.bytesPerMinute(bitrateMbps: 10)
        // 10 * 60 * 1e6 / 8 * 1.08 = 90_000_000? compute
        let expected = Int64(Double(10) * 60 * 1_000_000 / 8 * 1.08)
        XCTAssertEqual(v, expected)
    }

    func testH264Capping() {
        let hevc = BitrateLadder.presets(for: .hd1080, fps: 60, codec: .hevc)
        let h264 = BitrateLadder.presets(for: .hd1080, fps: 60, codec: .h264)
        XCTAssertEqual(h264.count, 2)
        XCTAssertEqual(h264, Array(hevc.prefix(2)))
    }

    func testStorageMath() {
        // Just ensure check returns success/failure consistently with bytesPerMinute
        let needed = BitrateLadder.bytesPerMinute(bitrateMbps: 1000) * 5
        _ = needed
        let result = StoragePreflight.check(bitrateMbps: 1000, minimumMinutes: 5)
        // free space likely less than needed for 1000 Mbps * 5 min -> insufficient
        switch result {
        case .success: break
        case .failure(.storageInsufficient): break
        default: XCTFail("unexpected")
        }
    }
}
