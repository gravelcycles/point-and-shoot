import XCTest
@testable import PointAndShoot

/// Persisted settings: defaults, the zoom lock, and loading settings saved by any app
/// version (an update must never wipe someone's setup).
final class SettingsTests: XCTestCase {
    func testDefaults() {
        let s = CameraSettings()
        XCTAssertEqual(s.mode, .photo)
        XCTAssertFalse(s.shutterSound, "The shutter is silent by default")
        XCTAssertFalse(s.showHistogram, "The histogram is off by default")
        XCTAssertFalse(s.zoomLocked, "Photo mode with default settings can zoom")
        XCTAssertEqual(s.availableModes, [.photo, .print, .video])
    }

    func testZoomLockFollowsBayerRAW() {
        var s = CameraSettings()
        s.mode = .print
        XCTAssertTrue(s.zoomLocked, "Print shoots Bayer RAW")
        s.mode = .photo
        s.processing = .zero
        XCTAssertTrue(s.zoomLocked, "Zero shoots Bayer RAW")
        s.processing = .natural
        s.rawMode = .bayer
        XCTAssertTrue(s.zoomLocked, "RAW (Bayer) can't be zoomed")
        s.rawMode = .proRAW
        XCTAssertFalse(s.zoomLocked, "ProRAW zooms normally")
        s.mode = .video
        s.processing = .zero
        s.rawMode = .bayer
        XCTAssertFalse(s.zoomLocked, "Video always zooms")
    }

    func testPrintAsFilterLeavesTheModePicker() {
        var s = CameraSettings()
        s.printPlacement = .filter
        XCTAssertEqual(s.availableModes, [.photo, .video])
        XCTAssertTrue(s.filterLooks.contains { $0.id == CameraSettings.printLookID })
        s.printPlacement = .mode
        XCTAssertFalse(s.filterLooks.contains { $0.id == CameraSettings.printLookID })
    }

    // MARK: Saved settings from other app versions

    private func savedObject(_ s: CameraSettings = CameraSettings()) throws -> [String: Any] {
        let data = try JSONEncoder().encode(s)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testEverySettingCanBeMissingFromOldSaves() throws {
        let full = try savedObject()
        for key in full.keys.sorted() {
            var old = full
            old.removeValue(forKey: key)
            let data = try JSONSerialization.data(withJSONObject: old)
            XCTAssertNotNil(CameraSettings.decodeSaved(data), "Settings saved without '\(key)' no longer load")
        }
    }

    func testOldSaveKeepsChoicesAndIgnoresRemovedOptions() throws {
        var old = try savedObject()
        old["mode"] = "video"
        old["frameRate"] = 60
        old.removeValue(forKey: "shutterSound")      // added later
        old["proControls"] = true                    // removed in #14
        let data = try JSONSerialization.data(withJSONObject: old)
        let s = try XCTUnwrap(CameraSettings.decodeSaved(data))
        XCTAssertEqual(s.mode, .video)
        XCTAssertEqual(s.frameRate, 60)
        XCTAssertFalse(s.shutterSound)
    }

    func testRoundTrip() throws {
        var s = CameraSettings()
        s.rawMode = .proRAW
        s.captureLook = "blockbuster"
        s.flash = .auto
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(CameraSettings.decodeSaved(data), s)
    }

    /// The LOOK picker shows one named set of looks, or all of them; every look but
    /// Original is in a set, and the choice survives a save.
    func testLookSetsFilterThePicker() throws {
        var s = CameraSettings()
        XCTAssertNil(s.lookSet)
        let all = s.filterLooks
        XCTAssertEqual(all.count, Look.all.count - 2, "all looks but Original and Print (a mode)")
        for set in LookSet.allCases {
            XCTAssertFalse(set.looks.isEmpty, "\(set.name) is empty")
            s.lookSet = set.rawValue
            XCTAssertFalse(s.filterLooks.isEmpty)
            XCTAssertTrue(s.filterLooks.allSatisfy { $0.set == set }, set.name)
        }
        XCTAssertEqual(LookSet.allCases.map(\.looks.count).reduce(0, +), Look.all.count - 1,
                       "every look but Original is in exactly one set")
        s.lookSet = LookSet.movie.rawValue
        let decoded = try XCTUnwrap(CameraSettings.decodeSaved(try JSONEncoder().encode(s)))
        XCTAssertEqual(decoded.lookSet, LookSet.movie.rawValue)
        s.lookSet = "a-set-from-a-newer-app"
        XCTAssertEqual(s.filterLooks.count, all.count, "an unknown set shows every look")
    }

    /// A look that's no longer offered never stays the camera's choice: it moves to its
    /// successor, or to Original.
    func testRetiredLookMovesToItsSuccessorOrOff() throws {
        for (retired, expected) in [("chrome", "slide"), ("mono400", "noir"), ("silver", "noir"),
                                    ("cine", "blockbuster"), ("portrait", "portrait400"), ("cool", "evergreen"),
                                    ("warm400", nil), ("bogus", nil)] as [(String, String?)] {
            var s = CameraSettings()
            s.captureLook = retired
            let decoded = try XCTUnwrap(CameraSettings.decodeSaved(try JSONEncoder().encode(s)))
            XCTAssertEqual(decoded.captureLook, expected, retired)
            if let id = decoded.captureLook { XCTAssertNotNil(Look.named(id), "\(retired) → \(id) isn't offered") }
        }
        for (id, entry) in Look.retired {
            XCTAssertNil(Look.named(id), "\(id) is offered again: take it out of Look.retired")
            if let next = entry.successor { XCTAssertNotNil(Look.named(next), "\(id)'s successor \(next) isn't offered") }
        }
    }
}
