import SwiftUI

// Task 10 — manual lens dial: horizontal lens-pin chip row.
//
// One chip per present lens of the back camera (front hides the picker),
// plus a trailing "Auto" chip that unpins. The pinned chip is highlighted with
// the theme accent; the Auto chip is highlighted while nothing is pinned. The
// row is disabled + dimmed until the session is ready (T4 review I1) — the same
// gate the rest of the viewfinder controls live under.

// MARK: - LensPicker

/// Lens picker for the live viewfinder: pins the active optical lens (manual
/// selection) or returns to Auto (continuous zoom with optical handoff).
struct LensPicker: View {

    let hud: CaptureHUDState

    // MARK: - Body

    var body: some View {
        if hud.position == .back {
            chipRow
        }
    }

    // MARK: - Chip row

    private var chipRow: some View {
        HStack(spacing: Theme.Spacing.m) {
            ForEach(lensChips) { chip in
                HUDChip(icon: chip.icon, label: chip.label, state: chip.state) {
                    hud.pinLens(chip.id)
                }
            }
            HUDChip(
                icon: "sparkles",
                label: "Auto",
                state: hud.pinnedLens == nil ? .on : .off
            ) {
                hud.unpinLens()
            }
        }
        .disabled(!hud.sessionReady)
        .opacity(hud.sessionReady ? 1 : Theme.Opacity.dimmed)
        .animation(.easeInOut(duration: Theme.Animation.labelFade), value: hud.sessionReady)
    }

    // MARK: - Derivation

    /// Present back-camera lenses, ascending by focal length, with the pinned
    /// state folded into each chip.
    private var lensChips: [LensChip] {
        guard hud.position == .back else { return [] }
        return hud.lenses
            .filter { $0.id != .front }
            .sorted { $0.focalLengthMM < $1.focalLengthMM }
            .map { lens in
                LensChip(
                    id: lens.id,
                    icon: "camera",
                    label: lens.displayName,
                    state: hud.pinnedLens == lens.id ? .on : .off
                )
            }
    }
}

// MARK: - LensChip

/// One lens-pin chip (state derived by the parent from `hud.pinnedLens`).
private struct LensChip: Identifiable {
    let id: CameraLensID
    let icon: String
    let label: String
    let state: HUDChipState
}
