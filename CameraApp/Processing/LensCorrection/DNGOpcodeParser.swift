import Foundation

// Task 13 — Adobe DNG OpcodeList parser (pure Foundation, unit-testable).
//
// The DNG spec stores per-lens optical correction data in the undefined DNG
// tags 52508/52509/52510 (OpcodeList1/2/3). The payload shape implemented here
// (v1 conservative):
//
//   payload   : UInt32 count, then `count` opcode records
//   record    : UInt32 opcodeID, UInt32 dngSpecVersion, UInt32 flags (12 bytes)
//               followed by the type-specific parameter blob (length implied by
//               the opcode type — see `DNGOpcodeParser.expectedParamByteLength`)
//
// Known opcode ids and their v1 parameter shapes:
//   1 WarpFisheye      : 2 × f64 (k1, k2) + u32 mode            → 20 bytes
//   3 WarpRectilinear  : planeCount u32 (=1) + per-plane 3 × abnormal
//                         + 2 × center, each S15M16 fixed       → 4 + planes × 20
//   4 FixVignetteRadial: center 2 × S15M16 + gain coefficients    → 4 × S15M16 (16 bytes)
//   7 TrimBounds       : 4 × u32 bounds                          → 16 bytes
//
// Conservative decode rule (Task 13 v1): the engine only consumes Warp /
// FixVignette parameters, so any mis-shaped blob for a known opcode id throws
// `.unknownOpcodeLength` instead of silently decoding something sloppy.

/// Typed errors surfaced by the DNG OpcodeList parser.
enum DNGOpcodeError: Error, Sendable {
    /// The payload (or one of its record headers) is shorter than declared.
    case truncated
    /// A known opcode id carried a parameter blob whose shape/length is not the
    /// conservative v1 expectation → refuse rather than decode sloppily.
    case unknownOpcodeLength(UInt32)
}

/// One decoded Adobe DNG lens-opcode record.
struct DNGOpcode: Sendable, Equatable {
    let id: UInt32
    let dngSpecVersion: UInt32
    let flags: UInt32
    let params: [Float]   // decoded via the S15M16 fixed helper
}

enum DNGOpcodeParser {

    // MARK: Known opcode parameter-blob shapes (v1 conservative)

    /// Expected parameter-blob byte length for each known opcode id. `nil` for
    /// unrecognized ids (→ `.unknownOpcodeLength` at parse time, never a guess).
    static func expectedParamByteLength(forOpcode id: UInt32) -> Int? {
        switch id {
        case 1: // WarpFisheye: 2 × f64 (k1, k2) + u32 mode → 20 bytes
            return 20
        case 3: // WarpRectilinear: planeCount u32 (=1) + per-plane params → 24 bytes
            return 24
        case 4: // FixVignetteRadial: center 2 × S15M16 + gains → 16 bytes
            return 16
        case 7: // TrimBounds: 4 × u32 bounds → 16 bytes
            return 16
        default:
            return nil
        }
    }

    // MARK: Parse

    /// Parses one OpcodeList payload (raw bytes from the DNG tags) into opcodes.
    static func parse(_ data: Data) throws -> [DNGOpcode] {
        guard data.count >= 4 else { throw DNGOpcodeError.truncated }
        let count = try readUInt32(data, at: 0)
        var offset = 4
        var opcodes: [DNGOpcode] = []
        for _ in 0..<count {
            guard data.count - offset >= 12 else { throw DNGOpcodeError.truncated }
            let id = try readUInt32(data, at: offset)
            let dngSpecVersion = try readUInt32(data, at: offset + 4)
            let flags = try readUInt32(data, at: offset + 8)
            offset += 12

            switch id {
            case 1:
                // WarpFisheye: 2 × f64 (k1, k2) + u32 mode → widened to Float.
                guard data.count - offset >= 20 else { throw DNGOpcodeError.unknownOpcodeLength(id) }
                opcodes.append(
                    DNGOpcode(
                        id: id,
                        dngSpecVersion: dngSpecVersion,
                        flags: flags,
                        params: [
                            readFloat32(data, at: offset),
                            readFloat32(data, at: offset + 4),
                            readFloat32(data, at: offset + 16),
                        ]
                    )
                )
                offset += 20
            case 3:
                // WarpRectilinear: planeCount u32 (=1) + per-plane 3 abnormal + 2 center S15M16.
                guard data.count - offset >= 4 else { throw DNGOpcodeError.truncated }
                let planeCount = Int(try readUInt32(data, at: offset))
                let expected = 4 + planeCount * 20
                guard data.count - offset >= expected else { throw DNGOpcodeError.unknownOpcodeLength(id) }
                var params: [Float] = []
                var cursor = offset + 4
                for _ in 0..<planeCount {
                    let abnormalK1 = fixedToFloat(try readUInt32(data, at: cursor))
                    let abnormalK2 = fixedToFloat(try readUInt32(data, at: cursor + 4))
                    let abnormalK3 = fixedToFloat(try readUInt32(data, at: cursor + 8))
                    let centerX = fixedToFloat(try readUInt32(data, at: cursor + 12))
                    let centerY = fixedToFloat(try readUInt32(data, at: cursor + 16))
                    params.append(contentsOf: [abnormalK1, abnormalK2, abnormalK3, centerX, centerY])
                    cursor += 20
                }
                opcodes.append(DNGOpcode(id: id, dngSpecVersion: dngSpecVersion, flags: flags, params: params))
                offset += expected
            case 4:
                // FixVignetteRadial: center 2 × S15M16 + gain coefficients (each S15M16).
                guard data.count - offset >= 16 else { throw DNGOpcodeError.unknownOpcodeLength(id) }
                opcodes.append(
                    DNGOpcode(
                        id: id,
                        dngSpecVersion: dngSpecVersion,
                        flags: flags,
                        params: [
                            fixedToFloat(try readUInt32(data, at: offset)),
                            fixedToFloat(try readUInt32(data, at: offset + 4)),
                            fixedToFloat(try readUInt32(data, at: offset + 8)),
                            fixedToFloat(try readUInt32(data, at: offset + 12)),
                        ]
                    )
                )
                offset += 16
            case 7:
                // TrimBounds: 4 × u32 BE bounds → widened to Float.
                guard data.count - offset >= 16 else { throw DNGOpcodeError.unknownOpcodeLength(id) }
                opcodes.append(
                    DNGOpcode(
                        id: id,
                        dngSpecVersion: dngSpecVersion,
                        flags: flags,
                        params: [
                            trimFloat(try readUInt32(data, at: offset)),
                            trimFloat(try readUInt32(data, at: offset + 4)),
                            trimFloat(try readUInt32(data, at: offset + 8)),
                            trimFloat(try readUInt32(data, at: offset + 12)),
                        ]
                    )
                )
                offset += 16
            default:
                throw DNGOpcodeError.unknownOpcodeLength(id)
            }
        }
        return opcodes
    }

    // MARK: S15M16 fixed-point decode

    /// S15M16 fixed → Float. Raw word layout: sign(1) + int(15) + frac(16);
    /// value = sign * (int + frac / 2^16). int is the magnitude field (bits 30...16),
    /// frac the fraction field (bits 15...0); the sign flag occupies bit 31.
    ///
    /// Task 13 brief worked vector: raw `0x8001_0000` (int = 1, frac = 0) → `1.0`.
    static func fixedToFloat(_ word: UInt32) -> Float {
        let intBits = Int((word >> 16) & 0x7FFF)
        let fracBits = Int(word & 0xFFFF)
        let value = Double(intBits) + Double(fracBits) / 65536.0
        let sign: Double = (word & 0x8000_0000) != 0 ? 1.0 : -1.0
        return Float(sign * value)
    }

    // MARK: Byte helpers (DNG payloads are big-endian)

    /// Widens a u32 BE value to Float (v1: bounds are integral values).
    private static func trimFloat(_ value: UInt32) -> Float {
        return Float(Double(Int(value)))
    }

    private static func readUInt32(_ data: Data, at offset: Int) throws -> UInt32 {
        guard data.count >= offset + 4 else { throw DNGOpcodeError.truncated }
        let b0 = data[offset]
        let b1 = data[offset + 1]
        let b2 = data[offset + 2]
        let b3 = data[offset + 3]
        return (UInt32(b0) << 24) | (UInt32(b1) << 16) | (UInt32(b2) << 8) | UInt32(b3)
    }

    private static func readFloat32(_ data: Data, at offset: Int) -> Float {
        let b0 = data[offset]
        let b1 = data[offset + 1]
        let b2 = data[offset + 2]
        let b3 = data[offset + 3]
        let bits = (UInt32(b0) << 24) | (UInt32(b1) << 16) | (UInt32(b2) << 8) | UInt32(b3)
        return unsafeBitCast(bits, to: Float.self)
    }
}
