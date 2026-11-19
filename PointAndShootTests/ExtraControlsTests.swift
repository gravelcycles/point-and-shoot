import CoreImage
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
        XCTAssertFalse(json.contains("dehaze") || json.contains("gradeShadowHue"), "unset extras must not be stored")
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

    func testEditorExtrasStorage() {
        XCTAssertEqual(EditorExtra.hidden(""), [])
        let stored = EditorExtra.store([.masks, .printer])
        XCTAssertEqual(stored, "masks,printer")
        XCTAssertEqual(EditorExtra.hidden(stored), [.masks, .printer])
        XCTAssertEqual(EditorExtra.hidden("masks,unknown"), [.masks])
        XCTAssertEqual(EditorExtra.allCases.filter(\.isFilm).count, 4)
    }
}
