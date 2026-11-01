import XCTest
import CoreVideo
@testable import CameraApp

final class LookTests: XCTestCase {

    // MARK: Recipe table

    func testClassicBWSaturationIsZero() {
        XCTAssertEqual(LookRecipes.recipe(for: .classicBW).saturation, 0.0, accuracy: 0)
    }

    func testVibrantMoreSaturatedThanNatural() {
        XCTAssertGreaterThan(LookRecipes.recipe(for: .vibrant).saturation,
                             LookRecipes.recipe(for: .natural).saturation)
    }

    func testEveryRecipeWithinDocumentedRanges() {
        for id in LookID.allCases {
            let r = LookRecipes.recipe(for: id)
            XCTAssertGreaterThanOrEqual(r.lift, -0.1)
            XCTAssertLessThanOrEqual(r.lift, 0.1)
            XCTAssertGreaterThanOrEqual(r.gamma, 0.8)
            XCTAssertLessThanOrEqual(r.gamma, 1.25)
            XCTAssertGreaterThanOrEqual(r.gain, 0.9)
            XCTAssertLessThanOrEqual(r.gain, 1.10)
            XCTAssertGreaterThanOrEqual(r.saturation, 0.0)
            XCTAssertLessThanOrEqual(r.saturation, 1.35)
            XCTAssertGreaterThanOrEqual(r.warmth, -0.05)
            XCTAssertLessThanOrEqual(r.warmth, 0.05)
            XCTAssertGreaterThanOrEqual(r.tint, -0.04)
            XCTAssertLessThanOrEqual(r.tint, 0.04)
            XCTAssertGreaterThanOrEqual(r.contrastS, 0.9)
            XCTAssertLessThanOrEqual(r.contrastS, 1.3)
            XCTAssertGreaterThanOrEqual(r.fade, 0.0)
            XCTAssertLessThanOrEqual(r.fade, 0.08)
        }
    }

    // MARK: Cube shape

    func testCubeShapeAndAlpha() {
        let cube = LookRecipes.cubeData()
        XCTAssertEqual(cube.count, 32 * 32 * 32 * 4)
        var i = 3
        while i < cube.count {
            XCTAssertEqual(cube[i], 1.0, accuracy: 0)
            i += 4
        }
    }

    func testCubeEndpointsForEveryRecipe() {
        let n = 32
        for id in LookID.allCases {
            let cube = LookRecipes.cubeData(for: id)
            // idx(0,0,0)
            XCTAssertEqual(cube[0], 0.0, accuracy: 1e-6, "look \(id) black r")
            XCTAssertEqual(cube[1], 0.0, accuracy: 1e-6, "look \(id) black g")
            XCTAssertEqual(cube[2], 0.0, accuracy: 1e-6, "look \(id) black b")
            // idx(31,31,31)
            let last = (n * n * n - 1) * 4
            XCTAssertEqual(cube[last], 1.0, accuracy: 1e-6, "look \(id) white r")
            XCTAssertEqual(cube[last + 1], 1.0, accuracy: 1e-6, "look \(id) white g")
            XCTAssertEqual(cube[last + 2], 1.0, accuracy: 1e-6, "look \(id) white b")
        }
    }

    // MARK: Monotonic sanity

    func testVibrantMonotonicRAxis() {
        let recipe = LookRecipes.recipe(for: .vibrant)
        var prev: Float = -1
        for r in [Float(0), 0.25, 0.5, 0.75, 1.0] {
            let (ro, _, _) = LookRecipes.apply(recipe: recipe, r: r, g: 0.5, b: 0.5)
            XCTAssertGreaterThanOrEqual(ro, prev)
            prev = ro
        }
    }

    // MARK: availableLooks

    func testAvailableLooksEqualsAllCases() {
        let engine = LookEngine()
        XCTAssertEqual(engine.availableLooks, LookID.allCases)
    }

    // MARK: Fast paths

    private func makeBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard status == kCVReturnSuccess, let b = buffer else { throw NSError(domain: "t", code: 1) }
        return b
    }

    func testFastPathPassthrough() async throws {
        let buf = try makeBuffer()
        let engine = LookEngine()
        let out1 = try await engine.apply(buf, look: .none, strength: 0.5)
        XCTAssertTrue(out1 === buf)
        let out2 = try await engine.apply(buf, look: .vibrant, strength: 0)
        XCTAssertTrue(out2 === buf)
    }
}
