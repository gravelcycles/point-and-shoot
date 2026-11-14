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

    /// A Print edit saved by the first Print build (#9): no stock id, no tuning.
    private var printV1Edit: EditRecipe {
        var r = printRecipe
        r.film = FilmRecipe(stock: nil, halation: 50, crossover: 0, tuning: nil, engine: nil)
        return r
    }

    func testPrintFromBeforeStockIDsResolvesToPrintAsItShipped() {
        let stock = FilmStock.resolved(for: printV1Edit.film!)
        XCTAssertEqual(stock, FilmStock.Legacy.printV1)
        XCTAssertEqual(stock.grainDensity, 0.012, "#9 shipped Print with 0.012 D grain")
    }

    func testStockEditsFromBeforePinningResolveToTheStocksAsShipped() {
        for id in FilmStock.all.keys {
            let film = FilmRecipe(stock: id, tuning: nil, engine: nil)
            XCTAssertEqual(FilmStock.resolved(for: film), FilmStock.Legacy.v2[id], id)
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
        // older edit renders the same; the stock it resolves to carries the old grain.
        XCTAssertLessThan(maxDiff(pixels(printV1Edit), pixels(printRecipe)), 1e-4)
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
