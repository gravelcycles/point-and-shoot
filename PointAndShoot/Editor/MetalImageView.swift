import CoreImage
import MetalKit
import SwiftUI

/// Draws a CIImage graph with Metal, aspect-fit. Re-renders only when the image (or the
/// zoom) changes, so dragging an adjustment costs exactly one GPU pass per frame.
///
/// With `zoomable`, it zooms like Photos: pinch (anchored under the fingers) and two-finger
/// pan at the same time, rubber-banding past the limits, double-tap fit ↔ 2.5×. Zoom is a
/// transform in the renderer, so Core Image only renders the visible region, at screen
/// resolution, from whatever source it's given (the editor hands it a sharper one when
/// zoomed in). One-finger drags are left alone: they're the editor's Snapseed adjust
/// gesture, unless `oneFingerPan` (tools without sliders).
///
/// Zooming and panning never re-run the edit: once the image has stopped changing for a
/// moment, it's rendered once into a bitmap (`raster`), and zoom/pan frames just draw that
/// bitmap moved and scaled. Re-running the RAW develop and the film look for every pinch
/// frame made zoom lag on device. `contentKey` says when the edit itself changed (the
/// bitmap is then dropped at once); a new image with the same key (the sharper source
/// arriving when zoomed in) keeps the old bitmap on screen until its own is ready.
struct MetalImageView: UIViewRepresentable {
    let image: CIImage?
    /// Changes whenever what the image shows changes (the edit, compare, crop).
    var contentKey = 0
    var zoomable = false
    var oneFingerPan = false
    /// Native pixel size of the photo, for the maximum zoom.
    var pixelSize: CGSize = .zero
    /// Reports the zoom scale as it changes (1 = fit).
    var onZoom: (CGFloat) -> Void = { _ in }
    /// A two-finger gesture started or ended (the editor ignores its own drag meanwhile).
    var onPinch: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: EditPipeline.device)
        view.delegate = context.coordinator
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.autoResizeDrawable = true
        view.backgroundColor = .black
        view.isOpaque = true
        view.accessibilityIdentifier = "editor.canvas"
        view.isAccessibilityElement = true
        (view.layer as? CAMetalLayer)?.colorspace = EditPipeline.displayColorSpace
        context.coordinator.install(on: view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        let c = context.coordinator
        let changed = c.image !== image || c.contentKey != contentKey
        c.image = image
        c.contentKey = contentKey
        if changed { c.scheduleRaster() }
        c.zoomable = zoomable
        c.oneFingerPan = oneFingerPan
        c.pixelSize = pixelSize
        c.onZoom = onZoom
        c.onPinch = onPinch
        // Zoom off (Crop, still loading): back to fit, so the crop handles line up.
        if !zoomable { c.reset() }
        c.updateGestures()
        view.setNeedsDisplay()
    }

    final class Coordinator: NSObject, MTKViewDelegate, UIGestureRecognizerDelegate {
        var image: CIImage?
        var contentKey = 0
        var zoomable = false
        var oneFingerPan = false

        /// The edit rendered once to a bitmap, for zoom and pan frames.
        private var raster: CIImage?
        private var rasterKey: Int?
        private var rasterJob: DispatchWorkItem?
        private var rasterGeneration = 0
        private static let rasterQueue = DispatchQueue(label: "editor.raster", qos: .userInitiated)
        /// The editor's sources are at most 4096 px; anything bigger isn't worth a bitmap.
        private static let rasterMaxSide: CGFloat = 4600
        var pixelSize: CGSize = .zero
        var onZoom: (CGFloat) -> Void = { _ in }
        var onPinch: (Bool) -> Void = { _ in }

        private(set) var zoom = ZoomState.identity
        private weak var view: MTKView?
        private let pinch = UIPinchGestureRecognizer()
        private let twoFingerPan = UIPanGestureRecognizer()
        private let oneFingerPanRecognizer = UIPanGestureRecognizer()
        private let doubleTap = UITapGestureRecognizer()
        private var activeGestures = 0
        /// The pinch's scale before rubber-banding.
        private var rawScale: CGFloat = 1
        private var lastReportedScale: CGFloat = 1

        // Settle animation.
        private var link: CADisplayLink?
        private var animFrom = ZoomState.identity
        private var animTo = ZoomState.identity
        private var animStart: CFTimeInterval = 0
        private let animDuration: CFTimeInterval = 0.32

        func install(on view: MTKView) {
            self.view = view
            pinch.addTarget(self, action: #selector(handlePinch(_:)))
            twoFingerPan.addTarget(self, action: #selector(handlePan(_:)))
            twoFingerPan.minimumNumberOfTouches = 2
            twoFingerPan.maximumNumberOfTouches = 2
            oneFingerPanRecognizer.addTarget(self, action: #selector(handlePan(_:)))
            oneFingerPanRecognizer.maximumNumberOfTouches = 1
            doubleTap.addTarget(self, action: #selector(handleDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            for g in [pinch, twoFingerPan, oneFingerPanRecognizer, doubleTap] as [UIGestureRecognizer] {
                g.delegate = self
                // Never swallow touches the SwiftUI gestures (the adjust drag) also need.
                g.cancelsTouchesInView = false
                view.addGestureRecognizer(g)
            }
            updateGestures()
        }

        func updateGestures() {
            pinch.isEnabled = zoomable
            twoFingerPan.isEnabled = zoomable
            doubleTap.isEnabled = zoomable
            oneFingerPanRecognizer.isEnabled = zoomable && oneFingerPan && zoom.isZoomed
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // Pinch and two-finger pan together (zoom and move at once); and alongside SwiftUI's.
            true
        }

        // MARK: Geometry

        private var viewSize: CGSize { view?.bounds.size ?? .zero }

        private var fittedSize: CGSize {
            guard let e = image?.extent, e.width > 0, e.height > 0, !e.isInfinite else { return viewSize }
            return aspectFitRect(e.size, in: viewSize).size
        }

        private var maxScale: CGFloat {
            let px = pixelSize.width > 0 ? pixelSize : (image?.extent.size ?? .zero)
            return ZoomMath.maxScale(pixelSize: px, fittedSize: fittedSize,
                                     screenScale: view?.traitCollection.displayScale ?? 3)
        }

        private func centred(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x - viewSize.width / 2, y: p.y - viewSize.height / 2)
        }

        private func set(_ z: ZoomState) {
            zoom = z
            view?.setNeedsDisplay()
            if abs(z.scale - lastReportedScale) > 0.01 || (z.scale == 1 && lastReportedScale != 1) {
                lastReportedScale = z.scale
                // Async: this can run inside a SwiftUI update (reset), which mustn't change state.
                let report = onZoom, scale = z.scale
                DispatchQueue.main.async { report(scale) }
            }
            oneFingerPanRecognizer.isEnabled = zoomable && oneFingerPan && z.isZoomed
        }

        // MARK: Gestures

        private func began() {
            stopAnimation()
            activeGestures += 1
            if activeGestures == 1 { let f = onPinch; DispatchQueue.main.async { f(true) } }
        }

        private func ended() {
            activeGestures = max(0, activeGestures - 1)
            guard activeGestures == 0 else { return }
            let f = onPinch
            DispatchQueue.main.async { f(false) }
            animate(to: ZoomMath.settled(zoom, maxScale: maxScale, fitted: fittedSize, view: viewSize))
        }

        @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
            switch g.state {
            case .began:
                began()
                rawScale = zoom.scale
            case .changed:
                // Incremental: each step zooms about the fingers' current centroid, so moving
                // them pans at the same time.
                rawScale *= g.scale
                g.scale = 1
                // Past 1× or the maximum, rubber-band (in log space: symmetric in and out).
                let banded = exp(ZoomMath.rubberBand(log(rawScale), in: 0...log(maxScale), limit: log(1.6)))
                set(ZoomMath.zoom(zoom, to: banded, anchor: centred(g.location(in: view))))
            case .ended, .cancelled, .failed:
                ended()
            default:
                break
            }
        }

        @objc private func handlePan(_ g: UIPanGestureRecognizer) {
            switch g.state {
            case .began:
                began()
            case .changed:
                let t = g.translation(in: view)
                g.setTranslation(.zero, in: view)
                var z = zoom
                let m = ZoomMath.maxOffset(scale: z.scale, fitted: fittedSize, view: viewSize)
                // Past an edge, the image follows the finger at a third of the speed.
                let dx = abs(z.offset.width) > m.width && (z.offset.width > 0) == (t.x > 0) ? t.x * 0.35 : t.x
                let dy = abs(z.offset.height) > m.height && (z.offset.height > 0) == (t.y > 0) ? t.y * 0.35 : t.y
                z.offset.width += dx
                z.offset.height += dy
                set(z)
            case .ended, .cancelled, .failed:
                ended()
            default:
                break
            }
        }

        @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
            guard activeGestures == 0 else { return }
            animate(to: ZoomMath.doubleTap(zoom, at: centred(g.location(in: view)), maxScale: maxScale,
                                           fitted: fittedSize, view: viewSize))
        }

        func reset() {
            guard zoom != .identity || link != nil else { return }
            stopAnimation()
            set(.identity)
        }

        // MARK: Animation

        private func animate(to target: ZoomState) {
            guard target != zoom else { return }
            stopAnimation()
            animFrom = zoom
            animTo = target
            animStart = CACurrentMediaTime()
            let link = CADisplayLink(target: self, selector: #selector(step))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        private func stopAnimation() {
            link?.invalidate()
            link = nil
        }

        @objc private func step() {
            let t = min(1, (CACurrentMediaTime() - animStart) / animDuration)
            let e = CGFloat(1 - pow(1 - t, 3))   // ease-out cubic
            let s = animFrom.scale + (animTo.scale - animFrom.scale) * e
            let o = CGSize(width: animFrom.offset.width + (animTo.offset.width - animFrom.offset.width) * e,
                           height: animFrom.offset.height + (animTo.offset.height - animFrom.offset.height) * e)
            set(ZoomState(scale: s, offset: o))
            if t >= 1 { stopAnimation(); set(animTo) }
        }

        // MARK: Bitmap

        /// The image changed: render it to a bitmap once it settles (slider drags change it
        /// every frame, and those frames render the graph directly, as before).
        func scheduleRaster() {
            // A different edit: the old bitmap is wrong now. The same edit from a sharper
            // source: keep showing the old one until the new one is ready.
            if rasterKey != contentKey {
                raster = nil
                rasterKey = nil
            }
            rasterJob?.cancel()
            rasterGeneration += 1
            guard let image else { return }
            let e = image.extent
            guard !e.isInfinite, e.width >= 1, e.height >= 1,
                  max(e.width, e.height) <= Self.rasterMaxSide else { return }
            let generation = rasterGeneration
            let key = contentKey
            let job = DispatchWorkItem { [weak self] in
                Self.rasterQueue.async {
                    let start = CACurrentMediaTime()
                    guard let cg = EditPipeline.context.createCGImage(image, from: e, format: .RGBA8,
                                                                      colorSpace: EditPipeline.displayColorSpace)
                    else { return }
                    let bitmap = CIImage(cgImage: cg)
                    let ms = Int((CACurrentMediaTime() - start) * 1000)
                    DispatchQueue.main.async {
                        guard let self, self.rasterGeneration == generation else { return }
                        self.raster = bitmap
                        self.rasterKey = key
                        self.view?.setNeedsDisplay()
                        if ms > 250 { Diag.log(.editor, "canvas bitmap \(cg.width)×\(cg.height) in \(ms) ms") }
                    }
                }
            }
            rasterJob = job
            // Soon while zooming (the sharper source just arrived); otherwise after a
            // pause, so a slider drag doesn't queue a render per step.
            let busy = zoom.isZoomed || activeGestures > 0
            DispatchQueue.main.asyncAfter(deadline: .now() + (busy ? 0.02 : 0.25), execute: job)
        }

        /// What to draw: the bitmap when it shows the current edit, else the live graph.
        private var shownImage: CIImage? {
            if let raster, rasterKey == contentKey { return raster }
            return image
        }

        // MARK: Drawing

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            view.setNeedsDisplay()
        }

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let commandBuffer = EditPipeline.queue.makeCommandBuffer() else { return }
            let size = view.drawableSize
            let bounds = CGRect(origin: .zero, size: size)
            var output = CIImage(color: .black).cropped(to: bounds)
            if let image = shownImage, image.extent.width > 0, image.extent.height > 0, !image.extent.isInfinite {
                let e = image.extent
                // Points → drawable pixels.
                let px = view.bounds.width > 0 ? size.width / view.bounds.width : 1
                let fit = min(size.width / e.width, size.height / e.height)
                let scale = fit * zoom.scale
                // Centre the image, then move it by the pan (Core Image's y axis points up).
                let tx = size.width / 2 + zoom.offset.width * px - e.width * scale / 2
                let ty = size.height / 2 - zoom.offset.height * px - e.height * scale / 2
                let placed = image
                    .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
                    .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    .transformed(by: CGAffineTransform(translationX: tx, y: ty))
                // Cropping to the screen means Core Image only renders what's visible.
                output = placed.cropped(to: bounds).composited(over: output)
            }
            EditPipeline.context.render(output, to: drawable.texture, commandBuffer: commandBuffer,
                                        bounds: bounds, colorSpace: EditPipeline.displayColorSpace)
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

/// Where an image of `imageSize` lands when aspect-fit into `container`.
func aspectFitRect(_ imageSize: CGSize, in container: CGSize) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0 else { return CGRect(origin: .zero, size: container) }
    let scale = min(container.width / imageSize.width, container.height / imageSize.height)
    let w = imageSize.width * scale, h = imageSize.height * scale
    return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
}
