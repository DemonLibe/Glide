import AppKit
import SwiftUI

/// Shows the active engine's video view. Both engines keep their own view;
/// switching between them only toggles visibility.
struct VideoSurface: NSViewRepresentable {
    @ObservedObject var controller: PlayerController

    func makeNSView(context: Context) -> EngineContainerView {
        let view = EngineContainerView()
        view.controller = controller
        return view
    }

    func updateNSView(_ view: EngineContainerView, context: Context) {
        view.show(controller.engineView)
    }
}

final class EngineContainerView: NSView {
    weak var controller: PlayerController?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Clicks are handled by the SwiftUI overlay above.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { controller?.window = window }
    }

    func show(_ engineView: NSView?) {
        for subview in subviews where subview !== engineView { subview.isHidden = true }
        guard let engineView else { return }
        if engineView.superview !== self {
            engineView.frame = bounds
            engineView.autoresizingMask = [.width, .height]
            addSubview(engineView)
        }
        engineView.isHidden = false
    }
}
