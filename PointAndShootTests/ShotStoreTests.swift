import UIKit
import XCTest
@testable import PointAndShoot

/// The app's own library on a throwaway folder: storing, rendering previews, grades,
/// trash/restore/delete, the 30-day retention rules, export rendering, and records written
/// by older versions. The simulator decodes no RAW, so these use processed originals and the
/// RAW-with-camera-preview fallback; the RAW develop itself is covered on device.
@MainActor
final class ShotStoreTests: XCTestCase {
    private var root: URL!
    private var store: ShotStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shots-\(UUID().uuidString)")
        store = ShotStore(root: root)
        await store.load()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func jpeg(_ color: UIColor = .orange, size: CGSize = CGSize(width: 600, height: 400)) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }.jpegData(compressionQuality: 0.9)!
    }

    private func waitUntilDeveloped(_ id: UUID, timeout: TimeInterval = 20) async {
        let deadline = Date().addingTimeInterval(timeout)
        while store.developing.contains(id) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @discardableResult
    private func addShot(captured: Date = Date(), recipe: EditRecipe = EditRecipe(),
                         kind: Shot.Kind = .processed) async throws -> Shot {
        // RAW kinds get JPEG bytes too: the simulator can't decode RAW, and what's tested
        // here is the grade, which settles before (and regardless of) the render.
        let shot = try await store.add(original: jpeg(), fileExtension: kind == .processed ? "jpg" : "dng", kind: kind,
                                       capturePreview: nil, recipe: recipe, captured: captured)
        await waitUntilDeveloped(shot.id)
        return shot
    }

    // MARK: Storing

    func testAddWritesFilesAndRendersPreviews() async throws {
        let shot = try await addShot()
        let dir = store.dir(shot.id)
        for file in ["shot.json", "recipe.json", "original.jpg", "preview.jpg", "thumb.jpg"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path), "missing \(file)")
        }
        XCTAssertEqual(store.shots.map(\.id), [shot.id])
        XCTAssertFalse(store.developing.contains(shot.id))
        XCTAssertEqual(store.shot(shot.id)?.pixelWidth, 600)
        let thumb = try XCTUnwrap(UIImage(contentsOfFile: dir.appendingPathComponent("thumb.jpg").path))
        XCTAssertLessThanOrEqual(max(thumb.size.width, thumb.size.height) * thumb.scale, ShotRenderer.thumbSide + 1)
        let image = await store.image(try XCTUnwrap(store.shot(shot.id)), .preview)
        XCTAssertNotNil(image)
    }

    func testNewestFirstAndReloadFromDisk() async throws {
        let older = try await addShot(captured: Date().addingTimeInterval(-60))
        let newer = try await addShot()
        XCTAssertEqual(store.shots.map(\.id), [newer.id, older.id])
        let reopened = ShotStore(root: root)
        await reopened.load()
        XCTAssertEqual(reopened.shots.map(\.id), [newer.id, older.id])
    }

    func testRAWShotFallsBackToTheCameraPreviewWhereItCantDecode() async throws {
        // A "DNG" the simulator can't develop, plus the camera's quick preview.
        let shot = try await store.add(original: Data("not a real dng".utf8), fileExtension: "dng", kind: .bayerRAW,
                                       capturePreview: jpeg(.blue), recipe: EditRecipe())
        await waitUntilDeveloped(shot.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.dir(shot.id).appendingPathComponent("preview.jpg").path),
                      "a RAW shot must still get a preview (from the camera's)")
    }

    // MARK: Grades

    func testGradeRoundTripsAndBumpsTheRevision() async throws {
        let shot = try await addShot()
        let revision = try XCTUnwrap(store.shot(shot.id)).revision
        var r = store.recipe(for: shot.id)
        r.exposure = 33
        r.look = "punch"
        store.setRecipe(r, for: shot.id)
        await waitUntilDeveloped(shot.id)
        XCTAssertGreaterThan(try XCTUnwrap(store.shot(shot.id)).revision, revision)
        let reopened = ShotStore(root: root)
        await reopened.load()
        XCTAssertEqual(reopened.recipe(for: shot.id).exposure, 33)
        XCTAssertEqual(reopened.recipe(for: shot.id).look, "punch")
    }

    func testEveryLookRendersAPreview() async throws {
        for look in Look.all {
            let shot = try await addShot(recipe: look.recipe)
            let preview = store.dir(shot.id).appendingPathComponent("preview.jpg")
            XCTAssertTrue(FileManager.default.fileExists(atPath: preview.path), "\(look.id) rendered no preview")
        }
    }

    // MARK: Trash

    func testTrashRestoreAndDeleteForever() async throws {
        let a = try await addShot(captured: Date().addingTimeInterval(-10))
        let b = try await addShot()
        store.moveToTrash([a.id])
        XCTAssertEqual(store.shots.map(\.id), [b.id])
        XCTAssertEqual(store.trash.map(\.id), [a.id])
        XCTAssertNotNil(store.trash.first?.trashedAt)

        store.restore([a.id])
        XCTAssertEqual(store.shots.map(\.id), [b.id, a.id], "restored in capture order")
        XCTAssertTrue(store.trash.isEmpty)
        XCTAssertNil(store.shot(a.id)?.trashedAt)

        store.moveToTrash([a.id, b.id])
        store.emptyTrash()
        XCTAssertTrue(store.shots.isEmpty && store.trash.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.dir(a.id).path), "files must be removed")
    }

    func testTrashSurvivesARelaunch() async throws {
        let a = try await addShot()
        store.moveToTrash([a.id])
        let reopened = ShotStore(root: root)
        await reopened.load()
        XCTAssertTrue(reopened.shots.isEmpty)
        XCTAssertEqual(reopened.trash.map(\.id), [a.id])
    }

    func testKeepSurvivesARelaunch() async throws {
        let a = try await addShot()
        store.setKeep(true, for: [a.id])
        let reopened = ShotStore(root: root)
        await reopened.load()
        XCTAssertEqual(reopened.shot(a.id)?.keep, true)
    }

    // MARK: Retention (the 30-day rule)

    private func shot(daysOld: Double, keep: Bool = false, trashedDaysAgo: Double? = nil, now: Date) -> Shot {
        var s = Shot(captured: now.addingTimeInterval(-daysOld * 86_400), kind: .bayerRAW, original: "original.dng")
        s.keep = keep
        s.trashedAt = trashedDaysAgo.map { now.addingTimeInterval(-$0 * 86_400) }
        return s
    }

    func testRetentionRules() {
        let now = Date()
        let fresh = shot(daysOld: 29, now: now)
        let old = shot(daysOld: 31, now: now)
        let kept = shot(daysOld: 90, keep: true, now: now)
        XCTAssertEqual(ShotRetention.dueForTrash([fresh, old, kept], now: now, storeForever: false), [old.id])
        XCTAssertEqual(ShotRetention.dueForTrash([fresh, old, kept], now: now, storeForever: true), [],
                       "Store Forever never trashes anything")

        let recentlyTrashed = shot(daysOld: 40, trashedDaysAgo: 5, now: now)
        let longTrashed = shot(daysOld: 80, trashedDaysAgo: 31, now: now)
        XCTAssertEqual(ShotRetention.dueForPurge([recentlyTrashed, longTrashed], now: now), [longTrashed.id])

        XCTAssertEqual(ShotRetention.daysLeft(fresh, now: now, storeForever: false), 1)
        var imported = shot(daysOld: 365, now: now)
        imported.added = now.addingTimeInterval(-2 * 86_400)
        XCTAssertEqual(ShotRetention.dueForTrash([imported], now: now, storeForever: false), [],
                       "the 30 days start when it entered the library")
        XCTAssertEqual(ShotRetention.daysLeft(imported, now: now, storeForever: false), 28)
        XCTAssertNil(ShotRetention.daysLeft(kept, now: now, storeForever: false))
        XCTAssertNil(ShotRetention.daysLeft(fresh, now: now, storeForever: true))
    }

    func testApplyRetentionMovesOldShotsAndPurgesOldTrash() async throws {
        let now = Date()
        // An older RAW (an import, a restored backup): its 30 days start when it was added.
        let old = try await addShot(captured: now.addingTimeInterval(-90 * 86_400))
        let kept = try await addShot(captured: now.addingTimeInterval(-90 * 86_400))
        store.setKeep(true, for: [kept.id])

        store.applyRetention(storeForever: false, now: now)
        XCTAssertEqual(Set(store.shots.map(\.id)), [old.id, kept.id], "an import of an older RAW isn't trashed on arrival")

        store.applyRetention(storeForever: false, now: now.addingTimeInterval(31 * 86_400))
        XCTAssertEqual(store.shots.map(\.id), [kept.id])
        XCTAssertEqual(store.trash.map(\.id), [old.id])

        // 30 more days in the Trash: gone for good.
        store.applyRetention(storeForever: false, now: now.addingTimeInterval(62 * 86_400))
        XCTAssertNil(store.shot(old.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.dir(old.id).path))
        XCTAssertEqual(store.shots.map(\.id), [kept.id])
    }

    func testRestoringAShotPastIts30DaysStartsAFresh30() async throws {
        let shot = try await addShot()
        let later = Date().addingTimeInterval(31 * 86_400)
        store.applyRetention(storeForever: false, now: later)
        XCTAssertEqual(store.trash.map(\.id), [shot.id])
        store.restore([shot.id], now: later)
        store.applyRetention(storeForever: false, now: later.addingTimeInterval(10 * 86_400))
        XCTAssertNotNil(store.shots.first { $0.id == shot.id }, "put back past its 30 days, it gets a fresh 30")
    }

    func testUndoKeepsTheDaysAShotHad() async throws {
        let shot = try await addShot()
        store.moveToTrash([shot.id])
        store.restore([shot.id])
        XCTAssertNil(store.shot(shot.id)?.restoredAt, "an Undo doesn't reset its 30 days")
        store.applyRetention(storeForever: false, now: Date().addingTimeInterval(31 * 86_400))
        XCTAssertTrue(store.shots.isEmpty)
    }

    func testStoreForeverNeverTrashes() async throws {
        let shot = try await addShot()
        store.applyRetention(storeForever: true, now: Date().addingTimeInterval(400 * 86_400))
        XCTAssertNotNil(store.shots.first { $0.id == shot.id })
    }

    func testAGradeSavedWhileDevelopingIsNotOverwritten() async throws {
        // Saved right after the capture, before its first develop (settle) has finished.
        let shot = try await store.add(original: jpeg(), fileExtension: "jpg", kind: .processed,
                                       capturePreview: nil, recipe: EditRecipe())
        var edited = store.recipe(for: shot.id)
        edited.exposure = 42
        store.setRecipe(edited, for: shot.id)
        await waitUntilDeveloped(shot.id)
        XCTAssertEqual(store.recipe(for: shot.id).exposure, 42)
        let reopened = ShotStore(root: root)
        await reopened.load()
        XCTAssertEqual(reopened.recipe(for: shot.id).exposure, 42, "the edit must be what's on disk")
    }

    private var filmGrade: EditRecipe { Look.all.first { $0.recipe.film != nil }!.recipe }
    /// The natural develop for a test shot (no exposure metadata: EV 10).
    private func natural(_ kind: Shot.Kind) -> Double {
        (EditRecipe.filmRAWExposure(bayer: kind == .bayerRAW, ev100: nil) * 100).rounded() / 100
    }

    /// A film grade saved onto a shot develops at the fixed exposure for that shot's RAW.
    func testAFilmGradeDevelopsAtTheFixedExposureForItsRAWType() async throws {
        XCTAssertNil(filmGrade.rawFilmExposure, "picking a film look leaves it to the photo's RAW")
        let pro = try await addShot(kind: .proRAW), bayer = try await addShot(kind: .bayerRAW)
        store.setRecipe(filmGrade, for: pro.id)
        store.setRecipe(filmGrade, for: bayer.id)
        await waitUntilDeveloped(pro.id)
        await waitUntilDeveloped(bayer.id)
        let reopened = ShotStore(root: root)
        await reopened.load()
        XCTAssertEqual(reopened.recipe(for: pro.id).rawFilmExposure, natural(.proRAW))
        XCTAssertEqual(reopened.recipe(for: bayer.id).rawFilmExposure, natural(.bayerRAW))
    }

    func testAFreshFilmShotIsPinnedToTheFixedExposureForItsRAWType() async throws {
        let pro = try await addShot(recipe: filmGrade, kind: .proRAW)
        let bayer = try await addShot(recipe: filmGrade, kind: .bayerRAW)
        XCTAssertEqual(store.recipe(for: pro.id).rawFilmExposure, natural(.proRAW), "natural, for its scene")
        XCTAssertEqual(store.recipe(for: bayer.id).rawFilmExposure, natural(.bayerRAW), "Bayer: as bright as ProRAW")
    }

    /// Shots still on an earlier build's automatic value (#42's +1.86, #52's Bayer +0.54):
    /// loading the library moves them to the natural one, and nothing else.
    func testLoadingMovesShotsOffEarlierAutomaticExposures() async throws {
        var old = filmGrade
        old.rawFilmExposure = 1.86                       // #42's fixed default
        var matched = filmGrade
        matched.rawFilmExposure = 2.31                   // a viewfinder match: kept
        let bayer = try await addShot(recipe: old, kind: .bayerRAW)
        let pro = try await addShot(recipe: old, kind: .proRAW)
        let kept = try await addShot(recipe: matched, kind: .bayerRAW)
        // What the earlier build left on disk: +1.86 on the Bayer shot.
        try JSONEncoder().encode(old).write(to: store.dir(bayer.id).appendingPathComponent("recipe.json"))
        try JSONEncoder().encode(old).write(to: store.dir(pro.id).appendingPathComponent("recipe.json"))
        let reopened = ShotStore(root: root)
        await reopened.load()
        XCTAssertEqual(reopened.recipe(for: bayer.id).rawFilmExposure, natural(.bayerRAW))
        XCTAssertEqual(reopened.recipe(for: pro.id).rawFilmExposure, natural(.proRAW))
        XCTAssertEqual(reopened.recipe(for: kept.id).rawFilmExposure, 2.31)
        let again = ShotStore(root: root)
        await again.load()
        XCTAssertEqual(again.recipe(for: bayer.id).rawFilmExposure, natural(.bayerRAW), "saved, once")
    }

    /// Older film edits move to the current engine at launch, with a backup of the grade
    /// as it was; Restore puts every backup back and turns migration off so it isn't redone.
    func testFilmMigrationIsRecoverable() async throws {
        UserDefaults.standard.removeObject(forKey: FilmMigration.enabledKey)
        defer { UserDefaults.standard.removeObject(forKey: FilmMigration.enabledKey) }
        var old = filmGrade
        old.film?.engine = 4
        old.shadows = 40
        old.contrast = 30
        let shot = try await addShot(recipe: filmGrade, kind: .proRAW)
        // What an earlier build left on disk.
        let onDisk = store.dir(shot.id).appendingPathComponent("recipe.json")
        try JSONEncoder().encode(old).write(to: onDisk)
        let reopened = ShotStore(root: root)
        await reopened.load()
        XCTAssertEqual(reopened.recipe(for: shot.id).film?.engine, FilmRecipe.currentEngine)
        XCTAssertEqual(reopened.recipe(for: shot.id).contrast, 15, accuracy: 0.01)
        XCTAssertEqual(reopened.preMigrationBackupCount(), 1)
        let backup = store.dir(shot.id).appendingPathComponent(FilmMigration.backupName)
        XCTAssertEqual(EditRecipe.decodeSaved(try Data(contentsOf: backup))?.film?.engine, 4)

        XCTAssertEqual(reopened.restorePreMigrationGrades(), 1)
        XCTAssertFalse(FilmMigration.isEnabled)
        XCTAssertEqual(reopened.recipe(for: shot.id).film?.engine, 4)
        XCTAssertEqual(reopened.recipe(for: shot.id).shadows, 40)
        XCTAssertEqual(reopened.preMigrationBackupCount(), 0)
        let again = ShotStore(root: root)
        await again.load()
        XCTAssertEqual(again.recipe(for: shot.id).film?.engine, 4, "restored edits aren't migrated again")
    }

    /// On device: picking Phromagraph in the editor showed a dark photo, and Save stored a
    /// +1.86 one ("a nice dark photo … I click save and it's this overexposed monstrosity").
    /// Picking left the film exposure unset and the preview rendered it as 0 EV. Whatever
    /// the editor shows must be what Save stores, for every way a grade changes.
    @MainActor
    func testTheEditorShowsExactlyWhatSaveStores() async throws {
        for kind in [Shot.Kind.proRAW, .bayerRAW] {
            let shot = try await addShot(kind: kind)
            let session = EditSession(shot: shot, store: store)
            let expected = natural(kind)
            session.apply(look: Look.named("phromagraph")!)
            XCTAssertEqual(session.recipe.rawFilmExposure, expected, "\(kind): picking a look")
            var copied = session.recipe
            copied.rawFilmExposure = nil
            session.apply(look: Look.all[0])   // Original
            session.paste(Look.named(CameraSettings.printLookID)!.recipe)
            XCTAssertEqual(session.recipe.rawFilmExposure, expected, "\(kind): pasting a look")
            session.recipe = copied                      // undo, or any direct change
            XCTAssertEqual(session.recipe.rawFilmExposure, expected, "\(kind): setting the grade")
            let shown = session.recipe
            let saved = await session.save()
            XCTAssertTrue(saved)
            XCTAssertEqual(session.recipe, shown, "\(kind): Save must store what the editor showed")
            XCTAssertEqual(store.recipe(for: shot.id).rawFilmExposure, expected)
        }
    }

    func testTheDefaultGradeLeavesTheExposureToEachShot() {
        XCTAssertNil(filmGrade.asDefaultGrade.rawFilmExposure, "each new shot's RAW type decides")
        XCTAssertNil(EditRecipe().asDefaultGrade.rawFilmExposure)
    }

    func testLoadDoesNotDropOrDuplicateAShotAddedMeanwhile() async throws {
        let fresh = ShotStore(root: root)
        let added = try await fresh.add(original: jpeg(), fileExtension: "jpg", kind: .processed,
                                        capturePreview: nil, recipe: EditRecipe())
        await fresh.load()
        XCTAssertEqual(fresh.shots.filter { $0.id == added.id }.count, 1)
    }

    // MARK: Export

    func testExportRendersSizedHEIFAndJPEG() async throws {
        let shot = try await addShot()
        let current = try XCTUnwrap(store.shot(shot.id))
        let heif = await ShotExporter.render(current, store: store, options: .init(format: .heif, maxSide: 300, quality: 0.9))
        let jpg = await ShotExporter.render(current, store: store, options: .init(format: .jpeg, maxSide: nil, quality: 0.9))
        let h = try XCTUnwrap(heif.flatMap { UIImage(data: $0) })
        XCTAssertEqual(max(h.size.width, h.size.height) * h.scale, 300, accuracy: 1)
        let j = try XCTUnwrap(jpg.flatMap { UIImage(data: $0) })
        XCTAssertEqual(max(j.size.width, j.size.height) * j.scale, 600, accuracy: 1, "nil = the photo's own size")
    }

    func testExportOptionsFromSettings() {
        var s = CameraSettings()
        XCTAssertEqual(ShotExporter.Options(s).maxSide, 2880)
        XCTAssertEqual(ShotExporter.Options(s).format, .heif)
        s.exportMaxSide = 0
        XCTAssertNil(ShotExporter.Options(s).maxSide)
    }

    // MARK: Records from any version

    func testShotDecodesWithMissingKeys() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)"}"#
        let shot = try JSONDecoder().decode(Shot.self, from: Data(json.utf8))
        XCTAssertEqual(shot.id, id)
        XCTAssertEqual(shot.kind, .bayerRAW)
        XCTAssertFalse(shot.keep)
        XCTAssertNil(shot.trashedAt)
    }

    func testExposureLine() {
        var s = Shot(kind: .bayerRAW, original: "original.dng")
        s.exposureTime = 1.0 / 121
        s.fNumber = 1.6
        s.iso = 40
        XCTAssertEqual(s.exposureLine, "1/121 s · f/1.6 · ISO 40")
    }
}
