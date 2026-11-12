import CoreImage
import Metal

struct RAWDefaults {
    var temperature: Float = 5500
    var tint: Float = 0
    var noiseReduction: Float = 0.5
    var localTone: Float = 0.5
    var boost: Float = 1
}

/// The whole edit as a Core Image graph. Building the graph is cheap; Core Image fuses it
/// into a handful of GPU passes when it's drawn, so sliders stay at display refresh rate.
enum EditPipeline {
    static let device: MTLDevice = MTLCreateSystemDefaultDevice()!
    static let queue: MTLCommandQueue = device.makeCommandQueue()!
    static let context = CIContext(mtlCommandQueue: queue, options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .name: "editor",
    ])
    static let displayColorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    // MARK: RAW

    static func readDefaults(_ raw: CIRAWFilter) -> RAWDefaults {
        RAWDefaults(
            temperature: raw.neutralTemperature,
            tint: raw.neutralTint,
            noiseReduction: raw.isLuminanceNoiseReductionSupported ? raw.luminanceNoiseReductionAmount : 0,
            localTone: raw.isLocalToneMapSupported ? raw.localToneMapAmount : 0,
            boost: raw.boostAmount)
    }

    static func configure(_ raw: CIRAWFilter, recipe r: EditRecipe, defaults d: RAWDefaults) {
        raw.exposure = Float(r.exposure / 50)
        raw.neutralTemperature = max(2000, min(50000, d.temperature + Float(r.warmth) * 40))
        raw.neutralTint = max(-150, min(150, d.tint + Float(r.tint) * 1.2))
        if raw.isLuminanceNoiseReductionSupported { raw.luminanceNoiseReductionAmount = Float(r.rawNoiseReduction / 100) }
        if raw.isLocalToneMapSupported { raw.localToneMapAmount = Float(r.rawLocalTone / 100) }
        raw.boostAmount = Float(r.rawBoost / 100)
    }

    // MARK: Geometry

    /// Rotation, flip and straighten (with auto-fill so no empty corners).
    static func orient(_ input: CIImage, recipe r: EditRecipe) -> CIImage {
        var image = input
        switch ((r.quarterTurns % 4) + 4) % 4 {
        case 1: image = image.oriented(.right)
        case 2: image = image.oriented(.down)
        case 3: image = image.oriented(.left)
        default: break
        }
        if r.flipped { image = image.oriented(.upMirrored) }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))

        if r.straighten != 0 {
            let e = image.extent
            let a = CGFloat(abs(r.straighten)) * .pi / 180
            let s = max((e.width * cos(a) + e.height * sin(a)) / e.width,
                        (e.width * sin(a) + e.height * cos(a)) / e.height)
            let c = CGPoint(x: e.midX, y: e.midY)
            // Positive straighten = clockwise on screen = negative in CI's y-up space.
            let t = CGAffineTransform(translationX: -c.x, y: -c.y)
                .concatenating(CGAffineTransform(rotationAngle: -CGFloat(r.straighten) * .pi / 180))
                .concatenating(CGAffineTransform(scaleX: s, y: s))
                .concatenating(CGAffineTransform(translationX: c.x, y: c.y))
            image = image.clampedToExtent().transformed(by: t).cropped(to: e)
        }
        return image
    }

    static func crop(_ image: CIImage, to crop: CGRect) -> CIImage {
        let e = image.extent
        let rect = CGRect(x: e.minX + crop.minX * e.width,
                          y: e.minY + (1 - crop.maxY) * e.height,
                          width: crop.width * e.width,
                          height: crop.height * e.height).integral
        return image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    // MARK: Full graph

    static func apply(_ r: EditRecipe, to base: CIImage, developedFromRAW: Bool, applyCrop: Bool = true) -> CIImage {
        var image = orient(base, recipe: r)
        if applyCrop && r.crop != CGRect(x: 0, y: 0, width: 1, height: 1) {
            image = crop(image, to: r.crop)
        }
        let bounds = image.extent
        // Radii are relative to image size so preview and export look the same.
        let unit = max(bounds.width, bounds.height) / 1000

        if !developedFromRAW && r.exposure != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: r.exposure / 50])
        }
        if !developedFromRAW && (r.warmth != 0 || r.tint != 0) {
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 + r.warmth * 32, y: r.tint),
            ])
        }

        // Local highlight recovery / shadow lift.
        if r.highlights < 0 || r.shadows > 0 {
            image = image.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1 + min(0, r.highlights) / 100 * 0.85,
                "inputShadowAmount": max(0, r.shadows) / 100 * 0.9,
                "inputRadius": 12 * unit,
            ])
        }

        // Global tone curve, applied in perceptual (gamma) space.
        let points = curvePoints(r)
        if points != identityCurve {
            image = image
                .applyingFilter("CILinearToSRGBToneCurve")
                .applyingFilter("CIToneCurve", parameters: [
                    "inputPoint0": CIVector(x: points[0].x, y: points[0].y),
                    "inputPoint1": CIVector(x: points[1].x, y: points[1].y),
                    "inputPoint2": CIVector(x: points[2].x, y: points[2].y),
                    "inputPoint3": CIVector(x: points[3].x, y: points[3].y),
                    "inputPoint4": CIVector(x: points[4].x, y: points[4].y),
                ])
                .applyingFilter("CISRGBToneCurveToLinear")
        }

        if r.vibrance != 0 {
            image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": r.vibrance / 100])
        }
        if r.mono {
            // Panchromatic-ish channel mix, a little red-sensitive like classic B&W stock.
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.34, y: 0.56, z: 0.10, w: 0),
                "inputGVector": CIVector(x: 0.34, y: 0.56, z: 0.10, w: 0),
                "inputBVector": CIVector(x: 0.34, y: 0.56, z: 0.10, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ])
        } else if r.saturation != 0 {
            image = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 + r.saturation / 100])
        }

        if r.structure != 0 {
            image = image.applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: 22 * unit,
                kCIInputIntensityKey: r.structure / 100 * 0.9,
            ])
        }
        if r.sharpen > 0 {
            image = image.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: r.sharpen / 100 * 0.9,
                kCIInputRadiusKey: max(1, 0.6 * unit),
            ])
        }

        if r.vignette != 0 {
            image = image.applyingFilter("CIVignetteEffect", parameters: [
                kCIInputCenterKey: CIVector(x: bounds.midX, y: bounds.midY),
                kCIInputRadiusKey: 0.62 * hypot(bounds.width, bounds.height) / 2,
                kCIInputIntensityKey: r.vignette / 100 * 0.9,
                "inputFalloff": 0.7,
            ])
        }

        if r.grain > 0 { image = addGrain(image, amount: r.grain / 100, unit: unit) }

        return image.cropped(to: bounds)
    }

    static let identityCurve: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.5, y: 0.5),
        CGPoint(x: 0.75, y: 0.75), CGPoint(x: 1, y: 1),
    ]

    static func curvePoints(_ r: EditRecipe) -> [CGPoint] {
        let c = r.contrast / 100, h = r.highlights / 100, s = r.shadows / 100
        let w = r.whites / 100, b = r.blacks / 100, f = r.fade / 100
        func clamp(_ v: Double) -> Double { min(1, max(0, v)) }

        let p0 = CGPoint(x: max(0, -b * 0.12), y: clamp(max(0, b) * 0.12 + f * 0.2))
        let p1 = CGPoint(x: 0.25, y: clamp(0.25 - c * 0.07 + (s < 0 ? s * 0.08 : s * 0.03) + f * 0.06))
        let p2 = CGPoint(x: 0.5, y: 0.5)
        let p3 = CGPoint(x: 0.75, y: clamp(0.75 + c * 0.07 + (h > 0 ? h * 0.08 : h * 0.03)))
        let p4: CGPoint = w >= 0
            ? CGPoint(x: 1 - w * 0.12, y: clamp(1 - f * 0.05))
            : CGPoint(x: 1, y: clamp(1 + w * 0.15 - f * 0.05))
        return [p0, p1, p2, p3, p4]
    }

    private static func addGrain(_ image: CIImage, amount: Double, unit: CGFloat) -> CIImage {
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }
        let bounds = image.extent
        let size = max(1, unit * 0.9)
        let k = amount * 0.45
        let grain = noise
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: k, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: k, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0.5 - k / 2, y: 0.5 - k / 2, z: 0.5 - k / 2, w: 1),
            ])
            .transformed(by: CGAffineTransform(scaleX: size, y: size))
            .cropped(to: bounds)
        return grain
            .applyingFilter("CISoftLightBlendMode", parameters: [
                kCIInputBackgroundImageKey: image.applyingFilter("CILinearToSRGBToneCurve"),
            ])
            .applyingFilter("CISRGBToneCurveToLinear")
    }
}
