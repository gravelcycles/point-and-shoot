import CoreLocation
import Foundation
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Getting RAWs in and out of the library:
/// - **Archive RAW** to Photos (the original DNGs, no grades) or to a zip that also carries
///   each shot's grade and record, for backup or moving to another phone.
/// - **Import Archive**: brings such a zip back; shots already in the library are skipped.
/// - **Import RAW Photos**: copies RAWs picked from Photos into the library (the system
///   picker needs no Photos permission); the originals stay where they are.
@MainActor
enum ShotArchive {
    /// Files of one shot that go into an archive.
    static let archivedFiles = ["shot.json", "recipe.json", "capture.jpg"]

    // MARK: Archive

    /// The shots' original RAW files into Photos, as plain RAW photos.
    @discardableResult
    static func archiveToPhotos(_ shots: [Shot], store: ShotStore) async throws -> Int {
        var n = 0
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        for shot in shots {
            let url = store.dir(shot.id).appendingPathComponent(shot.original)
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let location = shot.latitude.flatMap { lat in shot.longitude.map { CLLocation(latitude: lat, longitude: $0) } }
            if shot.isRAW {
                try await PhotoLibrary.saveRAW(data, fileExtension: url.pathExtension.isEmpty ? "dng" : url.pathExtension,
                                               name: "PS_" + formatter.string(from: shot.captured),
                                               created: shot.captured, location: location)
            } else {
                // A processed original (no RAW was possible): saved as the photo it is.
                try await PhotoLibrary.savePhoto(primary: data, rawCompanion: nil, location: location)
            }
            n += 1
        }
        Diag.log(.save, "archived \(n) RAW to Photos")
        return n
    }

    /// A zip of the shots (original, grade, record, camera preview) in a temporary folder.
    static func makeZip(_ shots: [Shot], store: ShotStore) async throws -> URL {
        var files: [(path: String, source: URL)] = []
        for shot in shots {
            let dir = store.dir(shot.id)
            for name in [shot.original] + archivedFiles
            where FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
                files.append(("\(shot.id.uuidString)/\(name)", dir.appendingPathComponent(name)))
            }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        // Earlier archives in tmp can be gigabytes: clear them out first.
        let tmp = FileManager.default.temporaryDirectory
        for old in (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent.hasPrefix("Point & Shoot RAW") && old.pathExtension == "zip" {
            try? FileManager.default.removeItem(at: old)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Point & Shoot RAW \(formatter.string(from: Date())) (\(shots.count)).zip")
        try? FileManager.default.removeItem(at: url)
        let entries = files
        try await Task.detached(priority: .userInitiated) {
            try ZipArchive.write(entries, to: url)
        }.value
        Diag.log(.save, "archived \(shots.count) to a zip")
        return url
    }

    // MARK: Import

    struct ImportResult: Equatable {
        var imported = 0
        var skipped = 0
        var notRAW = 0
        var failed = 0

        var summary: String {
            var parts: [String] = []
            parts.append(imported == 1 ? "1 photo imported" : "\(imported) photos imported")
            if skipped > 0 { parts.append("\(skipped) already in the library") }
            if notRAW > 0 { parts.append("\(notRAW) not RAW") }
            if failed > 0 { parts.append("\(failed) couldn't be read") }
            return parts.joined(separator: " · ")
        }
    }

    /// Brings back a zip made by Archive RAW: each folder is one shot, keeping its id,
    /// date, Keep tag and grade. Shots already in the library (same id) are skipped.
    static func importZip(at url: URL, store: ShotStore) async throws -> ImportResult {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        // Parsing, inflating and checking DNGs is heavy: all of it off the main thread. The
        // archive is read (mapped) once.
        let (archive, groups) = try await Task.detached(priority: .userInitiated) { () -> (ArchiveData, [ArchivedFolder]) in
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let groups = try Self.folders(in: data).map { ArchivedFolder(name: $0.key, files: $0.value) }
                .sorted { $0.name < $1.name }
            return (ArchiveData(data: data), groups)
        }.value
        var result = ImportResult()
        for group in groups {
            do {
                let files = group.files
                // The small record first: shots already here are skipped without inflating
                // their DNGs.
                let record = await Task.detached(priority: .userInitiated) { () -> Shot? in
                    guard let entry = files["shot.json"],
                          let data = try? ZipArchive.extract(entry, from: archive.data) else { return nil }
                    return try? JSONDecoder().decode(Shot.self, from: data)
                }.value
                guard let record, files[record.original] != nil else {
                    Diag.error(.importer, "archive folder \(group.name.prefix(8)) has no shot record or original")
                    result.failed += 1
                    continue
                }
                if store.shots.contains(where: { $0.id == record.id }) {
                    result.skipped += 1
                    continue
                }
                if store.trash.contains(where: { $0.id == record.id }) {
                    // In the Trash here: restoring the backup means putting it back.
                    store.restore([record.id])
                    result.imported += 1
                    continue
                }
                let parsed = try await Task.detached(priority: .userInitiated) { () -> ParsedShot in
                    let data = archive.data
                    let original = try ZipArchive.extract(files[record.original]!, from: data)
                    let recipe = try files["recipe.json"].flatMap { EditRecipe.decodeSaved(try ZipArchive.extract($0, from: data)) }
                    let preview = try files["capture.jpg"].map { try ZipArchive.extract($0, from: data) }
                    return ParsedShot(record: record, original: original, recipe: recipe, preview: preview)
                }.value
                let ext = (record.original as NSString).pathExtension
                let shot = try await store.add(original: parsed.original, fileExtension: ext.isEmpty ? "dng" : ext,
                                               kind: record.kind, capturePreview: parsed.preview,
                                               recipe: parsed.recipe ?? EditRecipe(), captured: record.captured, id: record.id)
                if record.keep { store.setKeep(true, for: [shot.id]) }
                result.imported += 1
            } catch {
                Diag.error(.importer, "couldn't import archive folder \(group.name.prefix(8))", error)
                result.failed += 1
            }
        }
        Diag.log(.importer, "archive import: \(result.summary)")
        return result
    }

    /// The archive's entries grouped by shot folder. Directory entries and the
    /// `__MACOSX` resource forks Finder adds when re-zipping are skipped.
    nonisolated static func folders(in data: Data) throws -> [String: [String: ZipArchive.Entry]] {
        var byShot: [String: [String: ZipArchive.Entry]] = [:]
        for e in try ZipArchive.entries(of: data) {
            if e.path.hasSuffix("/") || e.path.hasPrefix("__MACOSX/") || e.path.contains("/__MACOSX/") { continue }
            let parts = e.path.split(separator: "/").map(String.init)
            guard parts.count >= 2, !parts.last!.hasPrefix(".") else { continue }
            byShot[parts[parts.count - 2], default: [:]][parts.last!] = e
        }
        return byShot
    }

    /// RAWs picked in the system photo picker, copied into the library with the default
    /// grade. A pick without a RAW (a plain HEIF/JPEG) is skipped: the library is RAW only.
    static func importPicked(_ results: [PHPickerResult], store: ShotStore, grade: EditRecipe) async -> ImportResult {
        var result = ImportResult()
        for item in results {
            let provider = item.itemProvider
            guard let type = provider.registeredTypeIdentifiers.first(where: { id in
                UTType(id)?.conforms(to: .rawImage) == true
            }) else {
                result.notRAW += 1
                continue
            }
            guard let data = await loadData(provider, type: type) else {
                result.failed += 1
                continue
            }
            let captured = captureDate(of: data) ?? Date()
            do {
                let ext = UTType(type)?.preferredFilenameExtension ?? "dng"
                try await store.add(original: data, fileExtension: ext, kind: .imported, capturePreview: nil,
                                    recipe: grade, captured: captured)
                result.imported += 1
            } catch {
                Diag.error(.importer, "couldn't import a RAW from Photos", error)
                result.failed += 1
            }
        }
        Diag.log(.importer, "RAW import: \(result.summary)")
        return result
    }

    private static func loadData(_ provider: NSItemProvider, type: String) async -> Data? {
        await withCheckedContinuation { cont in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                if let error { Diag.error(.importer, "picker file failed", error) }
                // The file only exists during this callback: read it now.
                cont.resume(returning: url.flatMap { try? Data(contentsOf: $0) })
            }
        }
    }

    /// EXIF DateTimeOriginal (the moment of capture), if the file has it.
    static func captureDate(of data: Data) -> Date? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: text)
    }
}

/// The archive's bytes (memory-mapped), shared read-only between the import's steps.
private struct ArchiveData: @unchecked Sendable {
    let data: Data
}

private struct ArchivedFolder: Sendable {
    let name: String
    let files: [String: ZipArchive.Entry]
}

private struct ParsedShot: @unchecked Sendable {
    let record: Shot
    let original: Data
    let recipe: EditRecipe?
    let preview: Data?
}

/// The system photo picker, limited to images (no Photos permission needed).
struct RAWPicker: UIViewControllerRepresentable {
    let onPick: ([PHPickerResult]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 0
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: ([PHPickerResult]) -> Void
        init(onPick: @escaping ([PHPickerResult]) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            onPick(results)
        }
    }
}
