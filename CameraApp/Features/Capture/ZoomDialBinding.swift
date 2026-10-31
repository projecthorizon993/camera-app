import SwiftUI

// Task 7 — continuous zoom plumbing (brief deliverable 3): the dial surface
// derived from the service's lens/capability snapshots, plus the pinch
// gesture bound to the same path as the dial. The service clamps the final
// factor, but the UI clamps too so the dial/badge never display an
// out-of-range value.

// MARK: - ZoomStopPlanner

/// Pure derivation of the zoom dial surface. Foundation/CoreGraphics only —
/// unit-testable without hardware (see ZoomStopPlannerTests).
enum ZoomStopPlanner {

    /// Optical stops for the dial, ascending: 0.5× ultra-wide, 1× wide, and
    /// the telephoto factor when the lens exists (never displayed below 2×).
    /// The front camera has a single 1× stop.
    static func opticalStops(lenses: [LensInfo], position: DevicePosition, teleFactor: CGFloat) -> [CGFloat] {
        if position == .front { return [1] }
        var stops: [CGFloat] = []
        for lens in lenses where lens.id != .front {
            switch lens.id {
            case .ultraWide: stops.append(0.5)
            case .wide: stops.append(1)
            case .tele: stops.append(max(teleFactor, 2))
            case .front: break
            }
        }
        return stops.sorted()
    }

    /// Full draggable range. The front camera has no ultra-wide, so the lower
    /// bound is raised to 1× regardless of what the capability snapshot says.
    static func draggableRange(capabilities: CameraCapabilities, position: DevicePosition) -> ClosedRange<CGFloat> {
        let bounds = capabilities.zoomRange
        guard position == .front else { return bounds }
        let lower = max(bounds.lowerBound, 1)
        return lower...max(bounds.upperBound, lower)
    }
}

// MARK: - Pinch to zoom

/// Pinch gesture over the viewfinder: multiplies the factor that was live at
/// gesture start by the cumulative magnification, streaming through the same
/// throttled push path as the dial, and commits unconditionally on gesture
/// end so the final value always reaches the device.
private struct PinchToZoomModifier: ViewModifier {

    let hud: CaptureHUDState
    let isEnabled: Bool

    /// Factor live when the current pinch began; nil between gestures.
    @State private var pinchBase: CGFloat?

    func body(content: Content) -> some View {
        content.gesture(
            isEnabled
                ? MagnifyGesture()
                    .onChanged { value in
                        if pinchBase == nil { pinchBase = hud.zoomFactor }
                        hud.setZoomFactor((pinchBase ?? hud.zoomFactor) * value.magnification)
                    }
                    .onEnded { _ in
                        pinchBase = nil
                        hud.commitZoom()
                    }
                : nil
        )
    }
}

extension View {

    /// Continuous pinch zoom bound to `cameraService.setZoom` (via the HUD
    /// state's throttled push). Disabled while the session is starting so no
    /// off-main call can precede `startSession()`.
    func pinchToZoom(hud: CaptureHUDState, isEnabled: Bool) -> some View {
        modifier(PinchToZoomModifier(hud: hud, isEnabled: isEnabled))
    }
}
