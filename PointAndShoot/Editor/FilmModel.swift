import Foundation

// The "Print" look: a negative → print film emulation applied to scene-linear RAW data,
// in the spirit of a cinematographer's display-prep transform.
//
// This file is pure math (Foundation only) so it can be unit tested anywhere and kept in
// lockstep with scripts/filmmodel.py, the reference implementation the look is fitted
// with. The numbers live in scripts/print-stock.json and are generated into
// FilmStock+Print.swift. FilmPipeline.swift wires the math into Core Image.
//
// Signal path:
//   scene linear (Rec.2020) → layer exposure (film sensitivity matrix, incl. interlayer
//   saturation) → negative density (per-layer characteristic curves)    ← negative cube
//   → + grain (added in negative density, so the print curve shapes it)
//   → printing through the negative → print density (print curves, printer lights,
//   color crossover) → dye crosstalk → transmittance → display P3           ← print cube
// Halation is spatial, so FilmPipeline adds it to the scene-linear image before the
// negative cube.

/// Density as a function of log10 exposure: a monotone cubic through measured
/// (log exposure, density) points, flat beyond the ends. `gamma` scales the slope about
/// log exposure 0 (the exposure 18% grey gets), which is how contrast and color crossover
/// are applied.
struct FilmCurve: Hashable, Codable {
    let x: [Double]
    let y: [Double]
    private let m: [Double]
    var gamma: Double

    private enum CodingKeys: String, CodingKey { case x, y, gamma }

    /// Stored as its points (tangents are recomputed), so a photo can keep the exact
    /// curve it was rendered with (`FilmRecipe.tuning`).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(x: try c.decode([Double].self, forKey: .x),
                  y: try c.decode([Double].self, forKey: .y),
                  gamma: try c.decodeIfPresent(Double.self, forKey: .gamma) ?? 1)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        try c.encode(gamma, forKey: .gamma)
    }

    init(x: [Double], y: [Double], gamma: Double = 1) {
        precondition(x.count == y.count && x.count >= 2)
        self.x = x
        self.y = y
        self.gamma = gamma
        self.m = FilmCurve.tangents(x, y)
    }

    func density(_ logE: Double) -> Double {
        let n = x.count
        let u = min(max(logE * gamma, x[0]), x[n - 1])
        // Binary search for the segment [x[i], x[i+1]] holding u.
        var lo = 0, hi = n - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if x[mid] <= u { lo = mid } else { hi = mid }
        }
        let i = lo
        let h = x[i + 1] - x[i]
        let t = (u - x[i]) / h
        let t2 = t * t, t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * y[i] + (t3 - 2 * t2 + t) * h * m[i]
            + (-2 * t3 + 3 * t2) * y[i + 1] + (t3 - t2) * h * m[i + 1]
    }

    /// Fritsch–Carlson monotone cubic tangents (same algorithm as filmmodel.py).
    static func tangents(_ x: [Double], _ y: [Double]) -> [Double] {
        let n = x.count
        var d = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) { d[i] = (y[i + 1] - y[i]) / (x[i + 1] - x[i]) }
        var m = [Double](repeating: 0, count: n)
        m[0] = d[0]
        m[n - 1] = d[n - 2]
        if n > 2 { for i in 1..<(n - 1) { m[i] = (d[i - 1] + d[i]) / 2 } }
        for i in 0..<(n - 1) {
            if d[i] == 0 {
                m[i] = 0
                m[i + 1] = 0
                continue
            }
            let a = m[i] / d[i], b = m[i + 1] / d[i]
            let h = a * a + b * b
            if h > 9 {
                let t = 3 / h.squareRoot()
                m[i] = t * a * d[i]
                m[i + 1] = t * b * d[i]
            }
        }
        return m
    }
}

enum FilmMath {
    static func mul(_ m: [Double], _ v: (Double, Double, Double)) -> (Double, Double, Double) {
        (m[0] * v.0 + m[1] * v.1 + m[2] * v.2,
         m[3] * v.0 + m[4] * v.1 + m[5] * v.2,
         m[6] * v.0 + m[7] * v.1 + m[8] * v.2)
    }

    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// sRGB / Display P3 transfer function (encode).
    static func encodeSRGB(_ x: Double) -> Double {
        let v = min(1, max(0, x))
        return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    /// encodeSRGB(t²) sampled at t = 0…1: the sRGB curve is smooth in √ space, so linear
    /// interpolation in this table is accurate to < 1e-7.
    static let encodeTableSize = 4096
    static let encodeTable: [Double] = (0...encodeTableSize).map { i in
        let t = Double(i) / Double(encodeTableSize)
        return encodeSRGB(t * t)
    }

    static func matmul(_ a: [Double], _ b: [Double]) -> [Double] {
        var m = [Double](repeating: 0, count: 9)
        for i in 0..<3 { for j in 0..<3 { m[i * 3 + j] = a[i * 3] * b[j] + a[i * 3 + 1] * b[3 + j] + a[i * 3 + 2] * b[6 + j] } }
        return m
    }

    static func inverse3(_ m: [Double]) -> [Double] {
        let a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8]
        let A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g
        let det = a * A + b * B + c * C
        return [A / det, -(b * i - c * h) / det, (b * f - c * e) / det,
                B / det, (a * i - c * g) / det, -(a * f - c * d) / det,
                C / det, -(a * h - b * g) / det, (a * e - b * d) / det]
    }

    /// Linear Display P3 → linear Rec.2020, and back (both D65).
    static let p3ToRec2020: [Double] = [
        0.753833, 0.198597, 0.047570,
        0.045744, 0.941777, 0.012479,
        -0.001210, 0.017601, 0.983609,
    ]
    static let rec2020ToP3: [Double] = inverse3(p3ToRec2020)
    static let lumP3 = (0.2289746, 0.6917385, 0.0792869)

    /// Linear sRGB → linear Rec.2020 (both D65).
    static let sRGBToRec2020: [Double] = [
        0.627404, 0.329283, 0.043313,
        0.069097, 0.919540, 0.011362,
        0.016391, 0.088013, 0.895595,
    ]
}

/// One film system: a negative printed onto a print stock, plus its grain and halation.
/// Codable so each photo can store the exact tuning it was rendered with
/// (`FilmRecipe.tuning`): tuning a look in code later doesn't change older photos.
struct FilmStock: Hashable, Codable {
    /// The id recipes store (`FilmRecipe.stock`): "print", "warm400", …
    var id: String

    struct HalationSpread: Hashable, Codable {
        /// Scene-linear level above which clipped highlights get boosted (sensors clip
        /// where film doesn't), and the boost.
        var threshold: Double
        var boost: Double
        /// The same for already-rendered (display-referred) input.
        var displayThreshold: Double
        var displayBoost: Double
        /// Gaussian radii in thousandths of the picture's long side, and their weights.
        var sigmas: [Double]
        var weights: [Double]
    }

    /// Stops added to scene light before the film (where 18% grey lands).
    var exposure: Double
    /// Linear Rec.2020 scene light → exposure of the red, green, blue sensitive layers.
    /// Rows sum to 1 so neutrals stay neutral; negative off-diagonals model the interlayer
    /// effects that keep film colors rich.
    var sensitivity: [Double]
    /// Negative curves (R, G, B layers); log exposure relative to 18% grey.
    var negative: [FilmCurve]
    /// Print curves (R, G, B); log exposure relative to the exposure 18% grey prints with.
    var print: [FilmCurve]
    /// Printer lights: extra log exposure per channel (+ = denser = less of that color).
    var printer: [Double]
    /// Color crossover: relative print gamma per channel at crossover 0 (the look as
    /// designed). Red steeper / blue flatter = warm highlights, cool shadows.
    var crossover: [Double]
    /// Print dye crosstalk: density seen per channel = crosstalk · dye amounts.
    var crosstalk: [Double]
    /// Print transmittance relative to D-min → linear Display P3.
    var display: [Double]
    /// Halation: how much of the blurred light re-exposes each layer (R, G, B).
    var halation: [Double]
    var halationSpread: HalationSpread
    /// Grain: std dev in negative density per pixel at a 4032 px long side (strength 1),
    /// how independent the layers' grain is (0 = monochrome), and its blur radius in
    /// thousandths of the long side.
    var grainDensity: Double
    var grainChroma: Double
    var grainSize: Double
    /// 0…1: how much bright colors keep their scene hue instead of film's per-channel
    /// shoulder shift (which turns bright warm colors yellow). 0 = pure film (Print).
    var huePreserve: Double
    /// RGB gains after the mono mix for black-and-white filters (warm or cool toning).
    var monoTone: [Double]
    /// Split toning on the print's encoded output: offsets added with weight (1 − Y)² in
    /// the shadows and Y² in the highlights (Y = encoded luminance). Luminance-neutral,
    /// so the tone curve holds; a shadow tint also colors a lifted black. This is what
    /// gives a filter its own shadows: film blacks otherwise converge to the same neutral.
    var shadowTint: [Double] = [0, 0, 0]
    var highlightTint: [Double] = [0, 0, 0]

    /// One bend of the film's color rendering (`FilmLUT.twist`): the hues within `width`
    /// degrees of `hue` turn by `rotation` degrees, scale their chroma by 1 + `saturation`
    /// and get `stops` brighter (or darker). Hues: 0 red, 60 yellow, 120 green, 180 cyan,
    /// 240 blue, 300 magenta (skin ≈ 30, foliage ≈ 80, sky ≈ 225).
    /// Pinned tunings decode this with plain synthesized `Decodable` (TolerantJSON doesn't
    /// recurse into arrays), so never add a required field: new fields must be optional, or
    /// every photo pinned before them loses its whole edit. `filmlooks.py` refuses twists
    /// that fold or squeeze the hue order (slope < 0.2).
    struct HueTwist: Hashable, Codable {
        var hue: Double
        var width: Double
        var rotation: Double
        var saturation: Double
        var stops: Double
    }
    /// The film's own color by hue, applied to scene light in log space (the same at every
    /// brightness; neutrals untouched): cyan-leaning greens, golden skin, deep blue skies.
    /// What separates film stocks by structure rather than by tint. nil = none.
    /// Optional, and never filled in from the current stock (`offWhenMissing`): a tuning
    /// pinned before the field existed must render exactly as it did.
    var hueTwists: [HueTwist]? = nil
    /// Saturation the print's dyes add in density space (k = 1 + this, times the user's
    /// Saturation): > 0 dense slide-film color whose saturated hues get darker, < 0 a bleach
    /// bypass's silver draining color. nil = 0.
    var dyeSaturation: Double? = nil

    /// Fields a pinned tuning may lack that mean "off" when absent: `EditRecipe.decodeSaved`
    /// never fills these from the current stock, so older photos keep their look.
    static let offWhenMissing = ["hueTwists", "dyeSaturation"]

    var hasSplitTone: Bool { shadowTint.contains { $0 != 0 } || highlightTint.contains { $0 != 0 } }

    /// Density 18% grey produces on the negative, per layer.
    var greyNegativeDensity: (Double, Double, Double) {
        (negative[0].density(0), negative[1].density(0), negative[2].density(0))
    }
}

/// The user's adjustments that live inside the print transform. All are -1…1; 0 = the
/// look as designed.
struct FilmControls: Hashable {
    var contrast: Double = 0
    var saturation: Double = 0
    /// −1 removes the look's color crossover, +1 doubles it.
    var crossover: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    /// Film engine 3+: more Saturation works like the dyes (about each color's least dense
    /// channel, so richer is darker). Engines 1 and 2 spread about the mean, which
    /// brightens saturated colors; photos pinned with them keep that (`FilmRecipe.engine`).
    var subtractiveSaturation = false
    /// Film engine 4+: Highlights and Shadows go further (the owner: "do more, go further").
    /// Engines 1–3 keep their range (`FilmRecipe.engine`).
    var strongTone = false

    /// The user's saturation goes about each color's least dense channel.
    var saturatesSubtractively: Bool { subtractiveSaturation && saturation > 0 }

    /// How far Highlights and Shadows move print density at ±1. Engine 4 roughly doubles
    /// both (0.42 D ≈ 1.4 stops in the highlights, 0.75 D ≈ 2.5 stops in the shadows), as
    /// far as the tone curve stays monotonic: with both sliders at opposite extremes its
    /// slope stays above ~0.2, so nothing folds back into halos or banding.
    var highlightGain: Double { strongTone ? 0.42 : 0.22 }
    var shadowGain: Double { strongTone ? 0.75 : 0.45 }

    /// Film engine 5+: Highlights and Shadows re-expose the scene in broad regions before
    /// printing, the way Chromagraph's do (measured on the owner's screenshots, 2026-11-19:
    /// its Highlights +1 lifts everything but the deepest shadows ~3 stops; Shadows −1
    /// crushes ~1.7, +1 lifts ~0.5–1), and Contrast goes to ×2 and turns about `pivot`.
    /// An exposure shift that depends smoothly on the scene level keeps the film's own
    /// curve, colours and grain, and can't fold: `exposureShift` changes slower than the
    /// scene (slope ≥ ~0.25 at the worst combination). Engines 1–4 keep theirs.
    var toneRegions = false
    /// Engine 5+: where Contrast turns, in stops from 18% grey (0 = grey, as before).
    var pivot: Double = 0

    // The Film tool (all 0 = off, so they need no engine: older photos never had them).
    /// Printer lights, in log exposure added to each print layer (a lab's printer points:
    /// 1 point = 0.025). More exposure on a layer = more of its dye = less of that colour.
    var printerR: Double = 0
    var printerG: Double = 0
    var printerB: Double = 0
    /// Push (+) / pull (−) processing in stops, −2…2: development scales the negative's
    /// contrast about grey (×2^(0.2·push)), so grey stays put while blacks and highlights
    /// spread (or close up). Grain, added to the negative, scales with it. (Fog was tried:
    /// on the print's steep curve it brightened everything.)
    var push: Double = 0
    /// Flashing: a uniform pre-exposure of the negative, as a fraction of 18% grey's
    /// exposure (0…0.08): lifts and softens the toe, the cinematographer's trick.
    var flash: Double = 0
    /// Silver retention (bleach bypass), 0…1: dyes pulled toward their mean (less colour)
    /// and silver adding density in proportion to it (denser shadows, more contrast).
    var silver: Double = 0

    /// Printer lights from the sliders (−1…1): warm (less cyan, more yellow dye) and
    /// magenta (more magenta dye), up to 2 printer points (the print's steep curve makes
    /// that ~⅓ stop of colour at grey).
    static func printerLights(warm: Double, magenta: Double) -> (Double, Double, Double) {
        (-0.05 * warm, 0.05 * magenta, 0.05 * warm)
    }

    /// The negative's development: push/pull scales its contrast about grey (per layer).
    func develop(_ dn: Double, grey: Double) -> Double {
        guard push != 0 else { return dn }
        return grey + (dn - grey) * pow(2, 0.2 * push)
    }

    /// Flashing adds a uniform exposure to the negative (log exposure in, log exposure out).
    func flashed(_ logE: Double) -> Double {
        flash > 0 ? log10(pow(10, logE) + flash) : logE
    }

    /// The print-gamma multiplier for Contrast: ±1 → ×0.71…1.41 before engine 5; from
    /// engine 5 ×0.59…2 (Chromagraph's S-curve contrast goes to about ×2).
    var contrastGamma: Double {
        guard toneRegions else { return pow(2, contrast * 0.5) }
        return pow(2, contrast * (contrast > 0 ? 1 : 0.75))
    }

    // Engine 5's regions, in stops from 18% grey (logistic masks, width in stops).
    static let highlightStops = 3.0, highlightCenter = -3.0, highlightWidth = 1.0
    static let shadowLiftStops = 1.0, shadowCrushStops = 2.2, shadowCenter = 0.75, shadowWidth = 1.0

    /// Engine 5 re-exposes the scene before printing.
    var shiftsExposure: Bool { toneRegions && (highlights != 0 || shadows != 0 || (pivot != 0 && contrast != 0)) }

    /// Engine 5: stops added to a scene level `x` (stops from grey) before printing.
    /// - Contrast about `pivot`: the print gamma turns about grey, so a constant shift of
    ///   pivot·(1/K − 1) first makes the pivot the point that stays put.
    /// - Highlights: ±3 stops above ~−3 stops (half at −3, full by −1).
    /// - Shadows: +1 / −2.2 stops below ~+0.75 stops (full by −1, gone by +3).
    func exposureShift(_ x: Double) -> Double {
        var d = pivot * (1 / contrastGamma - 1)
        if highlights != 0 {
            d += highlights * Self.highlightStops / (1 + exp(-(x - Self.highlightCenter) / Self.highlightWidth))
        }
        if shadows != 0 {
            let amount = shadows > 0 ? Self.shadowLiftStops : Self.shadowCrushStops
            d += shadows * amount / (1 + exp((x - Self.shadowCenter) / Self.shadowWidth))
        }
        return d
    }

    /// Contrast's Pivot slider (0…100, encoded display brightness like Chromagraph's 0…1;
    /// 35 ≈ where 18% grey prints) → stops from grey: ~1.44 display stops per scene stop
    /// (the looks' mid-tone slope), clamped to −3.5…+3 (0 → −3.5, 100 → +2.3).
    static let defaultPivot: Double = 35
    static func pivotStops(_ slider: Double) -> Double {
        func decode(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let v = min(max(slider / 100, 0), 1)
        guard v > 0 else { return -3.5 }
        return min(max(log2(decode(v) / decode(defaultPivot / 100)) / 1.44, -3.5), 3)
    }

    /// The same controls with the engine flag cleared where it changes nothing (Saturation
    /// ≤ 0), so table caches see one key: engine-2 and engine-3 edits share tables, and
    /// prewarmed tables (built with default controls) serve every engine-3 look.
    var canonical: FilmControls {
        var c = self
        if !c.saturatesSubtractively { c.subtractiveSaturation = false }
        if c.highlights == 0 && c.shadows == 0 { c.strongTone = false }
        if c.toneRegions { c.strongTone = false }              // engine 5 replaces engine 4's shift
        if c.contrast == 0 { c.pivot = 0 }                     // a pivot turns nothing at contrast 0
        if c.highlights == 0 && c.shadows == 0 && c.contrast == 0 { c.toneRegions = false }
        return c
    }
}

/// Builds the two lookup tables the Core Image pipeline uses.
enum FilmLUT {
    /// Negative cube input: linear Rec.2020 divided by `shaperScale`, clamped to 0…1, then
    /// raised to 1/`shaperPower` (log-like spacing: ~2.5 cube steps per stop around grey).
    /// 16 = 6.5 stops of headroom over 18% grey.
    static let shaperScale = 16.0
    /// The film math's version (`FilmRecipe.engine` pins it per photo).
    /// 2: display-referred input is un-rendered with Apple's measured curve and saturation,
    ///    and exposed after.
    /// 3: the Saturation slider adds saturation subtractively, like the dyes (richer is
    ///    darker); the un-render is engine 2's.
    /// 4: Highlights and Shadows go about twice as far (`FilmControls.strongTone`).
    /// 5: Highlights and Shadows re-expose broad scene regions before printing, Contrast
    ///    goes to ×2 and turns about a pivot (`FilmControls.toneRegions`).
    /// 6: grain sized to the frame and as strong at every size, like Chromagraph's
    ///    (`FilmPipeline.addGrain`); the tables are engine 5's.
    /// Hue twists and dye saturation need no engine: they're stock fields, off when absent.
    static let currentEngine = 6

    /// The un-render a given engine uses (1 or 2): engines 2 and up share engine 2's, so
    /// their display-referred tables are the same and share a cache entry.
    static func unrenderEngine(_ engine: Int) -> Int { engine >= 2 ? 2 : 1 }
    static let shaperPower = 4.0
    /// Negative density is stored divided by this, so it fits the print cube's 0…1 input.
    static let densityScale = 4.0
    static let negativeDimension = 48
    static let printDimension = 48

    enum Source: Hashable {
        /// Scene-linear light, e.g. a RAW develop with no tone curve. 18% grey = 0.18.
        case sceneLinear
        /// An already-rendered display image (camera video, a processed HEIF). The cube
        /// undoes a generic camera tone curve first (on luminance, keeping each color's
        /// channel ratios) so highlights aren't compressed twice.
        case displayReferred
    }

    /// Engine 1's inverse of a generic phone rendering, display = 1.273·s / (1 + 0.808·s),
    /// which puts 18% grey at 0.20 and +3.5 stops at white. A guess; engine 2 measures it.
    static func sceneFromDisplay(_ x: Double) -> Double {
        let v = min(max(x, 0), 0.995)
        return v / (1.273 - 0.808 * v)
    }

    /// Engine 2: the inverse of Apple's rendering, measured on 13 iPhone 12 Pro ProRAWs
    /// (CIRAWFilter's default render against a neutral develop of the same file; see
    /// docs/film-looks.md §5¾). Display luminance → scene luminance, linear between knots in
    /// log2–log2, anchored like engine 1 (display 0.20 = scene 0.18): the median scene light
    /// behind each display level, which is what makes the viewfinder match the saved photo.
    /// Apple crushes shadows far more than engine 1 assumed; near white flattens at +3.5
    /// stops, where the RAW develop clips too.
    static let unrenderDisplayY: [Double] = [
        0.0025, 0.004, 0.006, 0.01, 0.016, 0.025, 0.04, 0.06, 0.09, 0.13, 0.2,
        0.28, 0.38, 0.48, 0.58, 0.66, 0.74, 0.81, 0.87, 0.92, 0.96, 0.995,
    ]
    static let unrenderSceneY: [Double] = [
        0.014848, 0.01808, 0.021215, 0.026133, 0.032434, 0.040882, 0.053768, 0.069891, 0.092267, 0.119648, 0.18,
        0.285852, 0.411258, 0.525263, 0.67323, 0.862166, 1.16483, 1.51356, 1.79013, 1.93731, 1.96963, 1.96964,
    ]
    /// Apple's saturation boost by display luminance (chroma relative to luminance, display
    /// over scene): it follows the curve's slope, ×3.4 in the toe to ×1.1 in the shoulder.
    static let unrenderSatY: [Double] = [0.003, 0.01, 0.03, 0.08, 0.18, 0.35, 0.6, 0.85, 1.0]
    static let unrenderSatBoost: [Double] = [3.357, 2.688, 1.944, 1.58, 1.397, 1.212, 1.124, 1.12, 1.0]
    private static let unrenderLogDisplay = unrenderDisplayY.map { log2($0) }
    private static let unrenderLogScene = unrenderSceneY.map { log2($0) }
    private static let unrenderLogSatY = unrenderSatY.map { log2($0) }

    /// Piecewise-linear interpolation, clamped at the ends (= numpy.interp).
    static func interp(_ x: Double, _ xs: [Double], _ ys: [Double]) -> Double {
        if x <= xs[0] { return ys[0] }
        if x >= xs[xs.count - 1] { return ys[ys.count - 1] }
        var i = 1
        while xs[i] < x { i += 1 }
        return ys[i - 1] + (ys[i] - ys[i - 1]) * (x - xs[i - 1]) / (xs[i] - xs[i - 1])
    }

    /// For a display-referred color (linear Rec.2020) → scene light (linear Rec.2020).
    /// Both engines undo the tone curve on luminance, which keeps hues: inverting per
    /// channel would read a saturated display red as a red channel stops overexposed.
    /// Engine 1 kept the display's channel ratios (so Apple's saturation stacked under the
    /// film's own); engine 2 uses the measured curve and divides out Apple's saturation.
    static func sceneFromDisplay(rgb: (Double, Double, Double), engine: Int = currentEngine)
        -> (Double, Double, Double) {
        let r = min(max(rgb.0, 0), 1), g = min(max(rgb.1, 0), 1), b = min(max(rgb.2, 0), 1)
        let y = 0.2627 * r + 0.6780 * g + 0.0593 * b
        if engine < 2 {
            let k = sceneFromDisplay(y) / max(y, 1e-6)
            return (r * k, g * k, b * k)
        }
        let yc = max(y, 1e-6), ly = log2(yc)
        let s = ly < unrenderLogDisplay[0]
            ? unrenderSceneY[0] * yc / unrenderDisplayY[0]          // toe: proportional to display
            : exp2(interp(ly, unrenderLogDisplay, unrenderLogScene))
        let k = interp(ly, unrenderLogSatY, unrenderSatBoost)
        func chan(_ v: Double) -> Double { max(1 + (v / yc - 1) / k, 0) * s }
        return (chan(r), chan(g), chan(b))
    }

    static func unshaped(_ u: Double) -> Double {
        shaperScale * pow(u, shaperPower)
    }

    /// Density → log exposure for a monotone negative curve: linear interpolation in a
    /// dense table (= filmmodel.neg_log_exposure).
    struct InverseCurve {
        static let samples = 1024
        let xs: [Double]
        let ds: [Double]

        init(_ curve: FilmCurve) {
            var probe = curve
            probe.gamma = 1
            let x0 = curve.x[0], x1 = curve.x[curve.x.count - 1]
            let n = Self.samples
            xs = (0...n).map { x0 + (x1 - x0) * Double($0) / Double(n) }
            ds = xs.map { probe.density($0) }
        }

        func logExposure(_ d: Double) -> Double {
            let n = ds.count
            if d <= ds[0] { return xs[0] }
            if d >= ds[n - 1] { return xs[n - 1] }
            var lo = 0, hi = n - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if ds[mid] <= d { lo = mid } else { hi = mid }
            }
            return xs[lo] + (xs[lo + 1] - xs[lo]) * (d - ds[lo]) / (ds[lo + 1] - ds[lo])
        }
    }

    /// Layer exposure → scene color in linear P3 (the sensitivity matrix's saturation
    /// undone), for highlight hue protection.
    static func hueMatrix(_ s: FilmStock) -> [Double] {
        FilmMath.matmul(FilmMath.rec2020ToP3, FilmMath.inverse3(s.sensitivity))
    }

    static let neutralMax = 100.0
    static let neutralRoot = pow(neutralMax, 0.25)
    static let neutralSamples = 1024

    /// How the stock renders a neutral at each exposure (rel. 18% grey), its color cast
    /// included: 3 × (neutralSamples + 1) linear P3 values, sampled evenly in
    /// exposure^(1/4) so a lookup is two square roots. Hue protection keeps this cast, so a
    /// warm or cool filter stays warm or cool in its highlights.
    static func neutralTable(stock s: FilmStock, controls c: FilmControls) -> [Double] {
        let curves = printCurves(stock: s, controls: c)
        let grey = s.greyNegativeDensity
        let pg = printGrey(stock: s, controls: c)
        let n = neutralSamples
        var table = [Double](repeating: 0, count: 3 * (n + 1))
        for k in 0...n {
            let r = neutralRoot * Double(k) / Double(n)
            let u = c.flashed(max(log10(max(r * r * r * r, 1e-12)), -6.0))
            let dp = (printDensity(c.develop(s.negative[0].density(u), grey: grey.0), channel: 0, stock: s, curves: curves, grey: pg),
                      printDensity(c.develop(s.negative[1].density(u), grey: grey.1), channel: 1, stock: s, curves: curves, grey: pg),
                      printDensity(c.develop(s.negative[2].density(u), grey: grey.2), channel: 2, stock: s, curves: curves, grey: pg))
            let out = display(print: dp, stock: s, curves: curves, controls: c)
            table[3 * k] = out.0; table[3 * k + 1] = out.1; table[3 * k + 2] = out.2
        }
        return table
    }

    /// Blends a bright color toward the scene's own hue, carried by the stock's neutral
    /// cast at that brightness and scaled to the same luminance; more as it gets brighter
    /// (film's per-channel shoulder would otherwise turn bright warm colors yellow).
    static func protectHue(_ out: (Double, Double, Double), scene: (Double, Double, Double),
                           neutral table: [Double], amount: Double) -> (Double, Double, Double) {
        let l = FilmMath.lumP3
        let yo = l.0 * out.0 + l.1 * out.1 + l.2 * out.2
        if yo <= 0.2 { return out }          // the blend weight is 0 below this
        let e = (max(scene.0, 0), max(scene.1, 0), max(scene.2, 0))
        let ye = l.0 * e.0 + l.1 * e.1 + l.2 * e.2
        // Neutral cast at this exposure (table lookup in exposure^(1/4)).
        let n = neutralSamples
        let t = min(ye, neutralMax).squareRoot().squareRoot() / neutralRoot * Double(n)
        let i = min(Int(t), n - 1), f = t - Double(i)
        let c0 = table[3 * i] + (table[3 * i + 3] - table[3 * i]) * f
        let c1 = table[3 * i + 1] + (table[3 * i + 4] - table[3 * i + 1]) * f
        let c2 = table[3 * i + 2] + (table[3 * i + 5] - table[3 * i + 2]) * f
        let inv = 1 / max(ye, 1e-9)
        var tgt = (e.0 * inv * c0, e.1 * inv * c1, e.2 * inv * c2)
        let yt = l.0 * tgt.0 + l.1 * tgt.1 + l.2 * tgt.2
        let k = yo / max(yt, 1e-9)
        tgt = (tgt.0 * k, tgt.1 * k, tgt.2 * k)
        let w = amount * FilmMath.smoothstep(0.2, 0.85, yo)
        return (out.0 + (tgt.0 - out.0) * w, out.1 + (tgt.1 - out.1) * w, out.2 + (tgt.2 - out.2) * w)
    }

    static let twistChroma = 0.25     // log10 chroma at which a hue's brightness shift is 63% in
    static let twistOffset = 0.01     // log(x + offset): dark colors fade to neutral instead of exploding

    /// The stock's color rendering by hue (`FilmStock.hueTwists`) on scene light (linear
    /// Rec.2020), before the film sees it (filmmodel.hue_twist). In log exposure, so it's
    /// the same at every brightness: hue and chroma in the plane perpendicular to the
    /// neutral axis, each twist weighted by a raised cosine of its distance in hue. Only
    /// built into the negative cube, so it costs nothing per frame.
    static func twist(_ rgb: (Double, Double, Double), _ twists: [FilmStock.HueTwist]) -> (Double, Double, Double) {
        let l0 = log10(max(rgb.0, 0) + twistOffset)
        let l1 = log10(max(rgb.1, 0) + twistOffset)
        let l2 = log10(max(rgb.2, 0) + twistOffset)
        let m = (l0 + l1 + l2) / 3
        let u = l0 - 0.5 * (l1 + l2)
        let v = (3.0.squareRoot() / 2) * (l1 - l2)
        let c = (u * u + v * v).squareRoot()
        let h = atan2(v, u) * 180 / .pi
        var rot = 0.0, sat = 0.0, lum = 0.0
        for t in twists {
            var x = (h - t.hue + 180).truncatingRemainder(dividingBy: 360)
            if x < 0 { x += 360 }
            let d = abs(x - 180)
            guard d < t.width else { continue }
            let w = 0.5 + 0.5 * cos(.pi * d / t.width)
            rot += w * t.rotation
            sat += w * t.saturation
            lum += w * t.stops
        }
        let c2 = c * max(1 + sat, 0)
        let a = (h + rot) * .pi / 180
        let u2 = c2 * cos(a), v2 = c2 * sin(a)
        let m2 = m + lum * log10(2.0) * (1 - exp(-c / twistChroma))
        let r3 = 3.0.squareRoot()
        return (max(pow(10, m2 + 2 / 3 * u2) - twistOffset, 0),
                max(pow(10, m2 - u2 / 3 + v2 / r3) - twistOffset, 0),
                max(pow(10, m2 - u2 / 3 - v2 / r3) - twistOffset, 0))
    }

    /// Scene light (Rec.2020 linear) → negative density per layer.
    static func negativeDensity(_ rgb: (Double, Double, Double), stock s: FilmStock) -> (Double, Double, Double) {
        let twists = s.hueTwists ?? []
        let e = FilmMath.mul(s.sensitivity, twists.isEmpty ? rgb : twist(rgb, twists))
        let k = 1 / 0.18
        return (s.negative[0].density(log10(max(e.0, 1e-6) * k)),
                s.negative[1].density(log10(max(e.1, 1e-6) * k)),
                s.negative[2].density(log10(max(e.2, 1e-6) * k)))
    }

    /// RGBA float cube, red fastest (CIColorCube's layout). Input: shaped Rec.2020.
    /// Output: negative density / densityScale. For display-referred input, `engine` picks
    /// the un-render, and from engine 2 `exposure` (stops) is applied after it, in scene
    /// light: exposing display values first clipped them at white and moved mid-tones by
    /// the wrong amount. (Scene-linear input takes its exposure before the cube.)
    static func negativeCube(stock: FilmStock, source: Source, engine: Int = currentEngine,
                             exposure: Double = 0) -> [Float] {
        let gain = exp2(exposure)
        let n = negativeDimension
        let step = 1 / Double(n - 1)
        var lin = [Double](repeating: 0, count: n)
        for i in 0..<n { lin[i] = unshaped(Double(i) * step) }
        var cube = [Float](repeating: 1, count: n * n * n * 4)
        var o = 0
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    var rgb = (lin[r], lin[g], lin[b])
                    if source == .displayReferred {
                        rgb = sceneFromDisplay(rgb: rgb, engine: engine)
                        if engine >= 2 { rgb = (rgb.0 * gain, rgb.1 * gain, rgb.2 * gain) }
                    }
                    let d = negativeDensity(rgb, stock: stock)
                    cube[o] = Float(d.0 / densityScale)
                    cube[o + 1] = Float(d.1 / densityScale)
                    cube[o + 2] = Float(d.2 / densityScale)
                    o += 4
                }
            }
        }
        return cube
    }

    /// The print curves with the user's contrast and crossover applied.
    static func printCurves(stock s: FilmStock, controls c: FilmControls) -> [FilmCurve] {
        let contrast = c.contrastGamma
        let amount = 1 + c.crossover
        return (0..<3).map { i in
            var curve = s.print[i]
            curve.gamma *= contrast * (1 + s.crossover[i] * amount)
            return curve
        }
    }

    /// The grey negative density the print is timed for, moved by the printer lights
    /// (printing sees grey − negative density + printer offset).
    static func printGrey(stock s: FilmStock, controls c: FilmControls) -> (Double, Double, Double) {
        let g = s.greyNegativeDensity
        return (g.0 + c.printerR, g.1 + c.printerG, g.2 + c.printerB)
    }

    /// Print density per channel for a negative density (printing is per channel).
    static func printDensity(_ dn: Double, channel c: Int, stock s: FilmStock, curves: [FilmCurve],
                             grey: (Double, Double, Double)) -> Double {
        let g = c == 0 ? grey.0 : c == 1 ? grey.1 : grey.2
        return curves[c].density(g - dn + s.printer[c])
    }

    /// The stock's dye saturation (`FilmStock.dyeSaturation`, filmmodel.dye_saturate).
    /// Film color is subtractive: purity costs density, so the most saturated colors are
    /// the darkest. > 0 spreads a color's densities away from its least dense channel: the
    /// dominant color stays and the others get denser, richer *and darker* (spreading
    /// about the mean would brighten the dominant channel instead). < 0 is retained silver:
    /// silver adds density in proportion to the mean, which with the print re-timed for
    /// grey is a pull toward the mean density. A grey whose three densities are equal is
    /// untouched; a stock's printer lights or crossover give greys a cast, which this scales
    /// by 1 + amount (and positive amounts add a little density: Slide's grey −0.08 stop).
    static func dyeSaturate(_ d: (Double, Double, Double), _ amount: Double) -> (Double, Double, Double) {
        guard amount != 0 else { return d }
        let pivot = amount > 0 ? min(d.0, d.1, d.2) : (d.0 + d.1 + d.2) / 3
        let k = 1 + amount
        return (pivot + (d.0 - pivot) * k, pivot + (d.1 - pivot) * k, pivot + (d.2 - pivot) * k)
    }

    /// Silver retention (bleach bypass): the dyes pull toward their mean, and the silver
    /// left in adds density in proportion to the print's neutral density.
    static func retainSilver(_ d: (Double, Double, Double), neutral: Double, _ amount: Double) -> (Double, Double, Double) {
        guard amount > 0 else { return d }
        let m = dyeSaturate(d, -0.35 * amount)
        let add = 0.1 * amount * neutral
        return (m.0 + add, m.1 + add, m.2 + add)
    }

    /// Print density → linear Display P3 (dye crosstalk, saturation, highlights/shadows).
    static func display(print dp: (Double, Double, Double), stock s: FilmStock, curves: [FilmCurve],
                        controls c: FilmControls) -> (Double, Double, Double) {
        var dm = FilmMath.mul(s.crosstalk, dp)
        let base = FilmMath.mul(s.crosstalk, (curves[0].y[0], curves[1].y[0], curves[2].y[0]))

        // The tone sliders weigh by the neutral density before the stock's dye saturation
        // (linear in the print densities, so printCube can tabulate it).
        let neutral = (dm.0 + dm.1 + dm.2) / 3
        dm = dyeSaturate(dm, s.dyeSaturation ?? 0)
        dm = retainSilver(dm, neutral: neutral, c.silver)
        // Saturation in density space (the user's slider): from engine 3, more saturation
        // is subtractive like the dyes; less, or engines 1–2, goes about the mean.
        if c.saturatesSubtractively {
            dm = dyeSaturate(dm, 0.6 * c.saturation)
        } else if c.saturation != 0 {
            let mean = (dm.0 + dm.1 + dm.2) / 3
            let k = 1 + c.saturation * (c.saturation > 0 ? 0.6 : 1)
            dm = (mean + (dm.0 - mean) * k, mean + (dm.1 - mean) * k, mean + (dm.2 - mean) * k)
        }
        // Highlights / shadows: shift density in the bright or the dark part of the scale.
        // (Engine 5 re-exposes the negative instead: `display(negative:)`, `printCube`.)
        if !c.toneRegions && (c.highlights != 0 || c.shadows != 0) {
            let wh = exp(-pow((neutral - 0.25) / 0.45, 2))
            let ws = FilmMath.smoothstep(0.9, 2.4, neutral)
            let shift = -c.highlightGain * c.highlights * wh - c.shadowGain * c.shadows * ws
            dm = (dm.0 + shift, dm.1 + shift, dm.2 + shift)
        }
        let ln10 = log(10.0)
        let t = (exp(-(dm.0 - base.0) * ln10), exp(-(dm.1 - base.1) * ln10), exp(-(dm.2 - base.2) * ln10))
        return FilmMath.mul(s.display, t)
    }

    /// Negative density (per layer) → linear Display P3.
    static func display(negative dn: (Double, Double, Double), stock s: FilmStock,
                        controls c: FilmControls = FilmControls()) -> (Double, Double, Double) {
        let curves = printCurves(stock: s, controls: c)
        let grey = s.greyNegativeDensity
        let pg = printGrey(stock: s, controls: c)
        // Each layer's log exposure (needed for engine 5's re-exposure, flashing or hue
        // protection).
        var le = (0.0, 0.0, 0.0)
        var dn = dn
        if c.shiftsExposure || c.flash > 0 || s.huePreserve > 0 {
            let inv = s.negative.map { InverseCurve($0) }
            le = (inv[0].logExposure(dn.0), inv[1].logExposure(dn.1), inv[2].logExposure(dn.2))
        }
        if c.shiftsExposure {
            // Engine 5: re-expose the negative by a smooth function of the neutral scene level.
            let sh = c.exposureShift((le.0 + le.1 + le.2) / 3 / log10(2.0)) * log10(2.0)
            le = (le.0 + sh, le.1 + sh, le.2 + sh)
        }
        if c.shiftsExposure || c.flash > 0 {
            dn = (negativeDensity(c.flashed(le.0), channel: 0, stock: s), negativeDensity(c.flashed(le.1), channel: 1, stock: s),
                  negativeDensity(c.flashed(le.2), channel: 2, stock: s))
        }
        let dp = (printDensity(c.develop(dn.0, grey: grey.0), channel: 0, stock: s, curves: curves, grey: pg),
                  printDensity(c.develop(dn.1, grey: grey.1), channel: 1, stock: s, curves: curves, grey: pg),
                  printDensity(c.develop(dn.2, grey: grey.2), channel: 2, stock: s, curves: curves, grey: pg))
        let out = display(print: dp, stock: s, curves: curves, controls: c)
        guard s.huePreserve > 0 else { return out }
        let e = (pow(10, le.0), pow(10, le.1), pow(10, le.2))
        return protectHue(out, scene: FilmMath.mul(hueMatrix(s), e), neutral: neutralTable(stock: s, controls: c),
                          amount: s.huePreserve)
    }

    /// A negative layer's density at a log exposure, on the same scale `InverseCurve`
    /// inverts (gamma 1; the negatives' gammas are all 1, crossover lives in the print).
    static func negativeDensity(_ logE: Double, channel c: Int, stock s: FilmStock) -> Double {
        var probe = s.negative[c]
        probe.gamma = 1
        return probe.density(logE)
    }

    /// RGBA float cube, red fastest. Input: negative density / densityScale. Output:
    /// Display P3 encoded with the sRGB transfer curve (so interpolation happens in a
    /// perceptual space).
    ///
    /// Rebuilt whenever an editor slider that lives in the film changes, so it has to be
    /// fast (~1 ms, not ~10). It's the same math as `display(negative:)`, factored:
    /// printing is per channel, and the density each channel sees is *linear* in the
    /// three print densities (dye crosstalk, then saturation about the mean), so
    /// transmittance = 10^base · Π_j 10^(−a_ij·dp_j): a product of per-axis terms, no
    /// exp per cell. Highlights/shadows depend only on the mean density (also linear), so
    /// they're a 1-D table. The sRGB encode is a table in √ space (error < 1e-7).
    static func printCube(stock: FilmStock, controls c: FilmControls) -> [Float] {
        let n = printDimension
        let step = densityScale / Double(n - 1)
        let curves = printCurves(stock: stock, controls: c)
        let grey = stock.greyNegativeDensity
        let pg = printGrey(stock: stock, controls: c)
        let negGrey = [grey.0, grey.1, grey.2]
        let ln10 = log(10.0)

        // Print density along each axis (each layer flashed, developed and printed on its
        // own, so these stay per-axis).
        var dp = [Double](repeating: 0, count: 3 * n)
        for ch in 0..<3 {
            let inv = c.flash > 0 ? InverseCurve(stock.negative[ch]) : nil
            for i in 0..<n {
                var dn = Double(i) * step
                if let inv { dn = negativeDensity(c.flashed(inv.logExposure(dn)), channel: ch, stock: stock) }
                dp[ch * n + i] = printDensity(c.develop(dn, grey: negGrey[ch]), channel: ch, stock: stock, curves: curves, grey: pg)
            }
        }
        // Density mixing: crosstalk, then saturation about the mean (S = k·I + (1−k)/3·1).
        let x = stock.crosstalk
        var a = x
        if c.saturation != 0 && !c.saturatesSubtractively {
            let k = 1 + c.saturation * (c.saturation > 0 ? 0.6 : 1)
            let m = (1 - k) / 3
            for i in 0..<3 {
                for j in 0..<3 {
                    a[i * 3 + j] = k * x[i * 3 + j] + m * (x[j] + x[3 + j] + x[6 + j])
                }
            }
        }
        let base = FilmMath.mul(x, (curves[0].y[0], curves[1].y[0], curves[2].y[0]))
        // f[(i*3 + j)*n + k] = 10^(−a_ij · dp_j[k])
        var f = [Double](repeating: 0, count: 9 * n)
        for i in 0..<3 {
            for j in 0..<3 {
                for k in 0..<n { f[(i * 3 + j) * n + k] = exp(-a[i * 3 + j] * dp[j * n + k] * ln10) }
            }
        }
        let b = (exp(base.0 * ln10), exp(base.1 * ln10), exp(base.2 * ln10))
        // Mean density = Σ_j w_j·dp_j (saturation keeps the mean). Highlights/shadows scale
        // transmittance by a smooth function of it, tabulated over the range it spans.
        let tone = !c.toneRegions && (c.highlights != 0 || c.shadows != 0)
        var nw = [Double](repeating: 0, count: 3 * n)
        var toneTable = [Double](), toneLo = 0.0, toneScale = 0.0
        let toneSize = 2048
        if tone {
            var lo = 0.0, hi = 0.0
            for j in 0..<3 {
                let w = (x[j] + x[3 + j] + x[6 + j]) / 3
                for k in 0..<n { nw[j * n + k] = w * dp[j * n + k] }
                let col = nw[(j * n)..<(j * n + n)]
                lo += col.min() ?? 0
                hi += col.max() ?? 0
            }
            toneLo = lo
            toneScale = Double(toneSize) / max(hi - lo, 1e-9)
            toneTable = (0...toneSize).map { i in
                let neutral = lo + Double(i) / toneScale
                let wh = exp(-pow((neutral - 0.25) / 0.45, 2))
                let ws = FilmMath.smoothstep(0.9, 2.4, neutral)
                return exp((c.highlightGain * c.highlights * wh + c.shadowGain * c.shadows * ws) * ln10)
            }
        }
        // Engine 5 re-exposes the negative per cell by a smooth function of its neutral
        // scene level (`FilmControls.exposureShift`): each axis's log exposure (inverse
        // negative curve), a table of the shift over the levels the cube spans, and per
        // channel a fine table of print density against log exposure.
        let shifting = c.shiftsExposure
        let log2v = log10(2.0)
        var le = [Double](), shiftTable = [Double](), dpTable = [Double]()
        var xLo = 0.0, xScale = 0.0, lLo = 0.0, lScale = 0.0
        let shiftSize = 2048, dpSize = 8192
        if shifting {
            le = [Double](repeating: 0, count: 3 * n)
            for j in 0..<3 {
                let inv = InverseCurve(stock.negative[j])
                for k in 0..<n { le[j * n + k] = inv.logExposure(Double(k) * step) }
            }
            func colMin(_ j: Int) -> Double { le[(j * n)..<(j * n + n)].min() ?? 0 }
            func colMax(_ j: Int) -> Double { le[(j * n)..<(j * n + n)].max() ?? 0 }
            xLo = (colMin(0) + colMin(1) + colMin(2)) / 3 / log2v
            let xHi = (colMax(0) + colMax(1) + colMax(2)) / 3 / log2v
            xScale = Double(shiftSize) / max(xHi - xLo, 1e-9)
            shiftTable = (0...shiftSize).map { i in c.exposureShift(xLo + Double(i) / xScale) * log2v }
            let sMin = shiftTable.min() ?? 0, sMax = shiftTable.max() ?? 0
            lLo = min(colMin(0), colMin(1), colMin(2)) + sMin
            let lHi = max(colMax(0), colMax(1), colMax(2)) + sMax
            lScale = Double(dpSize) / max(lHi - lLo, 1e-9)
            dpTable = [Double](repeating: 0, count: 3 * (dpSize + 1))
            for j in 0..<3 {
                for i in 0...dpSize {
                    let dn = negativeDensity(c.flashed(lLo + Double(i) / lScale), channel: j, stock: stock)
                    dpTable[j * (dpSize + 1) + i] = printDensity(c.develop(dn, grey: negGrey[j]), channel: j,
                                                                 stock: stock, curves: curves, grey: pg)
                }
            }
        }
        @inline(__always) func lookup(_ t: [Double], _ offset: Int, _ size: Int, _ u: Double) -> Double {
            let u = min(max(u, 0), Double(size))
            let i = min(Int(u), size - 1)
            return t[offset + i] + (t[offset + i + 1] - t[offset + i]) * (u - Double(i))
        }

        let d = stock.display
        // Highlight hue protection needs the scene color: exposure per axis (inverse
        // negative curve), mixed per cell through the hue matrix.
        // The scene color is linear in the per-axis exposures, so precompute each axis's
        // contribution: sa[(j*3 + i)*n + k] = hueMatrix[i][j] · exposure_j[k].
        let hp = stock.huePreserve
        var sa = [Double](repeating: 0, count: 9 * n)
        let neutral = hp > 0 ? neutralTable(stock: stock, controls: c) : []
        if hp > 0 {
            let hm = hueMatrix(stock)
            for j in 0..<3 {
                let inv = InverseCurve(stock.negative[j])
                for k in 0..<n {
                    let e = pow(10, inv.logExposure(Double(k) * step))
                    for i in 0..<3 { sa[(j * 3 + i) * n + k] = hm[i * 3 + j] * e }
                }
            }
        }
        let lum = FilmMath.lumP3
        let nSamples = neutralSamples
        let rootScale = Double(nSamples) / neutralRoot
        let encode = FilmMath.encodeTable
        let last = Double(FilmMath.encodeTableSize)
        @inline(__always) func enc(_ v: Double) -> Double {
            let t = min(max(v, 0), 1).squareRoot() * last
            let i = min(Int(t), FilmMath.encodeTableSize - 1)
            let frac = t - Double(i)
            return encode[i] + (encode[i + 1] - encode[i]) * frac
        }
        let toned = stock.hasSplitTone
        // Dye saturation, and from engine 3 more user saturation, pivot on each color's own
        // least dense (or mean) channel, which isn't a product of per-axis terms: those
        // take a per-cell path (three exps a cell, still a few ms).
        let dye = stock.dyeSaturation ?? 0
        let perCell = dye != 0 || c.saturatesSubtractively || shifting || c.silver > 0
        let userK = 1 + c.saturation * (c.saturation > 0 ? 0.6 : 1)
        let x0 = x[0], x1 = x[1], x2 = x[2], x3 = x[3], x4 = x[4], x5 = x[5], x6 = x[6], x7 = x[7], x8 = x[8]
        let s0 = stock.shadowTint[0], s1 = stock.shadowTint[1], s2 = stock.shadowTint[2]
        let h0 = stock.highlightTint[0], h1 = stock.highlightTint[1], h2 = stock.highlightTint[2]

        var cube = [Float](repeating: 1, count: n * n * n * 4)
        cube.withUnsafeMutableBufferPointer { out in
            f.withUnsafeBufferPointer { f in
                var o = 0
                for bi in 0..<n {
                    for gi in 0..<n {
                        // Everything but the red axis, once per row.
                        let p0 = b.0 * f[1 * n + gi] * f[2 * n + bi]
                        let p1 = b.1 * f[4 * n + gi] * f[5 * n + bi]
                        let p2 = b.2 * f[7 * n + gi] * f[8 * n + bi]
                        let rowNeutral = tone ? nw[n + gi] + nw[2 * n + bi] : 0
                        // Green and blue axes' share of the scene color, once per row.
                        let rs0 = hp > 0 ? sa[3 * n + gi] + sa[6 * n + bi] : 0
                        let rs1 = hp > 0 ? sa[4 * n + gi] + sa[7 * n + bi] : 0
                        let rs2 = hp > 0 ? sa[5 * n + gi] + sa[8 * n + bi] : 0
                        for ri in 0..<n {
                            var t0: Double, t1: Double, t2: Double
                            var sceneGain = 1.0
                            if !perCell {
                                t0 = p0 * f[ri]; t1 = p1 * f[3 * n + ri]; t2 = p2 * f[6 * n + ri]
                            } else {
                                var q0 = dp[ri], q1 = dp[n + gi], q2 = dp[2 * n + bi]
                                if shifting {
                                    let l0 = le[ri], l1 = le[n + gi], l2 = le[2 * n + bi]
                                    let sh = lookup(shiftTable, 0, shiftSize, ((l0 + l1 + l2) / 3 / log2v - xLo) * xScale)
                                    q0 = lookup(dpTable, 0, dpSize, (l0 + sh - lLo) * lScale)
                                    q1 = lookup(dpTable, dpSize + 1, dpSize, (l1 + sh - lLo) * lScale)
                                    q2 = lookup(dpTable, 2 * (dpSize + 1), dpSize, (l2 + sh - lLo) * lScale)
                                    sceneGain = exp(sh * ln10)
                                }
                                let mixed = (x0 * q0 + x1 * q1 + x2 * q2, x3 * q0 + x4 * q1 + x5 * q2,
                                             x6 * q0 + x7 * q1 + x8 * q2)
                                var m = dyeSaturate(mixed, dye)
                                m = retainSilver(m, neutral: (mixed.0 + mixed.1 + mixed.2) / 3, c.silver)
                                if c.saturatesSubtractively {
                                    m = dyeSaturate(m, 0.6 * c.saturation)
                                } else if userK != 1 {
                                    let mean = (m.0 + m.1 + m.2) / 3
                                    m = (mean + (m.0 - mean) * userK, mean + (m.1 - mean) * userK, mean + (m.2 - mean) * userK)
                                }
                                t0 = exp(-(m.0 - base.0) * ln10)
                                t1 = exp(-(m.1 - base.1) * ln10)
                                t2 = exp(-(m.2 - base.2) * ln10)
                            }
                            if tone {
                                let u = min(max((rowNeutral + nw[ri] - toneLo) * toneScale, 0), Double(toneSize))
                                let i = min(Int(u), toneSize - 1)
                                let h = toneTable[i] + (toneTable[i + 1] - toneTable[i]) * (u - Double(i))
                                t0 *= h; t1 *= h; t2 *= h
                            }
                            var rgb = (d[0] * t0 + d[1] * t1 + d[2] * t2,
                                       d[3] * t0 + d[4] * t1 + d[5] * t2,
                                       d[6] * t0 + d[7] * t1 + d[8] * t2)
                            // Highlight hue protection (= protectHue, inlined for speed).
                            let yo = lum.0 * rgb.0 + lum.1 * rgb.1 + lum.2 * rgb.2
                            if hp > 0 && yo > 0.2 {
                                let e0 = max((rs0 + sa[ri]) * sceneGain, 0), e1 = max((rs1 + sa[n + ri]) * sceneGain, 0)
                                let e2 = max((rs2 + sa[2 * n + ri]) * sceneGain, 0)
                                let ye = lum.0 * e0 + lum.1 * e1 + lum.2 * e2
                                let t = min(ye, 100.0).squareRoot().squareRoot() * rootScale
                                let i = min(Int(t), nSamples - 1), fr = t - Double(i)
                                let c0 = neutral[3 * i] + (neutral[3 * i + 3] - neutral[3 * i]) * fr
                                let c1 = neutral[3 * i + 1] + (neutral[3 * i + 4] - neutral[3 * i + 1]) * fr
                                let c2 = neutral[3 * i + 2] + (neutral[3 * i + 5] - neutral[3 * i + 2]) * fr
                                let inv = 1 / max(ye, 1e-9)
                                let g0 = e0 * inv * c0, g1 = e1 * inv * c1, g2 = e2 * inv * c2
                                let k = yo / max(lum.0 * g0 + lum.1 * g1 + lum.2 * g2, 1e-9)
                                let x = min(max((yo - 0.2) / 0.65, 0), 1)
                                let w = hp * x * x * (3 - 2 * x)
                                rgb = (rgb.0 + (g0 * k - rgb.0) * w, rgb.1 + (g1 * k - rgb.1) * w, rgb.2 + (g2 * k - rgb.2) * w)
                            }
                            var e0 = enc(rgb.0), e1 = enc(rgb.1), e2 = enc(rgb.2)
                            if toned {      // split toning (filmmodel.split_tone)
                                let y = lum.0 * e0 + lum.1 * e1 + lum.2 * e2   // in 0…1: e is, and lum sums to 1
                                let ws = (1 - y) * (1 - y), wh = y * y
                                e0 = min(max(e0 + ws * s0 + wh * h0, 0), 1)
                                e1 = min(max(e1 + ws * s1 + wh * h1, 0), 1)
                                e2 = min(max(e2 + ws * s2 + wh * h2, 0), 1)
                            }
                            out[o] = Float(e0)
                            out[o + 1] = Float(e1)
                            out[o + 2] = Float(e2)
                            o += 4
                        }
                    }
                }
            }
        }
        return cube
    }

    /// Display value of a neutral scene patch `stops` from 18% grey (no grain or halation).
    static func neutralResponse(stops: Double, stock: FilmStock,
                                controls: FilmControls = FilmControls()) -> (Double, Double, Double) {
        let x = 0.18 * pow(2, stops)
        return display(negative: negativeDensity((x, x, x), stock: stock), stock: stock, controls: controls)
    }
}
