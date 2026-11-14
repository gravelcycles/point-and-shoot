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

    func testFreezingPinsTheCurrentTuningOnce() {
        var r = printRecipe
        XCTAssertNil(r.film?.tuning)
        r.freezeFilmTuning()
        XCTAssertEqual(r.film?.tuning, FilmStock.printLook)
        var older = FilmStock.printLook
        older.exposure += 1
        r.film?.tuning = older
        r.freezeFilmTuning()
        XCTAssertEqual(r.film?.tuning, older, "An already pinned tuning must never be replaced")

        var plain = EditRecipe()
        plain.freezeFilmTuning()
        XCTAssertNil(plain.film, "Non-film edits stay as they are")
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
        XCTAssertNil(r.film?.tuning, "Re-picking a look should use its current tuning")
    }
}
