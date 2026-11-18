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

    // MARK: Retired looks

    /// The filters replaced by the looks keep rendering exactly as they were made:
    /// pinned tuning first, else the frozen history, never Print or a current look.
    func testRetiredLooksStillRenderWithTheirOwnTuning() throws {
        for (id, entry) in Look.retired {
            XCTAssertNil(FilmStock.all[id], "\(id) is retired but still offered")
            let shipped = try XCTUnwrap(FilmStock.Legacy.v2[id], "\(id) missing from the frozen history")
            var unpinned = EditRecipe()
            unpinned.look = id
            unpinned.film = FilmRecipe(stock: id, tuning: nil, engine: nil)
            XCTAssertEqual(FilmStock.resolved(for: unpinned), shipped, id)
            XCTAssertEqual(FilmStock.namedOrRetired(id), shipped, id)
            XCTAssertEqual(Look.displayName(id), entry.name, "the editor should still name \(id)")
        }
    }

    func testRetiredPinnedTuningMissingAFieldFillsFromItsOwnStock() throws {
        var r = EditRecipe()
        r.look = "cine"
        r.film = FilmRecipe(stock: "cine", tuning: FilmStock.Legacy.v2["cine"], engine: 1)
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any])
        var film = try XCTUnwrap(obj["film"] as? [String: Any])
        var tuning = try XCTUnwrap(film["tuning"] as? [String: Any])
        tuning.removeValue(forKey: "shadowTint")      // as if pinned before the field existed
        film["tuning"] = tuning
        obj["film"] = film
        let reopened = try XCTUnwrap(EditRecipe.decodeSaved(try JSONSerialization.data(withJSONObject: obj)))
        XCTAssertEqual(reopened.film?.tuning, FilmStock.Legacy.v2["cine"],
                       "A retired look's missing field must come from that look, not from Print")
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

    /// Hue twists and dye saturation came after tunings were pinned. A tuning pinned before
    /// them reopens *without* them (never filled in from today's stock of the same id),
    /// so the photo renders exactly as it was made.
    func testPinnedTuningFromBeforeHueTwistsReopensWithoutThem() throws {
        let r = try XCTUnwrap(Look.named("blockbuster")).recipe
        XCTAssertNotNil(r.film?.tuning?.hueTwists, "Blockbuster should use hue twists")
        XCTAssertNotNil(r.film?.tuning?.dyeSaturation, "Blockbuster should use dye saturation")
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any])
        var film = try XCTUnwrap(obj["film"] as? [String: Any])
        var tuning = try XCTUnwrap(film["tuning"] as? [String: Any])
        // Hard-coded, not FilmStock.offWhenMissing: forgetting a field there must fail here.
        XCTAssertTrue(Set(FilmStock.offWhenMissing).isSuperset(of: ["hueTwists", "dyeSaturation"]))
        for key in ["hueTwists", "dyeSaturation"] { tuning.removeValue(forKey: key) }
        film["tuning"] = tuning
        obj["film"] = film
        let reopened = try XCTUnwrap(EditRecipe.decodeSaved(try JSONSerialization.data(withJSONObject: obj)))
        XCTAssertNotNil(reopened.film?.tuning, "the older tuning made the edit unreadable")
        XCTAssertNil(reopened.film?.tuning?.hueTwists, "hue twists were filled in from today's stock")
        XCTAssertNil(reopened.film?.tuning?.dyeSaturation, "dye saturation was filled in from today's stock")
        // ...while a tuning that has them keeps them through a save.
        let saved = try XCTUnwrap(EditRecipe.decodeSaved(try JSONEncoder().encode(r)))
        XCTAssertEqual(saved.film?.tuning, r.film?.tuning)
    }

    /// Engine 4 changes only how far Highlights and Shadows go: at 0 it renders exactly like
    /// engine 3; with them moved it goes about twice as far; engine 3 photos keep theirs.
    func testEngineFourMakesHighlightsAndShadowsGoFurther() {
        XCTAssertEqual(FilmRecipe.currentEngine, 4)
        var r = printRecipe
        XCTAssertEqual(r.film?.engine, 4, "new looks pin engine 4")
        var engine3 = r
        engine3.film?.engine = 3
        XCTAssertLessThan(maxDiff(pixels(engine3), pixels(r)), 1e-4, "engine 4 must render like engine 3 at 0")
        func mean(_ recipe: EditRecipe) -> Float {
            let p = pixels(recipe); var sum: Float = 0
            for i in stride(from: 0, to: p.count, by: 4) { sum += 0.2126 * p[i] + 0.7152 * p[i + 1] + 0.0722 * p[i + 2] }
            return sum / Float(p.count / 4)
        }
        let base = mean(r)
        for (h, s) in [(100.0, 0.0), (-100.0, 0.0), (0.0, 100.0), (0.0, -100.0)] {
            var a = r, b = engine3
            a.highlights = h; a.shadows = s; b.highlights = h; b.shadows = s
            let four = mean(a) - base, three = mean(b) - base
            XCTAssertEqual(four.sign, three.sign, "same direction (h \(h), s \(s))")
            XCTAssertGreaterThan(abs(four), abs(three) * 1.3, "engine 4 goes further (h \(h), s \(s)): \(four) vs \(three)")
        }
    }

    /// Stronger Highlights/Shadows must never fold the tone curve back into visible halos or
    /// banding: every look's grey ramp, at the sliders' extremes, never dips by more than
    /// 0.5% (a fraction of one 8-bit step) wherever it's visible (above 1/255).
    /// Where one dye hits its floor before the others (Pastel's blue, in the deep shadows)
    /// the lift, keyed on mean density, can outpace the others for a moment: at most 0.16%
    /// there, ~1/20 of an 8-bit step, and engine 3 has the same shape, smaller.
    func testStrongToneKeepsEveryGreyRampMonotonic() {
        var worst = 1.0, worstAt = ""
        defer { print("strong tone: worst grey-ramp step ratio \(worst) (\(worstAt))") }
        for stock in FilmStock.all.values {
            for h in [-1.0, 0, 1] {
                for s in [-1.0, 0, 1] {
                    let c = FilmControls(highlights: h, shadows: s, subtractiveSaturation: true, strongTone: true)
                    var last = -1.0
                    for i in 0...600 {
                        let v = FilmLUT.neutralResponse(stops: -8 + Double(i) * 0.025, stock: stock, controls: c)
                        let y = 0.2290 * v.0 + 0.6917 * v.1 + 0.0793 * v.2
                        if y > 1.0 / 255 && last > 1.0 / 255 {
                            if y / last < worst { worst = y / last; worstAt = "\(stock.id) h \(h) s \(s)" }
                            XCTAssertGreaterThanOrEqual(y, last * (1 - 0.005), "\(stock.id) h \(h) s \(s) at \(-8 + Double(i) * 0.025) stops")
                        }
                        last = y
                    }
                }
            }
        }
    }

    /// Engine 3 changes only the Saturation slider: with it at 0, an engine-3 edit renders
    /// exactly like engine 2 (same un-render, same tables), and engine 2's slider keeps
    /// working as it did. Only edits from engine 3 get the subtractive slider.
    func testEngineThreeChangesOnlyTheSaturationSlider() {
        var r = printRecipe
        XCTAssertEqual(r.film?.engine, FilmRecipe.currentEngine)
        r.film?.engine = 3
        var engine2 = r
        engine2.film?.engine = 2
        XCTAssertLessThan(maxDiff(pixels(engine2), pixels(r)), 1e-4, "engine 3 must render like engine 2 at Saturation 0")
        r.saturation = 60
        engine2.saturation = 60
        XCTAssertGreaterThan(maxDiff(pixels(engine2), pixels(r)), 0.01, "engine 3's Saturation slider should differ")
        // ...and in the right direction: on a rich color, engine 3's slider is darker (dyes),
        // engine 2's brighter.
        func luminance(_ recipe: EditRecipe) -> Float {
            var rr = recipe
            rr.grain = 0
            let red = CIImage(color: CIColor(red: 0.8, green: 0.25, blue: 0.12)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
            let out = EditPipeline.apply(rr, to: red, developedFromRAW: false)
            let rect = CGRect(x: 0, y: 0, width: 8, height: 8)
            var px = [Float](repeating: 0, count: 8 * 8 * 4)
            EditPipeline.context.render(out.cropped(to: rect), toBitmap: &px, rowBytes: 8 * 16, bounds: rect,
                                        format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return 0.2126 * px[0] + 0.7152 * px[1] + 0.0722 * px[2]
        }
        XCTAssertLessThan(luminance(r), luminance(engine2), "engine 3's Saturation should darken a rich red")
        var unversioned = r
        unversioned.film?.engine = nil
        var engine1 = r
        engine1.film?.engine = 1
        XCTAssertLessThan(maxDiff(pixels(engine1), pixels(unversioned)), 1e-4, "no engine must render as engine 1")
    }

    func testPickingTheLookAgainMovesToTheNewestTuning() {
        var r = printRecipe
        var older = FilmStock.printLook
        older.exposure += 1
        r.film?.tuning = older
        Look.named(CameraSettings.printLookID)!.apply(&r)
        XCTAssertEqual(r.film?.tuning, FilmStock.printLook, "Re-picking a look should pin its current tuning")
    }

    /// Picking a film look leaves the develop exposure to the photo's RAW type (settled by
    /// `withFilmDevelopExposure`): natural for its scene light and RAW type.
    func testFilmLooksLeaveTheRAWExposureToThePhoto() {
        for look in Look.all { XCTAssertNil(look.recipe.rawFilmExposure, "\(look.id)") }
        XCTAssertEqual(printRecipe.withFilmDevelopExposure(hasRAW: true, bayer: false, ev100: 10).rawFilmExposure, 1.63)
        XCTAssertEqual(printRecipe.withFilmDevelopExposure(hasRAW: true, bayer: true, ev100: 10).rawFilmExposure, 1.0)
        // A photo's value (a viewfinder match, an older pin) stays until the look is picked
        // again, which leaves it to the RAW type again.
        var older = printRecipe
        older.rawFilmExposure = 2.31
        var edited = older
        edited.resetTone()
        XCTAssertEqual(edited.rawFilmExposure, 2.31, "Resetting tone keeps the photo's develop exposure")
        Look.named(CameraSettings.printLookID)!.apply(&edited)
        XCTAssertNil(edited.rawFilmExposure)
        // Pasting a film look leaves it to the target's RAW; pasting a plain one keeps it.
        var target = EditRecipe()
        target.rawFilmExposure = 0.5
        XCTAssertNil(printRecipe.look(appliedTo: target).rawFilmExposure)
        XCTAssertEqual(EditRecipe().look(appliedTo: target).rawFilmExposure, 0.5)
    }
}
