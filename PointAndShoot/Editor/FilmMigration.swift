import Foundation

/// Moves a film edit made with older film math (`FilmRecipe.engine`) onto the current
/// engine, choosing the new sliders that render it as closely as they can, so every photo
/// has today's controls without changing how it looks (the owner, 2026-11-19: "can't you
/// pick a setting in the new version that matched the old version?").
///
/// - Exact: Contrast (the same print gamma on the new scale), grain (the same size and
///   strength at a 4032 px export), engine 1 → 2 for photos developed from their RAW (the
///   two differ only for processed input).
/// - Fitted, on the stock's grey scale (−7…+5 stops, encoded luminance) and a few rich
///   colours: Saturation from engines 1–2 (it spread about the mean, brightening), and
///   Highlights/Shadows from engines 1–4 (they shifted print density at the ends of the
///   scale; engine 5 re-exposes broad regions, a different shape). Highlights/Shadows are
///   fitted together with the tone curve's four sliders where the edit has none, which
///   gets most photos within a few percent; strong old Highlights stay up to ~5–20% off at
///   the very ends. The remaining error is returned (and logged by the store).
/// - A processed photo (no RAW) on engine 1 keeps its engine: its un-render changed.
enum FilmMigration {
    /// Preferences → Processing → "Update Older Edits" (on by default). Off, nothing is
    /// migrated anywhere; "Restore Edits from Before the Update" turns it off and puts back
    /// every grade's backup (`ShotStore.restorePreMigrationGrades`).
    static let enabledKey = "film.migrateOlderEdits"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    /// Each shot's grade as it was before its first migration, next to its recipe.json.
    static let backupName = "recipe.before-migration.json"

    struct Result {
        var recipe: EditRecipe
        /// RMS difference on the grey scale (encoded luminance, 0…1) after the fit.
        var toneError: Double
        var changed: Bool
    }

    static func migrate(_ r: EditRecipe, developsFromRAW: Bool, force: Bool = false) -> Result {
        guard force || isEnabled, var film = r.film else { return Result(recipe: r, toneError: 0, changed: false) }
        let current = FilmRecipe.currentEngine
        let from = film.renderEngine
        guard from < current else { return Result(recipe: r, toneError: 0, changed: false) }
        if from < 2 && !developsFromRAW { return Result(recipe: r, toneError: 0, changed: false) }

        var out = r
        var toneError = 0.0
        guard var stock = FilmStock.resolved(for: r) else { return Result(recipe: r, toneError: 0, changed: false) }
        stock.huePreserve = 0          // tone and colour only; hue protection is the same either way

        // Saturation (engines 1–2 spread about the mean): fit the subtractive slider.
        if from < 3 && r.saturation > 0 {
            out.saturation = fitSaturation(r, stock: stock)
        }

        // Contrast: same print gamma (2^(c/2) before engine 5; 2^c, or 2^(0.75c) below 0, from 5).
        if from < 5 && r.contrast != 0 {
            let c = r.contrast / 100
            out.contrast = ((c > 0 ? c / 2 : c * 2 / 3) * 100 * 100).rounded() / 100
        }

        // Highlights / Shadows: fit engine 5's (and the tone curve where unused).
        if from < 5 && (r.highlights != 0 || r.shadows != 0) {
            let fit = fitTone(old: r, new: out, stock: stock)
            out.highlights = fit.highlights; out.shadows = fit.shadows
            if let curve = fit.curve {
                out.curveHighlightsValue = curve[0]; out.curveLightsValue = curve[1]
                out.curveDarksValue = curve[2]; out.curveShadowsValue = curve[3]
            }
            toneError = fit.error
        }

        // Grain: frame-sized from engine 6. Same size and strength at a 4032 px export.
        if from < 6 && r.grain > 0 {
            out.grain = min(200, (r.grain / FilmPipeline.frameGrainGain).rounded())
            out.grainSizeValue = min(300, max(25, (r.grainSizeValue / FilmPipeline.frameGrainScale).rounded()))
        }

        film = out.film ?? film
        film.engine = current
        out.film = film
        // Never write a broken number: a fit gone wrong leaves the edit as it was.
        let values = [out.contrast, out.highlights, out.shadows, out.saturation, out.grain, out.grainSizeValue,
                      out.curveHighlightsValue, out.curveLightsValue, out.curveDarksValue, out.curveShadowsValue, toneError]
        guard values.allSatisfy(\.isFinite) else {
            Diag.error(.editor, "film migration produced a non-finite value; edit left as it was")
            return Result(recipe: r, toneError: 0, changed: false)
        }
        return Result(recipe: out, toneError: toneError, changed: true)
    }

    // MARK: Grey scale

    private static let stops: [Double] = stride(from: -7.0, through: 5.0, by: 0.25).map { $0 }

    /// The stock's grey scale under some controls, as encoded luminance, straight from the
    /// scene's log exposure (no table inverse, so it's quick).
    static func greyScale(stock s: FilmStock, controls c: FilmControls, curve: [Double]? = nil) -> [Double] {
        let curves = FilmLUT.printCurves(stock: s, controls: c)
        let grey = s.greyNegativeDensity
        let pg = FilmLUT.printGrey(stock: s, controls: c)
        let twists = s.hueTwists ?? []
        let l = FilmMath.lumP3
        return stops.map { st in
            let x = 0.18 * pow(2, st)
            let e = FilmMath.mul(s.sensitivity, twists.isEmpty ? (x, x, x) : FilmLUT.twist((x, x, x), twists))
            var le = (log10(max(e.0, 1e-6) / 0.18), log10(max(e.1, 1e-6) / 0.18), log10(max(e.2, 1e-6) / 0.18))
            if c.shiftsExposure {
                let sh = c.exposureShift((le.0 + le.1 + le.2) / 3 / log10(2.0)) * log10(2.0)
                le = (le.0 + sh, le.1 + sh, le.2 + sh)
            }
            let dn = (FilmLUT.negativeDensity(c.flashed(le.0), channel: 0, stock: s),
                      FilmLUT.negativeDensity(c.flashed(le.1), channel: 1, stock: s),
                      FilmLUT.negativeDensity(c.flashed(le.2), channel: 2, stock: s))
            let dp = (FilmLUT.printDensity(c.develop(dn.0, grey: grey.0), channel: 0, stock: s, curves: curves, grey: pg),
                      FilmLUT.printDensity(c.develop(dn.1, grey: grey.1), channel: 1, stock: s, curves: curves, grey: pg),
                      FilmLUT.printDensity(c.develop(dn.2, grey: grey.2), channel: 2, stock: s, curves: curves, grey: pg))
            let v = FilmLUT.display(print: dp, stock: s, curves: curves, controls: c)
            let y = l.0 * FilmMath.encodeSRGB(v.0) + l.1 * FilmMath.encodeSRGB(v.1) + l.2 * FilmMath.encodeSRGB(v.2)
            return curve.map { ExtraGrades.curve(y, $0) } ?? y
        }
    }

    private static func controls(_ r: EditRecipe, engine: Int) -> FilmControls {
        var copy = r
        copy.film?.engine = engine
        return copy.filmControls
    }

    private static func rms(_ a: [Double], _ b: [Double]) -> Double {
        (zip(a, b).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) } / Double(a.count)).squareRoot()
    }

    struct ToneFit { var highlights: Double; var shadows: Double; var curve: [Double]?; var error: Double }

    /// Engine 5's Highlights/Shadows (slider units) and, where the edit has no curve yet, the
    /// tone curve's four sliders, closest to the old grey scale.
    static func fitTone(old: EditRecipe, new: EditRecipe, stock: FilmStock) -> ToneFit {
        let target = greyScale(stock: stock, controls: controls(old, engine: old.film?.renderEngine ?? 1))
        let useCurve = new.gradeParams.curve.allSatisfy { $0 == 0 }
        let existingCurve = new.gradeParams.curve
        var best = ToneFit(highlights: 0, shadows: 0, curve: nil, error: .infinity)
        func evaluate(_ h: Double, _ s: Double) {
            var trial = new
            trial.highlights = h; trial.shadows = s
            let base = greyScale(stock: stock, controls: controls(trial, engine: FilmRecipe.currentEngine))
            var curve: [Double]? = nil
            var fitted = base.map { ExtraGrades.curve($0, existingCurve) }
            if useCurve {
                let p = solveCurve(base: base, target: target)
                curve = p.map { ($0 * 100).rounded() }
                fitted = base.map { ExtraGrades.curve($0, curve!.map { $0 / 100 }) }
            }
            let e = rms(fitted, target)
            if e < best.error { best = ToneFit(highlights: h, shadows: s, curve: curve, error: e) }
        }
        for h in stride(from: -100.0, through: 100, by: 10) {
            for s in stride(from: -100.0, through: 100, by: 10) { evaluate(h, s) }
        }
        let (h0, s0) = (best.highlights, best.shadows)
        for h in stride(from: max(-100, h0 - 10), through: min(100, h0 + 10), by: 2) {
            for s in stride(from: max(-100, s0 - 10), through: min(100, s0 + 10), by: 2) { evaluate(h, s) }
        }
        if best.curve?.allSatisfy({ $0 == 0 }) == true { best.curve = nil }
        return best
    }

    /// Least squares for the tone curve's four sliders (−1…1): the curve is linear in them
    /// (`ExtraGrades.curve` before clamping).
    static func solveCurve(base: [Double], target: [Double]) -> [Double] {
        let regions: [(c: Double, w: Double)] = [(0.85, 0.12), (0.62, 0.14), (0.38, 0.14), (0.15, 0.12)]
        func basis(_ x: Double, _ k: Int) -> Double {
            0.15 * exp(-pow((x - regions[k].c) / regions[k].w, 2)) * 4 * x * (1 - x)
        }
        var a = [Double](repeating: 0, count: 16), b = [Double](repeating: 0, count: 4)
        for (x, t) in zip(base, target) {
            let f = (0..<4).map { basis(x, $0) }
            for i in 0..<4 {
                b[i] += f[i] * (t - x)
                for j in 0..<4 { a[i * 4 + j] += f[i] * f[j] }
            }
        }
        for i in 0..<4 { a[i * 4 + i] += 1e-4 }      // a little ridge: regions nobody's in stay 0
        // Gaussian elimination (4×4).
        var m = a, v = b
        for col in 0..<4 {
            var pivot = col
            for row in col..<4 where abs(m[row * 4 + col]) > abs(m[pivot * 4 + col]) { pivot = row }
            if pivot != col {
                for k in 0..<4 { m.swapAt(col * 4 + k, pivot * 4 + k) }
                v.swapAt(col, pivot)
            }
            let d = m[col * 4 + col]
            guard abs(d) > 1e-12 else { continue }
            for row in 0..<4 where row != col {
                let f = m[row * 4 + col] / d
                for k in 0..<4 { m[row * 4 + k] -= f * m[col * 4 + k] }
                v[row] -= f * v[col]
            }
        }
        return (0..<4).map { i in
            let d = m[i * 4 + i]
            return abs(d) > 1e-12 ? min(max(v[i] / d, -1), 1) : 0
        }
    }

    // MARK: Saturation

    private static let richColours: [(Double, Double, Double)] = [
        (0.5, 0.12, 0.06), (0.1, 0.3, 0.08), (0.08, 0.14, 0.5), (0.45, 0.35, 0.06), (0.3, 0.08, 0.35), (0.06, 0.3, 0.32),
    ]

    /// Engine 3's (subtractive) Saturation closest to an engine 1–2 edit's on rich colours.
    static func fitSaturation(_ r: EditRecipe, stock: FilmStock) -> Double {
        let oldC = controls(r, engine: r.film?.renderEngine ?? 1)
        func render(_ c: FilmControls) -> [Double] {
            richColours.flatMap { rgb -> [Double] in
                let v = FilmLUT.display(negative: FilmLUT.negativeDensity(rgb, stock: stock), stock: stock, controls: c)
                return [FilmMath.encodeSRGB(v.0), FilmMath.encodeSRGB(v.1), FilmMath.encodeSRGB(v.2)]
            }
        }
        let target = render(oldC)
        var best = (r.saturation, Double.infinity)
        for s in stride(from: 0.0, through: 100, by: 2) {
            var trial = r
            trial.saturation = s
            var c = controls(trial, engine: 3)
            c.highlights = oldC.highlights; c.shadows = oldC.shadows; c.strongTone = oldC.strongTone
            let e = rms(render(c), target)
            if e < best.1 { best = (s, e) }
        }
        return best.0
    }
}
