import CoreImage
import XCTest
@testable import PointAndShoot

/// A photo keeps the film tuning it was rendered with: tuning Print in code later must not
/// change older Print photos, even when they're reopened and re-saved in the editor.
final class FrozenTuningTests: XCTestCase {
    private func image() -> CIImage {
        CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 64, y: 48),
            "inputColor0": CIColor(red: 0.05, green: 0.05, blue: 0.08),
            "inputColor1": CIColor(red: 0.95, green: 0.8, blue: 0.6),
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
    }

    private func pixels(_ recipe: EditRecipe) -> [Float] {
        var r = recipe
        r.grain = 0   // grain is random; compare tone and colour only
        let out = EditPipeline.apply(r, to: image(), developedFromRAW: false)
        let rect = CGRect(x: 0, y: 0, width: 64, height: 48)
        var buf = [Float](repeating: 0, count: 64 * 48 * 4)
        EditPipeline.context.render(out.cropped(to: rect), toBitmap: &buf, rowBytes: 64 * 16, bounds: rect,
                                    format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return buf
    }

    private func maxDiff(_ a: [Float], _ b: [Float]) -> Float {
        var m: Float = 0
        for i in 0..<min(a.count, b.count) { m = max(m, abs(a[i] - b[i])) }
        return m
    }

    private var printRecipe: EditRecipe { Look.named(CameraSettings.printLookID)!.recipe }

    func testStockTuningRoundTripsThroughJSON() throws {
        for stock in FilmStock.all.values {
            let data = try JSONEncoder().encode(stock)
            XCTAssertEqual(try JSONDecoder().decode(FilmStock.self, from: data), stock, stock.id)
            XCTAssertLessThan(data.count, 20_000, "\(stock.id): tuning is \(data.count) bytes")
        }
    }

    func testPickingALookPinsItsCurrentTuning() {
        for look in Look.all {
            let r = look.recipe
            guard let film = r.film else { continue }
            XCTAssertEqual(film.tuning, FilmStock.named(film.stock), "\(look.id): tuning not pinned at pick time")
            XCTAssertEqual(film.engine, FilmRecipe.currentEngine)
        }
    }

    func testFreezingNeverReplacesAPinnedTuning() {
        var r = printRecipe
        var older = FilmStock.printLook
        older.exposure += 1
        r.film?.tuning = older
        r.freezeFilmTuning()
        XCTAssertEqual(r.film?.tuning, older, "An already pinned tuning must never be replaced")

        var plain = EditRecipe()
        plain.freezeFilmTuning()
        XCTAssertNil(plain.film, "Non-film edits stay as they are")
    }

    // MARK: Photos taken before tunings were pinned

    /// A Print edit as the first Print build (#9) saved it: no stock id, no tuning, 15% NR.
    private var printV1Edit: EditRecipe {
        var r = printRecipe
        r.film = FilmRecipe(stock: nil, tuning: nil, engine: nil, halation: 50, crossover: 0)
        r.rawNoiseReduction = 15
        r.rawInitialized = true
        return r
    }

    /// A Print edit as #20–#27 saved it: still no stock id or tuning, NR floored at 50.
    private var printV2Edit: EditRecipe {
        var r = printV1Edit
        r.rawNoiseReduction = 62
        return r
    }

    func testPrintFromTheFirstBuildResolvesToPrintAsItShipped() throws {
        let stock = try XCTUnwrap(FilmStock.resolved(for: printV1Edit))
        XCTAssertEqual(stock, FilmStock.Legacy.printV1)
        XCTAssertEqual(stock.grainDensity, 0.012, "#9 shipped Print with 0.012 D grain")
    }

    func testPrintFromAfterTheGrainFixResolvesToThatPrint() throws {
        let stock = try XCTUnwrap(FilmStock.resolved(for: printV2Edit))
        XCTAssertEqual(stock, FilmStock.Legacy.v2["print"])
        XCTAssertEqual(stock.grainDensity, 0.008, "#20 shipped Print with 0.008 D grain")
    }

    func testStockEditsFromBeforePinningResolveToTheStocksAsShipped() {
        for id in FilmStock.Legacy.v2.keys {
            var r = EditRecipe()
            r.film = FilmRecipe(stock: id, tuning: nil, engine: nil)
            XCTAssertEqual(FilmStock.resolved(for: r), FilmStock.Legacy.v2[id], id)
        }
        // Stocks added after pinning (Phromagraph) were always pinned; an unpinned one
        // falls back to the stock as it is now.
        for id in FilmStock.all.keys where FilmStock.Legacy.v2[id] == nil {
            var r = EditRecipe()
            r.film = FilmRecipe(stock: id, tuning: nil, engine: nil)
            XCTAssertEqual(FilmStock.resolved(for: r), FilmStock.named(id), id)
        }
    }

    func testSavingAnOlderEditPinsTheTuningItWasMadeWith() {
        var r = printV1Edit
        r.freezeFilmTuning()
        XCTAssertEqual(r.film?.tuning, FilmStock.Legacy.printV1, "Re-saving must keep its original look")
    }

    /// The frozen history must never change: it's what older photos re-render with.
    func testFrozenHistoryIsUntouched() {
        func fnv(_ s: String) -> UInt64 {
            var h: UInt64 = 0xcbf29ce484222325
            for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
            return h
        }
        XCTAssertEqual(fnv(FilmStock.Legacy.printV1JSON), FilmStock.Legacy.printV1Fingerprint,
                       "FilmStock+Legacy.swift was edited: older Print photos would change")
        XCTAssertEqual(fnv(FilmStock.Legacy.v2JSON), FilmStock.Legacy.v2Fingerprint,
                       "FilmStock+Legacy.swift was edited: older filter photos would change")
        XCTAssertEqual(FilmStock.Legacy.v2.count, 12, "every stock that existed is in the history")
    }

    func testOlderPrintEditRendersWithItsOwnGrain() {
        // Same tone and colour as today's Print (only grain changed), so with grain off the
        // older edit renders the same as Print on the same engine; the stock it resolves to
        // carries the old grain.
        var engineOne = printRecipe
        engineOne.film?.engine = 1
        XCTAssertLessThan(maxDiff(pixels(printV1Edit), pixels(engineOne)), 1e-4)
    }

    // MARK: Engine 2 (display-referred un-render measured from Apple's rendering)

    func testUnversionedEditsRenderWithEngineOne() {
        XCTAssertEqual(printV1Edit.film?.renderEngine, 1)
        var r = printV1Edit
        r.freezeFilmTuning()
        XCTAssertEqual(r.film?.engine, 1, "Saving an edit from before versioning must keep engine 1's math")
        XCTAssertEqual(printRecipe.film?.engine, FilmRecipe.currentEngine, "New looks pin the current engine")
    }

    func testEngineOneUnrenderIsUnchanged() {
        // Engine 1's un-render, exactly as it shipped: display = 1.273·s / (1 + 0.808·s) on
        // luminance, channel ratios kept.
        for c in [(0.5, 0.4, 0.3), (0.9, 0.2, 0.1), (0.05, 0.06, 0.08), (1.0, 1.0, 1.0)] {
            let y = 0.2627 * c.0 + 0.6780 * c.1 + 0.0593 * c.2
            let k = min(y, 0.995) / (1.273 - 0.808 * min(y, 0.995)) / y
            let got = FilmLUT.sceneFromDisplay(rgb: c, engine: 1)
            XCTAssertEqual(got.0, c.0 * k, accuracy: 1e-12)
            XCTAssertEqual(got.1, c.1 * k, accuracy: 1e-12)
            XCTAssertEqual(got.2, c.2 * k, accuracy: 1e-12)
        }
    }

    func testEngineTwoUnrendersWithApplesCurveAndSaturation() {
        // Mid grey keeps its anchor (display 0.20 = scene 0.18) and stays neutral.
        let g = FilmLUT.sceneFromDisplay(rgb: (0.2, 0.2, 0.2), engine: 2)
        XCTAssertEqual(g.0, 0.18, accuracy: 1e-9)
        XCTAssertEqual(g.2, 0.18, accuracy: 1e-9)
        // Apple crushes shadows: a dark display value is far more scene light than engine 1
        // assumed (display 0.01: about −2.8 stops, not −4.5).
        let dark2 = FilmLUT.sceneFromDisplay(rgb: (0.01, 0.01, 0.01), engine: 2).1
        let dark1 = FilmLUT.sceneFromDisplay(rgb: (0.01, 0.01, 0.01), engine: 1).1
        XCTAssertGreaterThan(log2(dark2 / dark1), 1)
        // Near white sits about +3.5 stops over grey, where the RAW develop clips too.
        let w = FilmLUT.sceneFromDisplay(rgb: (0.95, 0.95, 0.95), engine: 2)
        XCTAssertEqual(log2(w.1 / 0.18), 3.45, accuracy: 0.15)
        // Apple's saturation is divided out: a display color comes back less saturated.
        let c = (0.4, 0.2, 0.1)
        let one = FilmLUT.sceneFromDisplay(rgb: c, engine: 1), two = FilmLUT.sceneFromDisplay(rgb: c, engine: 2)
        XCTAssertLessThan(two.0 / two.2, one.0 / one.2)
        // Monotone in brightness (up to display 0.995, where both engines clamp).
        var last = 0.0
        for i in 1...199 {
            let v = Double(i) / 200
            let s = FilmLUT.sceneFromDisplay(rgb: (v, v, v), engine: 2).1
            XCTAssertGreaterThan(s, last, "not monotone at \(v)")
            last = s
        }
    }

    func testProcessedPhotosRenderDifferentlyOnEngineTwo() {
        var engineOne = printRecipe
        engineOne.film?.engine = 1
        XCTAssertGreaterThan(maxDiff(pixels(printRecipe), pixels(engineOne)), 0.01, "Engine 2 had no effect")
    }

    /// Exposure on a processed photo used to scale display values before un-rendering, so
    /// +1 EV clipped everything above display 0.5 to the same white.
    func testExposureOnAProcessedPhotoNoLongerClipsHighlights() {
        let rect = CGRect(x: 0, y: 0, width: 2, height: 1)
        let bright = CIImage(color: CIColor(red: 0.75, green: 0.75, blue: 0.75)).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        let brighter = CIImage(color: CIColor(red: 0.95, green: 0.95, blue: 0.95)).cropped(to: CGRect(x: 1, y: 0, width: 1, height: 1))
        let img = brighter.composited(over: bright)
        func render(_ engine: Int) -> [Float] {
            var r = printRecipe
            r.grain = 0
            r.film?.halation = 0
            r.film?.engine = engine
            r.exposure = 50     // +1 EV
            let out = EditPipeline.apply(r, to: img, developedFromRAW: false)
            var buf = [Float](repeating: 0, count: 8)
            EditPipeline.context.render(out.cropped(to: rect), toBitmap: &buf, rowBytes: 32, bounds: rect,
                                        format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return buf
        }
        let one = render(1), two = render(2)
        XCTAssertLessThan(abs(one[1] - one[5]), 0.002, "Engine 1 clips both patches to the same white (as shipped)")
        XCTAssertGreaterThan(abs(two[1] - two[5]), 0.01, "Engine 2 keeps highlight detail under +1 EV")
    }

    func testPinnedTuningRendersExactlyLikeTheCurrentOne() {
        var pinned = printRecipe
        pinned.freezeFilmTuning()
        XCTAssertLessThan(maxDiff(pixels(pinned), pixels(printRecipe)), 1e-4)
    }

    func testAnOlderPinnedTuningRendersAsItWas() {
        let current = pixels(printRecipe)
        var older = FilmStock.printLook
        older.exposure += 1           // "Print as it was tuned back then"
        var r = printRecipe
        r.film?.tuning = older
        let old = pixels(r)
        XCTAssertGreaterThan(maxDiff(old, current), 0.02, "The pinned tuning was ignored")
        // ...and the shared table cache didn't leak the older tuning into current renders.
        XCTAssertLessThan(maxDiff(pixels(printRecipe), current), 1e-4, "Older tuning polluted the cache")
    }

    func testPinnedTuningSurvivesSavingAndReopening() throws {
        var r = printRecipe
        var older = FilmStock.printLook
        older.exposure -= 0.5
        r.film?.tuning = older
        let reopened = try XCTUnwrap(EditRecipe.decodeSaved(try JSONEncoder().encode(r)))
        XCTAssertEqual(reopened.film?.tuning, older)
    }

    func testPinnedTuningFromAnOlderAppStillOpens() throws {
        var r = printRecipe
        r.freezeFilmTuning()
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any])
        var film = try XCTUnwrap(obj["film"] as? [String: Any])
        var tuning = try XCTUnwrap(film["tuning"] as? [String: Any])
        tuning.removeValue(forKey: "shadowTint")      // a field stocks gained later
        tuning.removeValue(forKey: "huePreserve")
        film["tuning"] = tuning
        obj["film"] = film
        let reopened = try XCTUnwrap(EditRecipe.decodeSaved(try JSONSerialization.data(withJSONObject: obj)))
        XCTAssertNotNil(reopened.film?.tuning, "An older pinned tuning made the whole edit unreadable")
        XCTAssertEqual(reopened.film?.tuning?.exposure, FilmStock.printLook.exposure)
    }

    func testPickingTheLookAgainMovesToTheNewestTuning() {
        var r = printRecipe
        var older = FilmStock.printLook
        older.exposure += 1
        r.film?.tuning = older
        Look.named(CameraSettings.printLookID)!.apply(&r)
        XCTAssertEqual(r.film?.tuning, FilmStock.printLook, "Re-picking a look should pin its current tuning")
    }
}
