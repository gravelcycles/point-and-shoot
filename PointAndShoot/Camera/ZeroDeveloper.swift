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
        guard let developed = developImage(dng: dng) else { return nil }
        return encode(developed.image, properties: developed.properties,
                      orientation: developed.orientation, asHEIF: asHEIF)
    }

    /// The neutral develop in the sensor's native (unrotated) orientation, the DNG's
    /// orientation tag, and the metadata to write with it. nil if the DNG can't be decoded.
    static func developImage(dng: Data) -> (image: CIImage, orientation: CGImagePropertyOrientation,
                                           properties: [String: Any])? {
        guard let raw = CIRAWFilter(imageData: dng, identifierHint: "com.adobe.raw-image") else { return nil }
        configureNeutral(raw)
        // Keep the sensor's native (unrotated) pixels and carry the DNG's orientation tag
        // instead of baking the rotation in. Photos only accepts a RAW + processed pair
        // (.alternatePhoto) when both have the same dimensions and orientation; an upright
        // 3024×4032 HEIF next to a 4032×3024 DNG tagged "rotate 90°" is rejected with
        // PHPhotosErrorInvalidResource (3300).
        let fileOrientation = raw.orientation
        raw.orientation = .up
        // (The iOS Simulator can't decode RAW: it returns an empty image, so this is nil there.)
        guard let image = raw.outputImage, !image.extent.isEmpty, !image.extent.isInfinite else { return nil }

        var props: [String: Any] = [:]
        for (k, v) in raw.properties { if let key = k as? String { props[key] = v } }
        props[kCGImagePropertyOrientation as String] = fileOrientation.rawValue
        if var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = fileOrientation.rawValue
            props[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        props.removeValue(forKey: kCGImagePropertyDNGDictionary as String)
        return (image, fileOrientation, props)
    }

    /// HEIF/JPEG with the DNG's metadata. If the encoder refuses some of that metadata,
    /// retry with just the orientation rather than losing the develop.
    static func encode(_ image: CIImage, properties: [String: Any], orientation: CGImagePropertyOrientation,
                       asHEIF: Bool) -> Data? {
        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        func write(_ img: CIImage) -> Data? {
            asHEIF
                ? context.heifRepresentation(of: img, format: .RGBA8, colorSpace: colorSpace, options: [quality: 0.92])
                : context.jpegRepresentation(of: img, colorSpace: colorSpace, options: [quality: 0.92])
        }
        if let data = write(image.settingProperties(properties)) { return data }
        return write(image.settingProperties([kCGImagePropertyOrientation as String: orientation.rawValue]))
    }
}
