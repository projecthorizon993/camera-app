import Foundation
import CoreGraphics

// MARK: - SuperResTier

enum SuperResTier: Sendable, Equatable {
    case passthrough
    case lanZZos2x
}

// MARK: - SuperResPlanner

enum SuperResPlanner {
    static let maxOutputDimension: Int = 4096

    static func sanitize(scale: Double) -> Double {
        guard scale.isFinite else { return 1.0 }
        return scale < 1.5 ? 1.0 : 2.0
    }

    static func tier(inputSize: CGSize, requestedScale: Double) -> SuperResTier {
        let effective = sanitize(scale: requestedScale)
        guard effective > 1.0 else { return .passthrough }
        let outW = Double(inputSize.width) * effective
        let outH = Double(inputSize.height) * effective
        guard outW <= Double(maxOutputDimension),
              outH <= Double(maxOutputDimension) else {
            return .passthrough
        }
        return .lanZZos2x
    }
}