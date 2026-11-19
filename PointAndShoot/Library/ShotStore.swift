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
    /// Renders queued per shot: "developing" lasts until the last one finishes.
    @ObservationIgnored private var pendingRenders: [UUID: Int] = [:]
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
        // Merge, don't replace: a shot added (a capture, a Lock Screen import) while the
        // folder was being read is newer than what's on disk, and must neither vanish nor
        // appear twice.
        var byID: [UUID: Shot] = [:]
        for shot in loaded { byID[shot.id] = shot }
        for shot in shots + trash { byID[shot.id] = shot }
        let all = Array(byID.values)
        shots = all.filter { $0.trashedAt == nil }.sorted { $0.captured > $1.captured }
        trash = all.filter { $0.trashedAt != nil }.sorted { $0.trashedAt! > $1.trashedAt! }
        isLoaded = true
        Diag.log(.roll, "library: \(shots.count) photos, \(trash.count) in trash")
        let known = Set(all.map(\.id))
        Task.detached(priority: .utility) { Self.sweepOrphans(in: root, keeping: known) }
        for shot in shots where !FileManager.default.fileExists(atPath: dir(shot.id).appendingPathComponent("preview.jpg").path) {
            develop(shot.id)
        }
        settleFilmExposures()
        migrateFilmEngines()
    }

    /// Film grades made with older film math move to the current engine once, with the new
    /// sliders that match their old look (`FilmMigration`: exact for contrast and grain,
    /// fitted for highlights/shadows and saturation), so every photo has today's controls.
    /// Shots whose sliders changed re-render.
    private func migrateFilmEngines() {
        for shot in shots + trash {
            let r = recipe(for: shot.id)
            let result = FilmMigration.migrate(r, developsFromRAW: shot.isRAW && r.useRAW)
            guard result.changed else { continue }
            let url = dir(shot.id).appendingPathComponent("recipe.json")
            // Recoverable: the grade as it was is kept next to it (the first backup wins,
            // so a later migration never overwrites the original).
            let backup = dir(shot.id).appendingPathComponent(FilmMigration.backupName)
            do {
                if !FileManager.default.fileExists(atPath: backup.path) {
                    try JSONEncoder().encode(r).write(to: backup, options: .atomic)
                }
                try JSONEncoder().encode(result.recipe).write(to: url, options: .atomic)
            } catch {
                Diag.error(.editor, "couldn't move the grade of \(shot.id.uuidString.prefix(8)) to film engine \(FilmRecipe.currentEngine)", error)
                continue
            }
            recipes[shot.id] = result.recipe
            var sameSliders = result.recipe
            sameSliders.film?.engine = r.film?.engine
            Diag.log(.editor, "grade \(shot.id.uuidString.prefix(8)) moved from film engine \(r.film?.renderEngine ?? 1) to \(FilmRecipe.currentEngine)"
                     + String(format: " (grey-scale fit error %.3f): ", result.toneError) + result.recipe.developSummary)
            if sameSliders != r, shots.contains(where: { $0.id == shot.id }) { develop(shot.id) }
        }
    }

    /// Film shots still on an earlier build's automatic develop exposure (#42's +1.86,
    /// #52's Bayer +0.54) move to the natural one for their scene and RAW type
    /// (`EditRecipe.withFilmDevelopExposure`) and re-render, once. Any other value stays.
    private func settleFilmExposures() {
        for shot in shots + trash where shot.isRAW {
            let r = recipe(for: shot.id)
            let settled = r.withFilmDevelopExposure(for: shot)
            guard settled != r else { continue }
            let url = dir(shot.id).appendingPathComponent("recipe.json")
            do { try JSONEncoder().encode(settled).write(to: url, options: .atomic) } catch {
                Diag.error(.editor, "couldn't settle the film exposure of \(shot.id.uuidString.prefix(8))", error)
                continue
            }
            recipes[shot.id] = settled
            Diag.log(.bake, "film exposure of \(shot.kind.rawValue) shot \(shot.id.uuidString.prefix(8)) (EV100 \(shot.ev100.map { String(format: "%.1f", $0) } ?? "?")): "
                     + String(format: "%@ → %+.2f EV", r.rawFilmExposure.map { String(format: "%+.2f", $0) } ?? "none",
                              settled.rawFilmExposure ?? 0))
            if shots.contains(where: { $0.id == shot.id }) { develop(shot.id) }
        }
    }

    /// Undoes the film-engine migration: every shot with a backup gets its grade from before
    /// the update back (and re-renders), and migration is switched off so it isn't redone.
    /// Returns how many grades were restored.
    @discardableResult
    func restorePreMigrationGrades() -> Int {
        UserDefaults.standard.set(false, forKey: FilmMigration.enabledKey)
        var restored = 0
        for shot in shots + trash {
            let backup = dir(shot.id).appendingPathComponent(FilmMigration.backupName)
            guard let data = try? Data(contentsOf: backup), let r = EditRecipe.decodeSaved(data) else { continue }
            let url = dir(shot.id).appendingPathComponent("recipe.json")
            do {
                try data.write(to: url, options: .atomic)
                try FileManager.default.removeItem(at: backup)
            } catch {
                Diag.error(.editor, "couldn't restore the grade of \(shot.id.uuidString.prefix(8))", error)
                continue
            }
            recipes[shot.id] = r
            restored += 1
            if shots.contains(where: { $0.id == shot.id }) { develop(shot.id) }
        }
        Diag.log(.editor, "restored \(restored) grades from before the film-engine update; migration off")
        return restored
    }

    /// How many shots have a grade backed up from before the film-engine update.
    func preMigrationBackupCount() -> Int {
        (shots + trash).filter {
            FileManager.default.fileExists(atPath: dir($0.id).appendingPathComponent(FilmMigration.backupName).path)
        }.count
    }

    /// Back in the foreground: shots whose graded preview never got rendered (the app was
    /// backgrounded mid-render, where the GPU isn't available) are developed again.
    func redevelopMissing() {
        guard isLoaded else { return }
        for shot in shots where !developing.contains(shot.id)
            && !FileManager.default.fileExists(atPath: dir(shot.id).appendingPathComponent("preview.jpg").path) {
            develop(shot.id)
        }
    }

    /// Folders with no readable record that are over an hour old: a capture that failed
    /// mid-write. Removed so their DNGs don't fill the phone unseen.
    private nonisolated static func sweepOrphans(in root: URL, keeping ids: Set<UUID>) {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for dir in dirs {
            guard let id = UUID(uuidString: dir.lastPathComponent), !ids.contains(id) else { continue }
            // Only folders that never got a record. One whose record exists but didn't
            // decode (a future format, a read error) is left alone: never delete a real shot.
            if fm.fileExists(atPath: dir.appendingPathComponent("shot.json").path) { continue }
            let modified = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            if Date().timeIntervalSince(modified) > 3600 {
                try? fm.removeItem(at: dir)
                Diag.error(.roll, "removed an incomplete shot folder \(id.uuidString.prefix(8))")
            }
        }
    }

    // MARK: Adding

    /// Stores a capture (or import) and starts rendering its graded preview. Returns as soon
    /// as the files are written: the shot shows (with the camera's preview) right away.
    @discardableResult
    func add(original: Data, fileExtension: String, kind: Shot.Kind, capturePreview: Data?,
             recipe: EditRecipe, captured: Date = Date(),
             id: UUID = UUID()) async throws -> Shot {
        var shot = Shot(id: id, captured: captured, kind: kind, original: "original.\(fileExtension)")
        shot.added = Date()
        // A grade made with older film math (an imported archive, a Default Grade) moves to
        // today's, looking the same (`FilmMigration`).
        let recipe = FilmMigration.migrate(recipe, developsFromRAW: kind != .processed && recipe.useRAW).recipe
        shot.readMetadata(from: original)
        let dir = self.dir(id)
        let record = shot
        try await Task.detached(priority: .userInitiated) {
            do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try original.write(to: dir.appendingPathComponent(record.original))
            // The camera's quick preview; for a RAW without one (Lock Screen, imports) the
            // DNG's own embedded preview, so there's always an image and a brightness
            // reference for film looks.
            if let preview = capturePreview ?? (record.isRAW ? ShotRenderer.embeddedPreview(of: original) : nil) {
                try preview.write(to: dir.appendingPathComponent("capture.jpg"))
            }
            try JSONEncoder().encode(recipe).write(to: dir.appendingPathComponent("recipe.json"))
            // Last and atomic: a folder is only a shot once its record is complete.
            try JSONEncoder().encode(record).write(to: dir.appendingPathComponent("shot.json"), options: .atomic)
            } catch {
                // Disk full, say: don't leave a half-written folder (and a 25 MB DNG) behind.
                try? FileManager.default.removeItem(at: dir)
                throw error
            }
        }.value
        recipes[id] = recipe
        shots.removeAll { $0.id == id }
        trash.removeAll { $0.id == id }
        shots.insert(shot, at: 0)
        shots.sort { $0.captured > $1.captured }
        Diag.log(.save, "stored \(id.uuidString.prefix(8)) \(kind.rawValue) \(original.count / 1024) KB")
        develop(id)
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

    /// Saves a new grade and re-renders the shot's preview and thumbnail. False if it
    /// couldn't be written (the editor says so instead of "Saved").
    @discardableResult
    func setRecipe(_ recipe: EditRecipe, for id: UUID) -> Bool {
        var r = recipe
        r.freezeFilmTuning()
        // A film grade develops its RAW at the fixed exposure for its RAW type (picking a
        // look leaves it to the photo), the same as the editor showed.
        if let shot = shot(id) {
            r = r.withFilmDevelopExposure(for: shot)
            // A pasted grade from older film math moves to today's, looking the same.
            r = FilmMigration.migrate(r, developsFromRAW: shot.isRAW && r.useRAW).recipe
        }
        let url = dir(id).appendingPathComponent("recipe.json")
        do { try JSONEncoder().encode(r).write(to: url, options: .atomic) } catch {
            Diag.error(.editor, "couldn't save the grade of \(id.uuidString.prefix(8))", error)
            return false
        }
        recipes[id] = r
        Diag.log(.editor, "grade stored \(id.uuidString.prefix(8)) (\(shot(id)?.kind.rawValue ?? "?")): \(r.developSummary)")
        // Settle the RAW develop too (a shot edited before its first develop finished needs
        // its noise reduction). Brightness is never changed: it comes from the grade.
        develop(id)
        return true
    }

    /// Renders the graded preview and thumbnail, one shot at a time. The grade is settled
    /// first (RAW noise reduction where it has none, a film look's fixed exposure).
    private func develop(_ id: UUID) {
        guard let shot = shot(id) else { return }
        pendingRenders[id, default: 0] += 1
        developing.insert(id)
        let dir = self.dir(id)
        let recipe = recipe(for: id)
        Task {
            let result = await Self.renderPreviews(shot: shot, dir: dir, recipe: recipe)
            // Only if the grade hasn't changed meanwhile: an edit saved while this shot was
            // still developing must never be overwritten by the capture's own settle.
            if let settled = result, settled != recipe, recipes[id] == recipe {
                recipes[id] = settled
                let url = dir.appendingPathComponent("recipe.json")
                do { try JSONEncoder().encode(settled).write(to: url, options: .atomic) } catch {
                    Diag.error(.editor, "couldn't save the settled grade of \(id.uuidString.prefix(8))", error)
                }
            }
            bumpRevision(id)
            let left = (pendingRenders[id] ?? 1) - 1
            pendingRenders[id] = left > 0 ? left : nil
            if left <= 0 { developing.remove(id) }
        }
    }

    private nonisolated static func renderPreviews(shot: Shot, dir: URL, recipe: EditRecipe) async -> EditRecipe? {
        let box = RecipeBox()
        await BakeQueue.shared.run {
            let start = Date()
            let r = ShotRenderer.prepare(recipe, shot: shot, in: dir)
            // Kept even if the render below fails (backgrounded).
            box.value = r
            guard let preview = ShotRenderer.render(shot, in: dir, recipe: r, maxSide: ShotRenderer.previewSide) else {
                Diag.error(.bake, "couldn't render \(shot.id.uuidString.prefix(8))")
                return
            }
            do {
                try ShotRenderer.writeJPEG(preview, to: dir.appendingPathComponent("preview.jpg"), quality: 0.9)
                let thumb = ShotRenderer.scaled(preview, maxSide: ShotRenderer.thumbSide)
                try ShotRenderer.writeJPEG(thumb, to: dir.appendingPathComponent("thumb.jpg"), quality: 0.85)
                Diag.log(.bake, "rendered \(shot.id.uuidString.prefix(8)) (\(shot.kind.rawValue)) in \(Int(Date().timeIntervalSince(start) * 1000)) ms: \(r.developSummary)")
            } catch {
                Diag.error(.bake, "couldn't write the preview of \(shot.id.uuidString.prefix(8))", error)
            }
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

    func restore(_ ids: [UUID], now: Date = Date()) {
        let set = Set(ids)
        var back = trash.filter { set.contains($0.id) }
        guard !back.isEmpty else { return }
        trash.removeAll { set.contains($0.id) }
        for i in back.indices {
            back[i].trashedAt = nil
            // Only a shot already past its 30 days gets a fresh 30 from now (or the next
            // sweep would trash it again); an Undo keeps the days it had.
            if !ShotRetention.dueForTrash([back[i]], now: now, storeForever: false).isEmpty {
                back[i].restoredAt = now
            }
            persist(back[i])
        }
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
