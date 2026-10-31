import Foundation
import AudioToolbox
import Combine

// Task 8 — capture feedback: the viewfinder-flash trigger + the shutter-sound
// toggle.
//
// BRIDGE-FILE RULE: this is the ONE file in the capture module allowed to
// import AudioToolbox — it is a thin hardware-feedback bridge around the
// system shutter click (system sound 1108). No other audio API may be used
// here, and no other module file may import AudioToolbox.
//
// Persistence is a plain Foundation `UserDefaults` wrapper (no SwiftUI), keyed
// so a SwiftUI `@AppStorage(ShutterSoundStore.soundEnabledKey)` in T7's UI
// reads and writes the exact same value.

// MARK: - Persistence

/// `@AppStorage`-compatible toggle persistence. Unset keys default to enabled
/// (matching the system camera's behaviour).
struct ShutterSoundStore {

    /// Shared key; a SwiftUI `@AppStorage(Self.soundEnabledKey)` binds to the
    /// same value as this wrapper (both default to `UserDefaults.standard`).
    static let soundEnabledKey = "capture.shutterSoundEnabled"

    private let defaults: UserDefaults

    /// - Parameter defaults: injectable for tests; production uses
    ///   `.standard`, which is what `@AppStorage` reads by default.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isSoundEnabled: Bool {
        get {
            defaults.object(forKey: Self.soundEnabledKey) == nil
                ? true
                : defaults.bool(forKey: Self.soundEnabledKey)
        }
        set { defaults.set(newValue, forKey: Self.soundEnabledKey) }
    }
}

// MARK: - ShutterFeedback

@MainActor
final class ShutterFeedback: ObservableObject {

    /// Sound toggle bound by settings UI; writes through to `UserDefaults`.
    @Published var isShutterSoundEnabled: Bool {
        didSet { store.isSoundEnabled = isShutterSoundEnabled }
    }

    /// Monotonic flash trigger: bumps once per fired shot. T7's viewfinder
    /// runs its opacity flash on `onChange(of:)` for this value.
    @Published private(set) var shutterFlashID = 0

    private let store: ShutterSoundStore

    init(store: ShutterSoundStore = ShutterSoundStore()) {
        self.store = store
        self.isShutterSoundEnabled = store.isSoundEnabled
    }

    /// Per-shot hook: bumps the flash trigger and, when enabled, plays the
    /// system shutter click. Called by `CaptureController` right after the
    /// frame lands.
    func shotFired() {
        shutterFlashID += 1
        playShutterSound()
    }

    /// Fires only the visual trigger (T7 may use it for press-down animation).
    func fireFlash() {
        shutterFlashID += 1
    }

    /// System shutter click via the AudioToolbox bridge. Fire-and-forget: the
    /// system sound service owns its own playback queue.
    func playShutterSound() {
        guard isShutterSoundEnabled else { return }
        AudioServicesPlaySystemSound(SystemSoundID(Self.shutterSystemSoundID))
    }

    /// 1108 = the iOS camera shutter system sound.
    static let shutterSystemSoundID: UInt32 = 1108
}
