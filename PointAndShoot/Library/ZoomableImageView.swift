import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// A photo that zooms like Photos: a UIScrollView, so pinch is anchored under the fingers,
/// you can pan while pinching, it rubber-bands at the edges and below 1×, and double-tap
/// toggles fit ↔ 2.5× at the tapped point. At 1× the scroll view can't scroll, so swipes go
/// to the pager (next photo) and the viewer's swipe-down; zoomed in, one finger pans, and
/// the pager takes over once the photo's edge is reached.
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    /// Native pixel size of the photo, for the maximum zoom.
    var pixelSize: CGSize
    /// False while the page is off screen: snap back to fit (like Photos).
    var isCurrent = true
    var onTap: () -> Void = {}
    /// Zoom scale (1 = fit) as it changes, including while pinching from 1×.
    var onZoom: (CGFloat) -> Void = { _ in }
    /// A touch sequence on the photo started (`false`, one finger) or a second finger joined
    /// it or lifts from it (`true`). Synchronous, straight from UIKit's touch handling, so the viewer knows
    /// before its swipe-down drag ends that this was a pinch, not a pull.
    var onTouches: (_ multiTouch: Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ZoomingScrollView {
        let view = ZoomingScrollView()
        view.coordinator = context.coordinator
        context.coordinator.view = view
        view.accessibilityIdentifier = "viewer.photo"
        return view
    }

    func updateUIView(_ view: ZoomingScrollView, context: Context) {
        let c = context.coordinator
        c.onTap = onTap
        c.onZoom = onZoom
        c.onTouches = onTouches
        view.pixelSize = pixelSize
        view.setImage(image)
        if !isCurrent { view.resetZoom(animated: false) }
    }

    final class Coordinator: NSObject {
        weak var view: ZoomingScrollView?
        var onTap: () -> Void = {}
        var onZoom: (CGFloat) -> Void = { _ in }
        var onTouches: (Bool) -> Void = { _ in }
        private var lastReported: CGFloat = 1

        /// `immediately` from inside a gesture, so the viewer knows before its own drag
        /// handlers run; otherwise deferred, because layout and SwiftUI updates (reset to
        /// fit) also zoom, and state mustn't change during a SwiftUI update.
        func report(_ scale: CGFloat, immediately: Bool = false) {
            guard abs(scale - lastReported) > 0.01 || (scale <= 1 && lastReported > 1) else { return }
            lastReported = scale
            let f = onZoom
            if immediately { f(scale) } else { DispatchQueue.main.async { f(scale) } }
        }
    }
}

final class ZoomingScrollView: UIScrollView, UIScrollViewDelegate {
    weak var coordinator: ZoomableImageView.Coordinator?
    var pixelSize: CGSize = .zero
    private let imageView = UIImageView()
    private var laidOutSize: CGSize = .zero
    private var imageAspect: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        decelerationRate = .fast
        bouncesZoom = true
        bounces = true
        alwaysBounceVertical = false
        alwaysBounceHorizontal = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.require(toFail: doubleTap)
        addGestureRecognizer(tap)

        let touches = TouchCountRecognizer { [weak self] multi in self?.coordinator?.onTouches(multi) }
        addGestureRecognizer(touches)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setImage(_ image: UIImage) {
        guard imageView.image !== image else { return }
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 0
        imageView.image = image
        // A sharper copy of the same photo swaps in place; a different shape (an edit
        // with a crop) starts over at fit.
        if imageAspect == 0 || abs(aspect - imageAspect) > 0.01 * max(aspect, 0.01) {
            imageAspect = aspect
            laidOutSize = .zero
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != laidOutSize, bounds.width > 0, bounds.height > 0 else { return }
        laidOutSize = bounds.size
        zoomScale = 1
        var fit = imageAspect > 0
            ? aspectFitRect(CGSize(width: imageAspect, height: 1), in: bounds.size).size
            : bounds.size
        // Never a hair bigger than the view (floating point): at 1× the scroll view must
        // have nothing to scroll, or it would steal the pager's swipes.
        fit = CGSize(width: min(fit.width, bounds.width), height: min(fit.height, bounds.height))
        imageView.frame = CGRect(origin: .zero, size: fit)
        contentSize = fit
        minimumZoomScale = 1
        maximumZoomScale = ZoomMath.maxScale(pixelSize: pixelSize, fittedSize: fit,
                                             screenScale: traitCollection.displayScale > 0 ? traitCollection.displayScale : 3)
        centre()
    }

    /// Keeps the photo centred while it's smaller than the screen in either direction.
    private func centre() {
        let size = imageView.frame.size
        let x = max(0, (bounds.width - size.width) / 2)
        let y = max(0, (bounds.height - size.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    func resetZoom(animated: Bool) {
        guard zoomScale != 1 else { return }
        setZoomScale(1, animated: animated)
    }

    @objc private func handleTap() { coordinator?.onTap() }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        if zoomScale > 1.01 {
            setZoomScale(1, animated: true)
            return
        }
        let scale = min(ZoomMath.doubleTapScale, maximumZoomScale)
        let p = g.location(in: imageView)
        let w = bounds.width / scale, h = bounds.height / scale
        zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        // Tell the viewer straight away (even before the scale moves), so its swipe-down
        // doesn't also start on a two-finger pinch.
        coordinator?.report(max(zoomScale, 1.02), immediately: isZooming)
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centre()
        // While fingers are pinching (even below 1×) or it's bouncing back, it counts as
        // zoomed, so the viewer's swipe-down stays out of the way until it has settled.
        coordinator?.report(isZooming || isZoomBouncing ? max(zoomScale, 1.02) : zoomScale, immediately: isZooming)
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        coordinator?.report(scale)
    }
}

/// Watches touches without ever recognizing anything (it stays `.possible` until the
/// fingers lift, then fails, so it never blocks, delays or cancels another gesture): reports when a touch sequence starts and when a second finger joins it.
final class TouchCountRecognizer: UIGestureRecognizer {
    private let report: (Bool) -> Void
    private var down = 0
    private var reportedMulti = false

    init(report: @escaping (Bool) -> Void) {
        self.report = report
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    // Never stopped by the pinch/pan recognizing, and never stops them.
    override func canBePrevented(by preventing: UIGestureRecognizer) -> Bool { false }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if down == 0 { reportedMulti = false; report(false) }
        down += touches.count
        if down >= 2, !reportedMulti { reportedMulti = true; report(true) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }

    private func lift(_ touches: Set<UITouch>) {
        // A pinch's fingers lifting: say so again, so "recently pinched" counts from the
        // end of the pinch, not its start.
        if down >= 2 { report(true) }
        down = max(0, down - touches.count)
        if down == 0 { state = .failed }
    }

    override func reset() {
        down = 0
        reportedMulti = false
    }
}
