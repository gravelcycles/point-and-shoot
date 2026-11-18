import CoreImage
import ImageIO
import Observation
import UIKit

enum EditError: LocalizedError {
    case couldNotLoad, couldNotRender
    var errorDescription: String? {
        switch self {
        case .couldNotLoad: "Couldn't open this photo."
        case .couldNotRender: "Couldn't render the edit."
        }
    }
}

/// Edits one shot's grade. Main-actor isolated; heavy work stays in explicit
/// `Task.detached` blocks. Saving writes the grade to the app's library (instant,
/// non-destructive: the RAW is never touched); exporting renders it into Photos.
@MainActor
@Observable
final class EditSession {
    let shot: Shot
    let store: ShotStore

    var recipe = EditRecipe() {
        didSet { if recipe != oldValue { recipeRevision &+= 1 } }
    }
    /// Bumped on every change to the grade: the canvas re-renders its zoom bitmap then.
    @ObservationIgnored private(set) var recipeRevision = 0
    /// The recipe as it was when opened (or last saved) — for "discard changes?".
    private(set) var savedRecipe = EditRecipe()
    /// Quick screen-size image shown instantly while the real source decodes.
    private(set) var placeholder: CIImage?
    private(set) var isLoading = true
    private(set) var hasRAW = false
    private(set) var isSaving = false
    private(set) var lookThumbnails: [String: UIImage] = [:]
    var errorMessage: String?
    /// The shot was moved to the trash while it was open.
    var assetDeleted = false

    /// Downsampled processed source (the camera's preview of a RAW shot, or a processed
    /// original): the compare image, and the source when there's no decodable RAW.
    @ObservationIgnored private var previewBase: CIImage?
    @ObservationIgnored private var previewRAW: CIRAWFilter?
    @ObservationIgnored private var rawDefaults = RAWDefaults()
    @ObservationIgnored private var previewMaxPixels: CGFloat = 2048
    /// Size of the (upright, uncropped) preview source.
    @ObservationIgnored private var sourceSize: CGSize = .zero
    /// Sharper sources for zooming in (`loadDetail`), used while `zoomedIn`.
    @ObservationIgnored private var detailBase: CIImage?
    @ObservationIgnored private var detailRAW: CIRAWFilter?
    @ObservationIgnored private var detailLoading = false
    private(set) var detailReady = false
    /// The canvas is zoomed in: render from the detail source once it's loaded.
    var zoomedIn = false
    private var useDetail: Bool { zoomedIn && detailReady }

    init(shot: Shot, store: ShotStore) {
        self.shot = shot
        self.store = store
    }

    private var dir: URL { store.dir(shot.id) }
    /// A RAW shot always develops from its RAW (its only processed image is the camera's
    /// small preview).
    var developsFromRAW: Bool { hasRAW }
    var hasChanges: Bool { !isLoading && recipe != savedRecipe }
    /// Something to reset: the grade isn't the untouched original.
    var canRevert: Bool { savedRecipe.look != nil || savedRecipe.film != nil || savedRecipe != Self.blank(savedRecipe) }

    /// A fresh grade keeping the RAW develop settled for this shot.
    private static func blank(_ r: EditRecipe) -> EditRecipe {
        var b = EditRecipe()
        b.useRAW = r.useRAW
        b.rawInitialized = r.rawInitialized
        b.rawNoiseReduction = r.rawNoiseReduction
        b.rawLocalTone = r.rawLocalTone
        b.rawBoost = r.rawBoost
        // Matched to the viewfinder at capture and never recomputed: keep it, or a film look
        // picked again later would come out darker than the viewfinder showed.
        b.rawFilmExposure = r.rawFilmExposure
        return b
    }

    // MARK: Loading

    func load(maxPixels: CGFloat) async {
        previewMaxPixels = maxPixels
        if let image = await store.image(shot, .preview) {
            placeholder = CIImage(image: image, options: [.applyOrientationProperty: true])
        }
        let shot = self.shot
        let dir = self.dir
        var loaded = store.recipe(for: shot.id)

        let base = await Task.detached(priority: .userInitiated) {
            Self.decodeSource(dir.appendingPathComponent(shot.isRAW ? "capture.jpg" : shot.original), maxPixels: maxPixels)
        }.value
        previewBase = base

        // Parsing a 25–75 MB DNG is too slow for the main thread.
        let opened = await Task.detached(priority: .userInitiated) { () -> RAWBox? in
            guard let raw = ShotRenderer.rawFilter(shot, in: dir) else { return nil }
            let native = raw.nativeSize
            raw.scaleFactor = Float(min(1, maxPixels / max(native.width, native.height, 1)))
            return RAWBox(raw: raw, defaults: EditPipeline.readDefaults(raw),
                          size: raw.outputImage?.extent.size ?? .zero)
        }.value
        if let opened {
            let raw = opened.raw
            rawDefaults = opened.defaults
            previewRAW = raw
            hasRAW = true
            if !loaded.rawInitialized {
                loaded.rawNoiseReduction = Double(rawDefaults.noiseReduction * 100)
                loaded.rawLocalTone = Double(rawDefaults.localTone * 100)
                loaded.rawBoost = Double(rawDefaults.boost * 100)
                loaded.rawInitialized = true
            }
        } else {
            loaded.useRAW = false
        }
        sourceSize = opened?.size ?? previewBase?.extent.size ?? .zero
        guard previewRAW != nil || previewBase != nil else {
            errorMessage = EditError.couldNotLoad.localizedDescription
            Diag.error(.editor, "couldn't load \(shot.id.uuidString.prefix(8)) for editing")
            isLoading = false
            return
        }

        recipe = loaded
        savedRecipe = loaded
        // A film photo from before film looks had a develop exposure (shot before
        // 2026-11-14) developed its RAW ~1.9 EV dark. Develop it like every film photo now,
        // from the RAW at the fixed exposure; it opens as an unsaved change, so Save keeps it.
        recipe = loaded.withFilmDevelopExposure(hasRAW: hasRAW)
        if recipe != loaded {
            Diag.log(.editor, "film photo \(shot.id.uuidString.prefix(8)) had no develop exposure: using "
                     + String(format: "%+.2f EV", EditRecipe.filmRAWExposure))
        }
        isLoading = false
        Task { await renderLookThumbnails() }
    }

    /// The photo, downsampled to `maxPixels` on its long side and baked into memory once so
    /// every edit starts from pixels, not a decode.
    nonisolated private static func decodeSource(_ url: URL, maxPixels: CGFloat) -> CIImage? {
        guard let full = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
        let scale = min(1, maxPixels / max(full.extent.width, full.extent.height))
        let scaled = full.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0,
        ])
        guard let cg = EditPipeline.context.createCGImage(scaled, from: scaled.extent, format: .RGBA8,
                                                          colorSpace: EditPipeline.displayColorSpace) else { return nil }
        return CIImage(cgImage: cg)
    }

    // MARK: Detail (zoomed in)

    /// The long side of the sharper source used while zoomed in (12 MP photos at full size).
    static let detailMaxPixels: CGFloat = 4096

    /// Loads the sharper source for zooming in: the RAW at (up to) full size. The
    /// screen-size preview stays in use at fit, where it's much cheaper per slider step.
    func loadDetail() async {
        guard !detailLoading, !detailReady, !isLoading else { return }
        detailLoading = true
        defer { detailLoading = false }
        let started = Date()
        let maxPixels = Self.detailMaxPixels
        let shot = self.shot
        let dir = self.dir
        detailRAW = await Task.detached(priority: .userInitiated) { () -> RAWBox? in
            guard let raw = ShotRenderer.rawFilter(shot, in: dir) else { return nil }
            let native = raw.nativeSize
            raw.scaleFactor = Float(min(1, maxPixels / max(native.width, native.height, 1)))
            return RAWBox(raw: raw, defaults: RAWDefaults(), size: .zero)
        }.value?.raw
        if !shot.isRAW || detailRAW == nil {
            let url = dir.appendingPathComponent(shot.isRAW ? "capture.jpg" : shot.original)
            detailBase = await Task.detached(priority: .userInitiated) {
                Self.decodeSource(url, maxPixels: maxPixels)
            }.value
        }
        guard detailRAW != nil || detailBase != nil else {
            Diag.error(.editor, "couldn't load the zoomed-in source for \(shot.id.uuidString.prefix(8))")
            return
        }
        detailReady = true
        Diag.log(.editor, "zoom source in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
    }

    /// The photo's native pixel size (for how far the canvas can zoom).
    var pixelSize: CGSize { CGSize(width: shot.pixelWidth ?? 4032, height: shot.pixelHeight ?? 3024) }

    // MARK: Rendering

    /// The source before any edit (for press-and-hold compare).
    var originalPreview: CIImage? { (useDetail ? detailBase : nil) ?? previewBase ?? placeholder }

    /// Source with geometry but no crop — what the crop tool draws on.
    func uncroppedPreview() -> CIImage? {
        guard let base = sourcePreview() else { return nil }
        var r = recipe
        r.crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        return EditPipeline.apply(r, to: base, developedFromRAW: developsFromRAW, applyCrop: false)
    }

    func editedPreview() -> CIImage? {
        guard let base = sourcePreview() else { return placeholder }
        return EditPipeline.apply(recipe, to: base, developedFromRAW: developsFromRAW)
    }

    private func sourcePreview() -> CIImage? {
        if developsFromRAW, let raw = (useDetail ? detailRAW : nil) ?? previewRAW {
            EditPipeline.configure(raw, recipe: recipe, defaults: rawDefaults)
            return raw.outputImage
        }
        return (useDetail ? detailBase : nil) ?? previewBase
    }

    /// Aspect (w/h) of the oriented, straightened frame — for crop aspect presets.
    var orientedAspect: CGFloat {
        let size = sourceSize
        guard size.width > 0, size.height > 0 else { return 1 }
        let turned = ((recipe.quarterTurns % 4) + 4) % 2 == 1
        return turned ? size.height / size.width : size.width / size.height
    }

    private func renderLookThumbnails() async {
        guard let base = previewBase ?? placeholder else { return }
        let recipe = self.recipe
        let thumbs = await Task.detached(priority: .utility) { () -> [String: UIImage] in
            let s = 220 / max(base.extent.width, base.extent.height)
            var small = base.transformed(by: CGAffineTransform(scaleX: s, y: s))
            small = small.transformed(by: CGAffineTransform(translationX: -small.extent.minX, y: -small.extent.minY))
            var result: [String: UIImage] = [:]
            for look in Look.all {
                var r = recipe
                r.resetTone()
                r.crop = CGRect(x: 0, y: 0, width: 1, height: 1)
                look.apply(&r)
                let img = EditPipeline.apply(r, to: small, developedFromRAW: false)
                if let cg = EditPipeline.context.createCGImage(img, from: img.extent, format: .RGBA8,
                                                               colorSpace: EditPipeline.displayColorSpace) {
                    result[look.id] = UIImage(cgImage: cg)
                }
            }
            return result
        }.value
        lookThumbnails = thumbs
    }

    func apply(look: Look) {
        var r = recipe
        r.resetTone()
        look.apply(&r)
        r.look = look.id == "none" ? nil : look.id
        recipe = r
    }

    /// The camera's own value for a RAW develop slider (what its reset goes back to).
    func rawDefault(_ id: String) -> Double? {
        guard hasRAW else { return nil }
        switch id {
        case "rawNR": return Double(rawDefaults.noiseReduction * 100)
        case "rawLTM": return Double(rawDefaults.localTone * 100)
        case "rawBoost": return Double(rawDefaults.boost * 100)
        default: return nil
        }
    }

    /// "Reset This Image": back to `grade` (the default grade), or with nil to the untouched
    /// original. The crop and this photo's RAW develop are kept.
    func resetToGrade(_ grade: EditRecipe?) {
        var r = Self.blank(recipe)
        if let grade {
            let geometry = recipe
            r = grade
            r.useRAW = geometry.useRAW
            r.rawInitialized = geometry.rawInitialized
            r.rawNoiseReduction = geometry.rawNoiseReduction
            r.rawLocalTone = geometry.rawLocalTone
            r.rawBoost = geometry.rawBoost
            r.rawFilmExposure = geometry.rawFilmExposure
        }
        r.crop = recipe.crop
        r.straighten = recipe.straighten
        r.quarterTurns = recipe.quarterTurns
        r.flipped = recipe.flipped
        // A film grade on a photo that had none develops at the fixed film exposure.
        if r.film != nil, r.rawFilmExposure == nil { r.rawFilmExposure = EditRecipe.filmRAWExposure }
        recipe = r
    }

    // MARK: Saving

    /// Saves the grade to the library (the shot's preview re-renders in the background).
    @discardableResult
    func save() async -> Bool {
        guard store.shots.contains(where: { $0.id == shot.id }) else {
            assetDeleted = true
            return false
        }
        guard store.setRecipe(recipe, for: shot.id) else {
            errorMessage = "Couldn't save the edit. Is the phone's storage full?"
            return false
        }
        recipe = store.recipe(for: shot.id)
        savedRecipe = recipe
        return true
    }

    /// Saves the grade, then exports the photo rendered into Photos.
    @discardableResult
    func saveCopy(options: ShotExporter.Options = ShotExporter.Options(CameraSettings.load())) async -> Bool {
        isSaving = true
        defer { isSaving = false }
        if store.shot(shot.id) != nil, !store.setRecipe(recipe, for: shot.id) {
            errorMessage = "Couldn't save the edit. Is the phone's storage full?"
            return false
        }
        savedRecipe = recipe
        guard let current = store.shot(shot.id) else { return false }
        do {
            try await ShotExporter.exportToPhotos([current], store: store, options: options)
            return true
        } catch {
            Diag.error(.editor, "export failed", error)
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Back to the untouched original (no look, every slider at zero).
    @discardableResult
    func revertToOriginal() async -> Bool {
        recipe = Self.blank(recipe)
        return await save()
    }
}

/// A RAW filter opened off the main thread, handed back once (never shared after).
private struct RAWBox: @unchecked Sendable {
    let raw: CIRAWFilter
    let defaults: RAWDefaults
    let size: CGSize
}
