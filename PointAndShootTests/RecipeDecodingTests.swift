import XCTest
@testable import PointAndShoot

/// Edits are stored in Photos as JSON and reopened by later app versions. A recipe that
/// fails to decode silently loses every slider, so every field must be optional in
/// practice: missing keys take defaults, unknown keys are ignored.
final class RecipeDecodingTests: XCTestCase {
    /// A recipe with every optional field set, so every key appears in its JSON.
    private func fullRecipe() -> EditRecipe {
        var r = EditRecipe()
        r.exposure = 12
        r.look = "cine"
        r.mixer = Array(repeating: 5, count: ColorBand.allCases.count * 3)
        r.film = FilmRecipe(stock: "print", halation: 70, crossover: -20)
        r.rawFilmExposure = 0.7
        r.crop = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.7)
        return r
    }

    private func object(_ r: EditRecipe) throws -> [String: Any] {
        let data = try JSONEncoder().encode(r)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testRoundTrip() throws {
        let r = fullRecipe()
        XCTAssertEqual(EditRecipe.decodeSaved(try JSONEncoder().encode(r)), r)
    }

    func testEveryFieldCanBeMissingFromOldEdits() throws {
        let full = try object(fullRecipe())
        for key in full.keys.sorted() {
            var old = full
            old.removeValue(forKey: key)
            let data = try JSONSerialization.data(withJSONObject: old)
            XCTAssertNotNil(EditRecipe.decodeSaved(data), "An edit saved without '\(key)' no longer opens")
        }
    }

    func testFilmFieldsCanBeMissing() throws {
        var full = try object(fullRecipe())
        full["film"] = ["stock": "print"]   // halation / crossover added later
        let data = try JSONSerialization.data(withJSONObject: full)
        let r = try XCTUnwrap(EditRecipe.decodeSaved(data))
        XCTAssertEqual(r.film?.halation, FilmRecipe().halation)
        XCTAssertEqual(r.film?.stock, "print")
    }

    func testMinimalLegacyEditAndUnknownKeys() throws {
        let data = Data(#"{"exposure": 30, "someFutureField": [1, 2, 3]}"#.utf8)
        let r = try XCTUnwrap(EditRecipe.decodeSaved(data))
        XCTAssertEqual(r.exposure, 30)
        XCTAssertNil(r.film)
        XCTAssertEqual(r.rawNoiseReduction, EditRecipe().rawNoiseReduction)
    }

    func testEveryLookProducesARecipeThatRoundTrips() throws {
        for look in Look.all {
            let r = look.recipe
            let decoded = EditRecipe.decodeSaved(try JSONEncoder().encode(r))
            XCTAssertEqual(decoded, r, "Look \(look.id) doesn't round-trip")
        }
    }
}
