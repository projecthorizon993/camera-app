import SwiftUI

// PLACEHOLDER — replaced by Task 9 (format / quality / capability-gated settings).

struct SettingsPlaceholder: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "gearshape")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Settings")
                .font(.largeTitle.bold())
            Text("Under construction")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Settings")
    }
}
