import AVFoundation
import XCTest
@testable import PointAndShoot

/// Every combination of settings × hardware × burst × zoom through the capture planner.
/// AVFoundation throws an uncatchable exception (instant crash) on invalid photo settings,
/// so these invariants are what keeps the shutter from crashing.
final class PhotoPlannerTests: XCTestCase {
    private func allSettings() -> [CameraSettings] {
        var out: [CameraSettings] = []
        for mode in [CaptureMode.photo, .print] {
            for processing in ProcessingLevel.allCases {
                for raw in RawMode.allCases {
                    for placement in PrintPlacement.allCases {
                        for look in [nil] + Look.all.map(\.id) {
                            for keep in [true, false] {
                                var s = CameraSettings()
                                s.mode = mode
                                s.processing = processing
                                s.rawMode = raw
                                s.printPlacement = placement
                                s.captureLook = look
                                s.keepProcessedWithRAW = keep
                                s.flash = keep ? .on : .off
                                s.resolution = keep ? .max : .standard
                                if mode == .print && placement == .filter { continue } // sanitized away
                                out.append(s)
                            }
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
                    let ctx = "\(s.mode) \(s.processing) raw=\(s.rawMode) look=\(s.captureLook ?? "-") burst=\(burst) caps=\(caps)"
                    checked += 1

                    if caps.zoomed {
                        XCTAssertNotEqual(d.raw, .bayer, "Bayer RAW while zoomed crashes: \(ctx)")
                    }
                    if d.raw == .bayer {
                        XCTAssertTrue(caps.bayerRAW, "Bayer RAW requested but unavailable: \(ctx)")
                        XCTAssertEqual(d.prioritization, .speed, "Bayer RAW must use .speed: \(ctx)")
                        XCTAssertTrue(d.standardDimensions, "Bayer RAW must be 12 MP: \(ctx)")
                        // The UI must have locked zoom for any mode that ends up shooting Bayer.
                        XCTAssertTrue(s.zoomLocked, "Shoots Bayer RAW but zoom isn't locked: \(ctx)")
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
                    if d.zeroDevelop {
                        XCTAssertEqual(d.raw, .bayer, "We can only develop a Bayer DNG: \(ctx)")
                        XCTAssertFalse(d.withProcessed, "Zero/film develops ask for RAW only: \(ctx)")
                    }
                    if d.raw == .none {
                        XCTAssertTrue(d.withProcessed, "Without RAW there must be a processed photo: \(ctx)")
                        if s.developsBayerRAW && !burst {
                            XCTAssertNotNil(d.fallbackNote, "Falling back from Zero/Print must say so: \(ctx)")
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 1000)
    }

    func testPrintModeShootsBayerAndKeepsTheDNG() {
        var s = CameraSettings()
        s.mode = .print
        let d = PhotoPlanner.decide(s, burst: false, caps: .init())
        XCTAssertEqual(d.raw, .bayer)
        XCTAssertTrue(d.zeroDevelop)
        XCTAssertTrue(d.storeRAW, "Print's edit re-develops from the DNG")
        XCTAssertFalse(d.withProcessed)
    }

    func testZoomedPrintFallsBackToProcessedWithANote() {
        var s = CameraSettings()
        s.mode = .print
        let d = PhotoPlanner.decide(s, burst: false, caps: .init(zoomed: true))
        XCTAssertEqual(d.raw, .none)
        XCTAssertNotNil(d.fallbackNote)
    }

    func testPlainPhotoIsProcessedOnly() {
        let d = PhotoPlanner.decide(CameraSettings(), burst: false, caps: .init())
        XCTAssertEqual(d.raw, .none)
        XCTAssertTrue(d.withProcessed)
        XCTAssertTrue(d.heif)
        XCTAssertNil(d.fallbackNote)
    }

    func testProRAWWithAndWithoutCompanion() {
        var s = CameraSettings()
        s.rawMode = .proRAW
        s.keepProcessedWithRAW = true
        XCTAssertEqual(PhotoPlanner.decide(s, burst: false, caps: .init()).raw, .proRAW)
        XCTAssertTrue(PhotoPlanner.decide(s, burst: false, caps: .init()).withProcessed)
        s.keepProcessedWithRAW = false
        XCTAssertFalse(PhotoPlanner.decide(s, burst: false, caps: .init()).withProcessed)
    }
}
