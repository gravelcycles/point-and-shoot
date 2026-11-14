import CoreImage
import Metal

struct RAWDefaults {
    var temperature: Float = 5500
    var tint: Float = 0
    var noiseReduction: Float = 0.5
    var localTone: Float = 0.5
    var boost: Float = 1
    var sharpness: Float = 0
    var detail: Float = 0
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
            boost: raw.boostAmount,
            sharpness: raw.isSharpnessSupported ? raw.sharpnessAmount : 0,
            detail: raw.isDetailSupported ? raw.detailAmount : 0)
    }

    static func configure(_ raw: CIRAWFilter, recipe r: EditRecipe, defaults d: RAWDefaults) {
        raw.exposure = Float(r.exposure / 50)
        raw.neutralTemperature = max(2000, min(50000, d.temperature + Float(r.warmth) * 40))
        raw.neutralTint = max(-150, min(150, d.tint + Float(r.tint) * 1.2))
        if raw.isLuminanceNoiseReductionSupported { raw.luminanceNoiseReductionAmount = Float(r.rawNoiseReduction / 100) }
        if r.film != nil {
            // The film look needs plain scene light: no tone curve, no local tone mapping
            // and no sharpening (the film model supplies the tone and texture).
            if raw.isLocalToneMapSupported { raw.localToneMapAmount = 0 }
            raw.boostAmount = 0
            if raw.isSharpnessSupported { raw.sharpnessAmount = 0 }
            if raw.isDetailSupported { raw.detailAmount = 0 }
        } else {
            if raw.isLocalToneMapSupported { raw.localToneMapAmount = Float(r.rawLocalTone / 100) }
            raw.boostAmount = Float(r.rawBoost / 100)
            if raw.isSharpnessSupported { raw.sharpnessAmount = d.sharpness }
            if raw.isDetailSupported { raw.detailAmount = d.detail }
        }
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

    /// `animateGrain`: move film grain every call (the live viewfinder).
    static func apply(_ r: EditRecipe, to base: CIImage, developedFromRAW: Bool, applyCrop: Bool = true,
                      animateGrain: Bool = false) -> CIImage {
        var image = orient(base, recipe: r)
        if applyCrop && r.crop != CGRect(x: 0, y: 0, width: 1, height: 1) {
            image = crop(image, to: r.crop)
        }
        let bounds = image.extent
        // Radii are relative to image size so preview and export look the same.
        let unit = max(bounds.width, bounds.height) / 1000

        if !developedFromRAW && r.exposure != 0 && r.film == nil {
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: r.exposure / 50])
        }
        if !developedFromRAW && (r.warmth != 0 || r.tint != 0) {
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 + r.warmth * 32, y: r.tint),
            ])
        }

        // Tone: either the film model, or local highlight/shadow + a global curve.
        var curveRecipe = r
        if let film = r.film {
            var fs = FilmPipeline.Settings()
            fs.stockID = film.stock ?? FilmStock.printLook.id
            fs.source = developedFromRAW ? .sceneLinear : .displayReferred
            fs.exposure = developedFromRAW ? 0 : r.exposure / 50   // RAW: already in the develop
            fs.halation = film.halation / 50
            fs.grain = r.grain / 50
            fs.controls = FilmControls(contrast: r.contrast / 100, saturation: r.saturation / 100,
                                       crossover: film.crossover / 100,
                                       highlights: r.highlights / 100, shadows: r.shadows / 100)
            fs.animateGrain = animateGrain
            image = FilmPipeline.apply(image, settings: fs, unit: unit)
            // Whites, blacks and fade still apply on top, as a curve.
            curveRecipe.contrast = 0
            curveRecipe.highlights = 0
            curveRecipe.shadows = 0
        } else if r.highlights < 0 || r.shadows > 0 {
            // Local highlight recovery / shadow lift.
            image = image.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1 + min(0, r.highlights) / 100 * 0.85,
                "inputShadowAmount": max(0, r.shadows) / 100 * 0.9,
                "inputRadius": 12 * unit,
            ])
        }

        // Global tone curve, applied in perceptual (gamma) space.
        let points = curvePoints(curveRecipe)
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

        // Color mixer before mono, so in B&W it works like darkroom color filters.
        if let mixer = r.mixer, mixer.contains(where: { $0 != 0 }) {
            image = image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": ColorMixer.size,
                "inputCubeData": ColorMixer.cube(for: mixer),
                "inputColorSpace": ColorMixer.colorSpace,
            ])
        }

        if r.vibrance != 0 {
            image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": r.vibrance / 100])
        }
        if r.mono {
            // Panchromatic-ish channel mix, a little red-sensitive like classic B&W stock,
            // toned by the film stock when there is one (Noir cool, Silver warm).
            let tone = r.film.map { FilmStock.named($0.stock).monoTone }.map { $0.map { CGFloat($0) } } ?? [1, 1, 1]
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.34 * tone[0], y: 0.56 * tone[0], z: 0.10 * tone[0], w: 0),
                "inputGVector": CIVector(x: 0.34 * tone[1], y: 0.56 * tone[1], z: 0.10 * tone[1], w: 0),
                "inputBVector": CIVector(x: 0.34 * tone[2], y: 0.56 * tone[2], z: 0.10 * tone[2], w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ])
        } else if r.saturation != 0 && r.film == nil {
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

        if r.grain > 0 && r.film == nil { image = addGrain(image, amount: r.grain / 100, unit: unit) }

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
