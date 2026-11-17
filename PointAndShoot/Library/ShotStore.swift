import Foundation
import Observation
import UIKit

/// The app's own photo library (see `Shot`). The single source of truth for the camera
/// thumbnail, the viewer, the grid and the editor. All state is main-actor; file work and
/// rendering run off the main thread, renders one at a time (`BakeQueue`).
@MainActor
@Observable
final class ShotStore {
    static let shared = ShotStore()

    let root: URL
    /// Live shots, newest first.
    private(set) var shots: [Shot] = []
    /// Trashed shots, most recently trashed first.
    private(set) var trash: [Shot] = []
    /// Shots whose graded preview is being rendered (fresh captures, edited grades).
    private(set) var developing: Set<UUID> = []
    private(set) var isLoaded = false

    @ObservationIgnored private var recipes: [UUID: EditRecipe] = [:]
    @ObservationIgnored private let images = NSCache<NSString, UIImage>()

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.root = support.appendingPathComponent("Shots", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        images.countLimit = 300
    }

    func dir(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func shot(_ id: UUID) -> Shot? { shots.first { $0.id == id } ?? trash.first { $0.id == id } }
    var newest: Shot? { shots.first }

    // MARK: Loading

    /// Reads every shot's record. Shots whose preview never finished (the app quit mid-render)
    /// are developed again.
    func load() async {
        let root = self.root
        let loaded = await Task.detached(priority: .userInitiated) { () -> [Shot] in
            let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            return dirs.compactMap { dir in
                guard let data = try? Data(contentsOf: dir.appendingPathComponent("shot.json")) else { return nil }
                return try? JSONDecoder().decode(Shot.self, from: data)
            }
        }.value
        shots = loaded.filter { $0.trashedAt == nil }.sorted { $0.captured > $1.captured }
        trash = loaded.filter { $0.trashedAt != nil }.sorted { $0.trashedAt! > $1.trashedAt! }
        isLoaded = true
        Diag.log(.roll, "library: \(shots.count) photos, \(trash.count) in trash")
        for shot in shots where !FileManager.default.fileExists(atPath: dir(shot.id).appendingPathComponent("preview.jpg").path) {
            develop(shot.id, viewfinderKey: nil)
        }
    }

    // MARK: Adding

    /// Stores a capture (or import) and starts rendering its graded preview. Returns as soon
    /// as the files are written: the shot shows (with the camera's preview) right away.
    @discardableResult
    func add(original: Data, fileExtension: String, kind: Shot.Kind, capturePreview: Data?,
             recipe: EditRecipe, viewfinderKey: Double? = nil, captured: Date = Date(),
             id: UUID = UUID()) async throws -> Shot {
        var shot = Shot(id: id, captured: captured, kind: kind, original: "original.\(fileExtension)")
        shot.readMetadata(from: original)
        let dir = self.dir(id)
        let record = shot
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try original.write(to: dir.appendingPathComponent(record.original))
            if let capturePreview { try capturePreview.write(to: dir.appendingPathComponent("capture.jpg")) }
            try JSONEncoder().encode(recipe).write(to: dir.appendingPathComponent("recipe.json"))
            try JSONEncoder().encode(record).write(to: dir.appendingPathComponent("shot.json"))
        }.value
        recipes[id] = recipe
        shots.insert(shot, at: 0)
        shots.sort { $0.captured > $1.captured }
        Diag.log(.save, "stored \(id.uuidString.prefix(8)) \(kind.rawValue) \(original.count / 1024) KB")
        develop(id, viewfinderKey: viewfinderKey)
        return shot
    }

    // MARK: Grades

    func recipe(for id: UUID) -> EditRecipe {
        if let r = recipes[id] { return r }
        let url = dir(id).appendingPathComponent("recipe.json")
        let r = (try? Data(contentsOf: url)).flatMap(EditRecipe.decodeSaved) ?? EditRecipe()
        recipes[id] = r
        return r
    }

    /// Saves a new grade and re-renders the shot's preview and thumbnail.
    func setRecipe(_ recipe: EditRecipe, for id: UUID) {
        var r = recipe
        r.freezeFilmTuning()
        recipes[id] = r
        let url = dir(id).appendingPathComponent("recipe.json")
        do { try JSONEncoder().encode(r).write(to: url, options: .atomic) } catch {
            Diag.error(.editor, "couldn't save the grade of \(id.uuidString.prefix(8))", error)
        }
        develop(id, viewfinderKey: nil, settle: false)
    }

    /// Renders the graded preview and thumbnail, one shot at a time. A fresh shot's grade is
    /// settled first (RAW noise reduction, a film look's matched exposure).
    private func develop(_ id: UUID, viewfinderKey: Double?, settle: Bool = true) {
        guard let shot = shot(id) else { return }
        developing.insert(id)
        let dir = self.dir(id)
        let recipe = recipe(for: id)
        Task {
            let result = await Self.renderPreviews(shot: shot, dir: dir, recipe: recipe, settle: settle,
                                                   viewfinderKey: viewfinderKey)
            if let settled = result, settled != recipe { recipes[id] = settled }
            bumpRevision(id)
            developing.remove(id)
        }
    }

    private nonisolated static func renderPreviews(shot: Shot, dir: URL, recipe: EditRecipe, settle: Bool,
                                                   viewfinderKey: Double?) async -> EditRecipe? {
        let box = RecipeBox()
        await BakeQueue.shared.run {
            let start = Date()
            var r = recipe
            if settle {
                r = ShotRenderer.prepare(recipe, shot: shot, in: dir, viewfinderKey: viewfinderKey)
                if r != recipe { try? JSONEncoder().encode(r).write(to: dir.appendingPathComponent("recipe.json"), options: .atomic) }
            }
            guard let preview = ShotRenderer.render(shot, in: dir, recipe: r, maxSide: ShotRenderer.previewSide) else {
                Diag.error(.bake, "couldn't render \(shot.id.uuidString.prefix(8))")
                return
            }
            do {
                try ShotRenderer.writeJPEG(preview, to: dir.appendingPathComponent("preview.jpg"), quality: 0.9)
                let thumb = ShotRenderer.scaled(preview, maxSide: ShotRenderer.thumbSide)
                try ShotRenderer.writeJPEG(thumb, to: dir.appendingPathComponent("thumb.jpg"), quality: 0.85)
                Diag.log(.bake, "rendered \(shot.id.uuidString.prefix(8)) \(r.look ?? "original") in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
            } catch {
                Diag.error(.bake, "couldn't write the preview of \(shot.id.uuidString.prefix(8))", error)
            }
            box.value = r
        }
        return box.value
    }

    private func bumpRevision(_ id: UUID) {
        update(id) { $0.revision += 1 }
    }

    // MARK: Changing shots

    private func update(_ id: UUID, _ change: (inout Shot) -> Void) {
        if let i = shots.firstIndex(where: { $0.id == id }) {
            change(&shots[i]); persist(shots[i])
        } else if let i = trash.firstIndex(where: { $0.id == id }) {
            change(&trash[i]); persist(trash[i])
        }
    }

    private func persist(_ shot: Shot) {
        let url = dir(shot.id).appendingPathComponent("shot.json")
        do { try JSONEncoder().encode(shot).write(to: url, options: .atomic) } catch {
            Diag.error(.roll, "couldn't save \(shot.id.uuidString.prefix(8))", error)
        }
    }

    func setKeep(_ keep: Bool, for ids: [UUID]) {
        for id in ids { update(id) { $0.keep = keep } }
        Diag.log(.roll, "\(keep ? "keep" : "unkeep") \(ids.count)")
    }

    func markExported(_ ids: [UUID]) {
        for id in ids { update(id) { $0.exportedAt = Date() } }
    }

    /// Moves shots to the trash (undoable; purged after `ShotRetention.trashDays`).
    func moveToTrash(_ ids: [UUID], now: Date = Date()) {
        let set = Set(ids)
        var moved = shots.filter { set.contains($0.id) }
        guard !moved.isEmpty else { return }
        shots.removeAll { set.contains($0.id) }
        for i in moved.indices { moved[i].trashedAt = now; persist(moved[i]) }
        trash.insert(contentsOf: moved, at: 0)
        Diag.log(.delete, "trashed \(moved.count)")
    }

    func restore(_ ids: [UUID]) {
        let set = Set(ids)
        var back = trash.filter { set.contains($0.id) }
        guard !back.isEmpty else { return }
        trash.removeAll { set.contains($0.id) }
        for i in back.indices { back[i].trashedAt = nil; persist(back[i]) }
        shots.append(contentsOf: back)
        shots.sort { $0.captured > $1.captured }
        Diag.log(.delete, "restored \(back.count)")
    }

    /// Deletes for good: the files are removed.
    func deleteForever(_ ids: [UUID]) {
        let set = Set(ids)
        shots.removeAll { set.contains($0.id) }
        trash.removeAll { set.contains($0.id) }
        for id in ids {
            recipes[id] = nil
            try? FileManager.default.removeItem(at: dir(id))
        }
        Diag.log(.delete, "deleted \(ids.count) for good")
    }

    func emptyTrash() { deleteForever(trash.map(\.id)) }

    /// The 30-day sweep: unkept shots to the trash, old trash deleted.
    func applyRetention(storeForever: Bool, now: Date = Date()) {
        let toTrash = ShotRetention.dueForTrash(shots, now: now, storeForever: storeForever)
        if !toTrash.isEmpty { moveToTrash(toTrash, now: now) }
        let toPurge = ShotRetention.dueForPurge(trash, now: now)
        if !toPurge.isEmpty { deleteForever(toPurge) }
    }

    // MARK: Images

    enum ImageKind: String { case thumb, preview }

    /// The graded render (the camera's quick preview until it exists). Cached per revision.
    func image(_ shot: Shot, _ kind: ImageKind) async -> UIImage? {
        let key = "\(shot.id.uuidString)-\(shot.revision)-\(kind.rawValue)" as NSString
        if let cached = images.object(forKey: key) { return cached }
        let dir = self.dir(shot.id)
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            for name in ["\(kind.rawValue).jpg", "preview.jpg", "capture.jpg"] {
                if let img = UIImage(contentsOfFile: dir.appendingPathComponent(name).path) {
                    return img.preparingForDisplay() ?? img
                }
            }
            return nil
        }.value
        if let image, FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(kind.rawValue).jpg").path) {
            images.setObject(image, forKey: key)
        }
        return image
    }

    /// Synchronous cache lookup (no disk), for first frames.
    func cachedImage(_ shot: Shot, _ kind: ImageKind) -> UIImage? {
        images.object(forKey: "\(shot.id.uuidString)-\(shot.revision)-\(kind.rawValue)" as NSString)
    }
}

/// Carries a settled grade out of a `BakeQueue` job.
private final class RecipeBox: @unchecked Sendable {
    var value: EditRecipe?
}
