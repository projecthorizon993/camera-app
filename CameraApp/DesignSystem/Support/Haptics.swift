import UIKit

// MARK: - Haptics

/// Haptic feedback wrappers for the design system.
///
/// Confinement note (plan ruling): this is the ONLY file in CameraApp allowed
/// to import UIKit. Everything else in DesignSystem stays pure SwiftUI, so the
/// kit remains previewable and testable without a UIKit host.
@MainActor
enum Haptics {

    /// Subtle tick — mode detents, chip toggles, snap points.
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Standard confirmation — shutter press, primary actions.
    static func medium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Strong emphasis — destructive or state-changing actions.
    static func heavy() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }

    /// Success notification — capture completed, permission granted.
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
