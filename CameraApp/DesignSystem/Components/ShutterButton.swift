import SwiftUI

// MARK: - ShutterButton

/// Primary capture control: photo shutter or record button.
///
/// - `.photo`: white ring + white circle, press-in scale animation.
/// - `.recordIdle`: white ring + red circle.
/// - `.recording(elapsed:)`: circle morphs to a rounded square, a red ring
///   pulses around the control, and the elapsed time reads out above.
///
/// Size scales through the `\.shutterButtonScale` environment value (1.0 by
/// default) so screens can enlarge the control for one-handed reach.
struct ShutterButton: View {

    // MARK: Mode

    /// What the shutter currently does.
    enum Mode: Equatable {
        case photo
        case recordIdle
        case recording(elapsed: TimeInterval)

        /// True while video is rolling (drives the morph + pulse).
        var isRecording: Bool {
            if case .recording = self { return true }
            return false
        }
    }

    // MARK: Inputs

    let mode: Mode
    let action: () -> Void

    // MARK: State

    @Environment(\.shutterButtonScale) private var scale
    @State private var pulsing = false

    // MARK: Body

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            if case .recording(let elapsed) = mode {
                elapsedLabel(elapsed)
            }
            Button(action: {
                Haptics.medium()
                action()
            }) {
                core
            }
            .buttonStyle(ShutterPressStyle())
            .animation(
                .spring(
                    response: Theme.Animation.pressResponse,
                    dampingFraction: Theme.Animation.pressDamping
                ),
                value: mode
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Core control

    @ViewBuilder
    private var core: some View {
        ZStack {
            if mode.isRecording {
                pulseRing
            }
            Circle()
                .stroke(Theme.Color.textPrimary, lineWidth: Theme.Dimension.shutterRingWidth)
            inner
        }
        .frame(width: Theme.Dimension.shutterDiameter * scale,
               height: Theme.Dimension.shutterDiameter * scale)
        .onAppear { pulsing = mode.isRecording }
        .onChange(of: mode) { _, newValue in
            pulsing = newValue.isRecording
        }
    }

    /// Expanding/fading red ring shown only while recording.
    private var pulseRing: some View {
        Circle()
            .stroke(
                Theme.Color.recordingRed.opacity(Theme.Opacity.pulseMax),
                lineWidth: Theme.Dimension.shutterRingWidth
            )
            .scaleEffect(pulsing ? Theme.Dimension.pulseScaleMax : 1.0)
            .opacity(pulsing ? Theme.Opacity.pulseMax : Theme.Opacity.pulseMin)
            .animation(
                .easeInOut(duration: Theme.Animation.pulseDuration)
                    .repeatForever(autoreverses: true),
                value: pulsing
            )
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var inner: some View {
        switch mode {
        case .photo:
            roundedInner(side: Theme.Dimension.shutterInner * scale,
                         corner: Theme.Dimension.shutterInner * scale / 2,
                         color: Theme.Color.textPrimary)
        case .recordIdle:
            roundedInner(side: Theme.Dimension.shutterInner * scale,
                         corner: Theme.Dimension.shutterInner * scale / 2,
                         color: Theme.Color.recordingRed)
        case .recording:
            roundedInner(side: Theme.Dimension.shutterRecordingSquare * scale,
                         corner: Theme.Dimension.recordCorner * scale,
                         color: Theme.Color.recordingRed)
        }
    }

    /// One morphing shape: a full-round corner radius reads as a circle; the
    /// small radius reads as the recording square, and the spring animates
    /// between them.
    private func roundedInner(side: CGFloat, corner: CGFloat, color: SwiftUI.Color) -> some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(color)
            .frame(width: side, height: side)
    }

    // MARK: Elapsed readout

    private func elapsedLabel(_ elapsed: TimeInterval) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Circle()
                .fill(Theme.Color.recordingRed)
                .frame(width: Theme.Dimension.recDotSize, height: Theme.Dimension.recDotSize)
            Text(Self.formatElapsed(elapsed))
                .font(Theme.Typography.value)
                .foregroundStyle(Theme.Color.textPrimary)
        }
        .padding(.horizontal, Theme.Dimension.chipHPadding)
        .padding(.vertical, Theme.Spacing.s)
        .background(Capsule().fill(Theme.Color.chrome900.opacity(Theme.Opacity.chipBackground)))
        .accessibilityLabel("Recording")
    }

    private static func formatElapsed(_ elapsed: TimeInterval) -> String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: Accessibility

    private var accessibilityText: String {
        switch mode {
        case .photo: return "Take photo"
        case .recordIdle: return "Start recording"
        case .recording: return "Stop recording"
        }
    }
}

// MARK: - Press style

/// Press-in scale animation for the shutter.
private struct ShutterPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? Theme.Dimension.shutterPressScale : 1.0)
            .animation(
                .spring(
                    response: Theme.Animation.pressResponse,
                    dampingFraction: Theme.Animation.pressDamping
                ),
                value: configuration.isPressed
            )
    }
}

// MARK: - Environment scale

private struct ShutterButtonScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    /// Multiplies the shutter's overall size. 1.0 is the standard control;
    /// larger values keep the same layout for thumb-reach ergonomics.
    var shutterButtonScale: CGFloat {
        get { self[ShutterButtonScaleKey.self] }
        set { self[ShutterButtonScaleKey.self] = newValue }
    }
}

// MARK: - Previews

#Preview("Shutter states") {
    HStack(spacing: Theme.Spacing.xl) {
        ShutterButton(mode: .photo, action: {})
        ShutterButton(mode: .recordIdle, action: {})
        ShutterButton(mode: .recording(elapsed: 83), action: {})
    }
    .padding(Theme.Spacing.xxl)
    .background(Theme.Color.chrome900)
}

#Preview("Enlarged (env scale)") {
    ShutterButton(mode: .photo, action: {})
        .padding(Theme.Spacing.xxl)
        .background(Theme.Color.chrome900)
        .environment(\.shutterButtonScale, 1.25)
}
