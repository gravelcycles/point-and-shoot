import CoreImage
import XCTest
@testable import PointAndShoot

/// Every filter through the real edit pipeline on the simulator's GPU: catches crashes,
/// NaNs and blank output in the film model before a photo ever does.
final class PipelineTests: XCTestCase {
    /// A small colourful test image: horizontal hue ramp, vertical brightness ramp.
    private func testImage() -> CIImage {
        let hue = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 96, y: 0),
            "inputColor0": CIColor(red: 0.9, green: 0.2, blue: 0.1),
            "inputColor1": CIColor(red: 0.1, green: 0.4, blue: 0.9),
        ])!.outputImage!
        let shade = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0, y: 72),
            "inputColor0": CIColor(red: 0.05, green: 0.05, blue: 0.05),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1),
        ])!.outputImage!
        return hue.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: shade])
            .cropped(to: CGRect(x: 0, y: 0, width: 96, height: 72))
    }

    private func pixels(of image: CIImage) throws -> [Float] {
        let rect = CGRect(x: 0, y: 0, width: 96, height: 72)
        var buffer = [Float](repeating: 0, count: 96 * 72 * 4)
        EditPipeline.context.render(image.cropped(to: rect), toBitmap: &buffer, rowBytes: 96 * 16,
                                    bounds: rect, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return buffer
    }

    func testEveryLookRendersFiniteVariedPixels() throws {
        let base = testImage()
        for look in Look.all {
            let out = EditPipeline.apply(look.recipe, to: base, developedFromRAW: false)
            XCTAssertFalse(out.extent.isInfinite, "\(look.id): infinite extent")
            let px = try pixels(of: out)
            XCTAssertTrue(px.allSatisfy { $0.isFinite }, "\(look.id): NaN/inf pixels")
            var lo = Float.greatestFiniteMagnitude
            var hi = -Float.greatestFiniteMagnitude
            var i = 0
            while i + 2 < px.count {
                let sum: Float = px[i] + px[i + 1] + px[i + 2]
                lo = min(lo, sum)
                hi = max(hi, sum)
                i += 4
            }
            XCTAssertGreaterThan(hi - lo, 0.05, "\(look.id): flat output")
        }
    }

    /// Hue twists bend colors only: a grey scale goes through every look's negative
    /// exactly as it would without them.
    func testHueTwistsLeaveNeutralsUntouched() {
        let twisted = FilmStock.all.values.filter { !($0.hueTwists ?? []).isEmpty }
        XCTAssertFalse(twisted.isEmpty, "no look uses hue twists")
        for stock in twisted {
            var plain = stock
            plain.hueTwists = nil
            for stops in stride(from: -6.0, through: 6.0, by: 1.0) {
                let x = 0.18 * pow(2, stops)
                let a = FilmLUT.negativeDensity((x, x, x), stock: stock)
                let b = FilmLUT.negativeDensity((x, x, x), stock: plain)
                XCTAssertEqual(a.0, b.0, accuracy: 1e-9, stock.id)
                XCTAssertEqual(a.1, b.1, accuracy: 1e-9, stock.id)
                XCTAssertEqual(a.2, b.2, accuracy: 1e-9, stock.id)
            }
        }
    }

    /// Film color is subtractive: the stock's dye saturation makes a rich color purer *and
    /// darker* (a video saturation boost would brighten it), and leaves a grey alone.
    func testDyeSaturationDeepensColorsAndKeepsGrey() {
        let plain = FilmStock.printLook
        var rich = plain
        rich.dyeSaturation = 0.4
        func lum(_ c: (Double, Double, Double)) -> Double { 0.2289746 * c.0 + 0.6917385 * c.1 + 0.0792869 * c.2 }
        for color in [(0.45, 0.28, 0.2), (0.12, 0.2, 0.45), (0.6, 0.5, 0.05)] {
            let neg = FilmLUT.negativeDensity(color, stock: plain)
            let a = FilmLUT.display(negative: neg, stock: plain)
            let b = FilmLUT.display(negative: neg, stock: rich)
            XCTAssertLessThan(lum(b), lum(a), "dye saturation brightened \(color)")
        }
        // Retained silver (< 0) drains color: a saturated red loses chroma.
        var silver = plain
        silver.dyeSaturation = -0.5
        let red = FilmLUT.negativeDensity((0.5, 0.06, 0.04), stock: plain)
        let r0 = FilmLUT.display(negative: red, stock: plain), r1 = FilmLUT.display(negative: red, stock: silver)
        XCTAssertLessThan(max(r1.0, r1.1, r1.2) - min(r1.0, r1.1, r1.2), max(r0.0, r0.1, r0.2) - min(r0.0, r0.1, r0.2))
        // A grey (three equal densities) is untouched, either way.
        for d in [0.3, 1.2, 2.5] {
            for amount in [0.4, -0.5] {
                let out = FilmLUT.dyeSaturate((d, d, d), amount)
                XCTAssertEqual(out.0, d, accuracy: 1e-12); XCTAssertEqual(out.1, d, accuracy: 1e-12)
                XCTAssertEqual(out.2, d, accuracy: 1e-12)
            }
        }
    }

    /// Hue twists never fold or squeeze the hue order (filmlooks.py refuses them; this is
    /// the same check on the shipped stocks): walking round the hue circle at a fixed
    /// chroma, the twisted hue keeps moving forward.
    func testHueTwistsKeepTheHueOrder() {
        let r3 = 3.0.squareRoot()
        func hue(_ c: (Double, Double, Double)) -> Double {
            let l = (log10(max(c.0, 0) + FilmLUT.twistOffset), log10(max(c.1, 0) + FilmLUT.twistOffset),
                     log10(max(c.2, 0) + FilmLUT.twistOffset))
            return atan2((r3 / 2) * (l.1 - l.2), l.0 - 0.5 * (l.1 + l.2)) * 180 / .pi
        }
        for stock in FilmStock.all.values {
            guard let twists = stock.hueTwists, !twists.isEmpty else { continue }
            var last: Double?
            var turned = 0.0
            for i in 0..<720 {
                let a = Double(i) / 2 * .pi / 180, m = log10(0.19), c = 0.4
                let u = c * cos(a), v = c * sin(a)
                let rgb = (pow(10, m + 2 / 3 * u) - FilmLUT.twistOffset, pow(10, m - u / 3 + v / r3) - FilmLUT.twistOffset,
                           pow(10, m - u / 3 - v / r3) - FilmLUT.twistOffset)
                let h = hue(FilmLUT.twist(rgb, twists))
                if let last {
                    var step = h - last
                    if step < -180 { step += 360 } else if step > 180 { step -= 360 }
                    XCTAssertGreaterThan(step, 0.05, "\(stock.id): hue order folds near \(Double(i) / 2)°")
                    turned += step
                }
                last = h
            }
            XCTAssertEqual(turned, 359.5, accuracy: 1, "\(stock.id): twisted hues should go round once")
        }
    }

    /// The cache itself: an engine-3 look at Saturation 0 gets the very table prewarm built
    /// with default controls (same storage), not a rebuild on the render queue.
    func testPrewarmedPrintTablesServeEngineThreeLooks() {
        let stock = FilmStock.named("blockbuster")
        let prewarmed = FilmPipeline.printCube(stock, FilmControls())
        var engine3 = FilmControls()
        engine3.subtractiveSaturation = true
        let asked = FilmPipeline.printCube(stock, engine3)
        let shared = prewarmed.withUnsafeBytes { a in asked.withUnsafeBytes { b in a.baseAddress == b.baseAddress } }
        XCTAssertTrue(shared, "an engine-3 look at Saturation 0 should reuse the prewarmed table")
    }

    /// Cache keys: the engine flag only matters with Saturation above 0, so a look at its
    /// defaults asks for the same tables prewarm built (with default controls).
    func testFilmControlsCanonicalKeySharesTables() {
        var c = FilmControls()
        c.subtractiveSaturation = true
        XCTAssertEqual(c.canonical, FilmControls())
        c.saturation = -0.3
        var expected = FilmControls(); expected.saturation = -0.3
        XCTAssertEqual(c.canonical, expected)
        c.saturation = 0.3
        XCTAssertTrue(c.canonical.subtractiveSaturation, "the flag matters with Saturation above 0")
    }

    /// From film engine 3, more Saturation works like the dyes: a rich color gets darker.
    /// Engines 1–2 spread density about the mean, which brightened it (a yellow at +50 went
    /// from 0.34 to 0.57 luminance); photos made with them keep that slider.
    func testSaturationSliderIsSubtractiveFromEngineThree() {
        let s = FilmStock.printLook
        func lum(_ c: (Double, Double, Double)) -> Double { 0.2289746 * c.0 + 0.6917385 * c.1 + 0.0792869 * c.2 }
        var older = FilmControls()
        older.saturation = 0.5
        var engine3 = older
        engine3.subtractiveSaturation = true
        for color in [(0.45, 0.28, 0.2), (0.12, 0.2, 0.45), (0.6, 0.5, 0.05)] {
            let neg = FilmLUT.negativeDensity(color, stock: s)
            let plain = lum(FilmLUT.display(negative: neg, stock: s))
            XCTAssertLessThan(lum(FilmLUT.display(negative: neg, stock: s, controls: engine3)), plain, "engine 3 brightened \(color)")
            XCTAssertGreaterThan(lum(FilmLUT.display(negative: neg, stock: s, controls: older)), plain, "the old slider changed for \(color)")
        }
    }

    func testSceneKeyIsPositiveAndFinite() throws {
        let key = try XCTUnwrap(FilmPipeline.sceneKey(of: testImage(), context: EditPipeline.context, source: .displayReferred))
        XCTAssertTrue(key.isFinite && key > 0)
    }

    func testRAWExposureMatchClampsAndRounds() throws {
        // Two stops: the usual gap between a neutral RAW develop and Apple's rendering.
        XCTAssertEqual(FilmPipeline.matchedExposure(target: 0.16, rawKey: 0.04), 2)
        XCTAssertEqual(try XCTUnwrap(FilmPipeline.matchedExposure(target: 0.1, rawKey: 0.03)), 1.74, accuracy: 1e-9)
        // Chromagraph's fixed +1.86 EV and the bright days above it fit well inside the cap.
        XCTAssertGreaterThanOrEqual(EditRecipe.filmExposureRange.upperBound, 3.5)
        XCTAssertEqual(FilmPipeline.matchedExposure(target: 1, rawKey: 0.001), EditRecipe.filmExposureRange.upperBound)
        XCTAssertEqual(FilmPipeline.matchedExposure(target: 0.001, rawKey: 1), EditRecipe.filmExposureRange.lowerBound)
        XCTAssertNil(FilmPipeline.matchedExposure(target: 0, rawKey: 0.04))
        XCTAssertNil(FilmPipeline.matchedExposure(target: 0.1, rawKey: .nan))
    }

    func testBakeQueueRunsInOrder() async {
        // Each later bake is shorter, so if bakes overlapped they'd finish out of order.
        let log = OrderLog()
        var tasks: [Task<Void, Never>] = []
        for i in 0..<4 {
            tasks.append(Task {
                await BakeQueue.shared.run {
                    try? await Task.sleep(nanoseconds: UInt64(4 - i) * 40_000_000)
                    await log.add(i)
                }
            })
            try? await Task.sleep(nanoseconds: 20_000_000)   // enqueue in a known order
        }
        for t in tasks { await t.value }
        let items = await log.items
        XCTAssertEqual(items, [0, 1, 2, 3], "Bakes must not overlap or reorder")
    }
}

private actor OrderLog {
    var items: [Int] = []
    func add(_ i: Int) { items.append(i) }
}
