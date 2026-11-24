import SwiftUI
import UIKit

/// Long-press and sweep selection for the library grid, like Photos:
/// - **Hold a photo** (Select mode or not) to select it; keep the finger down and drag to
///   select every photo between it and the finger.
/// - **In Select mode, sweep sideways** across photos to select (or deselect) a run of them.
///   A vertical drag still scrolls.
///
/// These are UIKit recognizers on the grid's own `UIScrollView` (found from a view placed
/// inside its content), not SwiftUI gestures on the cells: SwiftUI drag and long-press
/// gestures inside a `ScrollView` either block scrolling or are cancelled by it, depending
/// on the iOS version. The scroll view's pan waits for the sweep to fail, and the sweep
/// fails at once unless it's a sideways drag in Select mode, so scrolling is unchanged.
/// Points are in window coordinates (the grid's cells report `.global` frames).
struct GridSelectGestures: UIViewRepresentable {
    enum Phase { case began, changed, ended }

    /// Off while the grid is hidden behind the viewer's photo.
    var enabled: Bool
    var selecting: Bool
    /// A long press began, moved or ended.
    var onPress: (Phase, CGPoint) -> Void
    /// A sideways sweep in Select mode began, moved or ended.
    var onSweep: (Phase, CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> FinderView {
        let view = FinderView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        let coordinator = context.coordinator
        view.onWindow = { [weak coordinator, weak view] in
            coordinator?.attach(to: view?.enclosingScrollView)
        }
        return view
    }

    func updateUIView(_ view: FinderView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.scrollView == nil {
            context.coordinator.attach(to: view.enclosingScrollView)
        }
    }

    static func dismantleUIView(_ view: FinderView, coordinator: Coordinator) {
        coordinator.detach()
    }

    /// An invisible view inside the scroll view's content, to find the scroll view.
    final class FinderView: UIView {
        var onWindow: (() -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            // The hierarchy settles after this pass.
            DispatchQueue.main.async { [weak self] in self?.onWindow?() }
        }

        var enclosingScrollView: UIScrollView? {
            var view = superview
            while let current = view {
                if let scroll = current as? UIScrollView { return scroll }
                view = current.superview
            }
            return nil
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: GridSelectGestures
        private(set) weak var scrollView: UIScrollView?
        private var press: UILongPressGestureRecognizer!
        private var sweep: UIPanGestureRecognizer!

        init(_ parent: GridSelectGestures) {
            self.parent = parent
            super.init()
            press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
            press.minimumPressDuration = 0.35
            press.delegate = self
            sweep = UIPanGestureRecognizer(target: self, action: #selector(swept(_:)))
            sweep.maximumNumberOfTouches = 1
            sweep.delegate = self
        }

        func attach(to scroll: UIScrollView?) {
            guard let scroll, scroll !== scrollView else { return }
            detach()
            scroll.addGestureRecognizer(press)
            scroll.addGestureRecognizer(sweep)
            scrollView = scroll
        }

        func detach() {
            press.view?.removeGestureRecognizer(press)
            sweep.view?.removeGestureRecognizer(sweep)
            scrollView = nil
        }

        private static func phase(_ state: UIGestureRecognizer.State) -> Phase? {
            switch state {
            case .began: .began
            case .changed: .changed
            case .ended, .cancelled, .failed: .ended
            default: nil
            }
        }

        @objc private func pressed(_ g: UILongPressGestureRecognizer) {
            guard let phase = Self.phase(g.state) else { return }
            parent.onPress(phase, g.location(in: nil))
        }

        @objc private func swept(_ g: UIPanGestureRecognizer) {
            guard let phase = Self.phase(g.state) else { return }
            // Where the finger went down, not where the pan was recognized (~10 pt later),
            // so the first photo under the finger is part of the run.
            if phase == .began {
                let t = g.translation(in: nil)
                let p = g.location(in: nil)
                parent.onSweep(.began, CGPoint(x: p.x - t.x, y: p.y - t.y))
            }
            parent.onSweep(phase == .began ? .changed : phase, g.location(in: nil))
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard parent.enabled else { return false }
            if g === sweep {
                guard parent.selecting else { return false }
                let v = sweep.velocity(in: sweep.view)
                return abs(v.x) > abs(v.y)
            }
            return true
        }

        /// The grid scrolls only once a sweep has been ruled out (it is, as soon as the
        /// finger has moved: anything but a sideways drag in Select mode).
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            g === sweep && other === scrollView?.panGestureRecognizer
        }
    }
}

/// Where each visible grid cell is on screen (global coordinates), for the selection
/// gestures. A plain reference, so updating it while scrolling never re-renders the grid.
final class GridCellFrames {
    private var frames: [UUID: CGRect] = [:]

    func set(_ frame: CGRect, for id: UUID) { frames[id] = frame }
    func remove(_ id: UUID) { frames[id] = nil }
    func shot(at point: CGPoint) -> UUID? { frames.first { $0.value.contains(point) }?.key }
}

/// The run a long press or sweep selects: every photo between where it started and where
/// the finger is now, in grid order, added to (or removed from) what was selected before.
/// Pure, so it's unit-tested.
struct GridSweep: Equatable {
    /// Grid index where the finger went down.
    let anchor: Int
    /// Selecting (true) or deselecting the run, decided by the first photo touched.
    let adds: Bool
    /// The selection before the gesture.
    let base: Set<UUID>
    /// Grid index under the finger now.
    var current: Int

    init(anchor: Int, adds: Bool, base: Set<UUID>) {
        self.anchor = anchor
        self.adds = adds
        self.base = base
        current = anchor
    }

    func selection(in order: [UUID]) -> Set<UUID> {
        guard !order.isEmpty else { return base }
        let a = min(max(anchor, 0), order.count - 1)
        let c = min(max(current, 0), order.count - 1)
        let run = Set(order[min(a, c)...max(a, c)])
        return adds ? base.union(run) : base.subtracting(run)
    }
}
