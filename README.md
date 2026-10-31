# CameraApp

A pro/manual camera app for iPhone. v1 target device: **iPhone 11 Pro Max** (A13, iOS 27).
Built in Swift 6 / SwiftUI, minimum iOS 17, MVVM, no third-party dependencies.

Feature set v1 (one-liner): manual exposure/focus controls, focus & exposure bracketing,
video capture, in-app gallery, lens-correction and super-resolution processing, and
watermarking/looks — implemented across `CameraApp/` modules.

## Build flow: Windows → GitHub Actions

There is no local Xcode on Windows, so the project is never built on the dev machine.
Instead:

1. Commit and push to GitHub (the orchestrator manages the remote).
2. GitHub Actions (`.github/workflows/ios.yml`) runs on `macos-latest`:
   - selects Xcode 26,
   - installs XcodeGen and runs `xcodegen generate` (the `.xcodeproj` is **not** committed),
   - compiles the app for the iOS Simulator as a fast check,
   - archives unsigned and packages `build/CameraApp.ipa` as a downloadable artifact.

## Getting the unsigned IPA onto a device

1. Open the workflow run in GitHub → **Artifacts** → download `CameraApp-unsigned-ipa`.
2. Unzip to get `CameraApp.ipa`.
3. Sideload with **Sideloadly** or **AltServer** using a free Apple ID.
4. Free-account builds expire after **7 days** — re-sign with the same tool to keep it working.

The IPA is unsigned, so it cannot be installed via the App Store or TestFlight; a
sideloading tool (or re-signing with your own team) is required.

## Repo layout

| Path | Purpose |
| --- | --- |
| `project.yml` | XcodeGen project definition (source of truth for the Xcode project) |
| `CameraApp/App/` | App entry point and app-level composition |
| `CameraApp/Camera/` | Capture pipeline (session, device control) |
| `CameraApp/Manual/` | Manual exposure/focus/ISO/shutter UI + model |
| `CameraApp/Bracketing/` | Focus and exposure bracketing |
| `CameraApp/Video/` | Video recording |
| `CameraApp/Gallery/` | In-app media gallery |
| `CameraApp/Processing/LensCorrection/` | Lens-profile based correction |
| `CameraApp/SuperRes/` | Super-resolution processing |
| `CameraApp/Watermark/` | Watermark rendering |
| `CameraApp/Looks/` | Color looks/filters |
| `CameraApp/Permissions/` | Camera/mic/photos/location permission handling |
| `CameraApp/Core/` | Shared core utilities |
| `CameraApp/Resources/` | Bundled looks, lens profiles, watermark templates |
| `.github/workflows/` | CI (build + unsigned IPA artifact) |
| `docs/` | Device test checklist (`docs/device-tests.md`) and design docs |

## Device testing

Because CI only proves it compiles and archives, every task appends manual on-device
checks to [`docs/device-tests.md`](docs/device-tests.md), executed on the sideloaded
iPhone 11 Pro Max.
