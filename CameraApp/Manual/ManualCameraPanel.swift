import SwiftUI

// Task 9 — manual pro controls panel: ISO / shutter / focus / white balance,
// bound to the real `CameraService` through `ManualConfigEngine`.
//
// INTEGRATION: none here by contract — T7's viewfinder mounts
// `ManualControlsView` (the clean-init wrapper below). The panel never calls
// the service directly: all blocking `applyManualConfig`/`resetToAuto`
// traffic goes through the engine, which hops it onto a private serial queue
// (T4 review I1 — never on the main actor). The only service member reached
// from this file is the lock-guarded `supportedManualRanges` getter, via
// `engine.reloadRanges()` on mount.
//
// STYLING: no `CameraApp/DesignSystem/` exists in this worktree, so the panel
// uses plain SwiftUI sliders with explicit restyle markers.

/// Integration point for T7's viewfinder.
///
/// Module-internal on purpose: the app is a single module, so `internal` is
/// the widest usable access — a `public` init would leak the internal frozen
/// `CameraServiceProtocol` and does not compile. T7 wires it from a SwiftUI
/// body.
///
/// - Parameters:
///   - service: the live camera service (real or placeholder).
///   - isReady: session-ready flag; the panel disables itself until true.
///     T7 owns the lifecycle.
///
/// Mounting re-reads `supportedManualRanges` (`reloadRanges()`), so after a
/// lens switch T7 simply re-mounts this view (change its identity) and the
/// fresh ranges flow in.
struct ManualControlsView: View {
    @StateObject private var engine: ManualConfigEngine
    private let isReady: Bool

    init(service: any CameraServiceProtocol, isReady: Bool) {
        _engine = StateObject(wrappedValue: ManualConfigEngine(service: service))
        self.isReady = isReady
    }

    var body: some View {
        ManualCameraPanel(engine: engine, isReady: isReady)
            .onAppear { engine.reloadRanges() }
    }
}

/// The full panel: four sections (ISO, Shutter, Focus, WB), each with a value
/// display, a slider, an AUTO badge while its field is nil (auto mode), and a
/// per-section reset; plus a panel-level "RESET ALL" → `resetToAuto()`.
struct ManualCameraPanel: View {
    @ObservedObject var engine: ManualConfigEngine
    let isReady: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("MANUAL")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("RESET ALL") { engine.resetAll() }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
            }
            // TODO(T7a): restyle with DesignSystem ControlDial.

            if let message = engine.lastError {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .transition(.opacity)
            }

            ManualSection(
                title: "ISO",
                valueText: engine.iso.map(ValueFormatters.iso) ?? "AUTO",
                isAuto: engine.iso == nil,
                onReset: { engine.resetISO() }
            ) {
                isoSlider
            }

            ManualSection(
                title: "SHUTTER",
                valueText: engine.shutterSeconds.map { ValueFormatters.shutter(seconds: $0) } ?? "AUTO",
                isAuto: engine.shutterSeconds == nil,
                onReset: { engine.resetShutter() }
            ) {
                shutterSlider
            }

            ManualSection(
                title: "FOCUS",
                valueText: engine.lensPosition.map(ValueFormatters.lensPosition) ?? "AUTO",
                isAuto: engine.lensPosition == nil,
                onReset: { engine.resetFocus() }
            ) {
                focusSlider
            }

            ManualSection(
                title: "WHITE BALANCE",
                valueText: wbValueText,
                isAuto: engine.kelvin == nil && engine.tint == nil,
                onReset: { engine.resetWhiteBalance() }
            ) {
                VStack(spacing: 8) {
                    kelvinSlider
                    tintSlider
                }
            }

            Text("ISO and shutter lock together (device requirement); setting only one returns exposure to auto.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .disabled(!isReady)
        .opacity(isReady ? 1 : 0.55)
        .animation(.easeInOut(duration: 0.15), value: engine.lastError)
        .onAppear { engine.reloadRanges() }
    }

    // MARK: - Value display

    private var wbValueText: String {
        switch (engine.kelvin, engine.tint) {
        case (nil, nil): return "AUTO"
        case (let kelvin?, let tint?): return "\(ValueFormatters.kelvin(kelvin)) · \(ValueFormatters.tint(tint))"
        case (let kelvin?, nil): return ValueFormatters.kelvin(kelvin)
        case (nil, let tint?): return ValueFormatters.tint(tint)
        }
    }

    // MARK: - Sliders

    private var isoSlider: some View {
        Slider(
            value: Binding<Float>(
                get: { engine.iso ?? Self.midpoint(of: engine.ranges.iso) },
                set: {
                    engine.iso = $0
                    engine.noteFieldChanged()
                }
            ),
            in: engine.ranges.iso,
            onEditingChanged: sliderEditingChanged
        )
        // TODO(T7a): restyle with DesignSystem ControlDial.
    }

    /// Logarithmic slider so the fast end (1/8000 s) keeps usable screen
    /// space; a linear mapping would crush 1/8000…1/60 into a few pixels.
    private var shutterSlider: some View {
        Slider(
            value: Binding<Double>(
                get: {
                    Self.shutterToSlider(
                        engine.shutterSeconds ?? Self.midpoint(of: engine.ranges.exposureSeconds),
                        in: engine.ranges.exposureSeconds
                    )
                },
                set: {
                    engine.shutterSeconds = Self.sliderToShutter($0, in: engine.ranges.exposureSeconds)
                    engine.noteFieldChanged()
                }
            ),
            in: 0...1,
            onEditingChanged: sliderEditingChanged
        )
        // TODO(T7a): restyle with DesignSystem ControlDial.
    }

    private var focusSlider: some View {
        Slider(
            value: Binding<Float>(
                get: { engine.lensPosition ?? Self.midpoint(of: engine.ranges.lensPosition) },
                set: {
                    engine.lensPosition = $0
                    engine.noteFieldChanged()
                }
            ),
            in: engine.ranges.lensPosition,
            onEditingChanged: sliderEditingChanged
        )
        // TODO(T7a): restyle with DesignSystem ControlDial.
    }

    private var kelvinSlider: some View {
        Slider(
            value: Binding<Float>(
                get: { engine.kelvin ?? Self.midpoint(of: engine.ranges.kelvin) },
                set: {
                    engine.kelvin = $0
                    engine.noteFieldChanged()
                }
            ),
            in: engine.ranges.kelvin,
            step: 50,
            onEditingChanged: sliderEditingChanged
        )
        // TODO(T7a): restyle with DesignSystem ControlDial.
    }

    private var tintSlider: some View {
        Slider(
            value: Binding<Float>(
                get: { engine.tint ?? Self.midpoint(of: engine.ranges.tint) },
                set: {
                    engine.tint = $0
                    engine.noteFieldChanged()
                }
            ),
            in: engine.ranges.tint,
            step: 5,
            onEditingChanged: sliderEditingChanged
        )
        // TODO(T7a): restyle with DesignSystem ControlDial.
    }

    /// Drag end → unconditional final commit through the engine's coalescer.
    private func sliderEditingChanged(_ editing: Bool) {
        if !editing {
            engine.endEditing()
        }
    }

    // MARK: - Pure slider mapping helpers

    /// Concrete `Float`/`Double` overloads rather than a generic parameter:
    /// `FloatingPoint` does not refine `ExpressibleByFloatLiteral` (that is
    /// `BinaryFloatingPoint`), so the `0.5` literal in the body cannot
    /// type-check against a bare `T` (CI fix round 1). Nothing generic was
    /// being bought — every slider maps to one of these two types.
    private static func midpoint(of range: ClosedRange<Float>) -> Float {
        (range.lowerBound + range.upperBound) * 0.5
    }

    private static func midpoint(of range: ClosedRange<Double>) -> Double {
        (range.lowerBound + range.upperBound) * 0.5
    }

    /// Seconds → slider position in 0…1 over log space (identity at bounds).
    static func shutterToSlider(_ seconds: Double, in range: ClosedRange<Double>) -> Double {
        let low = log(range.lowerBound)
        let high = log(range.upperBound)
        guard high > low, seconds > 0 else { return 0 }
        return min(max((log(seconds) - low) / (high - low), 0), 1)
    }

    /// Slider position in 0…1 → seconds over log space, clamped to the range.
    static func sliderToShutter(_ position: Double, in range: ClosedRange<Double>) -> Double {
        let low = log(range.lowerBound)
        let high = log(range.upperBound)
        guard high > low else { return range.lowerBound }
        let seconds = exp(low + position * (high - low))
        return min(max(seconds, range.lowerBound), range.upperBound)
    }
}

// MARK: - Section scaffolding

/// One labeled manual-control row: title, live value, AUTO badge while the
/// bound field is nil, per-section reset, and the slider content.
private struct ManualSection<Content: View>: View {
    let title: String
    let valueText: String
    let isAuto: Bool
    let onReset: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(valueText)
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 64, alignment: .leading)
                if isAuto {
                    Text("AUTO")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.yellow.opacity(0.25)))
                        .foregroundStyle(.yellow)
                }
                Spacer()
                Button("Reset") { onReset() }
                    .font(.caption2)
                    .buttonStyle(.borderless)
            }
            content()
        }
    }
}
