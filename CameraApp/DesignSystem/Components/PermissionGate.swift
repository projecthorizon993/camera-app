import SwiftUI

// MARK: - PermissionGate

/// Full-screen permission gate in the themed camera-chrome look.
///
/// Pure UI: takes an SF Symbol `icon`, `title`, `message`, a primary button
/// (the permission request), and optionally renders a secondary "Open
/// Settings" button that deep-links via `SystemSettings` (OpenURLAction from
/// the environment — injectable in previews and tests).
///
/// Naming note: the type is `PermissionGate` and the file is
/// `PermissionGate.swift` because `PermissionGateView` is already taken by the
/// plain-styled component in CameraApp/Permissions/ (left untouched; a later
/// restyle task can swap it over to this kit component). Xcode requires
/// unique file basenames per target, hence the file rename as well.
struct PermissionGate: View {

    // MARK: Inputs

    /// SF Symbol for the permission (e.g. "camera.fill").
    let icon: String
    let title: String
    let message: String
    var primaryTitle: String = "Allow"
    let primaryAction: () -> Void
    /// Whether to show the secondary "Open Settings" button.
    var showsSettingsLink: Bool = true

    // MARK: State

    @Environment(\.openURL) private var openURL

    // MARK: Body

    var body: some View {
        ZStack {
            Theme.Color.chrome900
                .ignoresSafeArea()

            VStack(spacing: Theme.Spacing.xl) {
                Image(systemName: icon)
                    .font(.system(size: Theme.Dimension.gateIconSize, weight: .medium))
                    .foregroundStyle(Theme.Color.accent)
                    .frame(width: Theme.Dimension.gateIconCircle,
                           height: Theme.Dimension.gateIconCircle)
                    .background(Circle().fill(Theme.Color.chrome800))

                VStack(spacing: Theme.Spacing.m) {
                    Text(title)
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Color.textPrimary)
                        .multilineTextAlignment(.center)
                    Text(message)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, Theme.Spacing.xl)

                VStack(spacing: Theme.Spacing.m) {
                    Button {
                        Haptics.medium()
                        primaryAction()
                    } label: {
                        Text(primaryTitle)
                            .font(Theme.Typography.body.weight(.semibold))
                            .foregroundStyle(Theme.Color.chrome900)
                            .frame(maxWidth: .infinity,
                                   minHeight: Theme.Dimension.primaryButtonHeight)
                            .background(Capsule().fill(Theme.Color.accent))
                    }
                    .buttonStyle(.plain)

                    if showsSettingsLink {
                        Button {
                            SystemSettings.open(openURL)
                        } label: {
                            Text("Open Settings")
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Color.textPrimary)
                                .frame(maxWidth: .infinity,
                                       minHeight: Theme.Dimension.primaryButtonHeight)
                                .background(Capsule().stroke(
                                    Theme.Color.chrome600,
                                    lineWidth: Theme.Dimension.digitalStrokeWidth
                                ))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open the system Settings app")
                    }
                }
                .padding(.horizontal, Theme.Spacing.xl)
            }
            .padding(Theme.Spacing.xxl)
        }
    }
}

// MARK: - Previews

#Preview("Request state") {
    PermissionGate(
        icon: "camera.fill",
        title: "Camera Access Needed",
        message: "The viewfinder needs camera access to show a live preview and capture photos.",
        primaryTitle: "Allow",
        primaryAction: {}
    )
}

#Preview("Denied state (settings link)") {
    PermissionGate(
        icon: "camera.fill",
        title: "Camera Access Turned Off",
        message: "Camera access is turned off. Open Settings and enable Camera to use the viewfinder.",
        primaryTitle: "Try Again",
        primaryAction: {}
    )
}
