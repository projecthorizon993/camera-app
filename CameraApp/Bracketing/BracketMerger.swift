import Foundation
import CoreVideo
import Metal

// MARK: - BracketError

public enum BracketError: Error, Sendable {
    case metalUnavailable
    case insufficientFrames
    case fuseFailed
}

// MARK: - BracketMerger

/// Metal merge engine. GPU work runs off the caller's actor via a detached task.
public final class BracketMerger: @unchecked Sendable {

    public enum BracketError: Error, Sendable {
        case metalUnavailable
        case insufficientFrames
        case fuseFailed
    }

    private let device: MTLDevice?

    public init() {
        self.device = MTLCreateSystemDefaultDevice()
    }

    public func merge(frames: [CVPixelBuffer], mode: MergeMode,
                      orientation: PortraitLandscape) async throws -> CVPixelBuffer {
        // SE-0461: hop off the caller's actor explicitly.
        let capturedFrames = frames
        let capturedMode = mode
        return try await Task.detached(priority: .userInitiated) { [device] in
            guard let device else { throw BracketError.metalUnavailable }
            _ = device
            return try Self.mergeSync(frames: capturedFrames, mode: capturedMode)
        }.value
    }

    // MARK: - Sync implementation (CPU, deterministic, testable)

    private static func mergeSync(frames: [CVPixelBuffer], mode: MergeMode) throws -> CVPixelBuffer {
        guard !frames.isEmpty else { throw BracketError.insufficientFrames }
        if frames.count == 1 { return frames[0] }

        let width  = CVPixelBufferGetWidth(frames[0])
        let height = CVPixelBufferGetHeight(frames[0])
        let format = CVPixelBufferGetPixelFormatType(frames[0])
        guard format == kCVPixelFormatType_32BGRA else { throw BracketError.fuseFailed }
        for f in frames {
            guard CVPixelBufferGetWidth(f) == width,
                  CVPixelBufferGetHeight(f) == height,
                  CVPixelBufferGetPixelFormatType(f) == format else {
                throw BracketError.fuseFailed
            }
        }

        // Downsample luminance planes for the motion guard.
        let planes = try frames.map { try luminancePlane($0) }
        let refIndex = frames.count / 2
        let refPlane = planes[refIndex]

        // Keep-list + strengths.
        var kept: [Int] = []
        var strengths: [Float] = []
        for i in 0..<frames.count {
            let diff = MotionGuard.meanAbsDiff(reference: refPlane, candidate: planes[i])
            let v = MotionGuard.verdict(for: diff)
            switch v {
            case .aligned:
                kept.append(i); strengths.append(1.0)
            case .soft:
                kept.append(i); strengths.append(0.5)
            case .reject:
                break
            }
        }
        // Always keep the reference frame.
        if !kept.contains(refIndex) {
            kept.append(refIndex); strengths.append(1.0)
        }
        // Stable order.
        let ordered = kept.sorted()
        let orderedStrengths = ordered.map { idx -> Float in
            if let k = kept.firstIndex(of: idx) { return strengths[k] }
            return 1.0
        }

        guard !ordered.isEmpty else { throw BracketError.insufficientFrames }
        if ordered.count == 1 { return frames[ordered[0]] }

        // Allocate output.
        guard let outBuffer = allocateBuffer(width: width, height: height) else {
            throw BracketError.fuseFailed
        }

        switch mode {
        case .nightStack:
            try medianMerge(frames: frames, indices: ordered, width: width, height: height, into: outBuffer)
        case .fusion:
            try fusionMerge(frames: frames, indices: ordered, strengths: orderedStrengths,
                            width: width, height: height, into: outBuffer)
        }

        return outBuffer
    }

    // MARK: - Helpers

    private static func allocateBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attrs as CFDictionary, &buffer
        )
        return status == kCVReturnSuccess ? buffer : nil
    }

    private static func luminancePlane(_ buffer: CVPixelBuffer) throws -> [Float] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else {
            throw BracketError.fuseFailed
        }
        let width  = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bpr    = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw BracketError.fuseFailed }
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        let stepX = max(1, width / 64)
        let stepY = max(1, height / 64)
        var plane: [Float] = []
        plane.reserveCapacity((height / stepY) * (width / stepX))
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let off = y * bpr + x * 4
                let b = Float(ptr[off])     / 255.0
                let g = Float(ptr[off + 1]) / 255.0
                let r = Float(ptr[off + 2]) / 255.0
                plane.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
                x += stepX
            }
            y += stepY
        }
        return plane
    }

    private static func medianMerge(frames: [CVPixelBuffer], indices: [Int],
                                   width: Int, height: Int, into out: CVPixelBuffer) throws {
        // Lock inputs + output.
        for i in indices { CVPixelBufferLockBaseAddress(frames[i], .readOnly) }
        CVPixelBufferLockBaseAddress(out, [])
        defer {
            for i in indices { CVPixelBufferUnlockBaseAddress(frames[i], .readOnly) }
            CVPixelBufferUnlockBaseAddress(out, [])
        }

        let outBpr = CVPixelBufferGetBytesPerRow(out)
        guard let outBase = CVPixelBufferGetBaseAddress(out) else { throw BracketError.fuseFailed }
        let outPtr = outBase.assumingMemoryBound(to: UInt8.self)

        let inBprs = indices.map { CVPixelBufferGetBytesPerRow(frames[$0]) }
        let inPtrs = indices.map { CVPixelBufferGetBaseAddress(frames[$0])!.assumingMemoryBound(to: UInt8.self) }

        for py in 0..<height {
            for px in 0..<width {
                var rs: [Float] = []
                var gs: [Float] = []
                var bs: [Float] = []
                rs.reserveCapacity(indices.count)
                gs.reserveCapacity(indices.count)
                bs.reserveCapacity(indices.count)
                for (k, _) in indices.enumerated() {
                    let off = py * inBprs[k] + px * 4
                    bs.append(Float(inPtrs[k][off])     / 255.0)
                    gs.append(Float(inPtrs[k][off + 1]) / 255.0)
                    rs.append(Float(inPtrs[k][off + 2]) / 255.0)
                }
                rs.sort(); gs.sort(); bs.sort()
                let mid = rs.count / 2
                let off = py * outBpr + px * 4
                outPtr[off]     = UInt8((bs[mid] * 255.0).rounded())
                outPtr[off + 1] = UInt8((gs[mid] * 255.0).rounded())
                outPtr[off + 2] = UInt8((rs[mid] * 255.0).rounded())
                outPtr[off + 3] = 255
            }
        }
    }

    private static func fusionMerge(frames: [CVPixelBuffer], indices: [Int], strengths: [Float],
                                   width: Int, height: Int, into out: CVPixelBuffer) throws {
        let n = indices.count
        let pixelCount = width * height
        var accumR = [Float](repeating: 0, count: pixelCount)
        var accumG = [Float](repeating: 0, count: pixelCount)
        var accumB = [Float](repeating: 0, count: pixelCount)
        var weightSum = [Float](repeating: 0, count: pixelCount)

        for (k, frameIndex) in indices.enumerated() {
            let frame = frames[frameIndex]
            CVPixelBufferLockBaseAddress(frame, .readOnly)
            let bpr = CVPixelBufferGetBytesPerRow(frame)
            guard let base = CVPixelBufferGetBaseAddress(frame) else {
                CVPixelBufferUnlockBaseAddress(frame, .readOnly)
                throw BracketError.fuseFailed
            }
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            let strength = (k < strengths.count) ? strengths[k] : 1.0

            for py in 0..<height {
                for px in 0..<width {
                    let off = py * bpr + px * 4
                    let b = Float(ptr[off])     / 255.0
                    let g = Float(ptr[off + 1]) / 255.0
                    let r = Float(ptr[off + 2]) / 255.0
                    let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    let contrast = abs(luma - 0.5)
                    let sat = max(max(r, g), b) - min(min(r, g), b)
                    let w = BracketPlanner.mertensWeight(lightness: Float(luma),
                                                         contrast: Float(contrast),
                                                         saturation: Float(sat)) * strength
                    let idx = py * width + px
                    accumR[idx] += w * r
                    accumG[idx] += w * g
                    accumB[idx] += w * b
                    weightSum[idx] += w
                }
            }
            CVPixelBufferUnlockBaseAddress(frame, .readOnly)
        }

        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }
        let outBpr = CVPixelBufferGetBytesPerRow(out)
        guard let outBase = CVPixelBufferGetBaseAddress(out) else { throw BracketError.fuseFailed }
        let outPtr = outBase.assumingMemoryBound(to: UInt8.self)

        for py in 0..<height {
            for px in 0..<width {
                let idx = py * width + px
                let ws = weightSum[idx]
                let inv: Float = ws > 0 ? 1.0 / ws : 0
                let r = accumR[idx] * inv
                let g = accumG[idx] * inv
                let b = accumB[idx] * inv
                let off = py * outBpr + px * 4
                outPtr[off]     = UInt8((b * 255.0).rounded().clamped(to: 0...255))
                outPtr[off + 1] = UInt8((g * 255.0).rounded().clamped(to: 0...255))
                outPtr[off + 2] = UInt8((r * 255.0).rounded().clamped(to: 0...255))
                outPtr[off + 3] = 255
            }
        }
    }
}

// MARK: - Small helpers

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// end of file