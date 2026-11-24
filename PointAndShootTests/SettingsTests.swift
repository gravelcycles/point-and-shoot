import XCTest
@testable import PointAndShoot

/// Persisted settings: defaults, the zoom lock, and loading settings saved by any app
/// version (an update must never wipe someone's setup).
final class SettingsTests: XCTestCase {
    func testDefaults() {
        let s = CameraSettings()
        XCTAssertFalse(s.shutterSound, "The shutter is silent by default")
        XCTAssertFalse(s.showHistogram, "The histogram is off by default")
        XCTAssertFalse(s.zoomLocked, "Default settings can zoom")
        XCTAssertTrue(s.proRAWAvailable, "assumed until the main camera says otherwise")
        XCTAssertNil(s.proRAWUnavailableReason)
    }

    func testZoomLockFollowsBayerRAW() {
        var s = CameraSettings()
        XCTAssertFalse(s.zoomLocked, "ProRAW (the default) zooms")
        s.rawMode = .bayer
        XCTAssertFalse(s.shootsProRAW)
        XCTAssertTrue(s.zoomLocked, "Bayer RAW can't be zoomed")
    }

    /// A phone without ProRAW (not an iPhone Pro) shoots Bayer RAW whatever the saved choice,
    /// locks zoom like Bayer RAW, and says why ProRAW isn't offered.
    func testNoProRAWOnThisPhoneMeansBayerRAW() throws {
        var s = CameraSettings()
        s.proRAWAvailable = false
        XCTAssertTrue(s.prefersProRAW, "the choice is kept for a phone that has it")
        XCTAssertFalse(s.shootsProRAW)
        XCTAssertFalse(CameraController.proRAWActive(s), "ProRAW stays off in the photo output")
        XCTAssertTrue(s.zoomLocked)
        let reason = try XCTUnwrap(s.proRAWUnavailableReason)
        XCTAssertTrue(reason.contains("iPhone Pro"), reason)
        let decoded = try XCTUnwrap(CameraSettings.decodeSaved(try JSONEncoder().encode(s)))
        XCTAssertFalse(decoded.proRAWAvailable, "remembered, so the next launch starts right")
    }

    /// The photo output turns ProRAW on exactly when the settings say ProRAW (the default
    /// `.off` included); otherwise every "ProRAW" shot silently came out Bayer.
    func testProRAWIsEnabledWheneverItIsWhatWeShoot() {
        for mode in RawMode.allCases {
            for available in [true, false] {
                var s = CameraSettings()
                s.rawMode = mode
                s.proRAWAvailable = available
                XCTAssertEqual(CameraController.proRAWActive(s), s.shootsProRAW, "\(mode) \(available)")
            }
        }
        XCTAssertTrue(CameraController.proRAWActive(CameraSettings()))
    }

    /// Exactly what the app saved before Video and the Print mode were removed: an upgrade
    /// must load it, shooting ProRAW, with the removed options ignored.
    func testSettingsSavedBeforeVideoAndPrintModeWereRemovedLoad() throws {
        let json = #"{"mode":"photo","photoFormat":"heif","rawMode":"off","keepProcessedWithRAW":true,"processing":"zero","zeroKeepsDNG":true,"flash":"off","resolution":"standard","selfTimer":0,"captureLook":"warm400","printPlacement":"mode","videoResolution":"uhd4K","frameRate":24,"videoCodec":"hevc","videoColor":"sdr","stabilization":"standard","recordAudio":true,"shutterAngleLock":true,"logViewAssist":true,"showGrid":true,"showLevel":true,"showHistogram":false,"focusPeaking":true,"peakingColor":"red","zebras":false,"zebraThreshold":0.95,"frameLines":"none","volumeShutter":true,"saveLocation":true,"haptics":true,"shutterSound":false}"#
        let s = try XCTUnwrap(CameraSettings.decodeSaved(Data(json.utf8)))
        XCTAssertTrue(s.shootsProRAW)
        XCTAssertFalse(s.zoomLocked)
        XCTAssertFalse(s.storeForever)
        XCTAssertFalse(s.autoExport)
        XCTAssertEqual(s.exportMaxSide, 2880)
        XCTAssertTrue(s.proRAWAvailable)
        XCTAssertNil(s.captureLook, "a retired look with no successor is off")
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any])
        for removed in ["mode", "printPlacement", "videoResolution", "frameRate", "videoCodec", "videoColor",
                        "stabilization", "recordAudio", "shutterAngleLock", "logViewAssist"] {
            XCTAssertNil(saved[removed], "\(removed) is gone and isn't saved again")
        }
    }

    /// A camera left in Video opens in Photo, as it was; one left in Print mode opens in Photo
    /// with Phromagraph, Print's rendering fitted to Chromagraph.
    func testACameraLeftInVideoOrPrintModeOpensInPhoto() throws {
        var old = try savedObject()
        old["captureLook"] = "punch"
        old["mode"] = "video"
        old["frameRate"] = 60
        old["videoColor"] = "appleLog"
        var s = try XCTUnwrap(CameraSettings.decodeSaved(JSONSerialization.data(withJSONObject: old)))
        XCTAssertEqual(s.captureLook, "punch", "Video kept Photo's look")
        XCTAssertEqual(s.activeLook, "punch")
        old["mode"] = "print"
        s = try XCTUnwrap(CameraSettings.decodeSaved(JSONSerialization.data(withJSONObject: old)))
        XCTAssertEqual(s.captureLook, "phromagraph", "Print mode keeps its rendering")
        XCTAssertEqual(s.activeLook, "phromagraph")
        XCTAssertNotNil(s.startingGrade?.film)
        old["mode"] = "photo"
        s = try XCTUnwrap(CameraSettings.decodeSaved(JSONSerialization.data(withJSONObject: old)))
        XCTAssertEqual(s.captureLook, "punch")
    }

    /// Print as the camera's look, or as the Default Grade's look, moves to Phromagraph (the
    /// same rendering), like any retired look (`Look.movingOffRetired`): as designed.
    func testAPrintLookOrDefaultGradeMovesToPhromagraph() throws {
        var s = CameraSettings()
        s.captureLook = Look.printID
        var grade = Look.printLook.recipe
        grade.exposure = 25
        s.defaultGrade = grade
        let decoded = try XCTUnwrap(CameraSettings.decodeSaved(try JSONEncoder().encode(s)))
        XCTAssertEqual(decoded.captureLook, "phromagraph")
        let moved = try XCTUnwrap(decoded.defaultGrade)
        XCTAssertEqual(moved.look, "phromagraph")
        XCTAssertEqual(moved.film?.stock, "phromagraph")
        XCTAssertEqual(moved.film?.tuning, FilmStock.named("phromagraph"))
        XCTAssertEqual(moved.exposure, 0, "Phromagraph as designed")
        XCTAssertEqual(decoded.startingGrade?.look, "phromagraph", "and it still starts new shots")
    }

    func testStartingGrade() {
        var s = CameraSettings()
        XCTAssertNil(s.startingGrade, "no look, no default grade: the original")
        var g = Look.all[0].recipe          // Original
        g.exposure = 50
        s.defaultGrade = g
        XCTAssertEqual(s.startingGrade?.exposure, 50, "an Original default grade applies with no look picked")
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

    func testPlainLiveView() {
        var s = CameraSettings()
        XCTAssertFalse(s.plainLiveView, "Experimental: off by default")
        XCTAssertFalse(s.wantsPlainLiveView)
        s.plainLiveView = true
        XCTAssertTrue(s.wantsPlainLiveView, "every photo develops the RAW alone")
        s.rawMode = .bayer
        XCTAssertTrue(s.wantsPlainLiveView)
    }

    /// Print isn't a look you can pick any more (Phromagraph is the same rendering).
    func testPrintIsNotOffered() {
        var s = CameraSettings()
        XCTAssertFalse(s.filterLooks.contains { $0.id == Look.printID })
        for set in LookSet.allCases {
            s.lookSet = set.rawValue
            XCTAssertFalse(s.filterLooks.contains { $0.id == Look.printID }, set.name)
        }
        XCTAssertNil(Look.named(Look.printID))
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
        old["flash"] = "auto"
        old["showGrid"] = false
        old.removeValue(forKey: "shutterSound")      // added later
        old["proControls"] = true                    // removed in #14
        old["frameRate"] = 60                        // video, removed
        old["printPlacement"] = "filter"             // Print mode, removed
        let data = try JSONSerialization.data(withJSONObject: old)
        let s = try XCTUnwrap(CameraSettings.decodeSaved(data))
        XCTAssertEqual(s.flash, .auto)
        XCTAssertFalse(s.showGrid)
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
        XCTAssertEqual(all.count, Look.all.count - 1, "all looks but Original")
        for set in LookSet.allCases {
            XCTAssertFalse(set.looks.isEmpty, "\(set.name) is empty")
            s.lookSet = set.rawValue
            XCTAssertFalse(s.filterLooks.isEmpty)
            XCTAssertTrue(s.filterLooks.allSatisfy { $0.set == set }, set.name)
        }
        // A look added without `set:` silently lands in Essentials: pin its membership.
        XCTAssertEqual(LookSet.essentials.looks.map(\.id), ["phromagraph", "punch", "noir"])
        // Grades keep PR #35's ids, so its photos, saved choices and default grades still mean
        // the same looks; the new Slide and Bleach Bypass have ids of their own. Desert,
        // Pastel, Amber Haze and Sodium are retired.
        XCTAssertEqual(LookSet.grades.looks.map(\.id), ["neon", "slide", "bleach"])
        XCTAssertEqual(Look.named("slide")?.name, "Slide 70s")
        XCTAssertEqual(Look.named("bleach")?.name, "Bleach Grit")
        XCTAssertEqual(Look.named("classicslide")?.set, .stocks)
        XCTAssertEqual(Look.named("bleachbypass")?.set, .movie)
        // Every film look's stock exists (a typo would fall back to Print without a word).
        for look in Look.all {
            guard let stock = look.recipe.film?.stock else { continue }
            XCTAssertNotNil(FilmStock.all[stock], "\(look.id) uses stock \(stock), which doesn't exist")
            XCTAssertEqual(stock, look.id, "\(look.id)'s stock should share its id")
        }
        s.lookSet = LookSet.movie.rawValue
        let decoded = try XCTUnwrap(CameraSettings.decodeSaved(try JSONEncoder().encode(s)))
        XCTAssertEqual(decoded.lookSet, LookSet.movie.rawValue)
        s.lookSet = "a-set-from-a-newer-app"
        XCTAssertEqual(s.filterLooks.count, all.count, "an unknown set shows every look")
    }

    /// The strip always shows the look in use, even from another set (first, so it can be
    /// seen and turned off), and a set's count is the cards it shows.
    func testStripKeepsTheActiveLookAndCountsWhatItShows() {
        var s = CameraSettings()
        s.lookSet = LookSet.movie.rawValue
        s.captureLook = "neon"              // a Grades look
        XCTAssertEqual(s.stripLooks.first?.id, "neon")
        XCTAssertEqual(s.stripLooks.count, s.filterLooks.count + 1)
        s.captureLook = "blockbuster"       // already in the set: not doubled
        XCTAssertEqual(s.stripLooks.map(\.id), s.filterLooks.map(\.id))
        XCTAssertEqual(s.stripCount(of: .essentials), 3)
        XCTAssertEqual(s.stripCount(of: .movie), 4)
    }

    /// A look that's no longer offered never stays the camera's choice: it moves to its
    /// successor, or to Original.
    func testRetiredLookMovesToItsSuccessorOrOff() throws {
        for (retired, expected) in [("print", "phromagraph"), ("chrome", "classicslide"), ("mono400", "noir"), ("silver", "noir"),
                                    ("cine", "blockbuster"), ("portrait", "portrait400"), ("cool", "evergreen"),
                                    ("desert", "portrait400"), ("pastel", "portrait400"), ("sodium", "night800"),
                                    ("amber", nil), ("warm400", nil), ("bogus", nil)] as [(String, String?)] {
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

    /// A Default Grade on a retired look moves on with the camera's choice: its successor as
    /// designed, or no default grade (the Default Grade picker can't show a retired look).
    func testDefaultGradeOnARetiredLookMovesOn() throws {
        for (retired, expected) in [("desert", "portrait400"), ("sodium", "night800"), ("amber", nil),
                                    ("chrome", "classicslide")] as [(String, String?)] {
            var grade = EditRecipe()
            grade.look = retired
            grade.film = FilmRecipe(stock: retired, tuning: FilmStock.namedOrRetired(retired), engine: FilmRecipe.currentEngine)
            grade.exposure = 20
            var s = CameraSettings()
            s.captureLook = retired
            s.defaultGrade = grade
            let decoded = try XCTUnwrap(CameraSettings.decodeSaved(try JSONEncoder().encode(s)))
            XCTAssertEqual(decoded.captureLook, expected, retired)
            XCTAssertEqual(decoded.defaultGrade?.look, expected, retired)
            if let expected {
                XCTAssertEqual(decoded.defaultGrade?.film?.tuning, FilmStock.named(expected), retired)
                XCTAssertEqual(decoded.defaultGrade?.exposure, 0, "\(retired): the successor as designed")
            }
        }
        // A current look's grade is kept as it was.
        var s = CameraSettings()
        var grade = Look.named("neon")!.recipe
        grade.exposure = 20
        s.captureLook = "neon"
        s.defaultGrade = grade
        let decoded = try XCTUnwrap(CameraSettings.decodeSaved(try JSONEncoder().encode(s)))
        XCTAssertEqual(decoded.defaultGrade?.exposure, 20)
        XCTAssertEqual(decoded.defaultGrade?.look, "neon")
    }
}
