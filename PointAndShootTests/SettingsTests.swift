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
        XCTAssertFalse(s.zoomLocked, "ProRAW (the default) zooms")
        s.mode = .print
        XCTAssertFalse(s.zoomLocked, "Print on ProRAW zooms")
        s.rawMode = .bayer
        XCTAssertTrue(s.zoomLocked, "Bayer RAW can't be zoomed")
        s.mode = .photo
        XCTAssertTrue(s.zoomLocked)
        s.mode = .video
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
        s.captureLook = "cine"
        s.flash = .auto
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(CameraSettings.decodeSaved(data), s)
    }
}
