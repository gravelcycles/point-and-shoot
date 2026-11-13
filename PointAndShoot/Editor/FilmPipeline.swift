import CoreImage

/// Core Image side of the Print look (the math is in FilmModel.swift).
///
///   linear light ─ exposure ─ halation ─ shaper ─ negative cube ─ + grain ─ print cube ─ display
///
/// Halation and grain are spatial, so they live outside the lookup tables: halation is
/// added in scene light (as on film, where it is light bouncing back off the film base),
/// grain is added in negative density so the print curve shapes it the way a real print
/// does (most visible in the mid-tones, quieter in highlights and deep shadows).
enum FilmPipeline {
    static let stock = FilmStock.printLook

    struct Settings: Equatable {
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

    private static let lock = NSLock()
    private static var negativeCubes: [FilmLUT.Source: Data] = [:]
    private static var printCubes: [FilmControls: Data] = [:]

    static func negativeCube(_ source: FilmLUT.Source) -> Data {
        lock.lock()
        if let cube = negativeCubes[source] { lock.unlock(); return cube }
        lock.unlock()
        let cube = FilmLUT.negativeCube(stock: stock, source: source).withUnsafeBufferPointer { Data(buffer: $0) }
        lock.lock()
        negativeCubes[source] = cube
        lock.unlock()
        return cube
    }

    /// Builds the default tables off the main thread, so the first frame drawn with the
    /// look doesn't wait ~50 ms for them.
    static func prewarm() {
        DispatchQueue.global(qos: .utility).async {
            _ = negativeCube(.displayReferred)
            _ = printCube(FilmControls())
            _ = negativeCube(.sceneLinear)
        }
    }

    static func printCube(_ controls: FilmControls) -> Data {
        lock.lock()
        if let cube = printCubes[controls] { lock.unlock(); return cube }
        lock.unlock()
        let cube = FilmLUT.printCube(stock: stock, controls: controls).withUnsafeBufferPointer { Data(buffer: $0) }
        lock.lock()
        if printCubes.count > 24 { printCubes.removeAll() }
        printCubes[controls] = cube
        lock.unlock()
        return cube
    }

    // MARK: Render

    /// `image` is linear light in the working space (extended linear sRGB): scene light from
    /// a RAW develop with no tone curve, or a display-referred image for `.displayReferred`.
    /// `unit` is the long side / 1000, so spatial effects scale with the picture.
    static func apply(_ image: CIImage, settings s: Settings, unit: CGFloat) -> CIImage {
        let bounds = image.extent
        var x = image
        let ev = s.exposure + stock.exposure
        if ev != 0 {
            x = x.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev])
        }
        if s.halation > 0 {
            x = addHalation(x, amount: s.halation, source: s.source, unit: unit)
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
                "inputCubeData": negativeCube(s.source),
            ])

        if s.grain > 0 {
            x = addGrain(to: x, amount: s.grain, unit: unit, animate: s.animateGrain)
        }

        x = x.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": FilmLUT.printDimension,
            "inputCubeData": printCube(s.controls),
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
    private static func addHalation(_ image: CIImage, amount: Double, source: FilmLUT.Source, unit: CGFloat) -> CIImage {
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

    // MARK: Grain

    /// Zero-mean noise in negative density (the cube stores density ÷ densityScale): a
    /// shared, monochrome part plus a little per-layer color, softened to the grain size.
    /// Amplitude is defined for a 4032 px long side; smaller renders average it down the
    /// way a downscaled photo would.
    private static func addGrain(to image: CIImage, amount: Double, unit: CGFloat, animate: Bool) -> CIImage {
        guard var noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }
        let bounds = image.extent
        if animate {
            noise = noise.transformed(by: CGAffineTransform(translationX: CGFloat(Int.random(in: 0..<1024)),
                                                            y: CGFloat(Int.random(in: 0..<1024))))
        }
        let sigmaPx = max(0.35, Double(unit) * stock.grainSize)
        // CIRandomGenerator is uniform 0…1 in each of R, G, B, A (std 1/√12). Each layer
        // mixes its own channel with the shared A channel; the blur then scales the std
        // by Σw² of the 1-D kernel (separable 2-D Gaussian).
        let c = stock.grainChroma
        let norm = ((1 - c) * (1 - c) + c * c).squareRoot()
        let resolution = min(1, Double(unit) / 4.032)
        let target = stock.grainDensity * amount * resolution / FilmLUT.densityScale
        let k = target / (norm * (1 / 12.0.squareRoot()) * gaussianStdFactor(sigma: sigmaPx))
        let a = CGFloat(k * (1 - c)), b = CGFloat(k * c)
        let bias = -(a + b) * 0.5
        let grain = noise
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: b, y: 0, z: 0, w: a),
                "inputGVector": CIVector(x: 0, y: b, z: 0, w: a),
                "inputBVector": CIVector(x: 0, y: 0, z: b, w: a),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
            ])
            .cropped(to: bounds.insetBy(dx: -8, dy: -8))
            .applyingGaussianBlur(sigma: sigmaPx)
            .cropped(to: bounds)
        return grain.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: image])
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
