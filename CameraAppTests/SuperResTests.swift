import XCTest
import CoreVideo
import CoreGraphics
@testable import CameraApp

final class SuperResTests: XCTestCase {

    // MARK: Planner tier table

    func testTier2xUnderCapIsLanczos() {
        XCTAssertEqual(
            SuperResPlanner.tier(inputSize: CGSize(width: 100, height: 100), requestedScale: 2.0),
            .lanZZos2x
        )
    }

    func testTier4097Wide2xPassthrough() {
        XCTAssertEqual(
            SuperResPlanner.tier(inputSize: CGSize(width: 4097, height: 100), requestedScale: 2.0),
            .passthrough
        )
    }

    func testTierCapBoundaryPassthrough() {
        // 2049-wide input at 2x → 4098 output, over cap.
        XCTAssertEqual(
            SuperResPlanner.tier(inputSize: CGSize(width: 2049, height: 100), requestedScale: 2.0),
            .passthrough
        )
        // 2048-wide input at 2x → 4096 output, allowed.
        XCTAssertEqual(
            SuperResPlanner.tier(inputSize: CGSize(width: 2048, height: 100), requestedScale: 2.0),
            .lanZZos2x
        )
    }

    // MARK: Sanitize

    func testSanitize0_9To1() {
        XCTAssertEqual(SuperResPlanner.sanitize(scale: 0.9), 1.0)
    }

    func testSanitizeNaNTo1() {
        XCTAssertEqual(SuperResPlanner.sanitize(scale: .nan), 1.0)
    }

    func testSanitizeInfinityTo1() {
        XCTAssertEqual(SuperResPlanner.sanitize(scale: .infinity), 1.0)
        XCTAssertEqual(SuperResPlanner.sanitize(scale: -.infinity), 1.0)
    }

    func testSanitize1_6To2() {
        XCTAssertEqual(SuperResPlanner.sanitize(scale: 1.6), 2.0)
    }

    func testSanitizeMidpointRoundsUp() {
        XCTAssertEqual(SuperResPlanner.sanitize(scale: 1.5), 2.0)
    }

    // MARK: Engine fast paths

    private func makeBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA, nil, &buffer
        )
        guard status == kCVReturnSuccess, let b = buffer else {
            throw NSError(domain: "SuperResTests", code: 1)
        }
        return b
    }

    func testScaleOneReturnsSameBuffer() async throws {
        let buf = try makeBuffer()
        let engine = SuperResEngine(device: nil)
        let out = try await engine.apply(buf, scale: 1.0)
        XCTAssertTrue(out === buf)
    }

    func testNaNReturnsSameBuffer() async throws {
        let buf = try makeBuffer()
        let engine = SuperResEngine(device: nil)
        let out = try await engine.apply(buf, scale: .nan)
        XCTAssertTrue(out === buf)
    }
}