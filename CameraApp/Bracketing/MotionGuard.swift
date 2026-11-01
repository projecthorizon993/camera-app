import Foundation

// MARK: - MotionVerdict

public enum MotionVerdict: Sendable, Equatable {
    case aligned
    case soft
    case reject
}

// MARK: - MotionGuard

/// Frame-motion detector. Pure scalar math on [Float] planes.
public enum MotionGuard {

    /// Mean absolute difference (0...1) between reference and candidate planes.
    /// Both planes must have the same count; mismatched/empty inputs return 0.
    public static func meanAbsDiff(reference: [Float], candidate: [Float]) -> Float {
        guard !reference.isEmpty, reference.count == candidate.count else { return 0 }
        var acc: Float = 0
        for i in 0..<reference.count {
            acc += abs(reference[i] - candidate[i])
        }
        return acc / Float(reference.count)
    }

    /// Decision thresholds per spec.
    public static func verdict(for diff: Float) -> MotionVerdict {
        if diff <= 0.02 { return .aligned }
        if diff <= 0.10 { return .soft }
        return .reject
    }
}
