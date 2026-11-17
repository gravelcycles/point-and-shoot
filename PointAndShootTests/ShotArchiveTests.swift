import UIKit
import XCTest
@testable import PointAndShoot

/// The zip writer/reader and the archive round trip: archive shots, delete them, import the
/// zip, and get the same shots back (id, date, Keep, grade); importing again skips them.
@MainActor
final class ShotArchiveTests: XCTestCase {
    private var root: URL!
    private var store: ShotStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID().uuidString)")
        store = ShotStore(root: root)
        await store.load()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCRC32KnownValue() {
        XCTAssertEqual(ZipArchive.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(ZipArchive.crc32(Data()), 0)
    }

    func testZipRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.bin")
        let b = dir.appendingPathComponent("b.txt")
        let big = Data((0..<200_000).map { UInt8($0 % 251) })
        try big.write(to: a)
        try Data("héllo".utf8).write(to: b)
        let zip = dir.appendingPathComponent("out.zip")
        try ZipArchive.write([("x/a.bin", a), ("x/b.txt", b), ("empty", b)], to: zip)

        let data = try Data(contentsOf: zip)
        let entries = try ZipArchive.entries(of: data)
        XCTAssertEqual(entries.map(\.path), ["x/a.bin", "x/b.txt", "empty"])
        XCTAssertEqual(try ZipArchive.extract(entries[0], from: data), big)
        XCTAssertEqual(String(decoding: try ZipArchive.extract(entries[1], from: data), as: UTF8.self), "héllo")
    }

    func testNotAZipIsRejected() {
        XCTAssertThrowsError(try ZipArchive.entries(of: Data("definitely not a zip file at all".utf8)))
    }

    func testDamagedEntryFailsItsChecksum() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.bin")
        try Data(repeating: 7, count: 1000).write(to: a)
        let zip = dir.appendingPathComponent("out.zip")
        try ZipArchive.write([("a.bin", a)], to: zip)
        var data = try Data(contentsOf: zip)
        data[60] ^= 0xFF   // inside the stored bytes
        let entries = try ZipArchive.entries(of: data)
        XCTAssertThrowsError(try ZipArchive.extract(entries[0], from: data))
    }

    private func jpeg() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200)).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        }.jpegData(compressionQuality: 0.9)!
    }

    private func waitForRenders() async {
        let deadline = Date().addingTimeInterval(20)
        while !store.developing.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func testArchiveAndImportRoundTrip() async throws {
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        var grade = EditRecipe()
        grade.exposure = 21
        grade.look = "punch"
        let a = try await store.add(original: jpeg(), fileExtension: "jpg", kind: .processed,
                                    capturePreview: nil, recipe: grade, captured: when)
        let b = try await store.add(original: jpeg(), fileExtension: "jpg", kind: .processed,
                                    capturePreview: nil, recipe: EditRecipe())
        store.setKeep(true, for: [a.id])
        await waitForRenders()

        let zip = try await ShotArchive.makeZip(store.shots, store: store)
        defer { try? FileManager.default.removeItem(at: zip) }

        // Importing into the same library skips both.
        let again = try await ShotArchive.importZip(at: zip, store: store)
        XCTAssertEqual(again.imported, 0)
        XCTAssertEqual(again.skipped, 2)

        store.deleteForever([a.id, b.id])
        XCTAssertTrue(store.shots.isEmpty)
        let result = try await ShotArchive.importZip(at: zip, store: store)
        XCTAssertEqual(result.imported, 2)
        XCTAssertEqual(result.failed, 0)
        await waitForRenders()

        let back = try XCTUnwrap(store.shot(a.id))
        XCTAssertEqual(back.captured.timeIntervalSince1970, when.timeIntervalSince1970, accuracy: 1)
        XCTAssertTrue(back.keep)
        XCTAssertEqual(store.recipe(for: a.id).exposure, 21)
        XCTAssertEqual(store.recipe(for: a.id).look, "punch")
        XCTAssertNotNil(store.shot(b.id))
    }

    func testTrashedShotsComeBackFromAnArchive() async throws {
        let a = try await store.add(original: jpeg(), fileExtension: "jpg", kind: .processed,
                                    capturePreview: nil, recipe: EditRecipe())
        await waitForRenders()
        let zip = try await ShotArchive.makeZip(store.shots, store: store)
        defer { try? FileManager.default.removeItem(at: zip) }
        store.moveToTrash([a.id])
        let result = try await ShotArchive.importZip(at: zip, store: store)
        XCTAssertEqual(result.imported, 1)
        XCTAssertNotNil(store.shots.first { $0.id == a.id }, "restoring a backup puts a trashed shot back")
    }

    func testFinderRezipFoldersAreSkipped() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("f")
        try Data("x".utf8).write(to: f)
        let zip = dir.appendingPathComponent("out.zip")
        let id = UUID().uuidString
        try ZipArchive.write([("Top/", f), ("Top/\(id)/shot.json", f), ("__MACOSX/Top/\(id)/._shot.json", f)], to: zip)
        let groups = try ShotArchive.folders(in: Data(contentsOf: zip))
        XCTAssertEqual(Array(groups.keys), [id])
    }

    func testImportSummary() {
        var r = ShotArchive.ImportResult()
        r.imported = 3
        r.skipped = 1
        r.notRAW = 2
        XCTAssertEqual(r.summary, "3 photos imported · 1 already in the library · 2 not RAW")
    }
}
