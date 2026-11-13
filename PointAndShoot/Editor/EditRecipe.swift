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

    // Color mixer: 8 bands × (hue, saturation, luminance), -100…100. Stored only when
    // used (nil = untouched), which also keeps older saved edits decoding fine.
    var mixer: [Double]?

    // Film emulation (the Print look). nil = not a film look — older edits decode fine.
    // When set, exposure, contrast, highlights, shadows, saturation and grain act inside
    // the film model instead of as ordinary adjustments (see EditPipeline).
    var film: FilmRecipe?

    /// Key-path views of the film settings, for the sliders (only shown with a film look).
    var filmHalation: Double {
        get { film?.halation ?? FilmRecipe().halation }
        set { film?.halation = newValue }
    }
    var filmCrossover: Double {
        get { film?.crossover ?? FilmRecipe().crossover }
        set { film?.crossover = newValue }
    }

    /// Always-24-values view of the mixer, for key-path based sliders.
    var mixerValues: [Double] {
        get { mixer ?? Array(repeating: 0, count: ColorBand.allCases.count * 3) }
        set { mixer = newValue.allSatisfy { $0 == 0 } ? nil : newValue }
    }

    var isGeometryIdentity: Bool {
        crop == CGRect(x: 0, y: 0, width: 1, height: 1) && straighten == 0 && quarterTurns % 4 == 0 && !flipped
    }

    /// This recipe's look (tone, color, detail, effects) on top of `target`'s crop and RAW
    /// settings — for pasting an edit onto another photo.
    func look(appliedTo target: EditRecipe) -> EditRecipe {
        var r = self
        r.crop = target.crop
        r.straighten = target.straighten
        r.quarterTurns = target.quarterTurns
        r.flipped = target.flipped
        r.useRAW = target.useRAW
        r.rawInitialized = target.rawInitialized
        r.rawNoiseReduction = target.rawNoiseReduction
        r.rawLocalTone = target.rawLocalTone
        r.rawBoost = target.rawBoost
        return r
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

/// Settings of the film emulation that have no ordinary-edit equivalent.
struct FilmRecipe: Codable, Equatable {
    /// 0…100; 50 = the look as designed.
    var halation: Double = 50
    /// -100…100; 0 = the look's own color crossover (warm highlights, cool shadows),
    /// -100 = none, +100 = double.
    var crossover: Double = 0

    /// Grain amount the look starts with (EditRecipe.grain, 0…100; 50 = as designed).
    static let defaultGrain: Double = 50
}

/// Copy an edit from one photo, paste it on the next.
enum EditClipboard {
    static var recipe: EditRecipe?
}

enum ColorBand: Int, CaseIterable, Identifiable {
    case red, orange, yellow, green, aqua, blue, purple, magenta
    var id: Int { rawValue }

    var name: String {
        switch self {
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .aqua: "Aqua"
        case .blue: "Blue"
        case .purple: "Purple"
        case .magenta: "Magenta"
        }
    }

    /// Center hue in degrees.
    var hue: Double {
        switch self {
        case .red: 0
        case .orange: 30
        case .yellow: 60
        case .green: 120
        case .aqua: 180
        case .blue: 240
        case .purple: 270
        case .magenta: 300
        }
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

    /// Details for a film look: the film's own grain and halation come first.
    static let filmDetails: [Adjustment] = [
        .init(id: "grain", name: "Grain", range: 0...100, keyPath: \.grain),
        .init(id: "halation", name: "Halation", range: 0...100, keyPath: \.filmHalation),
        .init(id: "crossover", name: "Crossover", range: -100...100, keyPath: \.filmCrossover),
        .init(id: "structure", name: "Structure", range: -100...100, keyPath: \.structure),
        .init(id: "sharpen", name: "Sharpening", range: 0...100, keyPath: \.sharpen),
        .init(id: "fade", name: "Fade", range: 0...100, keyPath: \.fade),
        .init(id: "vignette", name: "Vignette", range: -100...100, keyPath: \.vignette),
    ]

    /// Hue / Saturation / Luminance for one color band.
    static func mixer(_ band: ColorBand) -> [Adjustment] {
        let base = band.rawValue * 3
        return [
            .init(id: "mix\(base)", name: "\(band.name) Hue", range: -100...100, keyPath: \.mixerValues[base]),
            .init(id: "mix\(base + 1)", name: "\(band.name) Saturation", range: -100...100, keyPath: \.mixerValues[base + 1]),
            .init(id: "mix\(base + 2)", name: "\(band.name) Luminance", range: -100...100, keyPath: \.mixerValues[base + 2]),
        ]
    }

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
    /// One or two plain sentences shown in the filter guide.
    let detail: String
    let apply: (inout EditRecipe) -> Void

    static let all: [Look] = [
        Look(id: "none", name: "Original", detail: "No filter — the photo exactly as captured.") { _ in },
        // Negative printed to print film, applied to the RAW sensor data when there is
        // any (FilmModel.swift). Dense blacks, a long soft highlight shoulder, warm
        // highlights over cool shadows, film color, halation and grain.
        Look(id: "print", name: "Print", detail: "Film from the sensor: a cinema negative printed to print film. Dense blacks, soft highlights, warm-over-cool color, halation and fine grain. Shoots RAW.") { r in
            r.film = FilmRecipe()
            r.grain = FilmRecipe.defaultGrain
            r.rawNoiseReduction = 15
        },
        Look(id: "natural", name: "Natural", detail: "Your photo, just cleaner: a touch more contrast and vibrance, highlights protected.") { r in
            r.contrast = 8; r.vibrance = 12; r.highlights = -10
        },
        Look(id: "warm400", name: "Warm 400", detail: "Warm portrait film: golden cast, lifted shadows, softer contrast and gentle grain. Lovely for people and golden hour.") { r in
            r.warmth = 18; r.fade = 14; r.contrast = -6; r.saturation = -8; r.shadows = 12; r.grain = 18; r.highlights = -15
        },
        Look(id: "portrait", name: "Skin", detail: "Flattering skin: slightly warm, softened texture, calmer highlights.") { r in
            r.warmth = 8; r.saturation = -6; r.vibrance = 6; r.structure = -15; r.highlights = -12; r.contrast = -4
        },
        Look(id: "cool", name: "Cool Air", detail: "Crisp and cool: blue-leaning whites, firmer contrast, quieter color. Overcast days, cities, snow.") { r in
            r.warmth = -16; r.tint = -4; r.contrast = 10; r.saturation = -12; r.blacks = -6
        },
        Look(id: "cine", name: "Cine", detail: "Movie grade: muted color, rolled-off highlights, a hint of warmth and a soft vignette.") { r in
            r.contrast = 14; r.saturation = -16; r.warmth = 6; r.highlights = -22; r.shadows = -6; r.fade = 8; r.vignette = 22
        },
        Look(id: "chrome", name: "Chrome", detail: "Punchy slide film: deep blacks, rich saturation, strong contrast.") { r in
            r.contrast = 22; r.saturation = 14; r.vibrance = -8; r.blacks = -12; r.vignette = 10
        },
        Look(id: "faded", name: "Faded", detail: "Matte and nostalgic: lifted blacks, low contrast, washed-out color, light grain.") { r in
            r.fade = 36; r.contrast = -16; r.saturation = -22; r.warmth = 6; r.grain = 10
        },
        Look(id: "punch", name: "Punch", detail: "Bold and vivid: big contrast, saturated color, extra crunch in the detail.") { r in
            r.contrast = 24; r.vibrance = 30; r.structure = 22; r.blacks = -8
        },
        Look(id: "mono400", name: "Mono 400", detail: "Classic black-and-white film: solid contrast and visible grain.") { r in
            r.mono = true; r.contrast = 24; r.grain = 26; r.blacks = -10; r.structure = 10
        },
        Look(id: "noir", name: "Noir", detail: "High-drama black and white: crushed blacks, bright highlights, heavy vignette.") { r in
            r.mono = true; r.contrast = 52; r.blacks = -30; r.highlights = 10; r.vignette = 38; r.grain = 14
        },
        Look(id: "silver", name: "Silver", detail: "Soft silver-print black and white: gentle contrast, open shadows, fine grain.") { r in
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
