import Foundation

// Task 18 — pure exposure planner for Night mode.
//
// Night is a SOFTWARE stack: N short-to-long exposures fused via
// `MergeMode.nightStack` (median, no optical flow). The planner turns the
// auto basis into a ladder of exposure durations that samples the scene
// near / under / over the auto point.
//
// `basisSeconds` is the auto exposure duration the camera reports (read-only;
// the service's exposure is NOT modified here). `maxSeconds` is the device
// max exposure duration (cap). `frameCount` is the requested stack size
// (8 = dim-scene default); the planner halves it when the basis is already
// long (>= 1 s) so the sensor budget is not exhausted.

struct NightPlan: Sendable, Equatable {
    let frameCount: Int          // 2…12 (recipe cap)
    let exposureSeconds: [Double] // duration per frame (sorted ascending)
    let gapSeconds: Double       // inter-frame sensor settle (recipe)
}

enum NightExposurePlanner {
    /// A13-tuned recipe (v1 fixed table, documented):
    ///   rung targets = basis · {1, 2, 4}, each capped at `maxSeconds`;
    ///   frames are assigned round-robin over the rungs so the stack samples
    ///   near / under / over the auto point; the resulting list is sorted
    ///   ascending. `frameCount` is clamped to 2…12. When `basisSeconds >= 1 s`
    ///   the count is halved (sensor budget) but never below 2.
    static func plan(basisSeconds: Double, maxSeconds: Double,
                     frameCount: Int) -> NightPlan {
        let clampedBasis = basisSeconds > 0 ? basisSeconds : 0.000125
        let cap = maxSeconds > 0 ? maxSeconds : clampedBasis

        // Halve the count for already-long bases (sensor budget).
        let requested: Int
        if clampedBasis >= 1.0 {
            requested = max(2, frameCount / 2)
        } else {
            requested = frameCount
        }
        let count = min(12, max(2, requested))

        // Rung ladder: basis · {1, 2, 4}, capped at the device maximum.
        let rungs: [Double] = [clampedBasis, clampedBasis * 2.0, clampedBasis * 4.0]
            .map { min($0, cap) }

        // Round-robin assignment over rungs, then ascending sort.
        var exposures: [Double] = []
        exposures.reserveCapacity(count)
        for index in 0..<count {
            exposures.append(rungs[index % rungs.count])
        }
        exposures.sort()

        return NightPlan(frameCount: count, exposureSeconds: exposures, gapSeconds: 0.1)
    }
}
