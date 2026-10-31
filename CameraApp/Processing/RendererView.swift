import SwiftUI
import UIKit
import MetalKit

// MARK: - RendererView
//
// SwiftUI wrapper around MTKView driving `MetalRenderer`. Owns no render
// state — the caller (view model / AppEnvironment) owns the renderer so the
// debug HUD can read the same instance's stats.
//
// Usage (Task 7a viewfinder):
//     let renderer = MetalRenderer(overlayProvider: myOverlayProvider)
//     RendererView(renderer: renderer)
//
// The MTKView is configured for a 30 fps camera preview: continuous rendering
// (isPaused = false, enableSetNeedsDisplay = false), framebufferOnly = true,
// and a BGRA8 color format matching the renderer's pipeline states.

struct RendererView: UIViewRepresentable {
    /// nil → no Metal device on this machine; a graceful fallback view is shown.
    let renderer: MetalRenderer?

    init(renderer: MetalRenderer?) {
        self.renderer = renderer
    }

    func makeUIView(context: Context) -> UIView {
        guard let renderer else {
            return RendererUnavailableView()
        }
        let view = MTKView(frame: .zero, device: renderer.device)
        view.delegate = renderer
        view.colorPixelFormat = .bgra8Unorm   // must match MetalRenderer's pipeline states
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.isOpaque = true
        view.backgroundColor = .black
        view.enableSetNeedsDisplay = false    // driven by the render thread, not setNeedsDisplay
        view.isPaused = false                 // continuous rendering
        view.preferredFramesPerSecond = 30    // camera delivers ~30 fps; don't burn GPU redrawing
        view.framebufferOnly = true           // drawable is render-target only → fastest path
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Delegate and configuration are fixed at creation; nothing to update.
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        (uiView as? MTKView)?.delegate = nil
    }
}

// MARK: - Fallback

/// Shown when MTLCreateSystemDefaultDevice() returns nil (e.g. simulators
/// without Metal support). Keeps the viewfinder layout intact.
private final class RendererUnavailableView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true

        let label = UILabel()
        label.text = "Metal is unavailable on this device."
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .callout)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: layoutMarginsGuide.leadingAnchor),
            layoutMarginsGuide.trailingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
