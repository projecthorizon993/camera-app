import Foundation
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO

// Task 4 — the AVFoundation hardware engine behind `CameraServiceProtocol`.
//
// CONCURRENCY (binding review finding I1)
// ---------------------------------------
// Under Approachable Concurrency (SE-0461) a `nonisolated async` method runs on
// the CALLER's actor, so `async throws` is NOT a background guarantee: if a
// `@MainActor` view awaits `capturePhoto`, the body would otherwise resume on the
// main thread. Every AVFoundation interaction in this file is therefore confined
// to the private serial `sessionQueue` — either inside an explicit
// `sessionQueue.async` hop (async members, via `withCheckedThrowingContinuation`)
// or inside `sessionQueue.sync` (synchronous members). Nothing touches a device,
// session, or output from the caller's actor.
//
// The photo-output delegate callbacks are delivered on AVFoundation's own
// internal queue (AVCapturePhotoOutput has no settable delegate queue, unlike the
// video-data output), so the per-capture `PhotoCaptureDelegate` only ever hands a
// `Result` to a continuation / lock-guarded dictionary — it never mutates
// session-queue state directly.
//
// STATE PUBLICATION
// -----------------
// The protocol getters (`capabilities`, `availableLenses`, `supportedManualRanges`)
// are synchronous and nonisolated, so `CameraService` is deliberately NOT
// `@MainActor`. Snapshots are published through lock-guarded stored properties
// (`stateLock`) rather than a `@Published` `@MainActor` state object; UI observes
// those getters or the `setPreviewFrameHandler` feed. This keeps the service
// usable from any isolation domain.
final class CameraService: NSObject, CameraServiceProtocol, @unchecked Sendable {

    // MARK: - Static presentation defaults
    //
    // `LensInfo.focalLengthMM`/`displayName` have no public AVFoundation source
    // (there is no device-level focal-length API) — they are A13-class display
    // hints. Presence is still runtime-derived: `availableLenses` keeps only the
    // hints whose physical device actually exists.

    private static let defaultLenses: [LensInfo] = [
        LensInfo(id: .ultraWide, displayName: "0.5x Ultra Wide", focalLengthMM: 13, aperture: 2.4),
        LensInfo(id: .wide, displayName: "1x Wide", focalLengthMM: 26, aperture: 1.8),
        LensInfo(id: .tele, displayName: "2x Telephoto", focalLengthMM: 52, aperture: 2.0),
        LensInfo(id: .front, displayName: "Front", focalLengthMM: 23, aperture: 2.2),
    ]

    /// Pre-session manual ranges, mirroring `iPhone11ProMaxFallback`.
    private static let defaultManualRanges = ManualRanges(
        iso: CameraCapabilities.iPhone11ProMaxFallback.isoRange,
        exposureSeconds: 0.000125...CameraCapabilities.iPhone11ProMaxFallback.maxShutterSeconds,
        lensPosition: 0...1,
        kelvin: 2000...8000,
        tint: -150...150
    )

    // MARK: - Queues & locks

    /// The one queue every AVFoundation call is confined to.
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let sessionQueueKey = DispatchSpecificKey<UInt8>()

    /// Preview-frame delivery queue for `AVCaptureVideoDataOutput`.
    private let videoOutputQueue = DispatchQueue(label: "camera.videoOutput")

    /// Guards every snapshot published to nonisolated callers.
    private let stateLock = NSLock()
    /// Guards the in-flight photo-capture delegates.
    private let delegateLock = NSLock()

    // MARK: - Published snapshots (stateLock)

    private var _capabilities: CameraCapabilities = .iPhone11ProMaxFallback
    private var _availableLenses: [LensInfo] = CameraService.defaultLenses
    private var _supportedManualRanges: ManualRanges = CameraService.defaultManualRanges
    private var _currentLens: CameraLensID = .wide
    private var _currentPosition: DevicePosition = .back
    private var _previewFrameHandler: (@Sendable (CVPixelBuffer) -> Void)?

    // MARK: - AVFoundation (sessionQueue-confined)

    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()

    private var currentInput: AVCaptureDeviceInput?
    private var currentDevice: AVCaptureDevice?
    private var cachedDevices: [CameraLensID: AVCaptureDevice] = [:]
    private var isConfigured = false

    // MARK: - Capture bookkeeping

    private var photoDelegates: [Int64: PhotoCaptureDelegate] = [:]

    /// Motion-guard hook for bracketed capture (Task 12 owns the merge). Unused
    /// for now; declared so the consumer contract is stable.
    var bracketAbortThreshold: Double = 0

    // MARK: - Init

    override init() {
        super.init()
        sessionQueue.setSpecific(key: sessionQueueKey, value: 1)
    }

    // MARK: - Locked snapshot helpers

    private func locked<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private func lockedDelegates<T>(_ body: () -> T) -> T {
        delegateLock.lock()
        defer { delegateLock.unlock() }
        return body()
    }

    /// Runs `work` on the session queue, executing inline if we are already on it
    /// (prevents self-deadlock when a synchronous member is reached from a queue
    /// closure).
    private func onSessionQueue<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: sessionQueueKey) != nil {
            return try work()
        }
        return try sessionQueue.sync(execute: work)
    }

    /// Async sibling of `onSessionQueue`: hops to the serial queue and resumes
    /// off it. `T` must be `Sendable` because it crosses the queue boundary.
    private func withSessionQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            sessionQueue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - CameraServiceProtocol: snapshot getters

    var capabilities: CameraCapabilities {
        locked { _capabilities }
    }

    var availableLenses: [LensInfo] {
        locked { _availableLenses }
    }

    var supportedManualRanges: ManualRanges {
        locked { _supportedManualRanges }
    }

    // MARK: - CameraServiceProtocol: session lifecycle

    /// Configures the session on the serial queue (once) and starts it off the
    /// main thread. Idempotent: repeated calls either no-op or (re)start a
    /// previously stopped session.
    func startSession() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CameraServiceError.sessionNotConfigured)
                    return
                }
                do {
                    try self.configureSessionLocked()
                    if !self.session.isRunning {
                        self.session.startRunning()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Stops the session off-main. Idempotent; the configuration is retained so a
    /// later `startSession()` is cheap.
    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    // MARK: - CameraServiceProtocol: device / lens switching

    func selectDevice(_ position: DevicePosition) throws {
        try onSessionQueue { try self.selectDeviceLocked(position) }
    }

    func selectLens(_ id: CameraLensID) throws {
        try onSessionQueue { try self.selectLensLocked(id) }
    }

    // MARK: - CameraServiceProtocol: zoom

    /// Continuous apparent-magnification zoom (0.5x…10x) with explicit lens
    /// handoff: the lens whose optical range covers the factor is selected, the
    /// input is swapped if needed, and the new device's `videoZoomFactor` is set
    /// so apparent magnification is preserved. Direct set — the UI owns smoothing.
    func setZoom(_ factor: CGFloat) throws {
        try onSessionQueue { try self.applyZoomLocked(factor) }
    }

    // MARK: - CameraServiceProtocol: manual configuration

    func applyManualConfig(_ config: ManualCameraConfig) throws {
        try onSessionQueue { try self.applyManualConfigLocked(config) }
    }

    func resetToAuto() throws {
        onSessionQueue { self.resetToAutoLocked() }
    }

    // MARK: - CameraServiceProtocol: capture

    /// Captures one still. All work happens on the session queue; the result is
    /// delivered through a checked continuation from the photo delegate.
    func capturePhoto(_ settings: PhotoCaptureSettings) async throws -> CapturedPhoto {
        let photos: [CapturedPhoto] = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CapturedPhoto], Error>) in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CameraServiceError.sessionNotConfigured)
                    return
                }
                // Build settings (and the timer-armed start) inside the queue so
                // the non-Sendable AVCapturePhotoSettings never crosses a
                // concurrency boundary.
                let start: @Sendable () -> Void = {
                    do {
                        let avSettings = try self.makePhotoSettings(settings)
                        self.applyOrientationLocked(settings.orientation)
                        self.fireCapture(avSettings, continuation: continuation)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                if settings.timerSeconds > 0 {
                    // Caller-side delay would be wrong; arm a dispatch timer here.
                    self.sessionQueue.asyncAfter(deadline: .now() + .seconds(settings.timerSeconds), execute: start)
                } else {
                    start()
                }
            }
        }
        guard let first = photos.first else {
            throw CameraServiceError.photoDataUnavailable
        }
        return first
    }

    /// Bracketed capture. `.aeb3` uses the hardware AE bracket; the `soft*`
    /// depths are sequential captures with stepped exposure on the queue. No
    /// merging happens here (Task 12 owns the merge).
    func captureBracket(depth: BracketDepth) async throws -> [CapturedPhoto] {
        if depth.isHardware {
            return try await captureHardwareBracket()
        }
        return try await captureSoftBracket(depth)
    }

    // MARK: - CameraServiceProtocol: video (Task 14 stubs)

    /// TODO(Task 14): configure `AVCaptureMovieFileOutput`/`AVAssetWriter`, audio
    /// input, ProRes/HEVC selection and start recording.
    func startVideoRecording(_ config: VideoRecordingConfig) throws {
        throw CameraServiceError.videoNotImplemented
    }

    /// TODO(Task 14): stop the recorder and return the finished file URL.
    ///
    /// Deviation from the brief: the frozen contract types this member as
    /// `async -> URL` (non-throwing), so it cannot throw
    /// `CameraServiceError.videoNotImplemented`. It returns a placeholder URL
    /// that no file backs; Task 14 replaces the body.
    func stopVideoRecording() async -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("camera-service-video-not-implemented.mov")
    }

    // MARK: - CameraServiceProtocol: focus / exposure

    /// `point` is in capture-device coordinates (0…1); use
    /// `CameraService.devicePoint(forViewPoint:inPreviewSize:)` to convert a
    /// preview-layer point first.
    func focus(at point: CGPoint) throws {
        try onSessionQueue { try self.focusLocked(point) }
    }

    func setExposureOffset(_ ev: Float) throws {
        try onSessionQueue { try self.setExposureOffsetLocked(ev) }
    }

    // MARK: - CameraServiceProtocol: preview frames

    func setPreviewFrameHandler(_ handler: (@Sendable (CVPixelBuffer) -> Void)?) {
        locked { _previewFrameHandler = handler }
    }

    /// Pure conversion from a point in a preview of `size` to normalized capture
    /// -device coordinates in 0…1. Exposed for Task 5's preview layer; rotation
    /// compensation stays the caller's responsibility (a `AVCaptureVideoPreviewLayer`
    /// knows its connection's rotation, this static helper does not).
    static func devicePoint(forViewPoint point: CGPoint, inPreviewSize size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        let x = min(max(point.x / size.width, 0), 1)
        let y = min(max(point.y / size.height, 0), 1)
        return CGPoint(x: x, y: y)
    }

    // MARK: - Session configuration (sessionQueue)

    private func configureSessionLocked() throws {
        if isConfigured { return }

        cachedDevices = discoverDevices()
        guard let wide = cachedDevices[.wide] else {
            throw CameraServiceError.deviceUnavailable(.back)
        }

        session.beginConfiguration()
        do {
            if session.canSetSessionPreset(.photo) {
                session.sessionPreset = .photo
            }

            let input = try AVCaptureDeviceInput(device: wide)
            guard session.canAddInput(input) else {
                throw CameraServiceError.configurationFailed("cannot add camera input")
            }
            session.addInput(input)
            currentInput = input
            currentDevice = wide

            guard session.canAddOutput(photoOutput) else {
                throw CameraServiceError.configurationFailed("cannot add photo output")
            }
            session.addOutput(photoOutput)

            guard session.canAddOutput(videoOutput) else {
                throw CameraServiceError.configurationFailed("cannot add video data output")
            }
            session.addOutput(videoOutput)
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA)
            ]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: videoOutputQueue)
        } catch {
            session.commitConfiguration()
            throw error
        }
        session.commitConfiguration()

        isConfigured = true
        locked {
            _currentLens = .wide
            _currentPosition = .back
            _availableLenses = lensHints(for: cachedDevices)
        }
        refreshCapabilitiesLocked()
    }

    /// Physical-device discovery. Built-in discrete devices keep the surface
    /// simple; virtual (multi-lens) devices are only consulted for capability
    /// probing, never added as inputs here.
    private func discoverDevices() -> [CameraLensID: AVCaptureDevice] {
        var result: [CameraLensID: AVCaptureDevice] = [:]

        let backTypes: [AVCaptureDevice.DeviceType] = [
            .builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera,
        ]
        let back = AVCaptureDevice.DiscoverySession(deviceTypes: backTypes, mediaType: .video, position: .back)
        for device in back.devices {
            switch device.deviceType {
            case .builtInUltraWideCamera: result[.ultraWide] = device
            case .builtInWideAngleCamera: result[.wide] = device
            case .builtInTelephotoCamera: result[.tele] = device
            default: break
            }
        }

        let front = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .front
        )
        if let frontDevice = front.devices.first {
            result[.front] = frontDevice
        }
        return result
    }

    private func lensHints(for devices: [CameraLensID: AVCaptureDevice]) -> [LensInfo] {
        let present = Self.defaultLenses.filter { devices[$0.id] != nil }
        return present.isEmpty ? Self.defaultLenses : present
    }

    // MARK: - Capabilities (sessionQueue)

    /// Queries the active format once per configuration and caches the result.
    /// Until the session is configured the getters report `iPhone11ProMaxFallback`.
    private func refreshCapabilitiesLocked() {
        guard let device = currentDevice else { return }
        let format = device.activeFormat

        let hasUltraWide = cachedDevices[.ultraWide] != nil
        let hasTele = cachedDevices[.tele] != nil
        let teleFactor = computeTeleFactorLocked()

        // Apparent-magnification range: 0.5x when an ultra-wide exists, 1x
        // otherwise, up to a ×10 digital cap (optical reach beyond that is
        // reachable but the brief fixes the UI dial at 10x).
        let minZoom: CGFloat = hasUltraWide ? 0.5 : 1.0
        let zoomRange: ClosedRange<CGFloat> = minZoom...10.0

        let maxShutter = Self.finiteOrDefault(format.maxExposureDuration.seconds, fallback: 1.0)
        let minShutter = Self.finiteOrDefault(format.minExposureDuration.seconds, fallback: 0.000125)
        let isoLow = format.minISO
        let isoHigh = max(format.maxISO, isoLow + 1)

        let supportsRAW = !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty
        let maxBracket = max(photoOutput.maxBracketedCapturePhotoCount, 1)

        // ProRes is a movie-output capability (`AVCaptureMovieFileOutput.availableVideoCodecTypes`,
        // owned by Task 14); there is no format-level check, so the gate stays
        // false here and Task 14 flips it. 10-bit HDR is a format capability.
        let supportsProRes = false
        let supports10Bit = format.isVideoHDRSupported

        let maxPhotoWidth = format.supportedMaxPhotoDimensions.map { Int($0.width) }.max() ?? 0
        let supports48MP = maxPhotoWidth >= 8000

        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        var resolutions: [VideoResolution] = [.hd1080]
        if Int(dimensions.height) >= 2160 || Int(dimensions.width) >= 3840 {
            resolutions.append(.uhd4K)
        }

        var maxFrameRate = 0.0
        for candidate in device.formats {
            for range in candidate.videoSupportedFrameRateRanges {
                maxFrameRate = max(maxFrameRate, Double(range.maxFrameRate))
            }
        }
        let maxFPS = maxFrameRate > 0 ? Int(maxFrameRate.rounded()) : 30

        let capabilities = CameraCapabilities(
            hasUltraWide: hasUltraWide,
            hasTele: hasTele,
            teleFactor: teleFactor,
            zoomRange: zoomRange,
            maxShutterSeconds: maxShutter,
            isoRange: isoLow...isoHigh,
            supportsRAW: supportsRAW,
            maxHardwareBracketCount: maxBracket,
            supportsProRes: supportsProRes,
            supports10BitHDR: supports10Bit,
            supports48MP: supports48MP,
            supportedResolutions: resolutions,
            maxFPS: maxFPS
        )

        locked {
            _capabilities = capabilities
            _supportedManualRanges = makeManualRanges(format: format, minShutter: minShutter, maxShutter: maxShutter)
        }
    }

    private func refreshManualRangesLocked() {
        guard let device = currentDevice else { return }
        let format = device.activeFormat
        let minShutter = Self.finiteOrDefault(format.minExposureDuration.seconds, fallback: 0.000125)
        let maxShutter = Self.finiteOrDefault(format.maxExposureDuration.seconds, fallback: 1.0)
        locked {
            _supportedManualRanges = makeManualRanges(format: format, minShutter: minShutter, maxShutter: maxShutter)
        }
    }

    private func makeManualRanges(format: AVCaptureDevice.Format, minShutter: Double, maxShutter: Double) -> ManualRanges {
        ManualRanges(
            iso: format.minISO...max(format.maxISO, format.minISO + 1),
            exposureSeconds: min(minShutter, maxShutter)...max(minShutter, maxShutter),
            lensPosition: 0...1,
            // No public Kelvin range API; conventional photographic bounds.
            kelvin: 2000...8000,
            tint: -150...150
        )
    }

    /// Runtime source for the telephoto factor: the virtual multi-camera's
    /// switch-over video-zoom factors. Falls back to the A13-class 2x only when
    /// no virtual device is exposed (no public API for discrete-tele optics).
    private func computeTeleFactorLocked() -> CGFloat {
        let virtualTypes: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: virtualTypes, mediaType: .video, position: .back)
        for device in discovery.devices {
            if let first = device.virtualDeviceSwitchOverVideoZoomFactors.first {
                return CGFloat(first.doubleValue)
            }
        }
        return 2.0
    }

    private static func finiteOrDefault(_ value: Double, fallback: Double) -> Double {
        (value.isFinite && value > 0) ? value : fallback
    }

    // MARK: - Device / lens switching (sessionQueue)

    private func selectDeviceLocked(_ position: DevicePosition) throws {
        guard currentDevice != nil else { throw CameraServiceError.sessionNotConfigured }
        switch position {
        case .front:
            try selectLensLocked(.front)
        case .back:
            if locked({ _currentPosition }) == .back { return }
            if let wide = cachedDevices[.wide] {
                try setInputLocked(to: wide, lens: .wide)
            } else if let ultra = cachedDevices[.ultraWide] {
                try setInputLocked(to: ultra, lens: .ultraWide)
            } else if let tele = cachedDevices[.tele] {
                try setInputLocked(to: tele, lens: .tele)
            } else {
                throw CameraServiceError.deviceUnavailable(.back)
            }
            locked { _currentPosition = .back }
        }
    }

    private func selectLensLocked(_ id: CameraLensID) throws {
        guard currentDevice != nil else { throw CameraServiceError.sessionNotConfigured }
        guard let device = cachedDevices[id] else { throw CameraServiceError.lensUnavailable(id) }
        try setInputLocked(to: device, lens: id)
        locked { _currentPosition = (id == .front) ? .front : .back }
    }

    /// Swaps the active input while keeping the session alive
    /// (`beginConfiguration`/`commitConfiguration`).
    private func setInputLocked(to device: AVCaptureDevice, lens: CameraLensID) throws {
        if currentDevice?.uniqueID == device.uniqueID {
            locked { _currentLens = lens }
            return
        }

        let newInput = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        let oldInput = currentInput
        if let oldInput {
            session.removeInput(oldInput)
        }
        if session.canAddInput(newInput) {
            session.addInput(newInput)
            session.commitConfiguration()
            currentInput = newInput
            currentDevice = device
            locked { _currentLens = lens }
            refreshManualRangesLocked()
        } else {
            if let oldInput {
                session.addInput(oldInput)
            }
            session.commitConfiguration()
            throw CameraServiceError.configurationFailed("cannot swap to \(device.localizedName)")
        }
    }

    private func deviceZoom(forApparent factor: CGFloat, lens: CameraLensID) -> CGFloat {
        let tele = locked { _capabilities.teleFactor }
        switch lens {
        case .ultraWide: return factor / 0.5
        case .tele: return factor / max(tele, 1)
        case .wide, .front: return factor
        }
    }

    private func lensForApparentZoom(_ factor: CGFloat) -> CameraLensID {
        let (position, caps) = locked { (_currentPosition, _capabilities) }
        if position == .front { return .front }
        if caps.hasUltraWide && factor < 1.0 { return .ultraWide }
        if caps.hasTele && factor >= caps.teleFactor { return .tele }
        return .wide
    }

    // MARK: - Zoom (sessionQueue)

    private func applyZoomLocked(_ factor: CGFloat) throws {
        guard currentDevice != nil else { throw CameraServiceError.sessionNotConfigured }
        let caps = locked { _capabilities }
        guard factor.isFinite else { throw CameraServiceError.zoomOutOfRange(factor) }

        let clamped = min(max(factor, caps.zoomRange.lowerBound), caps.zoomRange.upperBound)
        let target = lensForApparentZoom(clamped)

        if target != locked({ _currentLens }) {
            guard let device = cachedDevices[target] else { throw CameraServiceError.lensUnavailable(target) }
            try setInputLocked(to: device, lens: target)
        }
        guard let device = currentDevice else { throw CameraServiceError.sessionNotConfigured }

        var requested = deviceZoom(forApparent: clamped, lens: target)
        let minZoom = max(CGFloat(device.minAvailableVideoZoomFactor), 1)
        let maxZoom = max(CGFloat(device.activeFormat.videoMaxZoomFactor), minZoom)
        requested = min(max(requested, minZoom), maxZoom)

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.videoZoomFactor = requested
    }

    // MARK: - Manual configuration (sessionQueue)

    private func applyManualConfigLocked(_ config: ManualCameraConfig) throws {
        guard let device = currentDevice else { throw CameraServiceError.sessionNotConfigured }
        let format = device.activeFormat

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        // Exposure: `setExposureModeCustom` needs BOTH duration and ISO. If only
        // one is supplied, that field keeps its automatic behaviour.
        if let iso = config.iso, let duration = config.exposureDurationSeconds {
            guard device.isExposureModeSupported(.custom) else {
                throw CameraServiceError.manualExposureUnsupported
            }
            let clampedISO = min(max(iso, format.minISO), format.maxISO)
            let clampedDuration = min(max(duration, format.minExposureDuration.seconds), format.maxExposureDuration.seconds)
            let time = CMTime(seconds: clampedDuration, preferredTimescale: 1_000_000_000)
            device.setExposureModeCustom(duration: time, iso: clampedISO, completionHandler: nil)
        } else if config.iso != nil || config.exposureDurationSeconds != nil {
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
        }

        // Focus: locked at a normalized lens position.
        if let lensPosition = config.lensPosition {
            if device.isFocusModeSupported(.locked) {
                device.setFocusModeLocked(lensPosition: min(max(lensPosition, 0), 1), completionHandler: nil)
            }
        } else {
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
        }

        // White balance: locked to a temperature/tint pair.
        if let kelvin = config.kelvin, let tint = config.tint {
            guard device.isWhiteBalanceModeSupported(.locked) else {
                throw CameraServiceError.manualWhiteBalanceUnsupported
            }
            let ranges = locked { _supportedManualRanges }
            let clampedKelvin = min(max(kelvin, ranges.kelvin.lowerBound), ranges.kelvin.upperBound)
            let clampedTint = min(max(tint, ranges.tint.lowerBound), ranges.tint.upperBound)
            let temperatureTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                temperature: clampedKelvin, tint: clampedTint
            )
            let gains = device.deviceWhiteBalanceGains(for: temperatureTint)
            device.setWhiteBalanceModeLocked(with: clampGains(gains, on: device), completionHandler: nil)
        }
    }

    private func resetToAutoLocked() {
        guard let device = currentDevice else { return }
        try? device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
    }

    private func clampGains(_ gains: AVCaptureDevice.WhiteBalanceGains, on device: AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceGains {
        let maxGain = device.maxWhiteBalanceGain
        func clamp(_ value: Float) -> Float { min(max(value, 1), maxGain) }
        return AVCaptureDevice.WhiteBalanceGains(
            redGain: clamp(gains.redGain),
            greenGain: clamp(gains.greenGain),
            blueGain: clamp(gains.blueGain)
        )
    }

    // MARK: - Focus / exposure offset (sessionQueue)

    private func focusLocked(_ point: CGPoint) throws {
        guard let device = currentDevice else { throw CameraServiceError.sessionNotConfigured }
        let normalized = CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        if device.isFocusPointOfInterestSupported {
            device.focusPointOfInterest = normalized
            if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            }
        } else {
            throw CameraServiceError.focusPointUnsupported
        }

        if device.isExposurePointOfInterestSupported {
            device.exposurePointOfInterest = normalized
            if device.isExposureModeSupported(.autoExpose) {
                device.exposureMode = .autoExpose
            }
        }
    }

    private func setExposureOffsetLocked(_ ev: Float) throws {
        guard let device = currentDevice else { throw CameraServiceError.sessionNotConfigured }
        let clamped = min(max(ev, device.minExposureTargetBias), device.maxExposureTargetBias)
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.setExposureTargetBias(clamped, completionHandler: nil)
    }

    // MARK: - Still capture (sessionQueue)

    private func makePhotoSettings(_ settings: PhotoCaptureSettings) throws -> AVCapturePhotoSettings {
        guard isConfigured else { throw CameraServiceError.sessionNotConfigured }
        let avSettings: AVCapturePhotoSettings
        switch settings.format {
        case .jpeg:
            avSettings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        case .heif:
            // HEIF is HEVC-coded; fall back to JPEG when the output cannot encode it.
            let codec: AVVideoCodecType = photoOutput.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
            avSettings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
        case .dng:
            guard let rawFormat = firstRawPhotoPixelFormatType() else {
                throw CameraServiceError.rawUnsupported
            }
            avSettings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
        }
        applyFlash(settings.flash, to: avSettings)
        return avSettings
    }

    /// Reads the first RAW pixel format in an SDK-type-agnostic way: across
    /// toolchains this property has surfaced as either `[OSType]` or `[NSNumber]`,
    /// so it is boxed to `Any` and probed for both shapes.
    private func firstRawPhotoPixelFormatType() -> OSType? {
        for candidate in photoOutput.availableRawPhotoPixelFormatTypes {
            let boxed: Any = candidate
            if let number = boxed as? NSNumber {
                return number.uint32Value
            }
            if let raw = boxed as? OSType {
                return raw
            }
        }
        return nil
    }

    private func applyFlash(_ mode: FlashMode, to settings: AVCapturePhotoSettings) {
        let avMode: AVCaptureDevice.FlashMode
        switch mode {
        case .off: avMode = .off
        case .auto: avMode = .auto
        case .on: avMode = .on
        }
        settings.flashMode = photoOutput.supportedFlashModes.contains(avMode) ? avMode : .off
    }

    private func applyOrientationLocked(_ orientation: PortraitLandscape) {
        guard let connection = photoOutput.connection(with: .video) else { return }
        let angle: CGFloat = (orientation == .portrait) ? 90 : 0
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    /// Arms one capture and bridges its delegate result into `continuation`.
    /// Must be called on the session queue.
    private func fireCapture(_ avSettings: AVCapturePhotoSettings, continuation: CheckedContinuation<[CapturedPhoto], Error>) {
        let id = avSettings.uniqueID
        let lens = locked { _currentLens }
        let delegate = PhotoCaptureDelegate(lensID: lens) { [weak self] result in
            if let self {
                self.lockedDelegates { self.photoDelegates[id] = nil }
            }
            switch result {
            case .success(let photos): continuation.resume(returning: photos)
            case .failure(let error): continuation.resume(throwing: error)
            }
        }
        lockedDelegates { photoDelegates[id] = delegate }
        photoOutput.capturePhoto(with: avSettings, delegate: delegate)
    }

    // MARK: - Bracketed capture

    /// Hardware AE bracket: 3 standard frames at −2/0/+2 EV around the current
    /// exposure, delivered in a single bracketed capture.
    private func captureHardwareBracket() async throws -> [CapturedPhoto] {
        let photos: [CapturedPhoto] = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CapturedPhoto], Error>) in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CameraServiceError.sessionNotConfigured)
                    return
                }
                guard self.isConfigured else {
                    continuation.resume(throwing: CameraServiceError.sessionNotConfigured)
                    return
                }
                guard self.photoOutput.maxBracketedCapturePhotoCount >= 3 else {
                    continuation.resume(throwing: CameraServiceError.configurationFailed("hardware bracket unsupported"))
                    return
                }
                let biases: [Float] = [-2, 0, 2]
                let bracketed: [AVCaptureBracketedStillImageSettings] = biases.map { bias -> AVCaptureBracketedStillImageSettings in
                    AVCaptureAutoExposureBracketedStillImageSettings.autoExposureSettings(exposureTargetBias: bias)
                }
                let bracketSettings = AVCapturePhotoBracketSettings(
                    rawPixelFormatType: 0,
                    processedFormat: [AVVideoCodecKey: AVVideoCodecType.jpeg],
                    bracketedSettings: bracketed
                )
                bracketSettings.isLensStabilizationEnabled = false
                self.applyOrientationLocked(.portrait)
                self.fireCapture(bracketSettings, continuation: continuation)
            }
        }
        // Deliver dark → bright regardless of delegate arrival order.
        return photos.sorted { ($0.exifSummary?.shutterSeconds ?? 0) < ($1.exifSummary?.shutterSeconds ?? 0) }
    }

    /// Software bracket: lock exposure to the current auto values, step
    /// `exposureDuration` in equal EV increments across the depth's span, and
    /// capture sequentially on the queue. Task 12 merges the result.
    private func captureSoftBracket(_ depth: BracketDepth) async throws -> [CapturedPhoto] {
        let span: Double
        switch depth {
        case .soft5: span = 6.0    // ±3 EV
        case .soft7: span = 7.0    // ±3.5 EV
        case .soft9: span = 8.0    // ±4 EV
        case .aeb3: span = 4.0     // not reached (hardware path); defensive
        }
        let count = depth.frameCount

        let basis = try await withSessionQueue { try self.captureExposureBasisLocked() }
        _ = try await withSessionQueue { try self.lockCustomExposureLocked(basis) }

        var photos: [CapturedPhoto] = []
        photos.reserveCapacity(count)
        do {
            let step = count > 1 ? span / Double(count - 1) : 0
            let half = span / 2
            for index in 0..<count {
                if Task.isCancelled { break }
                let ev = -half + Double(index) * step
                let duration = basis.baseDurationSeconds * pow(2.0, ev)
                _ = try await withSessionQueue { try self.setExposureDurationLocked(duration, iso: basis.iso) }
                let settings = PhotoCaptureSettings(format: .jpeg, flash: .off, timerSeconds: 0, orientation: .portrait)
                photos.append(try await capturePhoto(settings))
            }
            _ = try await withSessionQueue { self.restoreAutoExposureLocked() }
            return photos
        } catch {
            _ = try? await withSessionQueue { self.restoreAutoExposureLocked() }
            throw error
        }
    }

    private struct ExposureBasis: Sendable {
        let iso: Float
        let baseDurationSeconds: Double
    }

    private func captureExposureBasisLocked() throws -> ExposureBasis {
        guard let device = currentDevice else { throw CameraServiceError.sessionNotConfigured }
        let format = device.activeFormat
        let base = Self.finiteOrDefault(device.exposureDuration.seconds, fallback: 1.0 / 60.0)
        let clampedBase = min(max(base, format.minExposureDuration.seconds), format.maxExposureDuration.seconds)
        return ExposureBasis(iso: device.iso, baseDurationSeconds: clampedBase)
    }

    private func lockCustomExposureLocked(_ basis: ExposureBasis) throws {
        guard let device = currentDevice else { throw CameraServiceError.sessionNotConfigured }
        guard device.isExposureModeSupported(.custom) else {
            throw CameraServiceError.manualExposureUnsupported
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        let time = CMTime(seconds: basis.baseDurationSeconds, preferredTimescale: 1_000_000_000)
        device.setExposureModeCustom(duration: time, iso: basis.iso, completionHandler: nil)
    }

    private func setExposureDurationLocked(_ duration: Double, iso: Float) throws {
        guard let device = currentDevice else { throw CameraServiceError.sessionNotConfigured }
        let format = device.activeFormat
        let clamped = min(max(duration, format.minExposureDuration.seconds), format.maxExposureDuration.seconds)
        let time = CMTime(seconds: clamped, preferredTimescale: 1_000_000_000)
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.setExposureModeCustom(duration: time, iso: iso, completionHandler: nil)
    }

    private func restoreAutoExposureLocked() {
        guard let device = currentDevice else { return }
        try? device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
    }
}

// MARK: - Preview frames

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {

    /// Called on `videoOutputQueue`. The handler is copied out under the lock and
    /// invoked outside it; the buffer is only valid for the duration of the call
    /// (the contract forbids retaining it).
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let handler = locked({ _previewFrameHandler }) else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        handler(pixelBuffer)
    }
}

// MARK: - Per-capture delegate

/// Bridges the photo output's delegate callbacks (delivered on AVFoundation's own
/// internal queue) to a single `Result`. One instance per capture; retained by
/// `CameraService` until `didFinishCaptureFor` fires.
private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {

    private let lensID: CameraLensID?
    private let resolve: @Sendable (Result<[CapturedPhoto], Error>) -> Void

    private let lock = NSLock()
    private var captured: [CapturedPhoto] = []
    private var firstError: (any Error)?
    private var finished = false

    init(lensID: CameraLensID?, resolve: @escaping @Sendable (Result<[CapturedPhoto], Error>) -> Void) {
        self.lensID = lensID
        self.resolve = resolve
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            locked { if firstError == nil { firstError = error } }
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            locked { if firstError == nil { firstError = CameraServiceError.photoDataUnavailable } }
            return
        }

        // `AVCaptureResolvedPhotoSettings` exposes no file-type property, so the
        // format is read from the encoded payload itself.
        let format = PhotoCaptureDelegate.captureFormat(for: data, isRaw: photo.isRawPhoto)

        // Processed captures report `photoDimensions`; RAW-only captures report
        // `rawPhotoDimensions`, so fall back when the processed size is zero.
        let resolved = photo.resolvedSettings
        let processed = resolved.photoDimensions
        var width = Int(processed.width)
        var height = Int(processed.height)
        if width == 0 || height == 0 {
            let raw = resolved.rawPhotoDimensions
            width = Int(raw.width)
            height = Int(raw.height)
        }

        let shot = CapturedPhoto(
            data: data,
            format: format,
            width: width,
            height: height,
            exifSummary: PhotoCaptureDelegate.makeExifSummary(photo: photo, lensID: lensID)
        )
        locked { captured.append(shot) }
    }

    /// Classifies an encoded capture by its ImageIO uniform type identifier.
    private static func captureFormat(for data: Data, isRaw: Bool) -> CaptureFormat {
        if isRaw { return .dng }
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let uti = CGImageSourceGetType(source) as String? {
            if uti.contains("heic") || uti.contains("heif") { return .heif }
        }
        return .jpeg
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        let (shots, storedError) = locked { (captured, firstError) }
        if let error {
            finish(.failure(error))
        } else if let storedError {
            finish(.failure(storedError))
        } else if shots.isEmpty {
            finish(.failure(CameraServiceError.photoDataUnavailable))
        } else {
            finish(.success(shots))
        }
    }

    private func finish(_ result: Result<[CapturedPhoto], Error>) {
        let shouldResolve = locked { () -> Bool in
            if finished { return false }
            finished = true
            return true
        }
        if shouldResolve {
            resolve(result)
        }
    }

    private static func makeExifSummary(photo: AVCapturePhoto, lensID: CameraLensID?) -> ExifSummary {
        let metadata = photo.metadata
        let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any]

        let iso = (exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.floatValue
        let shutter = (exif?[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue
        let focal = (exif?[kCGImagePropertyExifFocalLength as String] as? NSNumber)?.floatValue
        let aperture = (exif?[kCGImagePropertyExifFNumber as String] as? NSNumber)?.floatValue
        let model = (tiff?[kCGImagePropertyTIFFModel as String] as? String) ?? "Unknown"

        return ExifSummary(
            deviceModel: model,
            lensID: lensID,
            focalMM: focal,
            aperture: aperture,
            shutterSeconds: shutter,
            iso: iso,
            capturedAt: Date()
        )
    }
}
