import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import QuartzCore
import UIKit

/// Renders camera frames straight to a CAMetalLayer with Core Image on the GPU.
///
/// Rendering our own preview (instead of AVCaptureVideoPreviewLayer) is what lets us draw
/// focus peaking, zebras, a live histogram and a Log → Rec.709 view assist on the exact
/// pixels being recorded. Frames are dropped — never queued — if the GPU is busy, so the
/// preview never lags behind reality.
final class PreviewRenderer {
    struct Config {
        var peaking = false
        var peakingColor: (CGFloat, CGFloat, CGFloat) = (1, 0.15, 0.1)
        var zebras = false
        var zebraThreshold: Double = 0.95
        var logAssist = false
        var mirrored = false
        var transitionBlur = false
        var computeHistogram = true
        /// Capture look, previewed live.
        var look: EditRecipe?
    }

    let device: MTLDevice
    var onHistogram: ((Histogram) -> Void)?

    private let commandQueue: MTLCommandQueue
    private let context: CIContext
    private let renderQueue = DispatchQueue(label: "preview.render", qos: .userInteractive)
    private let analysisQueue = DispatchQueue(label: "preview.analysis", qos: .utility)
    private let displayColorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    private let lock = NSLock()
    private var config = Config()
    private var drawableSize: CGSize = .zero
    private var orientedSize: CGSize = .zero
    private var metalLayer: CAMetalLayer?
    private var rendering = false
    private var analyzing = false
    private var frameIndex = 0
    private var lastBase: CIImage?

    private lazy var logCube: Data = Self.makeAppleLogToRec709Cube(dimension: 33)
    private lazy var stripes: CIImage? = {
        let f = CIFilter(name: "CIStripesGenerator", parameters: [
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 0.9),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
            "inputWidth": 5.0,
            "inputSharpness": 1.0,
        ])
        return f?.outputImage?.transformed(by: CGAffineTransform(rotationAngle: .pi / 4))
    }()

    init() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Metal is required")
        }
        self.device = device
        self.commandQueue = queue
        self.context = CIContext(mtlCommandQueue: queue, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .cacheIntermediates: false,
            .name: "preview",
        ])
    }

    // MARK: - Configuration

    func update(_ body: (inout Config) -> Void) {
        lock.lock()
        let wasBlurred = config.transitionBlur
        body(&config)
        let nowBlurred = config.transitionBlur
        lock.unlock()
        if nowBlurred && !wasBlurred { renderTransitionFrame() }
    }

    func attach(layer: CAMetalLayer) {
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.colorspace = displayColorSpace
        layer.maximumDrawableCount = 3
        layer.allowsNextDrawableTimeout = true
        lock.lock()
        metalLayer = layer
        lock.unlock()
    }

    func setDrawableSize(_ size: CGSize) {
        lock.lock()
        drawableSize = size
        lock.unlock()
    }

    /// Size of the most recent frame after orientation (portrait), used for tap → sensor mapping.
    var orientedImageSize: CGSize {
        lock.lock()
        defer { lock.unlock() }
        return orientedSize
    }

    // MARK: - Frames

    func enqueue(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        if rendering || metalLayer == nil || drawableSize.width == 0 {
            lock.unlock()
            return
        }
        rendering = true
        let cfg = config
        let size = drawableSize
        let layer = metalLayer
        lock.unlock()

        renderQueue.async {
            autoreleasepool {
                self.render(pixelBuffer, cfg: cfg, size: size, layer: layer)
            }
            self.lock.lock()
            self.rendering = false
            self.lock.unlock()
        }
    }

    private func render(_ pixelBuffer: CVPixelBuffer, cfg: Config, size: CGSize, layer: CAMetalLayer?) {
        guard let layer else { return }
        var image: CIImage
        if cfg.logAssist {
            // Read raw Log code values (no color management), map through the view LUT.
            image = CIImage(cvPixelBuffer: pixelBuffer, options: [.colorSpace: NSNull()])
            image = image.applyingFilter("CIColorCube", parameters: [
                "inputCubeDimension": 33,
                "inputCubeData": logCube,
            ])
        } else {
            image = CIImage(cvPixelBuffer: pixelBuffer)
        }
        image = image.oriented(cfg.mirrored ? .leftMirrored : .right)

        let extent = image.extent
        lock.lock()
        orientedSize = extent.size
        lock.unlock()

        let bounds = CGRect(origin: .zero, size: size)
        let scale = max(size.width / extent.width, size.height / extent.height)
        image = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let tx = (size.width - extent.width * scale) / 2
        let ty = (size.height - extent.height * scale) / 2
        image = image.transformed(by: CGAffineTransform(translationX: tx, y: ty)).cropped(to: bounds)

        if let look = cfg.look {
            image = EditPipeline.apply(look, to: image, developedFromRAW: false, applyCrop: false, animateGrain: true)
                .cropped(to: bounds)
        }

        lastBase = image

        frameIndex &+= 1
        if cfg.computeHistogram && frameIndex % 5 == 0 { analyze(image) }

        if cfg.zebras { image = zebraOverlay(image, threshold: cfg.zebraThreshold) }
        if cfg.peaking { image = peakingOverlay(image, color: cfg.peakingColor) }
        if cfg.transitionBlur { image = blurred(image, bounds: bounds) }

        present(image, bounds: bounds, layer: layer)
    }

    private func present(_ image: CIImage, bounds: CGRect, layer: CAMetalLayer) {
        let final = image.composited(over: CIImage(color: .black).cropped(to: bounds))
        guard let drawable = layer.nextDrawable(), let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        context.render(final, to: drawable.texture, commandBuffer: commandBuffer, bounds: bounds, colorSpace: displayColorSpace)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func renderTransitionFrame() {
        renderQueue.async {
            self.lock.lock()
            let layer = self.metalLayer
            let size = self.drawableSize
            self.lock.unlock()
            guard let layer, let base = self.lastBase, size.width > 0 else { return }
            let bounds = CGRect(origin: .zero, size: size)
            self.present(self.blurred(base, bounds: bounds), bounds: bounds, layer: layer)
        }
    }

    private func blurred(_ image: CIImage, bounds: CGRect) -> CIImage {
        image.clampedToExtent()
            .applyingGaussianBlur(sigma: 28)
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -0.6])
            .cropped(to: bounds)
    }

    // MARK: - Assists

    private func peakingOverlay(_ image: CIImage, color: (CGFloat, CGFloat, CGFloat)) -> CIImage {
        let bounds = image.extent
        let edges = image
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
            .clampedToExtent()
            .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 5.0])
            .cropped(to: bounds)
        let mask = edges.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.2])
        let colored = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: color.0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: color.1, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: color.2, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ])
        return colored.composited(over: image)
    }

    private func zebraOverlay(_ image: CIImage, threshold: Double) -> CIImage {
        guard let stripes else { return image }
        let bounds = image.extent
        // Threshold is in display (gamma) terms; the working space is linear.
        let linear = pow(threshold, 2.2)
        let mask = image
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
            .applyingFilter("CIColorThreshold", parameters: ["inputThreshold": linear])
        let zebra = stripes.cropped(to: bounds).applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask,
        ])
        return zebra.composited(over: image)
    }

    // MARK: - Histogram

    private func analyze(_ image: CIImage) {
        lock.lock()
        if analyzing { lock.unlock(); return }
        analyzing = true
        lock.unlock()

        analysisQueue.async {
            defer {
                self.lock.lock()
                self.analyzing = false
                self.lock.unlock()
            }
            let extent = image.extent
            guard extent.width > 0 else { return }
            let s = 160 / extent.width
            let small = image
                .transformed(by: CGAffineTransform(scaleX: s, y: s))
                .applyingFilter("CILinearToSRGBToneCurve")
            let bins = 64
            let filter = CIFilter.areaHistogram()
            filter.inputImage = small
            filter.extent = small.extent
            filter.count = bins
            filter.scale = 1
            guard let output = filter.outputImage else { return }
            var raw = [Float](repeating: 0, count: bins * 4)
            self.context.render(output, toBitmap: &raw, rowBytes: bins * 4 * MemoryLayout<Float>.size,
                                bounds: CGRect(x: 0, y: 0, width: bins, height: 1), format: .RGBAf, colorSpace: nil)
            var h = Histogram()
            h.red = (0..<bins).map { raw[$0 * 4] }
            h.green = (0..<bins).map { raw[$0 * 4 + 1] }
            h.blue = (0..<bins).map { raw[$0 * 4 + 2] }
            h.luma = (0..<bins).map { 0.2126 * h.red[$0] + 0.7152 * h.green[$0] + 0.0722 * h.blue[$0] }
            self.onHistogram?(h)
        }
    }

    // MARK: - Apple Log view LUT

    /// Apple Log (per Apple's published curve) → scene linear → Rec.2020→709 → soft filmic
    /// shoulder. Output is linear; Core Image encodes it for the display.
    static func makeAppleLogToRec709Cube(dimension n: Int) -> Data {
        var cube = [Float]()
        cube.reserveCapacity(n * n * n * 4)
        let step = 1 / Float(n - 1)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let R = appleLogDecode(Float(r) * step)
                    let G = appleLogDecode(Float(g) * step)
                    let B = appleLogDecode(Float(b) * step)
                    let r709 = 1.6605 * R - 0.5876 * G - 0.0728 * B
                    let g709 = -0.1246 * R + 1.1329 * G - 0.0083 * B
                    let b709 = -0.0182 * R - 0.1006 * G + 1.1187 * B
                    cube.append(filmic(r709))
                    cube.append(filmic(g709))
                    cube.append(filmic(b709))
                    cube.append(1)
                }
            }
        }
        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func appleLogDecode(_ p: Float) -> Float {
        let r0: Float = -0.05641088
        let rt: Float = 0.01
        let c: Float = 47.28711236
        let b: Float = 0.00964052
        let g: Float = 0.08550479
        let d: Float = 0.69336945
        let pt = c * (rt - r0) * (rt - r0)
        if p >= pt { return powf(2, (p - d) / g) - b }
        if p > 0 { return sqrtf(p / c) + r0 }
        return r0
    }

    private static func filmic(_ v: Float) -> Float {
        let x = max(0, v) * 1.2
        let white: Float = 6
        let y = x * (1 + x / (white * white)) / (1 + x)
        return min(1, y)
    }
}
