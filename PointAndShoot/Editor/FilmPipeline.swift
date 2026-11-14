import CoreImage

/// Core Image side of the film looks: Print and the photo filters, one stock each (the
/// math is in FilmModel.swift, the stocks in FilmStock+Stocks.swift).
///
///   linear light ─ exposure ─ halation ─ shaper ─ negative cube ─ + grain ─ print cube ─ display
///
/// Halation and grain are spatial, so they live outside the lookup tables: halation is
/// added in scene light (as on film, where it is light bouncing back off the film base),
/// grain is added in negative density so the print curve shapes it the way a real print
/// does (most visible in the mid-tones, quieter in highlights and deep shadows).
enum FilmPipeline {
    struct Settings: Equatable {
        /// Which film stock (`FilmStock.all`); "print" is the Print look.
        var stockID = "print"
        var source: FilmLUT.Source = .sceneLinear
        /// Stops, applied to scene light before the film.
        var exposure: Double = 0
        /// 0…2, 1 = the look as designed.
        var halation: Double = 1
        /// 0…2, 1 = the look as designed.
        var grain: Double = 1
        var controls = FilmControls()
        /// Moves the grain pattern every call (live viewfinder) instead of keeping it fixed.
        var animateGrain = false
    }

    // MARK: Lookup tables (built on first use, cached)

    /// A small least-recently-used cache: each table is 1.8 MB, and the filter strip's live
    /// previews touch every stock.
    private final class TableCache<Key: Hashable> {
        private var tables: [Key: Data] = [:]
        private var order: [Key] = []
        let capacity: Int
        init(capacity: Int) { self.capacity = capacity }

        func get(_ key: Key) -> Data? {
            guard let t = tables[key] else { return nil }
            if let i = order.firstIndex(of: key) { order.remove(at: i) }
            order.append(key)
            return t
        }

        func set(_ key: Key, _ table: Data) {
            if tables[key] == nil { order.append(key) }
            tables[key] = table
            while order.count > capacity { tables[order.removeFirst()] = nil }
        }
    }

    private struct NegativeKey: Hashable { let stock: String; let source: FilmLUT.Source }
    private struct PrintKey: Hashable { let stock: String; let controls: FilmControls }

    private static let lock = NSLock()
    private static let negativeCubes = TableCache<NegativeKey>(capacity: 16)
    private static let printCubes = TableCache<PrintKey>(capacity: 18)

    static func negativeCube(_ stock: FilmStock, _ source: FilmLUT.Source) -> Data {
        let key = NegativeKey(stock: stock.id, source: source)
        lock.lock()
        if let cube = negativeCubes.get(key) { lock.unlock(); return cube }
        lock.unlock()
        let cube = FilmLUT.negativeCube(stock: stock, source: source).withUnsafeBufferPointer { Data(buffer: $0) }
        lock.lock()
        negativeCubes.set(key, cube)
        lock.unlock()
        return cube
    }

    static func printCube(_ stock: FilmStock, _ controls: FilmControls) -> Data {
        let key = PrintKey(stock: stock.id, controls: controls)
        lock.lock()
        if let cube = printCubes.get(key) { lock.unlock(); return cube }
        lock.unlock()
        let cube = FilmLUT.printCube(stock: stock, controls: controls).withUnsafeBufferPointer { Data(buffer: $0) }
        lock.lock()
        printCubes.set(key, cube)
        lock.unlock()
        return cube
    }

    /// Builds every stock's viewfinder tables off the main thread (~200 ms of CPU once),
    /// so neither the first frame with a filter nor the filter strip's live previews ever
    /// wait for them. Print's RAW table too, since Print mode develops from RAW.
    static func prewarm() {
        DispatchQueue.global(qos: .utility).async {
            let printStock = FilmStock.printLook
            _ = negativeCube(printStock, .displayReferred)
            _ = printCube(printStock, FilmControls())
            for stock in FilmStock.all.values where stock.id != printStock.id {
                _ = negativeCube(stock, .displayReferred)
                _ = printCube(stock, FilmControls())
            }
            _ = negativeCube(printStock, .sceneLinear)
        }
    }

    // MARK: Render

    /// `image` is linear light in the working space (extended linear sRGB): scene light from
    /// a RAW develop with no tone curve, or a display-referred image for `.displayReferred`.
    /// `unit` is the long side / 1000, so spatial effects scale with the picture.
    static func apply(_ image: CIImage, settings s: Settings, unit: CGFloat) -> CIImage {
        let stock = FilmStock.named(s.stockID)
        let bounds = image.extent
        var x = image
        let ev = s.exposure + stock.exposure
        if ev != 0 {
            x = x.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev])
        }
        if s.halation > 0 {
            x = addHalation(x, stock: stock, amount: s.halation, source: s.source, unit: unit)
        }

        // Shaper: → Rec.2020, ÷ scale, clamp to 0…1, ^(1/power). Matches FilmLUT.shaped.
        let m = FilmMath.sRGBToRec2020.map { CGFloat($0 / FilmLUT.shaperScale) }
        x = x
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: m[0], y: m[1], z: m[2], w: 0),
                "inputGVector": CIVector(x: m[3], y: m[4], z: m[5], w: 0),
                "inputBVector": CIVector(x: m[6], y: m[7], z: m[8], w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ])
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
            ])
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 1 / FilmLUT.shaperPower])
            .applyingFilter("CIColorCube", parameters: [
                "inputCubeDimension": FilmLUT.negativeDimension,
                "inputCubeData": negativeCube(stock, s.source),
            ])

        if s.grain > 0 {
            x = addGrain(to: x, stock: stock, amount: s.grain, unit: unit, animate: s.animateGrain)
        }

        x = x.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": FilmLUT.printDimension,
            "inputCubeData": printCube(stock, s.controls),
        ])
        // The print cube outputs Display P3 with the sRGB transfer curve.
        if let p3 = CGColorSpace(name: CGColorSpace.displayP3), let linear = x.matchedToWorkingSpace(from: p3) {
            x = linear
        } else {
            x = x.applyingFilter("CISRGBToneCurveToLinear")
        }
        return x.cropped(to: bounds)
    }

    // MARK: Halation

    /// Light that passes through the film reflects off its base and re-exposes the layers
    /// (mostly red) in a soft halo: the warm glow film gets around bright lights and hard
    /// bright edges. Energy-conserving, E' = (E + a·glow) / (1 + a), so flat areas keep
    /// their color and only edges next to bright light pick up the glow. Highlights near
    /// clipping are boosted first, since the sensor clips where film wouldn't.
    private static func addHalation(_ image: CIImage, stock: FilmStock, amount: Double, source: FilmLUT.Source,
                                    unit: CGFloat) -> CIImage {
        let bounds = image.extent
        let spread = stock.halationSpread
        let threshold = CGFloat(source == .sceneLinear ? spread.threshold : spread.displayThreshold)
        let boost = CGFloat(source == .sceneLinear ? spread.boost : spread.displayBoost)

        // src = image + boost · max(image − threshold, 0)
        let excess = image
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: boost, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: boost, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: boost, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: -boost * threshold, y: -boost * threshold, z: -boost * threshold, w: 0),
            ])
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1024, y: 1024, z: 1024, w: 0),
            ])
        let glowSource = excess.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: image])

        // Blur at quarter resolution: the glow is wide and smooth, so nothing is lost.
        let down: CGFloat = 4
        let small = glowSource.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: 1 / down, y: 1 / down))
        var glow: CIImage?
        for (sigma, weight) in zip(spread.sigmas, spread.weights) {
            let blurred = small
                .applyingGaussianBlur(sigma: max(0.5, sigma * Double(unit / down)))
                .applyingFilter("CIColorMatrix", parameters: scale(CGFloat(weight), CGFloat(weight), CGFloat(weight)))
            glow = glow.map { blurred.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? blurred
        }
        guard let glow else { return image }

        let a = stock.halation.map { CGFloat($0 * amount) }
        let keep = image.applyingFilter("CIColorMatrix", parameters: scale(1 / (1 + a[0]), 1 / (1 + a[1]), 1 / (1 + a[2]), alpha: 1))
        let halo = glow
            .transformed(by: CGAffineTransform(scaleX: down, y: down))
            .applyingFilter("CIColorMatrix", parameters: scale(a[0] / (1 + a[0]), a[1] / (1 + a[1]), a[2] / (1 + a[2])))
            .cropped(to: bounds)
        return halo.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: keep])
    }

    /// CIColorMatrix parameters for a per-channel gain.
    private static func scale(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, alpha: CGFloat = 0) -> [String: Any] {
        [
            "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ]
    }

    // MARK: Exposure matching

    /// `FilmLUT.sceneKey` of a Core Image image (linear working space), measured on a
    /// ~48 px Lanczos-downscaled copy. Cheap enough for the viewfinder a few times a second.
    static func sceneKey(of image: CIImage, context: CIContext, source: FilmLUT.Source) -> Double? {
        let e = image.extent
        guard e.width >= 1, e.height >= 1, e.width.isFinite, e.height.isFinite else { return nil }
        let w = 48
        let s = CGFloat(w) / e.width
        let h = max(1, Int(e.height * s))
        let small = image
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .clampedToExtent()
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
        var px = [Float](repeating: 0, count: w * h * 4)
        context.render(small, toBitmap: &px, rowBytes: w * 4 * MemoryLayout<Float>.size,
                       bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: nil)
        return FilmLUT.sceneKey(rgba: px, displayReferred: source == .displayReferred)
    }

    // MARK: Grain

    /// Zero-mean noise in negative density (the cube stores density ÷ densityScale): a
    /// shared, monochrome part plus a little per-layer color, softened to the grain size.
    /// Amplitude is defined for a 4032 px long side; smaller renders average it down the
    /// way a downscaled photo would.
    ///
    /// Every intermediate image is opaque, so nothing depends on how a filter treats alpha.
    /// (CIRandomGenerator's alpha is random too; a filter that un-premultiplies would divide
    /// by it and turn the grain into heavy-tailed speckle.)
    private static func addGrain(to image: CIImage, stock: FilmStock, amount: Double, unit: CGFloat,
                                 animate: Bool) -> CIImage {
        guard var noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }
        let bounds = image.extent
        if animate {
            noise = noise.transformed(by: CGAffineTransform(translationX: CGFloat(Int.random(in: 0..<1024)),
                                                            y: CGFloat(Int.random(in: 0..<1024))))
        }
        let padded = bounds.insetBy(dx: -8, dy: -8)
        // Uniform 0…1 in R, G, B (std 1/√12), alpha forced to 1.
        noise = noise.cropped(to: padded).settingAlphaOne(in: padded)

        // Soften to the grain size. Grain is usually under a pixel (σ ≈ 0.5 px at 4032 px),
        // where Core Image's Gaussian blur isn't guaranteed to blur by exactly σ, and the
        // amplitude below assumes it does. So small sizes use an explicit 3×3 Gaussian whose
        // effect on the noise (Σw² of the 1-D taps) is known exactly.
        let sigmaPx = max(0.35, Double(unit) * stock.grainSize)
        let stdFactor: Double
        if sigmaPx < 1 {
            let w1 = exp(-1 / (2 * sigmaPx * sigmaPx))
            let c0 = 1 / (1 + 2 * w1), c1 = w1 / (1 + 2 * w1)
            stdFactor = c0 * c0 + 2 * c1 * c1
            let w = [c1 * c1, c1 * c0, c1 * c1, c0 * c1, c0 * c0, c0 * c1, c1 * c1, c1 * c0, c1 * c1].map { CGFloat($0) }
            noise = noise.applyingFilter("CIConvolution3X3", parameters: [
                "inputWeights": CIVector(values: w, count: 9), "inputBias": 0,
            ])
        } else {
            stdFactor = gaussianStdFactor(sigma: sigmaPx)
            noise = noise.applyingGaussianBlur(sigma: sigmaPx)
        }

        // Mix the three independent channels into per-layer grain with the stock's
        // covariance: mostly shared (monochrome), `grainChroma` per layer. The covariance
        // α·J + β·I (J = all ones) is M² for the symmetric M = p·I + q·J.
        let c = stock.grainChroma
        let norm2 = (1 - c) * (1 - c) + c * c
        let alpha = (1 - c) * (1 - c) / norm2, beta = c * c / norm2
        let p = beta.squareRoot()
        let q = (-2 * p + (4 * p * p + 12 * alpha).squareRoot()) / 6
        let resolution = min(1, Double(unit) / 4.032)
        let target = stock.grainDensity * amount * resolution / FilmLUT.densityScale
        let k = target / ((1 / 12.0.squareRoot()) * stdFactor)
        let d = CGFloat(k * (p + q)), o = CGFloat(k * q)
        let bias = -CGFloat(k * (p + 3 * q)) * 0.5        // zero mean
        let grain = noise
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: d, y: o, z: o, w: 0),
                "inputGVector": CIVector(x: o, y: d, z: o, w: 0),
                "inputBVector": CIVector(x: o, y: o, z: d, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
            ])
            .cropped(to: bounds)
        // Both opaque: the sum has alpha 2, which settingAlphaOne puts back to 1.
        return grain
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: image])
            .settingAlphaOne(in: bounds)
    }

    /// How much a discrete 2-D Gaussian blur of `sigma` px shrinks white noise's std.
    static func gaussianStdFactor(sigma: Double) -> Double {
        let r = Int((sigma * 3).rounded(.up))
        var w = [Double]()
        for i in -r...r { w.append(exp(-Double(i * i) / (2 * sigma * sigma))) }
        let sum = w.reduce(0, +)
        let sumSq = w.reduce(0) { $0 + ($1 / sum) * ($1 / sum) }
        return sumSq   // = sqrt(Σ over 2-D of w_i²w_j²) = Σ w_i²
    }
}
