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
        // Greys: Print's print curves are the same per channel, so a grey stays a grey.
        let grey = FilmLUT.negativeDensity((0.18, 0.18, 0.18), stock: plain)
        let g0 = FilmLUT.display(negative: grey, stock: plain), g1 = FilmLUT.display(negative: grey, stock: rich)
        XCTAssertEqual(lum(g1), lum(g0), accuracy: 0.02)
    }

    /// From film engine 2, more Saturation works like the dyes: a rich color gets darker.
    /// Engine 1 spread density about the mean, which brightened it (a yellow at +50 went
    /// from 0.34 to 0.57 luminance); photos made with engine 1 keep that slider.
    func testSaturationSliderIsSubtractiveFromEngineTwo() {
        let s = FilmStock.printLook
        func lum(_ c: (Double, Double, Double)) -> Double { 0.2289746 * c.0 + 0.6917385 * c.1 + 0.0792869 * c.2 }
        var engine1 = FilmControls()
        engine1.saturation = 0.5
        var engine2 = engine1
        engine2.subtractiveSaturation = true
        for color in [(0.45, 0.28, 0.2), (0.12, 0.2, 0.45), (0.6, 0.5, 0.05)] {
            let neg = FilmLUT.negativeDensity(color, stock: s)
            let plain = lum(FilmLUT.display(negative: neg, stock: s))
            XCTAssertLessThan(lum(FilmLUT.display(negative: neg, stock: s, controls: engine2)), plain, "engine 2 brightened \(color)")
            XCTAssertGreaterThan(lum(FilmLUT.display(negative: neg, stock: s, controls: engine1)), plain, "engine 1 changed for \(color)")
        }
    }

    func testSceneKeyIsPositiveAndFinite() throws {
        let key = try XCTUnwrap(FilmPipeline.sceneKey(of: testImage(), context: EditPipeline.context, source: .displayReferred))
        XCTAssertTrue(key.isFinite && key > 0)
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
