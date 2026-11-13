import AVKit
import SwiftUI
import UIKit

/// Hosts the CAMetalLayer the renderer draws into, plus UIKit gestures (they give us exact
/// touch locations and play nicely together: tap, long-press, pinch, swipe).
struct PreviewView: UIViewRepresentable {
    let renderer: PreviewRenderer
    var onTap: (CGPoint, CGSize) -> Void
    var onLongPress: (CGPoint, CGSize) -> Void
    var onPinch: (CGFloat, UIGestureRecognizer.State) -> Void
    /// One-finger drag: translation, velocity, state. The caller decides the axis
    /// (vertical = exposure, horizontal = switch mode).
    var onPan: (CGPoint, CGPoint, UIGestureRecognizer.State) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PreviewMetalView {
        let view = PreviewMetalView()
        view.renderer = renderer
        view.backgroundColor = .black
        renderer.attach(layer: view.metalLayer)

        let c = context.coordinator
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap(_:)))
        let long = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.longPress(_:)))
        long.minimumPressDuration = 0.55
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        for g in [tap, long, pinch, pan] as [UIGestureRecognizer] { view.addGestureRecognizer(g) }
        return view
    }

    func updateUIView(_ uiView: PreviewMetalView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject {
        var parent: PreviewView
        init(_ parent: PreviewView) { self.parent = parent }

        @objc func tap(_ g: UITapGestureRecognizer) {
            guard let v = g.view else { return }
            parent.onTap(g.location(in: v), v.bounds.size)
        }

        @objc func longPress(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, let v = g.view else { return }
            parent.onLongPress(g.location(in: v), v.bounds.size)
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            parent.onPinch(g.scale, g.state)
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard let v = g.view else { return }
            parent.onPan(g.translation(in: v), g.velocity(in: v), g.state)
        }
    }
}

final class PreviewMetalView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    weak var renderer: PreviewRenderer?

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        contentScaleFactor = scale
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        guard size.width > 0, size.height > 0 else { return }
        metalLayer.drawableSize = size
        renderer?.setDrawableSize(size)
    }
}

/// Hardware shutter: volume buttons (and Camera Control click on iPhone 16).
struct CaptureEventView: UIViewRepresentable {
    var enabled: Bool
    var action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = true
        let coordinator = context.coordinator
        coordinator.action = action
        if #available(iOS 17.2, *) {
            let interaction = AVCaptureEventInteraction { event in
                if event.phase == .ended { coordinator.action?() }
            }
            interaction.isEnabled = enabled
            view.addInteraction(interaction)
            coordinator.interaction = interaction
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.action = action
        if #available(iOS 17.2, *) {
            (context.coordinator.interaction as? AVCaptureEventInteraction)?.isEnabled = enabled
        }
    }

    final class Coordinator {
        var action: (() -> Void)?
        var interaction: AnyObject?
    }
}
