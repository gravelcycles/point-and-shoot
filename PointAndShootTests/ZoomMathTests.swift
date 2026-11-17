import CoreGraphics
import XCTest
@testable import PointAndShoot

/// Photos-style zoom: the point under the fingers stays put, the image never rests showing
/// past its edge, limits rubber-band, double-tap goes to a point and back.
final class ZoomMathTests: XCTestCase {
    private let view = CGSize(width: 390, height: 600)
    /// A 4:3 landscape photo fitted into the view.
    private var fitted: CGSize { aspectFitRect(CGSize(width: 4032, height: 3024), in: view).size }

    private func viewPoint(of q: CGPoint, _ z: ZoomState) -> CGPoint {
        // q in fitted-image space from its centre → view space from the view's centre.
        CGPoint(x: z.offset.width + z.scale * q.x, y: z.offset.height + z.scale * q.y)
    }

    func testZoomKeepsTheAnchorUnderTheFingers() {
        var z = ZoomState.identity
        let anchor = CGPoint(x: 80, y: -40)
        // The image point under the anchor at 1×.
        let q = anchor
        for s in [1.5, 2.0, 3.7, 6.0, 2.2, 1.0] as [CGFloat] {
            z = ZoomMath.zoom(z, to: s, anchor: anchor)
            let p = viewPoint(of: q, z)
            XCTAssertEqual(p.x, anchor.x, accuracy: 1e-9)
            XCTAssertEqual(p.y, anchor.y, accuracy: 1e-9)
        }
    }

    func testIncrementalPinchMatchesOneStep() {
        // The editor applies pinch increments one at a time about the current centroid.
        var stepped = ZoomState.identity
        let anchor = CGPoint(x: -30, y: 55)
        for _ in 0..<20 { stepped = ZoomMath.zoom(stepped, to: stepped.scale * 1.05, anchor: anchor) }
        let direct = ZoomMath.zoom(.identity, to: pow(1.05, 20), anchor: anchor)
        XCTAssertEqual(stepped.scale, direct.scale, accuracy: 1e-9)
        XCTAssertEqual(stepped.offset.width, direct.offset.width, accuracy: 1e-6)
        XCTAssertEqual(stepped.offset.height, direct.offset.height, accuracy: 1e-6)
    }

    func testSettledNeverShowsPastTheEdge() {
        for s in [0.6, 1, 1.3, 2.5, 5, 9] as [CGFloat] {
            for o in [-900, -120, 0, 75, 2000] as [CGFloat] {
                let z = ZoomMath.settled(ZoomState(scale: s, offset: CGSize(width: o, height: -o)),
                                         maxScale: 6, fitted: fitted, view: view)
                XCTAssertGreaterThanOrEqual(z.scale, 1)
                XCTAssertLessThanOrEqual(z.scale, 6)
                let shown = ZoomMath.displayedRect(aspectFitRect(fitted, in: view), zoom: z, view: view)
                // Wider than the view → it covers the view; narrower → it's centred.
                if shown.width > view.width + 0.001 {
                    XCTAssertLessThanOrEqual(shown.minX, 0.001)
                    XCTAssertGreaterThanOrEqual(shown.maxX, view.width - 0.001)
                } else {
                    XCTAssertEqual(shown.midX, view.width / 2, accuracy: 0.001)
                }
                if shown.height > view.height + 0.001 {
                    XCTAssertLessThanOrEqual(shown.minY, 0.001)
                    XCTAssertGreaterThanOrEqual(shown.maxY, view.height - 0.001)
                } else {
                    XCTAssertEqual(shown.midY, view.height / 2, accuracy: 0.001)
                }
            }
        }
    }

    func testBelowFitSettlesBackToIdentity() {
        let z = ZoomMath.settled(ZoomState(scale: 0.7, offset: CGSize(width: 40, height: 10)),
                                 maxScale: 6, fitted: fitted, view: view)
        XCTAssertEqual(z, .identity)
    }

    func testRubberBandResistsAndIsBounded() {
        let range: ClosedRange<CGFloat> = 0...100
        XCTAssertEqual(ZoomMath.rubberBand(50, in: range, limit: 40), 50)
        let a = ZoomMath.rubberBand(120, in: range, limit: 40)
        let b = ZoomMath.rubberBand(400, in: range, limit: 40)
        XCTAssertGreaterThan(a, 100)
        XCTAssertLessThan(a, 120)         // resists
        XCTAssertGreaterThan(b, a)        // still moves the same way
        XCTAssertLessThan(b, 140)         // never more than `limit` past
        XCTAssertLessThan(ZoomMath.rubberBand(-50, in: range, limit: 40), 0)
        XCTAssertGreaterThan(ZoomMath.rubberBand(-5000, in: range, limit: 40), -40)
    }

    func testDoubleTapZoomsToThePointAndBack() {
        let tap = CGPoint(x: 60, y: 20)
        let z = ZoomMath.doubleTap(.identity, at: tap, maxScale: 6, fitted: fitted, view: view)
        XCTAssertEqual(z.scale, ZoomMath.doubleTapScale)
        // The tapped image point ends up in the middle (or as close as the edges allow).
        let p = viewPoint(of: tap, z)
        XCTAssertEqual(p.x, 0, accuracy: 0.5)
        XCTAssertEqual(ZoomMath.doubleTap(z, at: tap, maxScale: 6, fitted: fitted, view: view), .identity)
    }

    func testDoubleTapRespectsASmallMaximum() {
        let z = ZoomMath.doubleTap(.identity, at: .zero, maxScale: 2, fitted: fitted, view: view)
        XCTAssertEqual(z.scale, 2)
    }

    func testMaxScaleFollowsNativePixels() {
        // 12 MP across a 390 pt @3× screen: 2× native ≈ 6.9.
        let m = ZoomMath.maxScale(pixelSize: CGSize(width: 4032, height: 3024),
                                  fittedSize: CGSize(width: 390, height: 292.5), screenScale: 3)
        XCTAssertEqual(m, 4032 / 1170 * 2, accuracy: 0.01)
        // Small images still zoom to 4×; huge ones stop at 8×.
        XCTAssertEqual(ZoomMath.maxScale(pixelSize: CGSize(width: 800, height: 600),
                                         fittedSize: CGSize(width: 390, height: 292.5), screenScale: 3), 4)
        XCTAssertEqual(ZoomMath.maxScale(pixelSize: CGSize(width: 8064, height: 6048),
                                         fittedSize: CGSize(width: 390, height: 292.5), screenScale: 3), 8)
        XCTAssertEqual(ZoomMath.maxScale(pixelSize: .zero, fittedSize: .zero, screenScale: 3), 4)
    }
}
