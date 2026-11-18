import CoreLocation
import Foundation
import Photos

/// Gets shots out of the app: rendered with their grade into the iOS photo library (only
/// add access is needed) or as files for the share sheet.
@MainActor
enum ShotExporter {
    struct Options: Equatable {
        var format: ShotRenderer.ExportFormat = .heif
        /// Longest side; nil = the photo's own size.
        var maxSide: CGFloat? = 2880
        var quality: Double = 1

        init(format: ShotRenderer.ExportFormat = .heif, maxSide: CGFloat? = 2880, quality: Double = 1) {
            self.format = format
            self.maxSide = maxSide
            self.quality = quality
        }

        init(_ s: CameraSettings) {
            format = s.exportFormat
            maxSide = s.exportMaxSide > 0 ? CGFloat(s.exportMaxSide) : nil
            quality = min(max(s.exportQuality, 0.1), 1)
        }
    }

    enum ExportError: LocalizedError {
        case couldNotRender
        var errorDescription: String? { "Couldn't render the photo." }
    }

    /// Renders one shot to finished-photo bytes (off the main thread).
    static func render(_ shot: Shot, store: ShotStore, options: Options) async -> Data? {
        // A fresh shot's grade is settled by its first develop (RAW noise reduction, a
        // film look's matched exposure): wait for it, up to a minute.
        for _ in 0..<600 where store.developing.contains(shot.id) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let shot = store.shot(shot.id) ?? shot
        let dir = store.dir(shot.id)
        let recipe = store.recipe(for: shot.id)
        let start = Date()
        let data = await Task.detached(priority: .userInitiated) { () -> Data? in
            // Still unsettled (the develop timed out): settle it here, the same way.
            let r = (recipe.rawInitialized || !shot.isRAW) ? recipe
                : ShotRenderer.prepare(recipe, shot: shot, in: dir)
            return ShotRenderer.exportData(shot, in: dir, recipe: r, format: options.format,
                                           maxSide: options.maxSide, quality: options.quality)
        }.value
        if let data {
            Diag.log(.save, "rendered export of \(shot.id.uuidString.prefix(8)): \(data.count / 1024) KB in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        } else {
            Diag.error(.save, "couldn't render export of \(shot.id.uuidString.prefix(8))")
        }
        return data
    }

    /// Saves each shot, rendered, to Photos. Returns how many were saved.
    @discardableResult
    static func exportToPhotos(_ shots: [Shot], store: ShotStore, options: Options) async throws -> Int {
        try await PhotoLibrary.ensureAddAccess()
        var saved: [UUID] = []
        for shot in shots {
            guard let data = await render(shot, store: store, options: options) else { throw ExportError.couldNotRender }
            let location = shot.latitude.flatMap { lat in shot.longitude.map { CLLocation(latitude: lat, longitude: $0) } }
            try await PhotoLibrary.saveCopy(data: data, location: location)
            saved.append(shot.id)
        }
        store.markExported(saved)
        Diag.log(.save, "exported \(saved.count) to Photos")
        return saved.count
    }

    /// Rendered files in a temporary folder, for the share sheet.
    static func shareFiles(_ shots: [Shot], store: ShotStore, options: Options) async -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Share", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        var urls: [URL] = []
        for (i, shot) in shots.enumerated() {
            guard let data = await render(shot, store: store, options: options) else { continue }
            let name = "PS-\(formatter.string(from: shot.captured))\(shots.count > 1 ? "-\(i + 1)" : "")"
            let url = dir.appendingPathComponent(name).appendingPathExtension(options.format.fileExtension)
            if (try? data.write(to: url)) != nil { urls.append(url) }
        }
        return urls
    }

    /// Auto Export: once the shot's look has been developed, save it to Photos.
    static func autoExport(_ id: UUID, store: ShotStore, options: Options) async {
        for _ in 0..<600 where store.developing.contains(id) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // Not if it was trashed meanwhile.
        guard let shot = store.shots.first(where: { $0.id == id }) else { return }
        do {
            try await exportToPhotos([shot], store: store, options: options)
        } catch {
            Diag.error(.save, "auto export failed", error)
        }
    }
}
