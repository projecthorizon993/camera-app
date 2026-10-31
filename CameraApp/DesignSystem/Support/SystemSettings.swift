import SwiftUI

// MARK: - SystemSettings

/// Deep link into the system Settings page for this app.
///
/// The scheme matches `UIApplication.openSettingsURLString` ("app-settings:");
/// it is kept as a literal so DesignSystem stays free of UIKit imports outside
/// `Haptics.swift` (plan ruling). Opening goes through SwiftUI's
/// `OpenURLAction`, which callers (and tests/previews) can inject via the
/// `\.openURL` environment — that is the testable seam the brief asked for.
enum SystemSettings {

    /// URL of this app's page in the system Settings app.
    static let url = URL(string: "app-settings:")!

    /// Opens the app-settings screen using the provided action.
    /// Usage in a view: `SystemSettings.open(openURL)` where
    /// `@Environment(\.openURL) private var openURL`.
    static func open(_ action: OpenURLAction) {
        action(url)
    }
}
