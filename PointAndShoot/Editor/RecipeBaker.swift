import CoreImage
import ImageIO
import Photos

/// Applies an edit recipe to a photo already in the library, non-destructively — the same
/// kind of save the editor does. Used to bake a capture-time Look onto a fresh shot while
/// keeping the untouched original one "Revert" away.
enum RecipeBaker {
    /// `rawData`: the shot's DNG, when the caller still has it in memory. Film looks
    /// develop from it (scene light); other looks use the processed photo.
    static func apply(_ recipe: EditRecipe, toAssetWithID id: String, rawData: Data? = nil) async throws {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
                || PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return }

        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = false
        let input: PHContentEditingInput? = await withCheckedContinuation { cont in
            asset.requestContentEditingInput(with: options) { input, _ in cont.resume(returning: input) }
        }
        guard let input, let url = input.fullSizeImageURL,
              let base = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw EditError.couldNotLoad
        }

        var recipe = recipe
        var output: CIImage
        if recipe.film != nil, let raw = await rawFilter(rawData, asset: asset) {
            let defaults = EditPipeline.readDefaults(raw)
            recipe.rawInitialized = true
            recipe.rawLocalTone = Double(defaults.localTone * 100)
            recipe.rawBoost = Double(defaults.boost * 100)
            EditPipeline.configure(raw, recipe: recipe, defaults: defaults)
            output = raw.outputImage.map { EditPipeline.apply(recipe, to: $0, developedFromRAW: true) }
                ?? EditPipeline.apply(recipe, to: base, developedFromRAW: false)
        } else {
            output = EditPipeline.apply(recipe, to: base, developedFromRAW: false)
        }
        if let props = CIImage(contentsOf: url)?.properties {
            output = output.settingProperties(uprightProperties(props))
        }

        let editingOutput = PHContentEditingOutput(contentEditingInput: input)
        editingOutput.adjustmentData = PHAdjustmentData(
            formatIdentifier: EditRecipe.formatID,
            formatVersion: EditRecipe.formatVersion,
            data: try JSONEncoder().encode(recipe))
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        try EditPipeline.context.writeJPEGRepresentation(of: output, to: editingOutput.renderedContentURL,
                                                         colorSpace: EditPipeline.displayColorSpace,
                                                         options: [quality: 0.95])
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).contentEditingOutput = editingOutput
        }
    }

    private static func rawFilter(_ data: Data?, asset: PHAsset) async -> CIRAWFilter? {
        if let data, let raw = CIRAWFilter(imageData: data, identifierHint: "com.adobe.raw-image") { return raw }
        guard let data = await PhotoLibrary.rawData(for: asset) else { return nil }
        return CIRAWFilter(imageData: data, identifierHint: nil)
    }

    /// Source metadata with orientation reset (pixels are already upright) and stale
    /// dimensions removed.
    static func uprightProperties(_ props: [String: Any]) -> [String: Any] {
        var p = props
        p[kCGImagePropertyOrientation as String] = 1
        if var tiff = p[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            p[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        p.removeValue(forKey: kCGImagePropertyPixelWidth as String)
        p.removeValue(forKey: kCGImagePropertyPixelHeight as String)
        return p
    }
}

extension Look {
    static func named(_ id: String?) -> Look? {
        guard let id else { return nil }
        return all.first { $0.id == id && $0.id != "none" }
    }

    /// A fresh recipe containing just this look.
    var recipe: EditRecipe {
        var r = EditRecipe()
        apply(&r)
        r.look = id
        return r
    }
}
