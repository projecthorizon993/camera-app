import XCTest
import CoreVideo
@testable import CameraApp

// Task 13 — lens-correction engine tests (DNG opcode parsing + profile store +
// engine pass-through paths). Foundation + CoreVideo only; no Metal, no AVFoundation.
//
// Buffer choice mirrors ProcessingPipelineTests: real minimal 4×4 BGRA CVPixelBuffers
// via CVPixelBufferCreate; content is irrelevant, identity is what is asserted.

final class DNGOpcodeTests: XCTestCase {

    // MARK: Byte helpers (big-endian DNG payloads)

    private func uint32BE(_ value: UInt32) -> [UInt8] {
        return [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
    }

    // MARK: DNGOpcodeParser — S15M16 fixed decode

    func testFixedToFloatDecode() {
        // Brief worked vector: raw 0x8001_0000 → int 1, frac 0 → 1.0.
        XCTAssertEqual(DNGOpcodeParser.fixedToFloat(0x8001_0000), 1.0, accuracy: 0.0001)
        // int 2, frac 0.5 → 2.5.
        XCTAssertEqual(DNGOpcodeParser.fixedToFloat(0x8002_8000), 2.5, accuracy: 0.0001)
        // int 0, frac 0 → 0.0.
        XCTAssertEqual(DNGOpcodeParser.fixedToFloat(0x8000_0000), 0.0, accuracy: 0.0001)
    }

    // MARK: DNGOpcodeParser — synthetic OpcodeList2 payload

    func testParseSyntheticOpcodeList2() throws {
        // count = 2
        var bytes: [UInt8] = uint32BE(2)

        // Opcode 1: WarpRectilinear (id = 3). Header: id=3, specVersion=1, flags=0.
        bytes += uint32BE(3) + uint32BE(1) + uint32BE(0)
        // Blob: planeCount = 1, then per-plane 3 abnormal + 2 center S15M16:
        //   k1 = 1.0 (0x8001_0000), k2 = 0.5 (0x8000_8000), k3 = 0.0 (0x8000_0000),
        //   centerX = 1.0 (0x8001_0000), centerY = 0.0 (0x8000_0000)
        bytes += [0x00, 0x00, 0x00, 0x01]
        bytes += [0x80, 0x01, 0x00, 0x00]
        bytes += [0x80, 0x00, 0x80, 0x00]
        bytes += [0x80, 0x00, 0x00, 0x00]
        bytes += [0x80, 0x01, 0x00, 0x00]
        bytes += [0x80, 0x00, 0x00, 0x00]

        // Opcode 2: FixVignetteRadial (id = 4). Header: id=4, specVersion=1, flags=0.
        bytes += uint32BE(4) + uint32BE(1) + uint32BE(0)
        // Blob: centerX = 1.0, centerY = 0.0, gain1 = 2.5, gain2 = 0.5 (S15M16).
        bytes += [0x80, 0x01, 0x00, 0x00]
        bytes += [0x80, 0x00, 0x00, 0x00]
        bytes += [0x80, 0x02, 0x80, 0x00]
        bytes += [0x80, 0x00, 0x80, 0x00]

        let data = Data(bytes)
        let opcodes = try DNGOpcodeParser.parse(data)

        XCTAssertEqual(opcodes.count, 2)
        XCTAssertEqual(opcodes[0].id, 3)
        XCTAssertEqual(opcodes[0].dngSpecVersion, 1)
        XCTAssertEqual(opcodes[0].flags, 0)
        XCTAssertEqual(opcodes[0].params, [1.0, 0.5, 0.0, 1.0, 0.0])
        XCTAssertEqual(opcodes[1].id, 4)
        XCTAssertEqual(opcodes[1].params, [1.0, 0.0, 2.5, 0.5])
    }

    func testParseTruncatedPayloadThrows() {
        // count = 2 but no opcode records follow.
        let data = Data([0x00, 0x00, 0x00, 0x02])
        do {
            _ = try DNGOpcodeParser.parse(data)
            return XCTFail("expected parse to throw .truncated")
        } catch let error as DNGOpcodeError {
            guard case .truncated = error else {
                return XCTFail("unexpected error: \(error)")
            }
        } catch {
            return XCTFail("unexpected error type: \(error)")
        }
    }

    func testParseUnknownOpcodeLengthThrows() throws {
        // Known id (WarpRectilinear = 3) with a blob shorter than the expected 24 bytes.
        var bytes: [UInt8] = uint32BE(1)
        bytes += uint32BE(3) + uint32BE(1) + uint32BE(0)
        bytes += [0x00, 0x00, 0x00, 0x01]   // planeCount only, blob otherwise short
        let data = Data(bytes)
        do {
            _ = try DNGOpcodeParser.parse(data)
            return XCTFail("expected parse to throw .unknownOpcodeLength")
        } catch let error as DNGOpcodeError {
            guard case .unknownOpcodeLength(let id) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(id, 3)
        } catch {
            return XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: LensProfileStore — bundled identity + JSON round-trip

    func testLensProfileJSONRoundTrip() throws {
        let json = """
        {
          "lensID": "wide",
          "distortion": { "k1": 0.0, "k2": 0.0, "k3": 0.0 },
          "caOffsets": 0.0,
          "vignetteGain": 1.0,
          "source": "neutral"
        }
        """
        let profile = try JSONDecoder().decode(LensProfile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.lensID, .wide)
        XCTAssertEqual(profile.distortion.k1, 0.0)
        XCTAssertEqual(profile.distortion.k2, 0.0)
        XCTAssertEqual(profile.distortion.k3, 0.0)
        XCTAssertEqual(profile.caOffsets, 0.0)
        XCTAssertEqual(profile.vignetteGain, 1.0)
        XCTAssertEqual(profile.source, .neutral)

        let encoded = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(LensProfile.self, from: encoded)
        XCTAssertEqual(decoded, profile)
    }

    // MARK: LensCorrectionEngine — pass-through semantics (no Metal needed)

    private enum PixelBox {
        enum AllocationError: Error {
            case failed(CVReturn)
        }

        static func makeBuffer(width: Int = 4, height: Int = 4) throws -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                nil,
                &buffer
            )
            guard status == kCVReturnSuccess, let buffer else {
                throw AllocationError.failed(status)
            }
            return buffer
        }
    }

    func testEngineOffModeIsPassThrough() async throws {
        let engine = LensCorrectionEngine(device: nil)
        let buffer = try PixelBox.makeBuffer()
        let output = try await engine.apply(buffer, lens: .wide, mode: .off, strength: 1.0)
        XCTAssertTrue(output === buffer, ".off must be a zero-copy passthrough")
    }

    func testEngineAutoWithoutProfileIsPassThrough() async throws {
        // No bundled profile for `.tele` in v1 → `.auto` degrades to passthrough.
        let engine = LensCorrectionEngine(device: nil)
        let buffer = try PixelBox.makeBuffer()
        let output = try await engine.apply(buffer, lens: .tele, mode: .auto, strength: 1.0)
        XCTAssertTrue(output === buffer, ".auto with no profile must be a zero-copy passthrough")
    }

    func testEngineStrengthZeroIsPassThrough() async throws {
        let engine = LensCorrectionEngine(device: nil)
        let buffer = try PixelBox.makeBuffer()
        let output = try await engine.apply(buffer, lens: .wide, mode: .profile, strength: 0.0)
        XCTAssertTrue(output === buffer, "strength 0 must be an identity passthrough")
    }
}
