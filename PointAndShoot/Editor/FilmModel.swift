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
struct FilmCurve: Hashable {
    let x: [Double]
    let y: [Double]
    private let m: [Double]
    var gamma: Double

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

    /// Linear sRGB → linear Rec.2020 (both D65).
    static let sRGBToRec2020: [Double] = [
        0.627404, 0.329283, 0.043313,
        0.069097, 0.919540, 0.011362,
        0.016391, 0.088013, 0.895595,
    ]
}

/// One film system: a negative printed onto a print stock, plus its grain and halation.
struct FilmStock: Hashable {
    struct HalationSpread: Hashable {
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
}

/// Builds the two lookup tables the Core Image pipeline uses.
enum FilmLUT {
    /// Negative cube input: linear Rec.2020 divided by `shaperScale`, clamped to 0…1, then
    /// raised to 1/`shaperPower` (log-like spacing: ~2.5 cube steps per stop around grey).
    /// 16 = 6.5 stops of headroom over 18% grey.
    static let shaperScale = 16.0
    static let shaperPower = 4.0
    /// Negative density is stored divided by this, so it fits the print cube's 0…1 input.
    static let densityScale = 4.0
    static let negativeDimension = 48
    static let printDimension = 48

    enum Source: Hashable {
        /// Scene-linear light, e.g. a RAW develop with no tone curve. 18% grey = 0.18.
        case sceneLinear
        /// An already-rendered display image (camera video, a processed HEIF). The cube
        /// undoes a generic camera tone curve first so highlights aren't compressed twice.
        case displayReferred
    }

    /// Inverse of a generic phone rendering, display = 1.333·s / (1 + 1.11·s), which puts
    /// 18% grey at 0.20 and +4.5 stops at white.
    static func sceneFromDisplay(_ x: Double) -> Double {
        let v = min(max(x, 0), 0.995)
        return v / (1.333 - 1.11 * v)
    }

    static func unshaped(_ u: Double) -> Double {
        shaperScale * pow(u, shaperPower)
    }

    /// Scene light (Rec.2020 linear) → negative density per layer.
    static func negativeDensity(_ rgb: (Double, Double, Double), stock s: FilmStock) -> (Double, Double, Double) {
        let e = FilmMath.mul(s.sensitivity, rgb)
        let k = 1 / 0.18
        return (s.negative[0].density(log10(max(e.0, 1e-6) * k)),
                s.negative[1].density(log10(max(e.1, 1e-6) * k)),
                s.negative[2].density(log10(max(e.2, 1e-6) * k)))
    }

    /// RGBA float cube, red fastest (CIColorCube's layout). Input: shaped Rec.2020.
    /// Output: negative density / densityScale.
    static func negativeCube(stock: FilmStock, source: Source) -> [Float] {
        let n = negativeDimension
        let step = 1 / Double(n - 1)
        var lin = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let x = unshaped(Double(i) * step)
            lin[i] = source == .sceneLinear ? x : sceneFromDisplay(x)
        }
        var cube = [Float](repeating: 1, count: n * n * n * 4)
        var o = 0
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let d = negativeDensity((lin[r], lin[g], lin[b]), stock: stock)
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
        let contrast = pow(2, c.contrast * 0.5)      // ±1 → ×0.71…1.41 print gamma
        let amount = 1 + c.crossover
        return (0..<3).map { i in
            var curve = s.print[i]
            curve.gamma *= contrast * (1 + s.crossover[i] * amount)
            return curve
        }
    }

    /// Print density per channel for a negative density (printing is per channel).
    static func printDensity(_ dn: Double, channel c: Int, stock s: FilmStock, curves: [FilmCurve],
                             grey: (Double, Double, Double)) -> Double {
        let g = c == 0 ? grey.0 : c == 1 ? grey.1 : grey.2
        return curves[c].density(g - dn + s.printer[c])
    }

    /// Print density → linear Display P3 (dye crosstalk, saturation, highlights/shadows).
    static func display(print dp: (Double, Double, Double), stock s: FilmStock, curves: [FilmCurve],
                        controls c: FilmControls) -> (Double, Double, Double) {
        var dm = FilmMath.mul(s.crosstalk, dp)
        let base = FilmMath.mul(s.crosstalk, (curves[0].y[0], curves[1].y[0], curves[2].y[0]))

        // Saturation in density space: richer colors get denser (darker), like dyes,
        // instead of brighter.
        if c.saturation != 0 {
            let mean = (dm.0 + dm.1 + dm.2) / 3
            let k = 1 + c.saturation * (c.saturation > 0 ? 0.6 : 1)
            dm = (mean + (dm.0 - mean) * k, mean + (dm.1 - mean) * k, mean + (dm.2 - mean) * k)
        }
        // Highlights / shadows: shift density in the bright or the dark part of the scale.
        if c.highlights != 0 || c.shadows != 0 {
            let neutral = (dm.0 + dm.1 + dm.2) / 3
            let wh = exp(-pow((neutral - 0.25) / 0.45, 2))
            let ws = FilmMath.smoothstep(0.9, 2.4, neutral)
            let shift = -0.22 * c.highlights * wh - 0.45 * c.shadows * ws
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
        let dp = (printDensity(dn.0, channel: 0, stock: s, curves: curves, grey: grey),
                  printDensity(dn.1, channel: 1, stock: s, curves: curves, grey: grey),
                  printDensity(dn.2, channel: 2, stock: s, curves: curves, grey: grey))
        return display(print: dp, stock: s, curves: curves, controls: c)
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
        let ln10 = log(10.0)

        // Print density along each axis.
        var dp = [Double](repeating: 0, count: 3 * n)
        for ch in 0..<3 {
            for i in 0..<n {
                dp[ch * n + i] = printDensity(Double(i) * step, channel: ch, stock: stock, curves: curves, grey: grey)
            }
        }
        // Density mixing: crosstalk, then saturation about the mean (S = k·I + (1−k)/3·1).
        let x = stock.crosstalk
        var a = x
        if c.saturation != 0 {
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
        let tone = c.highlights != 0 || c.shadows != 0
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
                return exp((0.22 * c.highlights * wh + 0.45 * c.shadows * ws) * ln10)
            }
        }
        let d = stock.display
        let encode = FilmMath.encodeTable
        let last = Double(FilmMath.encodeTableSize)
        @inline(__always) func enc(_ v: Double) -> Float {
            let t = min(max(v, 0), 1).squareRoot() * last
            let i = min(Int(t), FilmMath.encodeTableSize - 1)
            let frac = t - Double(i)
            return Float(encode[i] + (encode[i + 1] - encode[i]) * frac)
        }

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
                        for ri in 0..<n {
                            var t0 = p0 * f[ri], t1 = p1 * f[3 * n + ri], t2 = p2 * f[6 * n + ri]
                            if tone {
                                let u = min(max((rowNeutral + nw[ri] - toneLo) * toneScale, 0), Double(toneSize))
                                let i = min(Int(u), toneSize - 1)
                                let h = toneTable[i] + (toneTable[i + 1] - toneTable[i]) * (u - Double(i))
                                t0 *= h; t1 *= h; t2 *= h
                            }
                            out[o] = enc(d[0] * t0 + d[1] * t1 + d[2] * t2)
                            out[o + 1] = enc(d[3] * t0 + d[4] * t1 + d[5] * t2)
                            out[o + 2] = enc(d[6] * t0 + d[7] * t1 + d[8] * t2)
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
