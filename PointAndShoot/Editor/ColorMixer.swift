import CoreGraphics
import Foundation

/// HSL color mixer baked into a 3D lookup table, so all 24 sliders cost one GPU texture
/// lookup per pixel. Works in sRGB (perceptual) space; greys are left alone so skin, skies
/// and foliage can be pushed without tinting neutrals.
enum ColorMixer {
    static let size = 32
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private static let lock = NSLock()
    private static var cache: [[Double]: Data] = [:]

    static func cube(for mixer: [Double]) -> Data {
        lock.lock()
        if let cached = cache[mixer] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let data = build(mixer)

        lock.lock()
        if cache.count > 32 { cache.removeAll() }
        cache[mixer] = data
        lock.unlock()
        return data
    }

    private static func build(_ m: [Double]) -> Data {
        let n = size
        let centers = ColorBand.allCases.map(\.hue)
        let step = 1.0 / Double(n - 1)
        var cube = [Float]()
        cube.reserveCapacity(n * n * n * 4)

        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    var rgb = (Double(r) * step, Double(g) * step, Double(b) * step)
                    var (h, s, l) = rgbToHSL(rgb.0, rgb.1, rgb.2)
                    if s > 0.0001 {
                        let (i, j, t) = neighbors(of: h, centers: centers)
                        func blend(_ k: Int) -> Double { (m[i * 3 + k] * (1 - t) + m[j * 3 + k] * t) / 100 }
                        // Fade the effect in with saturation so neutrals stay neutral.
                        let strength = smoothstep(0.0, 0.22, s)
                        h += blend(0) * 30 * strength
                        h = h.truncatingRemainder(dividingBy: 360)
                        if h < 0 { h += 360 }
                        s = min(1, max(0, s * (1 + blend(1) * strength)))
                        let headroom = 1 - abs(2 * l - 1) * 0.5
                        l = min(1, max(0, l + blend(2) * 0.32 * strength * headroom))
                        rgb = hslToRGB(h, s, l)
                    }
                    cube.append(Float(rgb.0))
                    cube.append(Float(rgb.1))
                    cube.append(Float(rgb.2))
                    cube.append(1)
                }
            }
        }
        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// The two band centers a hue sits between, and how far along (0…1) it is.
    private static func neighbors(of hue: Double, centers: [Double]) -> (Int, Int, Double) {
        let count = centers.count
        for i in 0..<count {
            let start = centers[i]
            let end = i + 1 < count ? centers[i + 1] : centers[0] + 360
            let h = hue < start && i == count - 1 ? hue + 360 : hue
            if h >= start && h < end {
                return (i, (i + 1) % count, (h - start) / (end - start))
            }
        }
        return (0, 1, 0)
    }

    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    static func rgbToHSL(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let maxV = max(r, g, b), minV = min(r, g, b)
        let l = (maxV + minV) / 2
        let d = maxV - minV
        guard d > 1e-9 else { return (0, 0, l) }
        let s = l > 0.5 ? d / (2 - maxV - minV) : d / (maxV + minV)
        var h: Double
        if maxV == r {
            h = (g - b) / d + (g < b ? 6 : 0)
        } else if maxV == g {
            h = (b - r) / d + 2
        } else {
            h = (r - g) / d + 4
        }
        h *= 60
        return (h, s, l)
    }

    static func hslToRGB(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
        guard s > 1e-9 else { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        let hk = h / 360
        func channel(_ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return (channel(hk + 1.0 / 3), channel(hk), channel(hk - 1.0 / 3))
    }
}
