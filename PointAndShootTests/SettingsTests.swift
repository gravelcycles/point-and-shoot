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

    /// The photo output turns ProRAW on exactly when the settings say ProRAW (the default
    /// `.off` included); otherwise every "ProRAW" shot silently came out Bayer.
    func testProRAWIsEnabledWheneverItIsWhatWeShoot() {
        for mode in RawMode.allCases {
            var s = CameraSettings()
            s.rawMode = mode
            XCTAssertEqual(CameraController.proRAWActive(s), s.shootsProRAW, "\(mode)")
        }
        XCTAssertTrue(CameraController.proRAWActive(CameraSettings()))
    }

    /// Exactly what the current app (`main`) saves: an upgrade must load it, shooting ProRAW.
    func testSettingsSavedByTheCurrentAppLoad() throws {
        let json = #"{"mode":"photo","photoFormat":"heif","rawMode":"off","keepProcessedWithRAW":true,"processing":"zero","zeroKeepsDNG":true,"flash":"off","resolution":"standard","selfTimer":0,"captureLook":"warm400","printPlacement":"mode","videoResolution":"uhd4K","frameRate":24,"videoCodec":"hevc","videoColor":"sdr","stabilization":"standard","recordAudio":true,"shutterAngleLock":true,"logViewAssist":true,"showGrid":true,"showLevel":true,"showHistogram":false,"focusPeaking":true,"peakingColor":"red","zebras":false,"zebraThreshold":0.95,"frameLines":"none","volumeShutter":true,"saveLocation":true,"haptics":true,"shutterSound":false}"#
        let s = try XCTUnwrap(CameraSettings.decodeSaved(Data(json.utf8)))
        XCTAssertTrue(s.shootsProRAW)
        XCTAssertFalse(s.zoomLocked)
        XCTAssertFalse(s.storeForever)
        XCTAssertFalse(s.autoExport)
        XCTAssertEqual(s.exportMaxSide, 2880)
    }

    func testStartingGrade() {
        var s = CameraSettings()
        XCTAssertNil(s.startingGrade, "no look, no default grade: the original")
        var g = Look.all[0].recipe          // Original
        g.exposure = 50
        s.defaultGrade = g
        XCTAssertEqual(s.startingGrade?.exposure, 50, "an Original default grade applies with no look picked")
        s.mode = .video
        XCTAssertNil(s.startingGrade, "video records no grade")
        s.mode = .photo
        s.captureLook = "punch"
        XCTAssertEqual(s.startingGrade?.look, "punch", "picking another look starts from that look")
        XCTAssertEqual(s.startingGrade?.exposure, 0)
    }

    func testAnUnreadableDefaultGradeKeepsTheRestOfTheSettings() throws {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CameraSettings())) as! [String: Any]
        object["showGrid"] = false
        object["defaultGrade"] = ["exposure": "not a number"]
        let s = try XCTUnwrap(CameraSettings.decodeSaved(JSONSerialization.data(withJSONObject: object)))
        XCTAssertFalse(s.showGrid)
        XCTAssertNil(s.defaultGrade)
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
        s.captureLook = "desert"
        s.flash = .auto
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(CameraSettings.decodeSaved(data), s)
    }

    /// A look that's no longer offered never stays the camera's choice: it moves to its
    /// successor, or to Original.
    func testRetiredLookMovesToItsSuccessorOrOff() throws {
        for (retired, expected) in [("chrome", "slide"), ("mono400", "noir"), ("silver", "noir"),
                                    ("cine", nil), ("warm400", nil), ("bogus", nil)] as [(String, String?)] {
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
