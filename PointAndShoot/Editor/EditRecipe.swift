import CoreGraphics
import Foundation

/// A non-destructive edit. Stored in Photos as PHAdjustmentData so it can be re-opened,
/// tweaked, or reverted in Photos at any time.
struct EditRecipe: Codable, Equatable {
    static let formatID = "com.pointandshoot.recipe"
    static let formatVersion = "1"

    // Light
    var exposure: Double = 0
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0

    // Color
    var warmth: Double = 0
    var tint: Double = 0
    var saturation: Double = 0
    var vibrance: Double = 0

    // Detail & effects
    var structure: Double = 0
    var sharpen: Double = 0
    var fade: Double = 0
    var grain: Double = 0
    var vignette: Double = 0
    var mono: Bool = false
    var look: String?

    // Geometry (crop is normalized, top-left origin, in the rotated/straightened frame)
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    var straighten: Double = 0
    var quarterTurns: Int = 0
    var flipped = false

    // RAW development
    var useRAW = true
    var rawInitialized = false
    var rawNoiseReduction: Double = 50
    var rawLocalTone: Double = 50
    var rawBoost: Double = 100

    var isGeometryIdentity: Bool {
        crop == CGRect(x: 0, y: 0, width: 1, height: 1) && straighten == 0 && quarterTurns % 4 == 0 && !flipped
    }

    /// Clears tone & color (used before applying a Look), keeping geometry and RAW settings.
    mutating func resetTone() {
        let keep = self
        self = EditRecipe()
        crop = keep.crop
        straighten = keep.straighten
        quarterTurns = keep.quarterTurns
        flipped = keep.flipped
        useRAW = keep.useRAW
        rawInitialized = keep.rawInitialized
        rawNoiseReduction = keep.rawNoiseReduction
        rawLocalTone = keep.rawLocalTone
        rawBoost = keep.rawBoost
    }
}

struct Adjustment: Identifiable {
    let id: String
    let name: String
    let range: ClosedRange<Double>
    let keyPath: WritableKeyPath<EditRecipe, Double>

    var isBipolar: Bool { range.lowerBound < 0 }

    static let tune: [Adjustment] = [
        .init(id: "exposure", name: "Exposure", range: -100...100, keyPath: \.exposure),
        .init(id: "contrast", name: "Contrast", range: -100...100, keyPath: \.contrast),
        .init(id: "highlights", name: "Highlights", range: -100...100, keyPath: \.highlights),
        .init(id: "shadows", name: "Shadows", range: -100...100, keyPath: \.shadows),
        .init(id: "whites", name: "Whites", range: -100...100, keyPath: \.whites),
        .init(id: "blacks", name: "Blacks", range: -100...100, keyPath: \.blacks),
        .init(id: "saturation", name: "Saturation", range: -100...100, keyPath: \.saturation),
        .init(id: "vibrance", name: "Vibrance", range: -100...100, keyPath: \.vibrance),
        .init(id: "warmth", name: "Warmth", range: -100...100, keyPath: \.warmth),
        .init(id: "tint", name: "Tint", range: -100...100, keyPath: \.tint),
    ]

    static let details: [Adjustment] = [
        .init(id: "structure", name: "Structure", range: -100...100, keyPath: \.structure),
        .init(id: "sharpen", name: "Sharpening", range: 0...100, keyPath: \.sharpen),
        .init(id: "fade", name: "Fade", range: 0...100, keyPath: \.fade),
        .init(id: "grain", name: "Grain", range: 0...100, keyPath: \.grain),
        .init(id: "vignette", name: "Vignette", range: -100...100, keyPath: \.vignette),
    ]

    static let raw: [Adjustment] = [
        .init(id: "rawNR", name: "Noise Reduction", range: 0...100, keyPath: \.rawNoiseReduction),
        .init(id: "rawLTM", name: "Apple Local Tone", range: 0...100, keyPath: \.rawLocalTone),
        .init(id: "rawBoost", name: "Film Contrast", range: 0...100, keyPath: \.rawBoost),
        .init(id: "exposure", name: "Exposure", range: -100...100, keyPath: \.exposure),
        .init(id: "warmth", name: "Temperature", range: -100...100, keyPath: \.warmth),
        .init(id: "tint", name: "Tint", range: -100...100, keyPath: \.tint),
    ]
}

struct Look: Identifiable {
    let id: String
    let name: String
    let apply: (inout EditRecipe) -> Void

    static let all: [Look] = [
        Look(id: "none", name: "Original") { _ in },
        Look(id: "natural", name: "Natural") { r in
            r.contrast = 8; r.vibrance = 12; r.highlights = -10
        },
        Look(id: "warm400", name: "Warm 400") { r in
            r.warmth = 18; r.fade = 14; r.contrast = -6; r.saturation = -8; r.shadows = 12; r.grain = 18; r.highlights = -15
        },
        Look(id: "portrait", name: "Skin") { r in
            r.warmth = 8; r.saturation = -6; r.vibrance = 6; r.structure = -15; r.highlights = -12; r.contrast = -4
        },
        Look(id: "cool", name: "Cool Air") { r in
            r.warmth = -16; r.tint = -4; r.contrast = 10; r.saturation = -12; r.blacks = -6
        },
        Look(id: "cine", name: "Cine") { r in
            r.contrast = 14; r.saturation = -16; r.warmth = 6; r.highlights = -22; r.shadows = -6; r.fade = 8; r.vignette = 22
        },
        Look(id: "chrome", name: "Chrome") { r in
            r.contrast = 22; r.saturation = 14; r.vibrance = -8; r.blacks = -12; r.vignette = 10
        },
        Look(id: "faded", name: "Faded") { r in
            r.fade = 36; r.contrast = -16; r.saturation = -22; r.warmth = 6; r.grain = 10
        },
        Look(id: "punch", name: "Punch") { r in
            r.contrast = 24; r.vibrance = 30; r.structure = 22; r.blacks = -8
        },
        Look(id: "mono400", name: "Mono 400") { r in
            r.mono = true; r.contrast = 24; r.grain = 26; r.blacks = -10; r.structure = 10
        },
        Look(id: "noir", name: "Noir") { r in
            r.mono = true; r.contrast = 52; r.blacks = -30; r.highlights = 10; r.vignette = 38; r.grain = 14
        },
        Look(id: "silver", name: "Silver") { r in
            r.mono = true; r.contrast = -8; r.fade = 22; r.shadows = 20; r.grain = 12
        },
    ]
}

enum CropAspect: String, CaseIterable, Identifiable {
    case free, original, square, fourFive, threeTwo, sixteenNine, scope
    var id: String { rawValue }
    var label: String {
        switch self {
        case .free: "Free"
        case .original: "Original"
        case .square: "1:1"
        case .fourFive: "4:5"
        case .threeTwo: "3:2"
        case .sixteenNine: "16:9"
        case .scope: "2.39"
        }
    }
    /// width / height, oriented to match the image (landscape image → landscape crop).
    func ratio(imageAspect: CGFloat) -> CGFloat? {
        let base: CGFloat?
        switch self {
        case .free: return nil
        case .original: return imageAspect
        case .square: base = 1
        case .fourFive: base = 5.0 / 4.0
        case .threeTwo: base = 3.0 / 2.0
        case .sixteenNine: base = 16.0 / 9.0
        case .scope: base = 2.39
        }
        guard let base else { return nil }
        return imageAspect >= 1 ? base : 1 / base
    }
}
