import CoreImage
import Foundation
import Vision

/// The editor's Lightroom-style extras, for every look: colour grading (a tint each for
/// shadows, midtones and highlights), a parametric tone curve, dehaze, and sky / subject
/// masks with their own exposure and saturation. Each is off at 0 and can be hidden in
/// Preferences → Processing → Editor Controls.
enum ExtraGrades {
    // MARK: Curve + colour grading (one cube)

    struct GradeParams: Hashable {
        var curve: [Double]          // highlights, lights, darks, shadows: −1…1
        var tints: [Double]          // shadow hue°, amount, mid hue°, amount, highlight hue°, amount (0…1)
        var isIdentity: Bool { curve.allSatisfy { $0 == 0 } && stride(from: 1, to: tints.count, by: 2).allSatisfy { tints[$0] == 0 } }
    }

    static let cubeSize = 33
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let lock = NSLock()
    private static var cache: [GradeParams: Data] = [:]

    /// The parametric curve (Lightroom's Highlights / Lights / Darks / Shadows) on encoded
    /// values: smooth bumps that leave black and white where they are, kept monotone.
    static func curve(_ x: Double, _ p: [Double]) -> Double {
        let regions: [(c: Double, w: Double)] = [(0.85, 0.12), (0.62, 0.14), (0.38, 0.14), (0.15, 0.12)]
        var y = x
        for (k, r) in regions.enumerated() where p[k] != 0 {
            y += 0.15 * p[k] * exp(-pow((x - r.c) / r.w, 2)) * 4 * x * (1 - x)
        }
        return min(max(y, 0), 1)
    }

    /// A luminance-neutral tint for a hue (degrees): the hue's colour minus its luminance.
    static func tint(hue: Double) -> (Double, Double, Double) {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
        let rgb: (Double, Double, Double)
        switch Int(h) {
        case 0: rgb = (1, x, 0)
        case 1: rgb = (x, 1, 0)
        case 2: rgb = (0, 1, x)
        case 3: rgb = (0, x, 1)
        case 4: rgb = (x, 0, 1)
        default: rgb = (1, 0, x)
        }
        let y = 0.2126 * rgb.0 + 0.7152 * rgb.1 + 0.0722 * rgb.2
        return (rgb.0 - y, rgb.1 - y, rgb.2 - y)
    }

    static func gradeCube(_ p: GradeParams) -> Data {
        lock.lock()
        if let d = cache[p] { lock.unlock(); return d }
        lock.unlock()
        let n = cubeSize
        let step = 1.0 / Double(n - 1)
        // Monotone curve table (running max), then per-region tints weighted by luminance.
        var table = [Double](repeating: 0, count: n)
        var last = 0.0
        for i in 0..<n { last = max(last, curve(Double(i) * step, p.curve)); table[i] = last }
        let ts = tint(hue: p.tints[0]), tm = tint(hue: p.tints[2]), th = tint(hue: p.tints[4])
        let ks = 0.18 * p.tints[1], km = 0.12 * p.tints[3], kh = 0.18 * p.tints[5]
        func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
            let t = min(max((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t)
        }
        var cube = [Float](repeating: 1, count: n * n * n * 4)
        var o = 0
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    var c = (table[r], table[g], table[b])
                    let y = 0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2
                    let ws = 1 - smooth(0, 0.6, y), wh = smooth(0.4, 1, y), wm = max(0, 1 - ws - wh)
                    c.0 += ws * ks * ts.0 + wm * km * tm.0 + wh * kh * th.0
                    c.1 += ws * ks * ts.1 + wm * km * tm.1 + wh * kh * th.1
                    c.2 += ws * ks * ts.2 + wm * km * tm.2 + wh * kh * th.2
                    cube[o] = Float(min(max(c.0, 0), 1))
                    cube[o + 1] = Float(min(max(c.1, 0), 1))
                    cube[o + 2] = Float(min(max(c.2, 0), 1))
                    o += 4
                }
            }
        }
        let data = cube.withUnsafeBufferPointer { Data(buffer: $0) }
        lock.lock()
        if cache.count > 16 { cache.removeAll() }
        cache[p] = data
        lock.unlock()
        return data
    }

    static func applyGrade(_ image: CIImage, _ p: GradeParams) -> CIImage {
        guard !p.isIdentity else { return image }
        return image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": cubeSize,
            "inputCubeData": gradeCube(p),
            "inputColorSpace": colorSpace,
        ])
    }

    // MARK: Dehaze

    /// −1…1. Clearing: wide-radius local contrast, a deeper black point and a little more
    /// colour (haze is low contrast, lifted and grey). Adding: a pale blue-grey veil.
    static func dehaze(_ image: CIImage, amount d: Double, unit: CGFloat) -> CIImage {
        guard d != 0 else { return image }
        let bounds = image.extent
        if d > 0 {
            let k = CGFloat(d)
            return image
                .applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 70 * unit, kCIInputIntensityKey: 0.75 * k])
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 1 + 0.03 * k, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 1 + 0.03 * k, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 1 + 0.03 * k, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputBiasVector": CIVector(x: -0.012 * k, y: -0.012 * k, z: -0.012 * k, w: 0),
                ])
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 + 0.25 * k])
                .cropped(to: bounds)
        }
        let k = CGFloat(-d) * 0.4
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1 - k, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1 - k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1 - k, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0.30 * k, y: 0.33 * k, z: 0.38 * k, w: 0),
        ])
    }

    // MARK: Masks

    /// Exposure (stops) and saturation (−1…1) inside a mask.
    static func adjust(_ image: CIImage, mask: CIImage, exposure: Double, saturation: Double) -> CIImage {
        guard exposure != 0 || saturation != 0 else { return image }
        var adjusted = image
        if exposure != 0 { adjusted = adjusted.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposure]) }
        if saturation != 0 {
            adjusted = adjusted.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 + saturation])
        }
        return adjusted.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask,
        ]).cropped(to: image.extent)
    }

    private static let skyLock = NSLock()
    private static var skyCubeData: Data?

    /// How sky-like a colour is (sRGB): bright, and blue or neutral rather than warm
    /// (skin, sunlit walls) or green (foliage).
    private static func skyCube() -> Data {
        skyLock.lock(); defer { skyLock.unlock() }
        if let d = skyCubeData { return d }
        let n = 16, step = 1.0 / Double(n - 1)
        func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
            let t = min(max((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t)
        }
        var cube = [Float](repeating: 1, count: n * n * n * 4)
        var o = 0
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let R = Double(r) * step, G = Double(g) * step, B = Double(b) * step
                    let y = 0.2126 * R + 0.7152 * G + 0.0722 * B
                    let bright = smooth(0.3, 0.65, y)
                    let notWarm = max(0, min(1, 1 - (R - B - 0.08) * 6))
                    let notGreen = max(0, min(1, 1 - (G - max(R, B) - 0.06) * 6))
                    let s = Float(bright * notWarm * notGreen)
                    cube[o] = s; cube[o + 1] = s; cube[o + 2] = s
                    o += 4
                }
            }
        }
        let d = cube.withUnsafeBufferPointer { Data(buffer: $0) }
        skyCubeData = d
        return d
    }

    /// Where the sky is: sky-coloured, towards the top, softened.
    static func skyMask(_ image: CIImage, unit: CGFloat) -> CIImage {
        let e = image.extent
        let colour = image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": 16, "inputCubeData": skyCube(), "inputColorSpace": colorSpace,
        ])
        let fall = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: e.midX, y: e.maxY - e.height * 0.2),
            "inputPoint1": CIVector(x: e.midX, y: e.maxY - e.height * 0.75),
            "inputColor0": CIColor(red: 1, green: 1, blue: 1),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0),
        ])!.outputImage!.cropped(to: e)
        return colour
            .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: fall])
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(10 * unit))
            .cropped(to: e)
    }

    /// The main subject (people, animals, objects in front), from Vision's foreground
    /// instance mask (iOS 17), worked out once per source image and framing and cached.
    /// nil where Vision can't (the simulator, nothing found).
    static func subjectMask(source: CIImage, framed image: CIImage, key: String) -> CIImage? {
        maskLock.lock()
        let table = subjectMasks
        let entry = table.object(forKey: source) as? [String: Any]
        maskLock.unlock()
        if let entry, entry["key"] as? String == key {
            return (entry["mask"] as? CIImage).map { fit($0, to: image.extent) }
        }
        let mask = computeSubjectMask(image)
        maskLock.lock()
        table.setObject(["key": key, "mask": mask as Any] as NSDictionary, forKey: source)
        maskLock.unlock()
        return mask.map { fit($0, to: image.extent) }
    }

    private static let maskLock = NSLock()
    private static let subjectMasks = NSMapTable<CIImage, NSDictionary>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    private static func fit(_ mask: CIImage, to e: CGRect) -> CIImage {
        let m = mask.extent
        guard m.width > 0, m.height > 0 else { return mask }
        return mask
            .transformed(by: CGAffineTransform(translationX: -m.minX, y: -m.minY))
            .transformed(by: CGAffineTransform(scaleX: e.width / m.width, y: e.height / m.height))
            .transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
            .cropped(to: e)
    }

    private static func computeSubjectMask(_ image: CIImage) -> CIImage? {
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return nil }
        let s = min(1, 768 / max(e.width, e.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        guard let cg = EditPipeline.context.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: colorSpace)
        else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg)
        do {
            try handler.perform([request])
            guard let result = request.results?.first else { return nil }
            let buffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
            // One channel: spread it to grey, opaque, so any blend reads it the same.
            return CIImage(cvPixelBuffer: buffer).applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        } catch {
            Diag.error(.editor, "subject mask failed", error)
            return nil
        }
    }
}
