import AVFoundation
import XCTest
@testable import PointAndShoot

/// Every combination of settings × hardware × burst × zoom through the capture planner.
/// AVFoundation throws an uncatchable exception (instant crash) on invalid photo settings,
/// so these invariants are what keeps the shutter from crashing.
final class PhotoPlannerTests: XCTestCase {
    private func allSettings() -> [CameraSettings] {
        var out: [CameraSettings] = []
        for proRAWAvailable in [true, false] {
            for processing in ProcessingLevel.allCases {
                for raw in RawMode.allCases {
                    for look in [nil, Look.printID] + Look.all.map(\.id) {
                        for keep in [true, false] {
                            var s = CameraSettings()
                            s.proRAWAvailable = proRAWAvailable
                            s.processing = processing
                            s.rawMode = raw
                            s.captureLook = look
                            s.keepProcessedWithRAW = keep
                            s.flash = keep ? .on : .off
                            s.resolution = keep ? .max : .standard
                            out.append(s)
                        }
                    }
                }
            }
        }
        return out
    }

    private func allCaps() -> [PhotoPlanner.Capabilities] {
        var out: [PhotoPlanner.Capabilities] = []
        for zoomed in [false, true] {
            for bayer in [false, true] {
                for proRAW in [false, true] {
                    out.append(.init(bayerRAW: bayer, proRAW: proRAW, hevc: true, flash: true, zoomed: zoomed))
                }
            }
        }
        return out
    }

    func testInvariantsHoldForEveryCombination() {
        var checked = 0
        for s in allSettings() {
            for caps in allCaps() {
                for burst in [false, true] {
                    let d = PhotoPlanner.decide(s, burst: burst, caps: caps)
                    let ctx = "proRAWAvailable=\(s.proRAWAvailable) \(s.processing) raw=\(s.rawMode) look=\(s.captureLook ?? "-") burst=\(burst) caps=\(caps)"
                    checked += 1

                    if caps.zoomed {
                        XCTAssertNotEqual(d.raw, .bayer, "Bayer RAW while zoomed crashes: \(ctx)")
                    }
                    if d.raw == .bayer {
                        XCTAssertTrue(caps.bayerRAW, "Bayer RAW requested but unavailable: \(ctx)")
                        XCTAssertEqual(d.prioritization, .speed, "Bayer RAW must use .speed: \(ctx)")
                        XCTAssertTrue(d.standardDimensions, "Bayer RAW must be 12 MP: \(ctx)")
                    }
                    if d.raw == .proRAW {
                        XCTAssertTrue(caps.proRAW, "ProRAW requested but unavailable: \(ctx)")
                    }
                    if burst {
                        XCTAssertEqual(d.raw, .none, "Bursts skip RAW: \(ctx)")
                        XCTAssertFalse(d.flash, "Bursts never flash: \(ctx)")
                        XCTAssertEqual(d.prioritization, .speed, "Bursts use .speed: \(ctx)")
                        XCTAssertTrue(d.standardDimensions, "Bursts are 12 MP: \(ctx)")
                    }
                    if !burst {
                        // RAW only: a processed photo only when the lens has no RAW at all.
                        // RAW it can shoot right now: ProRAW, or Bayer at 1×.
                        if caps.proRAW || (caps.bayerRAW && !caps.zoomed) {
                            XCTAssertNotEqual(d.raw, .none, "Every photo is a RAW: \(ctx)")
                        } else {
                            XCTAssertEqual(d.raw, .none, ctx)
                            XCTAssertNotNil(d.fallbackNote, "Falling back to a processed photo must say so: \(ctx)")
                        }
                        if s.shootsProRAW && caps.proRAW {
                            XCTAssertEqual(d.raw, .proRAW, "ProRAW chosen and available: \(ctx)")
                        }
                        if !s.proRAWAvailable && caps.bayerRAW && !caps.zoomed {
                            XCTAssertEqual(d.raw, .bayer, "No ProRAW on the phone: Bayer RAW: \(ctx)")
                            XCTAssertNil(d.fallbackNote, "Bayer is the phone's RAW, not a fallback: \(ctx)")
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 1000)
    }

    func testDefaultShootsProRAW() {
        let s = CameraSettings()
        XCTAssertTrue(s.shootsProRAW)
        XCTAssertFalse(s.zoomLocked, "ProRAW zooms")
        let d = PhotoPlanner.decide(s, burst: false, caps: .init())
        XCTAssertEqual(d.raw, .proRAW)
        XCTAssertNil(d.fallbackNote)
    }

    func testBayerWhenChosen() {
        var s = CameraSettings()
        s.rawMode = .bayer
        XCTAssertTrue(s.zoomLocked, "Bayer RAW can't be zoomed")
        let d = PhotoPlanner.decide(s, burst: false, caps: .init())
        XCTAssertEqual(d.raw, .bayer)
        XCTAssertEqual(d.prioritization, .speed)
        XCTAssertTrue(d.standardDimensions)
    }

    /// A phone without ProRAW (not an iPhone Pro): every shot is Bayer RAW, with no toast,
    /// and zoom is locked like any Bayer RAW (so it's never zoomed).
    func testNoProRAWOnThePhoneShootsBayerWithoutANote() {
        var s = CameraSettings()
        s.proRAWAvailable = false
        XCTAssertTrue(s.zoomLocked)
        let d = PhotoPlanner.decide(s, burst: false, caps: .init(proRAW: false))
        XCTAssertEqual(d.raw, .bayer)
        XCTAssertNil(d.fallbackNote, "no toast on every shot")
        XCTAssertEqual(d.prioritization, .speed)
        XCTAssertTrue(d.standardDimensions)
    }

    func testNoProRAWOnThisLensFallsBackToBayerWithANote() {
        let d = PhotoPlanner.decide(CameraSettings(), burst: false, caps: .init(proRAW: false))
        XCTAssertEqual(d.raw, .bayer)
        XCTAssertNotNil(d.fallbackNote)
    }

    func testZoomedBayerFallsBackToProRAWWithANote() {
        var s = CameraSettings()
        s.rawMode = .bayer
        let d = PhotoPlanner.decide(s, burst: false, caps: .init(zoomed: true))
        XCTAssertEqual(d.raw, .proRAW)
        XCTAssertNotNil(d.fallbackNote)
    }

    func testZoomedWithOnlyBayerFallsBackToProcessed() {
        let d = PhotoPlanner.decide(CameraSettings(), burst: false, caps: .init(proRAW: false, zoomed: true))
        XCTAssertEqual(d.raw, .none, "Bayer RAW while zoomed crashes")
        XCTAssertNotNil(d.fallbackNote)
    }

    func testNoRAWAtAllFallsBackToProcessed() {
        let d = PhotoPlanner.decide(CameraSettings(), burst: false, caps: .init(bayerRAW: false, proRAW: false))
        XCTAssertEqual(d.raw, .none)
        XCTAssertNotNil(d.fallbackNote)
    }

    func testProRAWResolution() {
        var s = CameraSettings()
        s.resolution = .max
        XCTAssertFalse(PhotoPlanner.decide(s, burst: false, caps: .init()).standardDimensions)
        s.resolution = .standard
        XCTAssertTrue(PhotoPlanner.decide(s, burst: false, caps: .init()).standardDimensions)
    }
}
