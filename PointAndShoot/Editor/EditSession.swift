import CoreImage
import ImageIO
import Observation
import Photos
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

@Observable
final class EditSession {
    let asset: PHAsset

    var recipe = EditRecipe()
    /// The recipe as it was when opened (or last saved) — for "discard changes?".
    private(set) var savedRecipe = EditRecipe()
    /// Quick screen-size image shown instantly while the real source decodes.
    private(set) var placeholder: CIImage?
    private(set) var isLoading = true
    private(set) var hasRAW = false
    private(set) var isSaving = false
    private(set) var lookThumbnails: [String: UIImage] = [:]
    var errorMessage: String?

    /// Downsampled, cached source for interactive preview (Apple's rendering).
    @ObservationIgnored private var previewBase: CIImage?
    @ObservationIgnored private var previewRAW: CIRAWFilter?
    @ObservationIgnored private var rawData: Data?
    @ObservationIgnored private var rawDefaults = RAWDefaults()
    @ObservationIgnored private var input: PHContentEditingInput?
    @ObservationIgnored private var previewMaxPixels: CGFloat = 2048

    init(asset: PHAsset) {
        self.asset = asset
    }

    var developsFromRAW: Bool { hasRAW && recipe.useRAW }
    var hasChanges: Bool { !isLoading && recipe != savedRecipe }
    var canRevert: Bool { asset.hasAdjustments }

    // MARK: Loading

    func load(maxPixels: CGFloat) async {
        previewMaxPixels = maxPixels
        loadPlaceholder(maxPixels: maxPixels)
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        options.canHandleAdjustmentData = { data in
            data.formatIdentifier == EditRecipe.formatID && data.formatVersion == EditRecipe.formatVersion
        }
        let input: PHContentEditingInput? = await withCheckedContinuation { cont in
            asset.requestContentEditingInput(with: options) { input, _ in cont.resume(returning: input) }
        }
        guard let input, let url = input.fullSizeImageURL else {
            errorMessage = EditError.couldNotLoad.localizedDescription
            isLoading = false
            return
        }
        self.input = input

        var loaded = EditRecipe()
        if let adjustment = input.adjustmentData, adjustment.formatIdentifier == EditRecipe.formatID,
           let saved = try? JSONDecoder().decode(EditRecipe.self, from: adjustment.data) {
            loaded = saved
        }

        let base = await Task.detached(priority: .userInitiated) { () -> CIImage? in
            guard let full = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
            let scale = min(1, maxPixels / max(full.extent.width, full.extent.height))
            let scaled = full.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0,
            ])
            // Bake the downsampled source into memory once so every edit starts from pixels, not a decode.
            guard let cg = EditPipeline.context.createCGImage(scaled, from: scaled.extent, format: .RGBA8,
                                                              colorSpace: EditPipeline.displayColorSpace) else { return nil }
            return CIImage(cgImage: cg)
        }.value

        guard let base else {
            errorMessage = EditError.couldNotLoad.localizedDescription
            isLoading = false
            return
        }
        previewBase = base

        if let data = await PhotoLibrary.rawData(for: asset),
           let raw = CIRAWFilter(imageData: data, identifierHint: nil) {
            rawData = data
            rawDefaults = EditPipeline.readDefaults(raw)
            let native = raw.nativeSize
            raw.scaleFactor = Float(min(1, maxPixels / max(native.width, native.height, 1)))
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

        recipe = loaded
        savedRecipe = loaded
        isLoading = false
        Task { await renderLookThumbnails() }
    }

    private func loadPlaceholder(maxPixels: CGFloat) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.version = .current
        let side = min(maxPixels, 1400)
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                              contentMode: .aspectFit, options: options) { [weak self] image, _ in
            guard let self, let image, self.isLoading else { return }
            self.placeholder = CIImage(image: image, options: [.applyOrientationProperty: true])
        }
    }

    // MARK: Rendering

    /// The source before any edit (for press-and-hold compare).
    var originalPreview: CIImage? { previewBase ?? placeholder }

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
        if developsFromRAW, let raw = previewRAW {
            EditPipeline.configure(raw, recipe: recipe, defaults: rawDefaults)
            return raw.outputImage
        }
        return previewBase
    }

    /// Aspect (w/h) of the oriented, straightened frame — for crop aspect presets.
    var orientedAspect: CGFloat {
        guard let base = previewBase else { return 1 }
        let turned = ((recipe.quarterTurns % 4) + 4) % 2 == 1
        let w = base.extent.width, h = base.extent.height
        return turned ? h / w : w / h
    }

    private func renderLookThumbnails() async {
        guard let base = previewBase else { return }
        let recipe = self.recipe
        let fromRAW = false
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
                let img = EditPipeline.apply(r, to: small, developedFromRAW: fromRAW)
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

    // MARK: Saving

    private func renderFullResolution() async throws -> CIImage {
        guard let input, let url = input.fullSizeImageURL else { throw EditError.couldNotRender }
        let recipe = self.recipe
        let fromRAW = developsFromRAW
        let rawData = self.rawData
        let defaults = rawDefaults
        return try await Task.detached(priority: .userInitiated) { () -> CIImage in
            var base: CIImage?
            if fromRAW, let rawData, let raw = CIRAWFilter(imageData: rawData, identifierHint: nil) {
                EditPipeline.configure(raw, recipe: recipe, defaults: defaults)
                base = raw.outputImage
            } else {
                base = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
            }
            guard let base else { throw EditError.couldNotRender }
            var output = EditPipeline.apply(recipe, to: base, developedFromRAW: fromRAW)
            if let props = CIImage(contentsOf: url)?.properties {
                var p = props
                p[kCGImagePropertyOrientation as String] = 1
                if var tiff = p[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
                    tiff[kCGImagePropertyTIFFOrientation as String] = 1
                    p[kCGImagePropertyTIFFDictionary as String] = tiff
                }
                p.removeValue(forKey: kCGImagePropertyPixelWidth as String)
                p.removeValue(forKey: kCGImagePropertyPixelHeight as String)
                output = output.settingProperties(p)
            }
            return output
        }.value
    }

    /// Non-destructive save: Photos keeps the original and our recipe; revert any time.
    @discardableResult
    func save() async -> Bool {
        guard let input else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            let image = try await renderFullResolution()
            let output = PHContentEditingOutput(contentEditingInput: input)
            output.adjustmentData = PHAdjustmentData(
                formatIdentifier: EditRecipe.formatID,
                formatVersion: EditRecipe.formatVersion,
                data: try JSONEncoder().encode(recipe))
            let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
            try EditPipeline.context.writeJPEGRepresentation(of: image, to: output.renderedContentURL,
                                                             colorSpace: EditPipeline.displayColorSpace,
                                                             options: [quality: 0.95])
            let asset = self.asset
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest(for: asset).contentEditingOutput = output
            }
            savedRecipe = recipe
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func saveCopy() async -> Bool {
        isSaving = true
        defer { isSaving = false }
        do {
            let image = try await renderFullResolution()
            let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
            guard let data = EditPipeline.context.heifRepresentation(of: image, format: .RGBA8,
                                                                    colorSpace: EditPipeline.displayColorSpace,
                                                                    options: [quality: 0.93]) else {
                throw EditError.couldNotRender
            }
            try await PhotoLibrary.saveCopy(data: data)
            savedRecipe = recipe
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func revertToOriginal() async -> Bool {
        let asset = self.asset
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest(for: asset).revertAssetContentToOriginal()
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
