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

    var body: some View {
        NavigationStack {
            List {
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
                    Toggle("Verbose Logging", isOn: loggingBinding)
                    Button("Save Diagnostic Log") {
                        Logger.save("user requested diagnostic log export")
                    }
                    .foregroundStyle(.blue)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Bindings

    private var proModeBinding: Binding<Bool> {
        Binding(
            get: { environment.captureController.settings.proMode },
            set: { newValue in
                environment.captureController.settings.proMode = newValue
                if newValue {
                    // Apply the currently selected look.
                    try? environment.lookEngine.loadLook(environment.captureController.settings.selectedLook)
                }
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
                Logger.ui("look: \(newValue.rawValue)")
            }
        )
    }

    // MARK: - Actions

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
