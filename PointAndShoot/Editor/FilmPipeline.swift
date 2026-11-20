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
        /// A photo's pinned tuning (`FilmRecipe.tuning`); overrides `stockID` when set.
        var tuning: FilmStock?
        var source: FilmLUT.Source = .sceneLinear
        /// The film math's version the photo was made with (`FilmRecipe.renderEngine`).
        var engine = FilmLUT.currentEngine
        /// Stops, applied to scene light before the film.
        var exposure: Double = 0
        /// 0…2, 1 = the look as designed.
        var halation: Double = 1
        /// 0…4, 1 = the look as designed.
        var grain: Double = 1
        /// Multiplies the look's grain size (0.25…3, 1 = as designed).
        var grainSize: Double = 1
        /// −1…1: monochrome grain … the look's … strongly coloured (Film tool).
        var grainColor: Double = 0
        /// Grain one pixel across at any size (Chromagraph's "Force Pixel Size Grain").
        var pixelGrain = false
        /// Multiplies the halation's spread (0.25…3) and moves its colour: −1 pure red,
        /// 0 the look's, +1 a warm white bloom (Film tool).
        var halationSize: Double = 1
        var halationColor: Double = 0
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

    /// Display-referred tables depend on the engine (the un-render) and, from engine 2, on
    /// the exposure (applied after the un-render, inside the table). Scene-linear tables
    /// depend on neither, so they key with engine 0 and exposure 0.
    private struct NegativeKey: Hashable {
        let stock: String; let source: FilmLUT.Source; let engine: Int; let exposure: Int
    }
    private struct PrintKey: Hashable { let stock: String; let controls: FilmControls }

    /// Cache identity: the id for a stock as it is in code, id + a hash of the values for a
    /// photo's pinned older tuning (so the two never share tables).
    static func cacheKey(_ stock: FilmStock) -> String {
        FilmStock.all[stock.id] == stock ? stock.id : "\(stock.id)#\(stock.hashValue)"
    }

    private static let lock = NSLock()
    /// A display-referred viewfinder table for every stock, the RAW looks' tables, plus
    /// room for an edit's exposures on a processed photo (each exposure is its own table)
    /// and a few editor slider positions. Sized from the stock count: the LOOK strip's
    /// "All" previews touch every stock every 2 s (on their own queue), so a smaller cache
    /// would evict the viewfinder's tables, which would then rebuild on the render queue
    /// and stall it. ~1.8 MB a table: ~45 MB each at 19 stocks.
    static let tableCapacity = FilmStock.all.count + 6
    private static let negativeCubes = TableCache<NegativeKey>(capacity: tableCapacity)
    private static let printCubes = TableCache<PrintKey>(capacity: tableCapacity)
    /// Tables with an edit's exposure baked in (processed photos, engine 2+): one per
    /// 1/100 stop, so dragging Exposure makes many. They get their own small cache, so a
    /// drag can never evict the viewfinder's and the LOOK strip's tables.
    private static let exposureCubes = TableCache<NegativeKey>(capacity: 4)

    static func negativeCube(_ stock: FilmStock, _ source: FilmLUT.Source, engine: Int = FilmLUT.currentEngine,
                             exposure: Double = 0) -> Data {
        let display = source == .displayReferred
        // Exposure in 1/100 stops: slider steps, and a table per distinct value.
        let ev = display && engine >= 2 ? Int((exposure * 100).rounded()) : 0
        let key = NegativeKey(stock: cacheKey(stock), source: source,
                              engine: display ? FilmLUT.unrenderEngine(engine) : 0, exposure: ev)
        let cache = ev == 0 ? negativeCubes : exposureCubes
        lock.lock()
        if let cube = cache.get(key) { lock.unlock(); return cube }
        lock.unlock()
        let cube = FilmLUT.negativeCube(stock: stock, source: source, engine: key.engine, exposure: Double(ev) / 100)
            .withUnsafeBufferPointer { Data(buffer: $0) }
        lock.lock()
        cache.set(key, cube)
        lock.unlock()
        return cube
    }

    static func printCube(_ stock: FilmStock, _ controls: FilmControls) -> Data {
        let controls = controls.canonical      // one key per distinct table
        let key = PrintKey(stock: cacheKey(stock), controls: controls)
        lock.lock()
        if let cube = printCubes.get(key) { lock.unlock(); return cube }
        lock.unlock()
        let cube = FilmLUT.printCube(stock: stock, controls: controls).withUnsafeBufferPointer { Data(buffer: $0) }
        lock.lock()
        printCubes.set(key, cube)
        lock.unlock()
        return cube
    }

    /// Builds every stock's viewfinder tables off the main thread (~0.5 s of CPU once for
    /// 19 stocks, ~35 ms each with hue twists),
    /// so neither the first frame with a filter nor the filter strip's live previews ever
    /// wait for them. The RAW tables too for the looks that shoot RAW (Print, Phromagraph).
    static func prewarm() {
        DispatchQueue.global(qos: .utility).async {
            let printStock = FilmStock.printLook
            _ = negativeCube(printStock, .displayReferred)
            _ = printCube(printStock, FilmControls())
            for stock in FilmStock.all.values where stock.id != printStock.id {
                _ = negativeCube(stock, .displayReferred)
                _ = printCube(stock, FilmControls())
            }
            for look in Look.all where look.capturesRAW {
                if let id = look.recipe.film?.stock { _ = negativeCube(FilmStock.named(id), .sceneLinear) }
            }
        }
    }

    /// Builds the viewfinder's tables for a look as the viewfinder will render it (its
    /// exposure baked in: `ViewfinderMatch`), so switching to it never builds on the render
    /// queue. Call off the main thread.
    static func prewarmViewfinder(_ recipe: EditRecipe) {
        guard let film = recipe.film, let stock = FilmStock.resolved(for: recipe) else { return }
        _ = negativeCube(stock, .displayReferred, engine: film.renderEngine, exposure: recipe.exposure / 50 + stock.exposure)
        _ = printCube(stock, recipe.filmControls)
    }

    // MARK: Render

    /// `image` is linear light in the working space (extended linear sRGB): scene light from
    /// a RAW develop with no tone curve, or a display-referred image for `.displayReferred`.
    /// `unit` is the long side / 1000, so spatial effects scale with the picture.
    static func apply(_ image: CIImage, settings s: Settings, unit: CGFloat) -> CIImage {
        let stock = s.tuning ?? FilmStock.named(s.stockID)
        let bounds = image.extent
        var x = image
        let ev = s.exposure + stock.exposure
        // Engine 2 exposes display-referred input after un-rendering it, inside the negative
        // table; exposing display values here would clip them at white.
        let exposeInTable = s.source == .displayReferred && s.engine >= 2
        if ev != 0 && !exposeInTable {
            x = x.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev])
        }
        if s.halation > 0 {
            x = addHalation(x, stock: stock, amount: s.halation, size: s.halationSize, color: s.halationColor,
                            source: s.source, unit: unit)
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
                "inputCubeData": negativeCube(stock, s.source, engine: s.engine, exposure: exposeInTable ? ev : 0),
            ])

        if s.grain > 0 && s.engine >= 7 {
            x = addMeasuredGrain(to: x, stock: stock, amount: s.grain, size: s.grainSize, color: s.grainColor,
                                 pixel: s.pixelGrain, unit: unit, animate: s.animateGrain)
        } else if s.grain > 0 {
            x = addGrain(to: x, stock: stock, amount: s.grain, size: s.grainSize, color: s.grainColor,
                         frame: s.engine >= 6, pixel: s.pixelGrain, unit: unit, animate: s.animateGrain)
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
    private static func addHalation(_ image: CIImage, stock: FilmStock, amount: Double, size: Double = 1,
                                    color: Double = 0, source: FilmLUT.Source, unit: CGFloat) -> CIImage {
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
                .applyingGaussianBlur(sigma: max(0.5, sigma * size * Double(unit / down)))
                .applyingFilter("CIColorMatrix", parameters: scale(CGFloat(weight), CGFloat(weight), CGFloat(weight)))
            glow = glow.map { blurred.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? blurred
        }
        guard let glow else { return image }

        let a = halationStrengths(stock.halation, amount: amount, color: color).map { CGFloat($0) }
        let keep = image.applyingFilter("CIColorMatrix", parameters: scale(1 / (1 + a[0]), 1 / (1 + a[1]), 1 / (1 + a[2]), alpha: 1))
        let halo = glow
            .transformed(by: CGAffineTransform(scaleX: down, y: down))
            .applyingFilter("CIColorMatrix", parameters: scale(a[0] / (1 + a[0]), a[1] / (1 + a[1]), a[2] / (1 + a[2])))
            .cropped(to: bounds)
        return halo.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: keep])
    }

    /// Per-channel halation strength: the look's, times the amount, with its colour moved
    /// toward pure red (−1: green and blue gone) or a warm white bloom (+1: green 60% and
    /// blue 30% of red), so the overall glow stays about as strong.
    static func halationStrengths(_ h: [Double], amount: Double, color c: Double) -> [Double] {
        var r = h[0], g = h[1], b = h[2]
        if c < 0 {
            g *= 1 + c; b *= 1 + c
        } else if c > 0 {
            g += c * (0.6 * r - g); b += c * (0.3 * r - b)
        }
        return [r * amount, g * amount, b * amount]
    }

    /// Grain colour: the share of independent per-layer grain, from the look's own
    /// (`color` 0) down to monochrome (−1) or up to 0.8 (+1).
    static func grainChroma(_ base: Double, color c: Double) -> Double {
        c < 0 ? base * (1 + c) : base + (0.8 - base) * c
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
    ///
    /// Film engine 6 (`frame`): like Chromagraph's, the grain's size is a share of the frame
    /// and its strength is the same at every size, so it reads the same on screen, in the
    /// viewer and in an export. The old way it was ~half a pixel at 4032 px and averaged
    /// down for previews: on screen it all but vanished (the owner: "they look totally
    /// different"). Measured on the owner's screenshots of Chromagraph at amplitude 1.25
    /// (2026-11-19): ~0.5‰ of the long side (σ), ~3.7/255 high-passed in the mid-tones.
    /// `frameGrainScale` and `frameGrainGain` map the stocks' numbers onto that, so
    /// Phromagraph at 50 (Chromagraph's 1.25) lands on it. `pixel`: one pixel at any size.
    ///
    /// Every intermediate image is opaque, so nothing depends on how a filter treats alpha.
    /// (CIRandomGenerator's alpha is random too; a filter that un-premultiplies would divide
    /// by it and turn the grain into heavy-tailed speckle.)
    static let frameGrainScale = 3.0
    static let frameGrainGain = 0.88

    private static func addGrain(to image: CIImage, stock: FilmStock, amount: Double, size: Double = 1,
                                 color: Double = 0, frame: Bool = false, pixel: Bool = false,
                                 unit: CGFloat, animate: Bool) -> CIImage {
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
        let sigmaPx = pixel ? 0.5
            : max(0.35, Double(unit) * stock.grainSize * size * (frame ? frameGrainScale : 1))
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
        let c = grainChroma(stock.grainChroma, color: color)
        let norm2 = (1 - c) * (1 - c) + c * c
        let alpha = (1 - c) * (1 - c) / norm2, beta = c * c / norm2
        let p = beta.squareRoot()
        let q = (-2 * p + (4 * p * p + 12 * alpha).squareRoot()) / 6
        // Engine 6 and pixel grain keep their strength at every size; before, smaller
        // renders averaged it down.
        let resolution = frame || pixel ? frameGrainGain : min(1, Double(unit) / 4.032)
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

    /// Each stock's per-layer grain weights (`FilmGrain.layerGains`), worked out once.
    private static var layerGainCache: [String: (Double, Double, Double)] = [:]

    static func layerGains(_ stock: FilmStock) -> (Double, Double, Double) {
        let key = cacheKey(stock)
        lock.lock()
        if let g = layerGainCache[key] { lock.unlock(); return g }
        lock.unlock()
        let g = FilmGrain.layerGains(stock: stock)
        lock.lock()
        if layerGainCache.count > 64 { layerGainCache.removeAll() }
        layerGainCache[key] = g
        lock.unlock()
        return g
    }

    /// Film engine 7: Chromagraph's grain, measured on its full-size exports (`FilmGrain`).
    /// Per-pixel white noise filtered by a Catmull-Rom kernel the size of the grain cell
    /// (two 9-tap passes, whose effect on the std is known exactly), so it's crisp and
    /// about a pixel across at 2880 px; the cell is a share of the frame, never under
    /// `FilmGrain.minimumCellPixels`, and the per-pixel strength is the same at every
    /// render size (on screen, in the viewer and in an export). It's added in negative
    /// density with each layer weighted so a grey's three channels move together (neutral
    /// grain), at `grainDensity` × `FilmGrain.outputGain` × amount × `strength(size:)` of
    /// encoded output on grey; the print curve then fades it toward black and white.
    /// `pixel`: one-pixel grain (no filter), at the amount's strength whatever the Size.
    ///
    /// Every intermediate image is opaque (see `addGrain`): the noise is made zero-mean
    /// before filtering, so the kernel's negative lobes never need values below 0 to be kept.
    private static func addMeasuredGrain(to image: CIImage, stock: FilmStock, amount: Double, size: Double,
                                         color: Double, pixel: Bool, unit: CGFloat, animate: Bool) -> CIImage {
        guard var noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }
        let bounds = image.extent
        if animate {
            noise = noise.transformed(by: CGAffineTransform(translationX: CGFloat(Int.random(in: 0..<1024)),
                                                            y: CGFloat(Int.random(in: 0..<1024))))
        }
        let padded = bounds.insetBy(dx: -CGFloat(FilmGrain.radius + 4), dy: -CGFloat(FilmGrain.radius + 4))
        // Uniform 0…1 in R, G, B (std 1/√12), alpha forced to 1 first (CIColorMatrix
        // un-premultiplies, and the generator's alpha is random), then zero mean.
        noise = noise.cropped(to: padded).settingAlphaOne(in: padded)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: -0.5, y: -0.5, z: -0.5, w: 1),
            ])
            .cropped(to: padded)

        let cell = pixel ? 0 : FilmGrain.cellPixels(size: size, unit: Double(unit))
        let w = FilmGrain.kernel(cell: cell)
        if !pixel {
            let taps = CIVector(values: w.map { CGFloat($0) }, count: w.count)
            noise = noise
                .applyingFilter("CIConvolution9Horizontal", parameters: ["inputWeights": taps, "inputBias": 0])
                .applyingFilter("CIConvolution9Vertical", parameters: ["inputWeights": taps, "inputBias": 0])
                .settingAlphaOne(in: padded)
        }
        let stdFactor = FilmGrain.stdFactor(w)

        // Shared (monochrome) and per-layer parts, as in `addGrain`, then each layer weighted
        // so the grain is neutral on grey.
        let c = grainChroma(stock.grainChroma, color: color)
        let norm2 = (1 - c) * (1 - c) + c * c
        let alpha = (1 - c) * (1 - c) / norm2, beta = c * c / norm2
        let p = beta.squareRoot()
        let q = (-2 * p + (4 * p * p + 12 * alpha).squareRoot()) / 6
        let target = stock.grainDensity * FilmGrain.outputGain * amount * (pixel ? 1 : FilmGrain.strength(size: size))
        let k = target / ((1 / 12.0.squareRoot()) * stdFactor) / FilmLUT.densityScale
        let g = layerGains(stock)
        func row(_ gain: Double, _ i: Int) -> CIVector {
            let d = CGFloat(gain * k * (p + q)), o = CGFloat(gain * k * q)
            return CIVector(x: i == 0 ? d : o, y: i == 1 ? d : o, z: i == 2 ? d : o, w: 0)
        }
        let grain = noise
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": row(g.0, 0),
                "inputGVector": row(g.1, 1),
                "inputBVector": row(g.2, 2),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ])
            .cropped(to: bounds)
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
