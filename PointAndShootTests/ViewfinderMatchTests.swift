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

    func testCorrectionBrightensDimScenesAndDarkensBrightOnes() {
        // Measured: the viewfinder ran ~1 EV under the photo at night, ~0.5 over in sun.
        XCTAssertGreaterThan(ViewfinderMatch.correction(ev100: 4.7), 0.6)          // night street
        XCTAssertEqual(ViewfinderMatch.correction(ev100: 10), 0.03, accuracy: 1e-9)  // indoors / dusk
        XCTAssertLessThan(ViewfinderMatch.correction(ev100: 15), -0.5)              // bright sun
        // Never extrapolates far beyond the measured range.
        XCTAssertEqual(ViewfinderMatch.correction(ev100: -5), ViewfinderMatch.maxCorrection)
        XCTAssertEqual(ViewfinderMatch.correction(ev100: 25), -ViewfinderMatch.maxCorrection)
        var last = Double.infinity
        for ev in stride(from: 0.0, through: 20, by: 0.5) {
            let c = ViewfinderMatch.correction(ev100: ev)
            XCTAssertLessThanOrEqual(c, last)
            last = c
        }
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

    func testFilmPhotoWithoutADevelopExposureGetsTheFixedOneForItsRAW() {
        var r = Look.named(CameraSettings.printLookID)!.recipe
        r.rawFilmExposure = nil                       // as saved before 2026-11-14, or a fresh pick
        XCTAssertEqual(r.withFilmDevelopExposure(hasRAW: true, bayer: false).rawFilmExposure, EditRecipe.filmRAWExposure)
        XCTAssertEqual(r.withFilmDevelopExposure(hasRAW: true, bayer: true).rawFilmExposure, EditRecipe.filmBayerRAWExposure)
        XCTAssertNil(r.withFilmDevelopExposure(hasRAW: false, bayer: false).rawFilmExposure, "no RAW, nothing to develop")
        var processed = r
        processed.useRAW = false
        XCTAssertNil(processed.withFilmDevelopExposure(hasRAW: true, bayer: true).rawFilmExposure)
        var matched = r
        matched.rawFilmExposure = 2.4                 // baked with a per-shot match (#22–#41)
        XCTAssertEqual(matched.withFilmDevelopExposure(hasRAW: true, bayer: true).rawFilmExposure, 2.4, "never replaced")
        XCTAssertNil(EditRecipe().withFilmDevelopExposure(hasRAW: true, bayer: true).rawFilmExposure, "not a film look")
        // The shared +1.86 (until 2026-11-19) moves to the Bayer value only on a Bayer RAW.
        var shared = r
        shared.rawFilmExposure = EditRecipe.filmRAWExposure
        XCTAssertEqual(shared.withFilmDevelopExposure(hasRAW: true, bayer: true).rawFilmExposure, EditRecipe.filmBayerRAWExposure)
        XCTAssertEqual(shared.withFilmDevelopExposure(hasRAW: true, bayer: false).rawFilmExposure, EditRecipe.filmRAWExposure)
    }

    /// A Bayer photo develops darker than a ProRAW one, and the preview follows it.
    func testBayerRAWPreviewIsDarkerByTheMeasuredOffset() {
        for ev in [4.0, 10.0, 15.0] {
            XCTAssertEqual(ViewfinderMatch.correction(ev100: ev, bayer: true),
                           ViewfinderMatch.correction(ev100: ev) + ViewfinderMatch.bayerOffset, accuracy: 1e-12)
        }
        XCTAssertLessThan(ViewfinderMatch.bayerOffset, -0.5)
    }
}
