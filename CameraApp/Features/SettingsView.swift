import SwiftUI
import UIKit
import os

// MARK: - SettingsView
//
// Real settings page replacing the Task 9 placeholder. Offers:
//   • Pro mode toggle + color look selector (color grading)
//   • Watermark template info (always applied in the pipeline)
//   • "Open in Stock Photos" — deep-links to the system Photos app
//   • Diagnostic logging
//
// All values are read from / written to the shared AppEnvironment so the
// viewfinder capture path picks them up live (pro mode → look applied via
// the pipeline; watermark → stage template/opacity).

struct SettingsView: View {
    @ObservedObject var environment: AppEnvironment

    @State private var showPhotosAlert = false
    @State private var showPresetPicker = false
    @State private var selectedPreset: CapturePreset = .auto

    var body: some View {
        NavigationStack {
            List {
                // MARK: Capture preset
                Section("Capture Preset") {
                    Picker("Preset", selection: $selectedPreset) {
                        ForEach(CapturePreset.allCases, id: \.self) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedPreset) { _, newValue in
                        applyPreset(newValue)
                    }
                }

                // MARK: Pro mode
                Section("Pro Mode") {
                    Toggle("Pro Mode", isOn: proModeBinding)
                        .help("Enables color looks and manual capture controls.")
                    if environment.captureController.settings.proMode {
                        Picker("Color Look", selection: lookBinding) {
                            ForEach(LookID.allCases, id: \.self) { look in
                                Text(look.displayName).tag(look)
                            }
                        }
                        .pickerStyle(.inline)
                        .help("Applied to every capture through the processing pipeline.")
                    }
                }

                // MARK: Watermark
                Section("Watermark") {
                    Text("Auto-applied to every capture (JPEG/HEIF).")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Color.textSecondary)
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
        }
    }

    // MARK: - Bindings

    private var proModeBinding: Binding<Bool> {
        Binding(
            get: { environment.captureController.settings.proMode },
            set: { newValue in
                environment.captureController.settings.proMode = newValue
                if newValue {
                    try? environment.lookEngine.loadLook(environment.captureController.settings.selectedLook)
                }
                savePersistedSettings()
                Logger.ui("pro mode \(newValue ? "on" : "off")")
            }
        )
    }

    private var lookBinding: Binding<LookID> {
        Binding(
            get: { environment.captureController.settings.selectedLook },
            set: { newValue in
                environment.captureController.settings.selectedLook = newValue
                try? environment.lookEngine.loadLook(newValue)
                savePersistedSettings()
                Logger.ui("look: \(newValue.rawValue)")
            }
        )
    }

    // MARK: - Actions

    private func loadPersistedSettings() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: SettingsKeys.proMode) != nil {
            environment.captureController.settings.proMode = defaults.bool(forKey: SettingsKeys.proMode)
        }
        if defaults.object(forKey: SettingsKeys.selectedLook) != nil,
           let raw = defaults.string(forKey: SettingsKeys.selectedLook),
           let look = LookID(rawValue: raw) {
            environment.captureController.settings.selectedLook = look
            try? environment.lookEngine.loadLook(look)
        }
        if defaults.object(forKey: SettingsKeys.capturePreset) != nil,
           let raw = defaults.string(forKey: SettingsKeys.capturePreset),
           let preset = CapturePreset(rawValue: raw) {
            selectedPreset = preset
            applyPreset(preset)
        }
        Logger.ui("settings loaded from UserDefaults")
    }

    private func savePersistedSettings() {
        let defaults = UserDefaults.standard
        defaults.set(environment.captureController.settings.proMode, forKey: SettingsKeys.proMode)
        defaults.set(environment.captureController.settings.selectedLook.rawValue, forKey: SettingsKeys.selectedLook)
        defaults.set(selectedPreset.rawValue, forKey: SettingsKeys.capturePreset)
        Logger.ui("settings saved to UserDefaults")
    }

    private func applyPreset(_ preset: CapturePreset) {
        environment.captureController.settings.format = preset.format
        environment.captureController.settings.flashMode = preset.flashMode
        environment.captureController.settings.proMode = preset.proMode
        environment.captureController.settings.selectedLook = preset.selectedLook
        if preset.proMode {
            try? environment.lookEngine.loadLook(preset.selectedLook)
        }
        savePersistedSettings()
        Logger.ui("preset applied: \(preset.rawValue)")
    }

    private func openStockPhotos() {
        let photosURL = URL(string: "photos-redirect://")!
        if UIApplication.shared.canOpenURL(photosURL) {
            UIApplication.shared.open(photosURL)
        } else {
            // Fallback: open Photos app via its bundle URL scheme
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
