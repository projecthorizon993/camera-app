import XCTest
import CoreVideo
@testable import CameraApp

final class BracketEngineTests: XCTestCase {

    // MARK: Planner

    func testEVLaddersMatchSpanTable() {
        // aeb3: 4 EV over 3 frames -> -2,0,+2
        XCTAssertEqual(BracketPlanner.evLadder(depth: .aeb3), [-2.0, 0.0, 2.0])
        // soft5: 6 EV over 5 frames -> -3,-1.5,0,1.5,3
        let l5 = BracketPlanner.evLadder(depth: .soft5)
        XCTAssertEqual(l5.count, 5)
        XCTAssertEqual(l5.first!, -3.0, accuracy: 1e-9)
        XCTAssertEqual(l5.last!, 3.0, accuracy: 1e-9)
        // soft7 / soft9 counts
        XCTAssertEqual(BracketPlanner.evLadder(depth: .soft7).count, 7)
        XCTAssertEqual(BracketPlanner.evLadder(depth: .soft9).count, 9)
    }

    func testMertensWeightMidGrayOutperformsExtremes() {
        let mid  = BracketPlanner.mertensWeight(lightness: 0.5, contrast: 0.5, saturation: 0.5)
        let dark = BracketPlanner.mertensWeight(lightness: 0.0, contrast: 0.5, saturation: 0.5)
        let bright = BracketPlanner.mertensWeight(lightness: 1.0, contrast: 0.5, saturation: 0.5)
        XCTAssertGreaterThan(mid, dark)
        XCTAssertGreaterThan(mid, bright)
        // symmetry around 0.5
        let a = BracketPlanner.mertensWeight(lightness: 0.25, contrast: 0.5, saturation: 0.5)
        let b = BracketPlanner.mertensWeight(lightness: 0.75, contrast: 0.5, saturation: 0.5)
        XCTAssertEqual(a, b, accuracy: 1e-6)
    }

    func testNormalizeSumsToOne() {
        let w: [Float] = [1, 2, 3]
        let n = BracketPlanner.normalize(w)
        let sum = n.reduce(0, +)
        XCTAssertEqual(sum, 1.0, accuracy: 1e-6)
        XCTAssertEqual(n.count, 3)
        XCTAssertEqual(n[0], 1.0/6.0, accuracy: 1e-6)
        XCTAssertEqual(n[1], 2.0/6.0, accuracy: 1e-6)
        XCTAssertEqual(n[2], 3.0/6.0, accuracy: 1e-6)
    }

    func testNormalizeUniformEdgeCase() {
        let n = BracketPlanner.normalize([0, 0, 0])
        XCTAssertEqual(n.count, 3)
        for v in n { XCTAssertEqual(v, 1.0/3.0, accuracy: 1e-6) }
        let empty = BracketPlanner.normalize([])
        XCTAssertTrue(empty.isEmpty)
    }

    func testValidPlansForTwoToNineFrames() {
        for count in 2...9 {
            let plan = BracketPlan(frameCount: count, mode: count % 2 == 0 ? .fusion : .nightStack)
            XCTAssertEqual(plan.frameCount, count)
        }
    }

    // MARK: MotionGuard

    func testMotionGuardIdenticalAligned() {
        let plane = [Float](repeating: 0.5, count: 16)
        XCTAssertEqual(MotionGuard.meanAbsDiff(reference: plane, candidate: plane), 0)
        XCTAssertEqual(MotionGuard.verdict(for: 0), .aligned)
    }

    func testMotionGuardReject() {
        XCTAssertEqual(MotionGuard.verdict(for: 0.11), .reject)
    }

    func testMotionGuardSoft() {
        XCTAssertEqual(MotionGuard.verdict(for: 0.05), .soft)
    }

    func testMotionGuardMeanAbsDiffValue() {
        let ref: [Float] = [0, 0.5, 1.0]
        let cand: [Float] = [0.1, 0.5, 0.9]
        let diff = MotionGuard.meanAbsDiff(reference: ref, candidate: cand)
        XCTAssertEqual(diff, (0.1 + 0 + 0.1) / 3.0, accuracy: 1e-6)
    }

    // MARK: Partial frames

    private func makeBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard status == kCVReturnSuccess, let b = buffer else { throw NSError(domain: "t", code: 1) }
        return b
    }

    func testSingleFramePassthrough() async throws {
        let buf = try makeBuffer()
        let merger = BracketMerger()
        let out = try await merger.merge(frames: [buf], mode: .fusion, orientation: .portrait)
        XCTAssertTrue(out === buf)
    }

    func testTwoFramesProduceBuffer() async throws {
        let b1 = try makeBuffer()
        let b2 = try makeBuffer()
        let merger = BracketMerger()
        let out = try await merger.merge(frames: [b1, b2], mode: .fusion, orientation: .portrait)
        XCTAssertEqual(CVPixelBufferGetWidth(out), 4)
        XCTAssertEqual(CVPixelBufferGetHeight(out), 4)
    }
}
EOF
