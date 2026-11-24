import XCTest
@testable import PointAndShoot

/// The viewfinder predicts the RAW-developed photo: its correction follows the scene's
/// light (the meter), never the photo's inputs, and doesn't move with manual controls.
final class ViewfinderMatchTests: XCTestCase {
    func testEV100FromSettings() throws {
        // f/2, 1/125 s, ISO 100 = EV 9 (log2(4 × 125) ≈ 8.97); doubling ISO lowers it a stop.
        let a = try XCTUnwrap(ViewfinderMatch.meteredEV100(aperture: 2, seconds: 1.0 / 125, iso: 100, targetOffset: 0, targetBias: 0))
        XCTAssertEqual(a, log2(4 * 125.0), accuracy: 1e-9)
        let b = try XCTUnwrap(ViewfinderMatch.meteredEV100(aperture: 2, seconds: 1.0 / 125, iso: 200, targetOffset: 0, targetBias: 0))
        XCTAssertEqual(a - b, 1, accuracy: 1e-9)
        XCTAssertNil(ViewfinderMatch.meteredEV100(aperture: 2, seconds: 0, iso: 100, targetOffset: 0, targetBias: 0))
        XCTAssertNil(ViewfinderMatch.meteredEV100(aperture: 2, seconds: .nan, iso: 100, targetOffset: 0, targetBias: 0))
    }

    /// Manual ISO / shutter: exposing a stop under moves the meter's offset by −1, so the
    /// scene's light (and the correction) stays put. The viewfinder itself gets a stop
    /// darker, exactly like the RAW.
    func testManualExposureDoesNotMoveTheSceneReading() throws {
        let metered = try XCTUnwrap(ViewfinderMatch.meteredEV100(aperture: 1.6, seconds: 1.0 / 60, iso: 400, targetOffset: 0, targetBias: 0))
        let fasterShutter = try XCTUnwrap(ViewfinderMatch.meteredEV100(aperture: 1.6, seconds: 1.0 / 120, iso: 400, targetOffset: -1, targetBias: 0))
        let lowerISO = try XCTUnwrap(ViewfinderMatch.meteredEV100(aperture: 1.6, seconds: 1.0 / 60, iso: 200, targetOffset: -1, targetBias: 0))
        XCTAssertEqual(fasterShutter, metered, accuracy: 1e-9)
        XCTAssertEqual(lowerISO, metered, accuracy: 1e-9)
    }

    /// EV compensation in auto: auto-exposure lands on the biased target (offset ≈ 0), a
    /// stop under the meter; the scene reading stays the same.
    func testEVCompensationDoesNotMoveTheSceneReading() throws {
        let metered = try XCTUnwrap(ViewfinderMatch.meteredEV100(aperture: 1.6, seconds: 1.0 / 60, iso: 400, targetOffset: 0, targetBias: 0))
        let minusOne = try XCTUnwrap(ViewfinderMatch.meteredEV100(aperture: 1.6, seconds: 1.0 / 120, iso: 400, targetOffset: 0, targetBias: -1))
        XCTAssertEqual(minusOne, metered, accuracy: 1e-9)
    }

    /// The photo follows Apple's per-scene brightness (a touch under), so the preview only
    /// needs that touch (−0.2), and comes down with the photo where it's capped.
    func testCorrectionIsTheNaturalBiasUpToTheCap() {
        for ev in stride(from: 3.0, through: 11.5, by: 0.5) {
            XCTAssertEqual(ViewfinderMatch.correction(ev100: ev), EditRecipe.naturalBias, accuracy: 1e-9, "EV \(ev)")
        }
        // Brighter scenes stop at the cap (+1.86); Apple's rendering keeps getting brighter,
        // so the preview comes down with the photo.
        XCTAssertLessThan(ViewfinderMatch.correction(ev100: 14), EditRecipe.naturalBias)
        XCTAssertEqual(ViewfinderMatch.correction(ev100: 14),
                       EditRecipe.brightestFilmExposure - EditRecipe.appleMatchedExposure(ev100: 14), accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(ViewfinderMatch.correction(ev100: 40), -ViewfinderMatch.maxCorrection)
        XCTAssertLessThanOrEqual(ViewfinderMatch.correction(ev100: -10), ViewfinderMatch.maxCorrection)
    }

    func testCorrectionMovesInStepsWithoutFlicker() {
        let step = ViewfinderMatch.step
        XCTAssertEqual(ViewfinderMatch.stepped(0.1, current: 0), 0, "within the dead band: stays")
        XCTAssertEqual(ViewfinderMatch.stepped(0.2, current: 0), step, accuracy: 1e-12)
        XCTAssertEqual(ViewfinderMatch.stepped(0.55, current: 0), 3 * step, accuracy: 1e-12)
        // Hovering around a step's edges (half a step either side) doesn't toggle it.
        XCTAssertEqual(ViewfinderMatch.stepped(step * 1.45, current: step), step)
        XCTAssertEqual(ViewfinderMatch.stepped(step * 0.55, current: step), step)
        XCTAssertEqual(ViewfinderMatch.stepped(step * 1.8, current: step), 2 * step, accuracy: 1e-12)
    }

    // MARK: Old photos develop at the fixed exposure

    /// Natural brightness from the photo's own settings: dim scenes darker, bright ones
    /// brighter (Apple's measured behaviour), a touch under Apple, and a Bayer RAW darker by
    /// the amount it develops brighter, so both look the same.
    func testNaturalExposureFollowsTheScenesLight() {
        let dim = EditRecipe.filmRAWExposure(bayer: false, ev100: 3.4)     // the owner's bunk-bed room
        let room = EditRecipe.filmRAWExposure(bayer: false, ev100: 10)
        let sun = EditRecipe.filmRAWExposure(bayer: false, ev100: 15)
        XCTAssertEqual(room, 1.63, accuracy: 1e-9)
        XCTAssertLessThan(dim, 1.0, "a dim room isn't lifted to Chromagraph's +1.86")
        XCTAssertGreaterThan(dim, 0.5)
        XCTAssertEqual(sun, EditRecipe.brightestFilmExposure, "never brighter than Chromagraph")
        XCTAssertLessThan(dim, room); XCTAssertLessThan(room, sun)
        XCTAssertEqual(EditRecipe.filmRAWExposure(bayer: false, ev100: 30), sun, "clamped to the measured range")
        XCTAssertEqual(EditRecipe.filmRAWExposure(bayer: false, ev100: nil), room, "no metadata: EV 10")
        XCTAssertEqual(EditRecipe.filmRAWExposure(bayer: true, ev100: 10), room - EditRecipe.bayerScale, accuracy: 1e-9)
    }

    func testFilmPhotoWithoutADevelopExposureGetsTheNaturalOne() {
        var r = Look.printLook.recipe
        r.rawFilmExposure = nil                       // as saved before 2026-11-14, or a fresh pick
        XCTAssertEqual(r.withFilmDevelopExposure(hasRAW: true, bayer: false, ev100: 10).rawFilmExposure, 1.63)
        XCTAssertEqual(r.withFilmDevelopExposure(hasRAW: true, bayer: true, ev100: 10).rawFilmExposure, 1.0)
        XCTAssertNil(r.withFilmDevelopExposure(hasRAW: false, bayer: false, ev100: 10).rawFilmExposure, "no RAW, nothing to develop")
        var processed = r
        processed.useRAW = false
        XCTAssertNil(processed.withFilmDevelopExposure(hasRAW: true, bayer: true, ev100: 10).rawFilmExposure)
        var matched = r
        matched.rawFilmExposure = 2.4                 // baked with a per-shot match (#22–#41)
        XCTAssertEqual(matched.withFilmDevelopExposure(hasRAW: true, bayer: true, ev100: 10).rawFilmExposure, 2.4, "never replaced")
        XCTAssertNil(EditRecipe().withFilmDevelopExposure(hasRAW: true, bayer: true, ev100: 10).rawFilmExposure, "not a film look")
        // Earlier builds' automatic values (#42's +1.86, #52's Bayer +0.54) move to natural.
        for earlier in EditRecipe.earlierFixedExposures {
            var old = r
            old.rawFilmExposure = earlier
            XCTAssertEqual(old.withFilmDevelopExposure(hasRAW: true, bayer: false, ev100: 3.4).rawFilmExposure,
                           (EditRecipe.filmRAWExposure(bayer: false, ev100: 3.4) * 100).rounded() / 100)
        }
    }

}
