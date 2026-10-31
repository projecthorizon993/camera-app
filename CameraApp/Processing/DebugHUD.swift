import SwiftUI
import Foundation

// MARK: - Thermal observability hook (Task 20 wiring point)
//
// The thermal governor POLICY belongs to Task 20; this exposes only the
// current state and change notifications so the debug HUD — and later the
// governor — can observe it.

enum ThermalObservation {
    static var current: ProcessInfo.ThermalState {
        ProcessInfo.processInfo.thermalState
    }

    /// Subscribes to thermal state changes. Returns the token for
    /// NotificationCenter.removeObserver(_:).
    @discardableResult
    static func observe(_ handler: @escaping @Sendable (ProcessInfo.ThermalState) -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            handler(ProcessInfo.processInfo.thermalState)
        }
    }
}

#if DEBUG
// MARK: - DebugHUDHost (debug builds only)
//
// SwiftUI overlay (NOT Metal text): render fps, dropped-frame count, current
// thermal state and the active pipeline stage list. The insertion point in the
// viewfinder (Task 7a) must also be DEBUG-gated:
//
//     #if DEBUG
//     DebugHUDHost(renderer: renderer, pipeline: environment.pipeline,
//                  isVisible: $showsDebugHUD)
//         .allowsHitTesting(false)
//     #endif
//
// `isVisible` is the runtime visibility toggle (wire it to a debug setting).

struct DebugHUDHost: View {
    @Binding private var isVisible: Bool
    private let renderer: MetalRenderer?
    private let pipeline: (any ProcessingPipelineProtocol)?

    init(
        renderer: MetalRenderer?,
        pipeline: (any ProcessingPipelineProtocol)? = nil,
        isVisible: Binding<Bool> = .constant(true)
    ) {
        self.renderer = renderer
        self.pipeline = pipeline
        self._isVisible = isVisible
    }

    var body: some View {
        Group {
            if isVisible {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    hudPanel
                }
            }
        }
    }

    private var hudPanel: some View {
        let stats = renderer?.currentStats() ?? MetalRenderer.RenderStats()
        return VStack(alignment: .leading, spacing: 4) {
            Text(String(format: "fps %.0f", stats.fps))
            Text("dropped \(stats.droppedFrameCount)")
            Text("thermal \(Self.thermalLabel(ThermalObservation.current))")
            Text("stages \(activeStageNames)")
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(.green)
        .padding(8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
    }

    private var activeStageNames: String {
        guard let provider = pipeline as? any PipelineStageListProviding else { return "none" }
        let names = provider.activeStages.map(\.rawValue)
        return names.isEmpty ? "none" : names.joined(separator: ", ")
    }

    static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
#endif
