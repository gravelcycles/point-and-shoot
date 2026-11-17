import CoreImage
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Renders a shot's original with its grade: the viewer's preview, the grid thumbnail, the
/// editor's source, and exports. Everything goes through `EditPipeline`, the same graph the
/// editor draws, so what you export is what you saw.
enum ShotRenderer {
    static let previewSide: CGFloat = 2048
    static let thumbSide: CGFloat = 360

    /// The original, opened for rendering at most `maxSide` pixels on the long side
    /// (nil = full resolution).
    struct Source {
        var image: CIImage
        /// Developed from the RAW (scene light), rather than a processed image.
        var fromRAW: Bool
        var raw: CIRAWFilter?
        var defaults = RAWDefaults()
    }

    static func originalData(_ shot: Shot, in dir: URL) -> Data? {
        try? Data(contentsOf: dir.appendingPathComponent(shot.original), options: .mappedIfSafe)
    }

    /// A RAW filter for the shot's DNG, or nil when it has none or it can't be decoded
    /// (the simulator decodes no RAW: an empty extent).
    static func rawFilter(_ shot: Shot, in dir: URL) -> CIRAWFilter? {
        let ext = (shot.original as NSString).pathExtension
        let hint = UTType(filenameExtension: ext)?.identifier ?? "com.adobe.raw-image"
        guard shot.isRAW, let data = originalData(shot, in: dir),
              let raw = CIRAWFilter(imageData: data, identifierHint: hint) else { return nil }
        let native = raw.nativeSize
        guard native.width > 1, native.height > 1 else { return nil }
        return raw
    }

    static func source(_ shot: Shot, in dir: URL, recipe: EditRecipe, maxSide: CGFloat?) -> Source? {
        // A RAW shot always develops from its RAW when it decodes: the only processed image
        // it has is the camera's 1440 px preview.
        if let raw = rawFilter(shot, in: dir) {
            let defaults = EditPipeline.readDefaults(raw)
            let native = raw.nativeSize
            if let maxSide { raw.scaleFactor = Float(min(1, maxSide / max(native.width, native.height))) }
            EditPipeline.configure(raw, recipe: recipe, defaults: defaults)
            if let image = raw.outputImage, image.extent.width > 1 {
                return Source(image: image, fromRAW: true, raw: raw, defaults: defaults)
            }
        }
        // A processed original, or the camera's quick preview where the RAW can't be decoded.
        let file = shot.isRAW ? "capture.jpg" : shot.original
        guard let image = CIImage(contentsOf: dir.appendingPathComponent(file),
                                  options: [.applyOrientationProperty: true]) else { return nil }
        return Source(image: scaled(image, maxSide: maxSide), fromRAW: false)
    }

    static func scaled(_ image: CIImage, maxSide: CGFloat?) -> CIImage {
        let long = max(image.extent.width, image.extent.height)
        guard let maxSide, long > maxSide else { return image }
        let scaled = image.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: maxSide / long, kCIInputAspectRatioKey: 1.0,
        ])
        return scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.minX, y: -scaled.extent.minY))
    }

    /// The graded image.
    static func render(_ shot: Shot, in dir: URL, recipe: EditRecipe, maxSide: CGFloat?) -> CIImage? {
        guard let source = source(shot, in: dir, recipe: recipe, maxSide: maxSide) else { return nil }
        return EditPipeline.apply(recipe, to: source.image, developedFromRAW: source.fromRAW)
    }

    /// Settles the RAW develop a fresh shot starts from, as the editor would: the camera's
    /// own noise reduction (floored for film looks, which add grain and have no
    /// sharpening), and a film look's exposure matched to what the viewfinder showed.
    static func prepare(_ recipe: EditRecipe, shot: Shot, in dir: URL, viewfinderKey: Double?) -> EditRecipe {
        var r = recipe
        r.freezeFilmTuning()
        guard shot.isRAW, let raw = rawFilter(shot, in: dir) else {
            r.useRAW = shot.isRAW
            return r
        }
        let defaults = EditPipeline.readDefaults(raw)
        if !r.rawInitialized {
            let nr = Double(defaults.noiseReduction * 100)
            r.rawNoiseReduction = r.film != nil ? max(nr, EditRecipe.filmMinimumNoiseReduction) : nr
            r.rawLocalTone = Double(defaults.localTone * 100)
            r.rawBoost = Double(defaults.boost * 100)
            r.rawInitialized = true
        }
        if r.film != nil, r.rawFilmExposure == nil {
            let reference = CIImage(contentsOf: dir.appendingPathComponent("capture.jpg"),
                                    options: [.applyOrientationProperty: true])
            let target = viewfinderKey ?? reference.flatMap {
                FilmPipeline.sceneKey(of: $0, context: EditPipeline.context, source: .displayReferred)
            }
            if let target { r.rawFilmExposure = matchedExposure(raw, recipe: r, defaults: defaults, target: target) }
        }
        return r
    }

    /// Stops that bring the RAW develop's scene key to `target` (measured small: the key is
    /// an average). Clamped: a night scene Apple's video lifts hard shouldn't push the film
    /// more than 2.5 stops.
    private static func matchedExposure(_ raw: CIRAWFilter, recipe: EditRecipe, defaults: RAWDefaults,
                                        target: Double) -> Double? {
        var r = recipe
        r.rawFilmExposure = 0
        EditPipeline.configure(raw, recipe: r, defaults: defaults)
        let native = raw.nativeSize
        raw.scaleFactor = Float(min(1, 256 / max(native.width, native.height, 1)))
        guard let image = raw.outputImage,
              let key = FilmPipeline.sceneKey(of: image, context: EditPipeline.context, source: .sceneLinear),
              key > 0, target > 0 else { return nil }
        let ev = min(max(log2(target / key), -1.5), 2.5)
        return (ev * 100).rounded() / 100
    }

    // MARK: Files

    static func writeJPEG(_ image: CIImage, to url: URL, quality: Double) throws {
        let q = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        try EditPipeline.context.writeJPEGRepresentation(of: image, to: url, colorSpace: EditPipeline.displayColorSpace,
                                                         options: [q: quality])
    }

    enum ExportFormat: String, Codable, CaseIterable, Identifiable {
        case heif, jpeg
        var id: String { rawValue }
        var label: String { self == .heif ? "HEIF" : "JPEG" }
        var fileExtension: String { self == .heif ? "heic" : "jpg" }
    }

    /// The finished photo: graded, sized (`maxSide` nil = the photo's own resolution) and
    /// encoded, carrying the original's metadata (capture settings, GPS).
    static func exportData(_ shot: Shot, in dir: URL, recipe: EditRecipe, format: ExportFormat,
                           maxSide: CGFloat?, quality: Double) -> Data? {
        guard var image = render(shot, in: dir, recipe: recipe, maxSide: nil) else { return nil }
        image = scaled(image, maxSide: maxSide)
        if let data = originalData(shot, in: dir), let props = CIImage(data: data)?.properties {
            image = image.settingProperties(RecipeBaker.uprightProperties(props))
        }
        let q = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        let ctx = EditPipeline.context
        switch format {
        case .heif:
            return ctx.heifRepresentation(of: image, format: .RGBA8, colorSpace: EditPipeline.displayColorSpace,
                                          options: [q: quality])
        case .jpeg:
            return ctx.jpegRepresentation(of: image, colorSpace: EditPipeline.displayColorSpace, options: [q: quality])
        }
    }

    /// The preview JPEG embedded in a RAW file (upright), for RAWs that arrive without the
    /// camera's quick preview.
    static func embeddedPreview(of data: Data, maxSide: Int = 1440) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxSide,
              ] as CFDictionary) else { return nil }
        return jpegData(of: cg, orientation: .up)
    }

    /// JPEG of the camera's quick preview, upright via its orientation tag.
    static func jpegData(of cg: CGImage, orientation: CGImagePropertyOrientation, quality: Double = 0.85) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyOrientation: orientation.rawValue,
        ] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
