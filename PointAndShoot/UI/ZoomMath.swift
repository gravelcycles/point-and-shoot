import CoreGraphics

/// A zoomed view of an aspect-fit image: `scale` × the fitted size, with the image's centre
/// `offset` points from the view's centre. Used by the editor canvas (the viewer uses a
/// UIScrollView, which does the same thing natively).
struct ZoomState: Equatable {
    var scale: CGFloat = 1
    var offset: CGSize = .zero

    static let identity = ZoomState()
    var isZoomed: Bool { scale > 1.01 }
}

/// The math behind Photos-style zoom, pure so it's unit-tested: pinch anchored under the
/// fingers, pan at the same time, rubber-banding past the limits, double-tap to a point.
enum ZoomMath {
    /// Photos-style double-tap zoom.
    static let doubleTapScale: CGFloat = 2.5

    /// How far in is worth going: twice the photo's native pixels (so single pixels are
    /// visible), never less than 4× or more than 8×.
    static func maxScale(pixelSize: CGSize, fittedSize: CGSize, screenScale: CGFloat) -> CGFloat {
        guard fittedSize.width > 0, screenScale > 0, pixelSize.width > 0 else { return 4 }
        let native = pixelSize.width / (fittedSize.width * screenScale)
        return min(max(4, native * 2), 8)
    }

    /// Zoom to `newScale` keeping the point under `anchor` (view coordinates, relative to the
    /// view's centre) where it is.
    static func zoom(_ z: ZoomState, to newScale: CGFloat, anchor: CGPoint) -> ZoomState {
        guard z.scale > 0 else { return z }
        let k = newScale / z.scale
        // A view point p = offset + scale·q (q in fitted-image space, from its centre).
        // Keeping p fixed: offset' = p − (p − offset)·k.
        return ZoomState(scale: newScale,
                         offset: CGSize(width: anchor.x - (anchor.x - z.offset.width) * k,
                                        height: anchor.y - (anchor.y - z.offset.height) * k))
    }

    /// How far the image may move each way at `scale` without showing past its edge.
    static func maxOffset(scale: CGFloat, fitted: CGSize, view: CGSize) -> CGSize {
        CGSize(width: max(0, (fitted.width * scale - view.width) / 2),
               height: max(0, (fitted.height * scale - view.height) / 2))
    }

    /// The resting state after a gesture: scale within 1…max, no gap at the edges.
    static func settled(_ z: ZoomState, maxScale: CGFloat, fitted: CGSize, view: CGSize,
                        anchor: CGPoint = .zero) -> ZoomState {
        var s = z
        let clampedScale = min(max(z.scale, 1), maxScale)
        if clampedScale != z.scale { s = zoom(z, to: clampedScale, anchor: anchor) }
        let m = maxOffset(scale: s.scale, fitted: fitted, view: view)
        s.offset = CGSize(width: min(max(s.offset.width, -m.width), m.width),
                          height: min(max(s.offset.height, -m.height), m.height))
        return s
    }

    /// Past a limit, movement meets more and more resistance (like UIScrollView's bounce).
    /// `value` is the unconstrained position; the result never strays more than `limit`
    /// beyond the range.
    static func rubberBand(_ value: CGFloat, in range: ClosedRange<CGFloat>, limit: CGFloat) -> CGFloat {
        guard limit > 0 else { return min(max(value, range.lowerBound), range.upperBound) }
        func band(_ over: CGFloat) -> CGFloat { (1 - 1 / (over * 0.55 / limit + 1)) * limit }
        if value > range.upperBound { return range.upperBound + band(value - range.upperBound) }
        if value < range.lowerBound { return range.lowerBound - band(range.lowerBound - value) }
        return value
    }

    /// Double-tap: zoomed → back to fit; at fit → `doubleTapScale` centred on the tap.
    static func doubleTap(_ z: ZoomState, at point: CGPoint, maxScale: CGFloat,
                          fitted: CGSize, view: CGSize) -> ZoomState {
        if z.isZoomed { return .identity }
        let target = min(doubleTapScale, maxScale)
        // Bring the tapped point to the middle of the view, then settle at the edges.
        var s = zoom(z, to: target, anchor: point)
        s.offset.width -= point.x
        s.offset.height -= point.y
        return settled(s, maxScale: maxScale, fitted: fitted, view: view)
    }

    /// Where a fitted image (`fittedRect`, in view space) is drawn at zoom `z`.
    static func displayedRect(_ fittedRect: CGRect, zoom z: ZoomState, view: CGSize) -> CGRect {
        let w = fittedRect.width * z.scale, h = fittedRect.height * z.scale
        return CGRect(x: view.width / 2 + z.offset.width - w / 2,
                      y: view.height / 2 + z.offset.height - h / 2,
                      width: w, height: h)
    }
}
