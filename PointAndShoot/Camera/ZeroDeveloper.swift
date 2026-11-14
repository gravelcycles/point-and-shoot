import CoreImage
import ImageIO

/// "Zero" processing: take the Bayer DNG straight off the sensor and develop it like a
/// film scan — no local tone mapping, no luminance smoothing, no oversharpening.
/// Just demosaic, white balance, a gentle global tone curve, and a touch of chroma NR.
enum ZeroDeveloper {
    static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .cacheIntermediates: false,
        .name: "zero-developer",
    ])

    static func configureNeutral(_ raw: CIRAWFilter) {
        raw.isGamutMappingEnabled = true
        if raw.isLocalToneMapSupported { raw.localToneMapAmount = 0 }
        if raw.isLuminanceNoiseReductionSupported { raw.luminanceNoiseReductionAmount = 0 }
        // Chroma noise is never "texture" — remove a little of it.
        if raw.isColorNoiseReductionSupported { raw.colorNoiseReductionAmount = 0.3 }
        if raw.isSharpnessSupported { raw.sharpnessAmount = 0.1 }
        if raw.isDetailSupported { raw.detailAmount = 0 }
        raw.extendedDynamicRangeAmount = 0
        raw.boostAmount = 1
    }

    static func develop(dng: Data, asHEIF: Bool) -> Data? {
        guard let raw = CIRAWFilter(imageData: dng, identifierHint: "com.adobe.raw-image") else { return nil }
        configureNeutral(raw)
        // Keep the sensor's native (unrotated) pixels and carry the DNG's orientation tag
        // instead of baking the rotation in. Photos only accepts a RAW + processed pair
        // (.alternatePhoto) when both have the same dimensions and orientation; an upright
        // 3024×4032 HEIF next to a 4032×3024 DNG tagged "rotate 90°" is rejected with
        // PHPhotosErrorInvalidResource (3300).
        let fileOrientation = raw.orientation
        raw.orientation = .up
        guard var image = raw.outputImage else { return nil }

        var props: [String: Any] = [:]
        for (k, v) in raw.properties { if let key = k as? String { props[key] = v } }
        props[kCGImagePropertyOrientation as String] = fileOrientation.rawValue
        if var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = fileOrientation.rawValue
            props[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        props.removeValue(forKey: kCGImagePropertyDNGDictionary as String)
        image = image.settingProperties(props)

        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        if asHEIF {
            return context.heifRepresentation(of: image, format: .RGBA8, colorSpace: colorSpace, options: [quality: 0.92])
        }
        return context.jpegRepresentation(of: image, colorSpace: colorSpace, options: [quality: 0.92])
    }
}
