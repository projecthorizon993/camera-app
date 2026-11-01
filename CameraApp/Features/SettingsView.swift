import SwiftUI
import UIKit
import os

// MARK: - SettingsView
//
// Real settings page replacing the Task 9 placeholder. Offers:
//   • Pro mode toggle + color look selector (color grading)
//   • Lens correction on/off toggle
//   • Watermark preview toggle
//   • Capture preset picker (Auto/Pro/Portrait/Landscape/Night/Video)
//   • "Open in Stock Photos" — deep-links to the system Photos app
//   • Diagnostic logging
//
// Crash-safety: all settings are read into local @State variables on appear,
// and written back on change. No direct access to environment.captureController
// during view body evaluation, avoiding crashes from lazy init of CameraService.

struct SettingsView: View {
    @ObservedObject var environment: AppEnvironment

    @State private var showPhotosAlert = false
    @State private var isLoaded = false
    @State private var proMode = false
    @State private var selectedLook: LookID = .none
    @State private var lensCorrectionEnabled = false
    @State private var showWatermarkPreview = false
    @State private var preset: CapturePreset = .auto

    var body: some View {
        NavigationStack {
            List {
                // MARK: Capture preset
                Section("Capture Preset") {
                    Picker("Preset", selection: $preset) {
                        ForEach(CapturePreset.allCases, id: \.self) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                }

                // MARK: Pro mode
                Section("Pro Mode") {
                    Toggle("Pro Mode", isOn: $proMode)
                        .help("Enables color looks and manual capture controls.")
                    if proMode {
                        Picker("Color Look", selection: $selectedLook) {
                            ForEach(LookID.allCases, id: \.self) { look in
                                Text(look.displayName).tag(look)
                            }
                        }
                        .pickerStyle(.inline)
                        .help("Applied to every capture through the processing pipeline.")
                    }
                }

                // MARK: Lens correction
                Section("Lens Correction") {
                    Toggle("Enable Lens Correction", isOn: $lensCorrectionEnabled)
                        .help("Applies per-lens Brown-Conrady distortion correction.")
                }

                // MARK: Watermark
                Section("Watermark") {
                    Toggle("Show in Preview", isOn: $showWatermarkPreview)
                        .help("Draws the watermark on the live viewfinder.")
                    Text("Template: \(environment.watermarkRenderer.availableTemplates.map { $0.displayName }.joined(separator: ", "))")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Color.textSecondary)
                    Text("DNG captures are saved untouched (no watermark).")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Color.textSecondary)
                }

                // MARK: Photos library
                Section("Photos") {
                    Button("Open in Stock Photos") {
                        showPhotosAlert = true
                    }
                    .foregroundStyle(.blue)
                    .confirmationDialog("Open Photos", isPresented: $showPhotosAlert) {
                        Button("Open Photos App") {
                            openStockPhotos()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Open the system Photos app to view your camera roll.")
                    }
                }

                // MARK: Diagnostics
                Section("Diagnostics") {
                    Button("Save Diagnostic Log") {
                        Logger.save("user requested diagnostic log export")
                    }
                    .foregroundStyle(.blue)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                loadPersistedSettings()
            }
            .onChange(of: proMode) { _, newValue in
                environment.captureController.settings.proMode = newValue
                if newValue {
                    try? environment.lookEngine.loadLook(selectedLook)
                }
                savePersistedSettings()
            }
            .onChange(of: selectedLook) { _, newValue in
                environment.captureController.settings.selectedLook = newValue
                try? environment.lookEngine.loadLook(newValue)
                savePersistedSettings()
            }
            .onChange(of: lensCorrectionEnabled) { _, newValue in
                LensCorrectionEngine.isEnabled = newValue
                savePersistedSettings()
            }
            .onChange(of: showWatermarkPreview) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.showWatermarkPreview)
            }
            .onChange(of: preset) { _, newValue in
                environment.captureController.settings.format = newValue.format
                environment.captureController.settings.flashMode = newValue.flashMode
                environment.captureController.settings.proMode = newValue.proMode
                environment.captureController.settings.selectedLook = newValue.selectedLook
                proMode = newValue.proMode
                selectedLook = newValue.selectedLook
                if newValue.proMode {
                    try? environment.lookEngine.loadLook(newValue.selectedLook)
                }
                savePersistedSettings()
            }
        }
    }

    // MARK: - Actions

    private func loadPersistedSettings() {
        guard !isLoaded else { return }
        isLoaded = true

        let defaults = UserDefaults.standard
        if defaults.object(forKey: SettingsKeys.proMode) != nil {
            proMode = defaults.bool(forKey: SettingsKeys.proMode)
        }
        environment.captureController.settings.proMode = proMode

        if defaults.object(forKey: SettingsKeys.selectedLook) != nil,
           let raw = defaults.string(forKey: SettingsKeys.selectedLook),
           let look = LookID(rawValue: raw) {
            selectedLook = look
            environment.captureController.settings.selectedLook = look
            try? environment.lookEngine.loadLook(look)
        }
        if defaults.object(forKey: SettingsKeys.capturePreset) != nil,
           let raw = defaults.string(forKey: SettingsKeys.capturePreset),
           let preset = CapturePreset(rawValue: raw) {
            self.preset = preset
            environment.captureController.settings.format = preset.format
            environment.captureController.settings.flashMode = preset.flashMode
            environment.captureController.settings.proMode = preset.proMode
            environment.captureController.settings.selectedLook = preset.selectedLook
            proMode = preset.proMode
            selectedLook = preset.selectedLook
            if preset.proMode {
                try? environment.lookEngine.loadLook(preset.selectedLook)
            }
        }
        lensCorrectionEnabled = defaults.bool(forKey: SettingsKeys.lensCorrectionEnabled)
        showWatermarkPreview = defaults.bool(forKey: SettingsKeys.showWatermarkPreview)
        Logger.ui("settings loaded from UserDefaults")
    }

    private func savePersistedSettings() {
        let defaults = UserDefaults.standard
        defaults.set(environment.captureController.settings.proMode, forKey: SettingsKeys.proMode)
        defaults.set(environment.captureController.settings.selectedLook.rawValue, forKey: SettingsKeys.selectedLook)
        defaults.set(LensCorrectionEngine.isEnabled, forKey: SettingsKeys.lensCorrectionEnabled)
        Logger.ui("settings saved to UserDefaults")
    }

    private func openStockPhotos() {
        let photosURL = URL(string: "photos-redirect://")!
        if UIApplication.shared.canOpenURL(photosURL) {
            UIApplication.shared.open(photosURL)
        } else {
            let alt = URL(string: "com.apple.mobileslideshow://")!
            UIApplication.shared.open(alt)
        }
        Logger.ui("opened stock Photos app")
    }
}

// MARK: - LookID display names

extension LookID {
    var displayName: String {
        switch self {
        case .none: return "None (Auto)"
        case .authentic: return "Authentic (Leica-inspired)"
        case .vibrant: return "Vibrant"
        case .natural: return "Natural"
        case .classicBW: return "Classic B&W"
        }
    }
}

// MARK: - CapturePreset

enum CapturePreset: String, CaseIterable, Sendable {
    case auto = "Auto"
    case pro = "Pro"
    case portrait = "Portrait"
    case landscape = "Landscape"
    case night = "Night"
    case video = "Video"

    var format: CaptureFormat {
        switch self {
        case .auto: return .jpeg
        case .pro: return .heif
        case .portrait: return .heif
        case .landscape: return .heif
        case .night: return .jpeg
        case .video: return .heif
        }
    }

    var flashMode: FlashMode {
        switch self {
        case .auto: return .auto
        case .pro: return .off
        case .portrait: return .off
        case .landscape: return .off
        case .night: return .off
        case .video: return .off
        }
    }

    var proMode: Bool {
        switch self {
        case .auto: return false
        case .pro: return true
        case .portrait: return true
        case .landscape: return true
        case .night: return false
        case .video: return false
        }
    }

    var selectedLook: LookID {
        switch self {
        case .auto: return .none
        case .pro: return .authentic
        case .portrait: return .natural
        case .landscape: return .vibrant
        case .night: return .none
        case .video: return .none
        }
    }

    static func from(format: CaptureFormat, proMode: Bool) -> CapturePreset {
        for preset in CapturePreset.allCases {
            if preset.format == format && preset.proMode == proMode {
                return preset
            }
        }
        return .auto
    }
}

// MARK: - SettingsKeys

enum SettingsKeys {
    static let proMode = "settings.proMode"
    static let selectedLook = "settings.selectedLook"
    static let capturePreset = "settings.capturePreset"
    static let watermarkEnabled = "settings.watermarkEnabled"
    static let lensCorrectionEnabled = "settings.lensCorrectionEnabled"
    static let showWatermarkPreview = "settings.showWatermarkPreview"
}