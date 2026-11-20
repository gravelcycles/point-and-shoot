import CoreImage
import ImageIO
import XCTest
@testable import PointAndShoot

/// The Film tool (printer lights, push/pull, flashing, silver, grain colour, halation size
/// and colour) and the extras for every look (colour grading, tone curve, dehaze, masks).
final class ExtraControlsTests: XCTestCase {
    private var printRecipe: EditRecipe { Look.named(CameraSettings.printLookID)!.recipe }

    private func image() -> CIImage {
        CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 64, y: 48),
            "inputColor0": CIColor(red: 0.05, green: 0.05, blue: 0.08),
            "inputColor1": CIColor(red: 0.95, green: 0.8, blue: 0.6),
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
    }

    private func pixels(_ recipe: EditRecipe) -> [Float] {
        var r = recipe
        r.grain = 0
        let out = EditPipeline.apply(r, to: image(), developedFromRAW: false)
        let rect = CGRect(x: 0, y: 0, width: 64, height: 48)
        var buf = [Float](repeating: 0, count: 64 * 48 * 4)
        EditPipeline.context.render(out.cropped(to: rect), toBitmap: &buf, rowBytes: 64 * 16, bounds: rect,
                                    format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return buf
    }

    private func maxDiff(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { max($0, abs($1.0 - $1.1)) }
    }

    /// Untouched, none of the new controls changes anything: their fields stay nil and the
    /// film's controls are the plain ones.
    func testEveryNewControlIsOffByDefault() {
        let r = printRecipe
        for a in Adjustment.filmTool + Adjustment.extras {
            var moved = r
            moved[keyPath: a.keyPath] = EditRecipe()[keyPath: a.keyPath]
            XCTAssertEqual(moved, r, "\(a.id): setting its default changed the edit")
        }
        var c = r.filmControls
        c.pivot = 0
        XCTAssertEqual(c.printerR, 0); XCTAssertEqual(c.push, 0); XCTAssertEqual(c.flash, 0); XCTAssertEqual(c.silver, 0)
        XCTAssertTrue(r.gradeParams.isIdentity)
        let data = try! JSONEncoder().encode(EditRecipe())
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("dehaze") || json.contains("gradeShadowHue") || json.contains("localTone")
                       || json.contains("appleTone"), "unset extras must not be stored")
    }

    /// Local Tone on two big flat halves: far from the edge, the dark half comes up and the
    /// bright half goes down by the reference gain (so CIGammaAdjust's negative power and the
    /// area average do what the formula says), every pixel stays finite and opaque, and the
    /// dark half's gain at full strength is capped.
    func testLocalToneDodgesAndBurns() {
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let w: CGFloat = 1000, h: CGFloat = 400
        let d = 0.02, b = 0.8
        func flat(_ v: Double, _ rect: CGRect) -> CIImage {
            CIImage(color: CIColor(red: v, green: v, blue: v, colorSpace: linear)!).cropped(to: rect)
        }
        let img = flat(b, CGRect(x: w / 2, y: 0, width: w / 2, height: h))
            .composited(over: flat(d, CGRect(x: 0, y: 0, width: w / 2, height: h)))
        func at(_ out: CIImage, _ x: CGFloat) -> [Float] {
            var px = [Float](repeating: 0, count: 4)
            EditPipeline.context.render(out, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: x, y: h / 2, width: 1, height: 1),
                                        format: .RGBAf, colorSpace: nil)
            return px
        }
        let p = ExtraGrades.localTonePower
        let average = pow((pow(d, p) + pow(b, p)) / 2, 1 / p)
        for amount in [0.5, 1.0] {
            let out = ExtraGrades.localTone(img, amount: amount, sceneLinear: true, unit: w / 1000)
            XCTAssertEqual(out.extent, img.extent)
            let dark = at(out, 250), bright = at(out, 750)
            let gd = ExtraGrades.localToneGain(region: d, average: average, amount: amount, sceneLinear: true)
            let gb = ExtraGrades.localToneGain(region: b, average: average, amount: amount, sceneLinear: true)
            XCTAssertGreaterThan(gd, 1.5); XCTAssertLessThan(gb, 0.8)
            XCTAssertEqual(Double(dark[0]) / d, gd, accuracy: gd * 0.04, "dark half at \(amount)")
            XCTAssertEqual(Double(bright[0]) / b, gb, accuracy: gb * 0.04, "bright half at \(amount)")
            XCTAssertEqual(dark[3], 1, accuracy: 1e-4); XCTAssertEqual(bright[3], 1, accuracy: 1e-4)
            for x in stride(from: CGFloat(0), to: w, by: 25) {
                XCTAssertTrue(at(out, x).allSatisfy(\.isFinite), "finite at \(x)")
            }
        }
        XCTAssertEqual(ExtraGrades.localToneGain(region: 1e-6, average: 1, amount: 1, sceneLinear: true),
                       pow(2, ExtraGrades.localToneLimit), accuracy: 1e-9)
        XCTAssertLessThan(ExtraGrades.localToneGain(region: d, average: average, amount: 1, sceneLinear: false),
                          ExtraGrades.localToneGain(region: d, average: average, amount: 1, sceneLinear: true))
        // Through the whole edit, on a film look and on Original: it changes the picture.
        for start in [EditRecipe(), printRecipe] {
            var r = start
            r.localTone = 80
            XCTAssertGreaterThan(maxDiff(pixels(r), pixels(start)), 0.01)
        }
    }

    /// Apple Tone: a film look's RAW develops with Apple's rendering at the viewfinder's
    /// brightness instead of the film's develop exposure, it survives picking another look,
    /// and older edits (and Original) are untouched.
    func testAppleToneDevelop() {
        var r = printRecipe
        r.film?.engine = FilmLUT.currentEngine
        r.rawFilmExposure = 1.5
        r.exposure = 25
        XCTAssertFalse(r.printsAppleRender)
        XCTAssertEqual(EditPipeline.rawExposureSplit(r).develop, 2.0, accuracy: 1e-9)
        r.appleToneValue = true
        XCTAssertTrue(r.printsAppleRender)
        XCTAssertEqual(EditPipeline.rawExposureSplit(r).develop, 0.5, accuracy: 1e-9, "no film develop exposure")
        // Without EXIF the scene counts as EV 10, where the viewfinder sits 0.2 under Apple.
        XCTAssertEqual(EditPipeline.appleToneExposure(properties: nil), EditRecipe.naturalBias, accuracy: 1e-9)
        let exif: [AnyHashable: Any] = [kCGImagePropertyExifDictionary as String: [
            kCGImagePropertyExifISOSpeedRatings as String: [50.0],
            kCGImagePropertyExifExposureTime as String: 1.0 / 4000,
            kCGImagePropertyExifFNumber as String: 1.6,
        ] as [String: Any]]
        let ev = EditPipeline.ev100(properties: exif)!
        XCTAssertEqual(ev, log2(1.6 * 1.6 * 4000) + 1, accuracy: 1e-9)
        XCTAssertEqual(EditPipeline.appleToneExposure(properties: exif), ViewfinderMatch.correction(ev100: ev), accuracy: 1e-9)
        XCTAssertLessThan(EditPipeline.appleToneExposure(properties: exif), EditRecipe.naturalBias, "a bright day comes down")
        // Kept when the look changes, like the RAW tab's settings.
        let other = Look.all.first { $0.recipe.film != nil && $0.id != r.look }!
        XCTAssertEqual(r.withLook(other).appleTone, true)
        // Engine 1 (its un-render never saw a RAW) and Original ignore it.
        var old = r
        old.film?.engine = 1
        XCTAssertFalse(old.printsAppleRender)
        var original = EditRecipe()
        original.appleToneValue = true
        XCTAssertFalse(original.printsAppleRender)
        // Older edits decode with it off.
        let decoded = EditRecipe.decodeSaved(try! JSONEncoder().encode(printRecipe))
        XCTAssertNil(decoded?.appleTone); XCTAssertNil(decoded?.localTone)
    }

    /// Each film control moves the neutral scale the way it should.
    func testFilmToolDirections() {
        let stock = FilmStock.printLook
        func grey(_ c: FilmControls, _ stops: Double = 0) -> (Double, Double, Double) {
            FilmLUT.neutralResponse(stops: stops, stock: stock, controls: c)
        }
        let base = grey(FilmControls())
        var warm = FilmControls()
        (warm.printerR, warm.printerG, warm.printerB) = FilmControls.printerLights(warm: 1, magenta: 0)
        let w = grey(warm)
        XCTAssertGreaterThan(w.0 / w.2, base.0 / base.2 * 1.2, "warm printer lights should warm grey")
        var push = FilmControls()
        push.push = 2
        XCTAssertEqual(grey(push).1, base.1, accuracy: 1e-9, "push keeps grey")
        XCTAssertGreaterThan(grey(push, 2).1, grey(FilmControls(), 2).1, "push spreads the highlights")
        XCTAssertLessThan(grey(push, -2).1, grey(FilmControls(), -2).1, "...and deepens the shadows")
        var flash = FilmControls()
        flash.flash = 0.08
        XCTAssertGreaterThan(grey(flash, -4).1, grey(FilmControls(), -4).1 * 1.5, "flashing lifts the shadows")
        var silver = FilmControls()
        silver.silver = 1
        let red = FilmLUT.negativeDensity((0.5, 0.12, 0.06), stock: stock)
        let a = FilmLUT.display(negative: red, stock: stock), b = FilmLUT.display(negative: red, stock: stock, controls: silver)
        XCTAssertLessThan(b.0 / max(b.1, 1e-6), a.0 / max(a.1, 1e-6), "silver retention drains colour")
    }

    /// The film controls reach the render, and the print cube matches the reference math.
    func testFilmToolRendersAndMatchesTheReference() {
        var r = printRecipe
        let base = pixels(r)
        let cases: [(WritableKeyPath<EditRecipe, Double>, Double)] = [
            (\.filmPrinterWarm, 80), (\.filmPush, 80), (\.filmFlash, 100), (\.filmSilver, 100)]
        for (path, v) in cases {
            var m = r
            m[keyPath: path] = v
            XCTAssertGreaterThan(maxDiff(pixels(m), base), 0.01, "\(path) changed nothing")
        }
        r.filmSilver = 60; r.filmPush = 50; r.filmFlash = 40; r.filmPrinterMagenta = -30
        let c = r.filmControls
        let stock = FilmStock.printLook
        let cube = FilmLUT.printCube(stock: stock, controls: c)
        let n = FilmLUT.printDimension
        for (ri, gi, bi) in [(10, 20, 30), (24, 24, 24), (40, 9, 25)] {
            let step = FilmLUT.densityScale / Double(n - 1)
            let ref = FilmLUT.display(negative: (Double(ri) * step, Double(gi) * step, Double(bi) * step), stock: stock, controls: c)
            let o = ((bi * n + gi) * n + ri) * 4
            XCTAssertEqual(Double(cube[o + 1]), FilmMath.encodeSRGB(ref.1), accuracy: 2e-3, "print cube vs reference at \(ri),\(gi),\(bi)")
        }
    }

    func testGrainAndHalationShapes() {
        XCTAssertEqual(FilmPipeline.grainChroma(0.15, color: 0), 0.15)
        XCTAssertEqual(FilmPipeline.grainChroma(0.15, color: -1), 0)
        XCTAssertEqual(FilmPipeline.grainChroma(0.15, color: 1), 0.8, accuracy: 1e-12)
        let h = [0.15, 0.04, 0.005]
        XCTAssertEqual(FilmPipeline.halationStrengths(h, amount: 1, color: 0), h)
        let red = FilmPipeline.halationStrengths(h, amount: 1, color: -1)
        XCTAssertEqual(red[1], 0); XCTAssertEqual(red[2], 0)
        let white = FilmPipeline.halationStrengths(h, amount: 1, color: 1)
        XCTAssertEqual(white[1], 0.09, accuracy: 1e-12)
    }

    /// The parametric curve keeps black and white, stays monotone, and each region moves its
    /// part of the scale; tints are luminance-neutral.
    func testCurveAndTints() {
        for p in [[1.0, 1, 1, 1], [-1, -1, -1, -1], [1, -1, 1, -1]] {
            XCTAssertEqual(ExtraGrades.curve(0, p), 0)
            XCTAssertEqual(ExtraGrades.curve(1, p), 1)
        }
        XCTAssertGreaterThan(ExtraGrades.curve(0.85, [1, 0, 0, 0]), 0.85)
        XCTAssertLessThan(ExtraGrades.curve(0.15, [0, 0, 0, -1]), 0.15)
        XCTAssertEqual(ExtraGrades.curve(0.15, [1, 0, 0, 0]), 0.15, accuracy: 0.01, "Highlights barely touch the shadows")
        for hue in stride(from: 0.0, to: 360, by: 30) {
            let t = ExtraGrades.tint(hue: hue)
            XCTAssertEqual(0.2126 * t.0 + 0.7152 * t.1 + 0.0722 * t.2, 0, accuracy: 1e-9)
        }
        let cube = ExtraGrades.gradeCube(.init(curve: [0.5, -0.5, 0.5, -0.5], tints: [210, 1, 30, 0, 45, 1]))
        XCTAssertEqual(cube.count, ExtraGrades.cubeSize * ExtraGrades.cubeSize * ExtraGrades.cubeSize * 4 * 4)
    }

    /// Every extra reaches the render on any look, and the masks never fail the render
    /// (Vision may find no subject in the simulator: then it's a no-op).
    func testExtrasRender() {
        for start in [EditRecipe(), printRecipe] {
            let base = pixels(start)
            let cases: [(WritableKeyPath<EditRecipe, Double>, Double)] = [
                (\.gradeShadowAmountValue, 100), (\.gradeHighlightAmountValue, 100),
                (\.curveLightsValue, 100), (\.dehazeValue, 100), (\.dehazeValue, -100)]
            for (path, v) in cases {
                var m = start
                m[keyPath: path] = v
                XCTAssertGreaterThan(maxDiff(pixels(m), base), 0.005, "\(path) = \(v) changed nothing")
            }
            var subject = start
            subject.subjectExposureValue = 100
            XCTAssertEqual(pixels(subject).count, base.count)
        }
    }

    /// The sky mask finds a bright blue top and ignores a warm wall below it.
    func testSkyMaskFindsTheSky() {
        let sky = CIImage(color: CIColor(red: 0.45, green: 0.62, blue: 0.9)).cropped(to: CGRect(x: 0, y: 24, width: 64, height: 24))
        let wall = CIImage(color: CIColor(red: 0.8, green: 0.5, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 24))
        let img = sky.composited(over: wall)
        let mask = ExtraGrades.skyMask(img, unit: 0.064)
        func mean(_ rect: CGRect) -> Float {
            var px = [Float](repeating: 0, count: Int(rect.width * rect.height) * 4)
            EditPipeline.context.render(mask, toBitmap: &px, rowBytes: Int(rect.width) * 16, bounds: rect,
                                        format: .RGBAf, colorSpace: nil)
            return stride(from: 0, to: px.count, by: 4).reduce(0) { $0 + px[$1] } / Float(px.count / 4)
        }
        XCTAssertGreaterThan(mean(CGRect(x: 0, y: 40, width: 64, height: 8)), 0.4, "the sky at the top")
        XCTAssertLessThan(mean(CGRect(x: 0, y: 0, width: 64, height: 12)), 0.1, "not the warm wall")
    }

    /// The colour mixer visibly changes its colour family, on a saturated and on a muted
    /// colour, with and without a film look (the owner saw no difference on device).
    func testMixerChangesItsColours() {
        func render(_ r: EditRecipe, _ c: CIColor) -> [Float] {
            let img = CIImage(color: c).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
            let out = EditPipeline.apply(r, to: img, developedFromRAW: false)
            var px = [Float](repeating: 0, count: 8 * 8 * 4)
            EditPipeline.context.render(out.cropped(to: img.extent), toBitmap: &px, rowBytes: 8 * 16, bounds: img.extent,
                                        format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return Array(px[0..<3])
        }
        for start in [EditRecipe(), printRecipe] {
            var start = start
            start.grain = 0
            for (colour, band) in [(CIColor(red: 0.8, green: 0.2, blue: 0.1), ColorBand.red),
                                   (CIColor(red: 0.62, green: 0.55, blue: 0.48), .orange)] {
                let base = render(start, colour)
                for k in 0..<3 {
                    var r = start
                    r.mixerValues[band.rawValue * 3 + k] = 100
                    let moved = render(r, colour)
                    let d = zip(moved, base).map { abs($0 - $1) }.max() ?? 0
                    XCTAssertGreaterThan(d, 0.02, "\(band) channel \(k) on \(start.look ?? "original"): \(base) → \(moved)")
                }
            }
        }
    }

    /// Every slider and toggle has an ⓘ explanation (the colour mixer's per-band sliders are
    /// covered by the band picker's).
    func testEveryControlIsExplained() {
        let all = Adjustment.tune + Adjustment.details + Adjustment.filmDetails + Adjustment.raw
            + Adjustment.filmTool + Adjustment.extras
        for a in all {
            XCTAssertNotNil(EditorHelp.controls[a.id], "\(a.id) has no ⓘ text")
        }
        for id in ["mono", "pixelGrain", "mixerBands", "appleTone"] { XCTAssertNotNil(EditorHelp.controls[id], id) }
        for tab in ["contrast", "shadowHighlight", "grain", "printer", "process", "silver", "curveLights", "sky", "local", "raw"] {
            XCTAssertNotNil(EditorHelp.together(tab, isFilm: true), tab)
        }
    }

    func testEditorExtrasStorage() {
        XCTAssertEqual(EditorExtra.hidden(""), [])
        let stored = EditorExtra.store([.masks, .printer])
        XCTAssertEqual(stored, "masks,printer")
        XCTAssertEqual(EditorExtra.hidden(stored), [.masks, .printer])
        XCTAssertEqual(EditorExtra.hidden("masks,unknown"), [.masks])
        XCTAssertEqual(EditorExtra.allCases.filter(\.isFilm).count, 4)
    }
}
