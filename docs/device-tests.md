# Device Tests

Manual on-device test checklist — appended by each task; executed on the sideloaded iPhone 11 Pro Max.

## Task 4 — CameraService

Run on the sideloaded iPhone 11 Pro Max (A13). All checks assume the real
`CameraService` is wired in; before it is, `AppEnvironment` still returns
`PlaceholderCameraService` and none of this exercises hardware.

**Session lifecycle**
1. Call `startSession()`; expect the session to reach `isRunning` with no UI
   freeze — start work happens on `camera.session`, not the main thread.
2. Call `startSession()` again — idempotent, no second configuration.
3. `stopSession()` then `startSession()` — session restarts without rebuilding
   the full configuration.
4. Before `startSession()`, read `capabilities` — expect
   `CameraCapabilities.iPhone11ProMaxFallback`.

**Capabilities (after startSession)**
5. `capabilities` no longer equals the fallback: confirm `supportsRAW == true`,
   `maxHardwareBracketCount >= 3`, `zoomRange == 0.5...10`, `hasUltraWide`,
   `hasTele`, `teleFactor == 2`, and `supportsProRes == false` /
   `supports10BitHDR` (A13: HDR format flag may be false at the photo preset).
6. `availableLenses` lists ultra-wide, wide, telephoto and front.

**Lens switch**
7. `selectLens(.ultraWide)`, `.wide`, `.tele` — the preview keeps running across
   each swap (input swap is wrapped in begin/commit configuration).
8. `selectLens(.front)` / `selectDevice(.front)` then `selectDevice(.back)` —
   returns to the wide rear lens.
9. `selectLens(.tele)` on a device without a telephoto throws
   `CameraServiceError.lensUnavailable`.

**Zoom across boundaries**
10. `setZoom(0.5)` → ultra-wide (device zoom ~1.0). `setZoom(1.0)` → wide.
    `setZoom(2.0)` → telephoto. Watch the preview: apparent magnification is
    preserved across each handoff (no jump).
11. `setZoom(10)` clamps to the active device's max; `setZoom(0.1)` clamps to the
    range low bound.

**Manual sliders stick**
12. `applyManualConfig` with both `iso` and `exposureDurationSeconds` — the
    preview exposure holds after lifting the finger (exposure mode custom).
13. `applyManualConfig` with `lensPosition` — focus locks at that distance.
14. `applyManualConfig` with `kelvin` + `tint` — white balance locks; the tint is
    on the magenta/green axis.
15. `resetToAuto()` — exposure/focus/white balance return to continuous auto and
    respond to scene changes again.
16. `supportedManualRanges` reflects the active format (ISO min…max,
    shutter min…max per lens).

**Focus / exposure**
17. Tap to `focus(at:)` with device coordinates from
    `CameraService.devicePoint(forViewPoint:inPreviewSize:)` — focus pulls to the
    tapped point; exposure follows.
18. `setExposureOffset(+2)` / `(-2)` — preview brightens/darkens; clamps to the
    device's min/max exposure-target bias.

**Capture**
19. `capturePhoto` jpeg — returns non-empty `Data`, non-zero width/height, and an
    `ExifSummary` with ISO, shutter, focal length, aperture and device model.
20. `capturePhoto` heif — succeeds (HEVC available on A13) and the data's UTI is
    HEIC.
21. `capturePhoto` dng — succeeds on A13; if
    `availableRawPhotoPixelFormatTypes` is empty (e.g. no configured session),
    it throws `CameraServiceError.rawUnsupported`.
22. `capturePhoto` with `timerSeconds: 3` — shutter fires ~3 s later, on the
    session queue (no main-thread sleep).
23. `capturePhoto` before `startSession()` throws
    `CameraServiceError.sessionNotConfigured`.

**Bracketing**
24. `captureBracket(depth: .aeb3)` — three frames at −2/0/+2 EV, returned
    dark→bright.
25. `captureBracket(depth: .soft5/.soft7/.soft9)` — 5/7/9 frames with evenly
    stepped exposure spanning ±3/±3.5/±4 EV, returned dark→bright; exposure is
    restored to continuous auto afterwards.

**Preview frames**
26. `setPreviewFrameHandler` — frames arrive on `camera.videoOutput` at the
    preview rate; `alwaysDiscardsLateVideoFrames` means no backlog under load.
27. Set the handler to `nil` — frames stop being delivered.

**Video (Task 14 stubs)**
28. `startVideoRecording(_:)` throws `CameraServiceError.videoNotImplemented`.
29. `stopVideoRecording()` returns a placeholder URL that no file backs.
