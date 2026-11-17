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
    /// Film looks baked at capture never develop with less luminance noise reduction.
    static let filmMinimumNoiseReduction: Double = 50
    var rawLocalTone: Double = 50
    var rawBoost: Double = 100
    /// Stops added to the RAW develop under a film look so the shot matches the
    /// viewfinder's brightness (measured when the look is baked at capture). nil = none;
    /// optional so older edits decode.
    var rawFilmExposure: Double?

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

    /// Decodes a saved edit from any app version: fields it lacks take their defaults
    /// (including inside `film`), unknown ones are ignored. Never use plain JSONDecoder for
    /// stored recipes: it fails on the first missing key.
    static func decodeSaved(_ data: Data) -> EditRecipe? {
        TolerantJSON.decode(EditRecipe.self, from: data, defaults: EditRecipe()) { saved in
            var saved = saved
            if var film = saved["film"] as? [String: Any], let base = TolerantJSON.object(FilmRecipe()) {
                // A pinned tuning from an older app version may lack fields stocks gained
                // since: take those from the current stock of the same id.
                if let tuning = film["tuning"] as? [String: Any],
                   let current = TolerantJSON.object(FilmStock.namedOrRetired((tuning["id"] as? String) ?? (film["stock"] as? String))) {
                    film["tuning"] = TolerantJSON.merging(tuning, over: current)
                }
                saved["film"] = TolerantJSON.merging(film, over: base)
            }
            return saved
        }
    }

    /// Pins the film stock's current tuning into the recipe (no-op if already pinned or
    /// not a film look). Called when an edit is baked or saved.
    mutating func freezeFilmTuning() {
        guard var f = film, f.tuning == nil else { return }
        f.tuning = FilmStock.resolved(for: self)
        if f.engine == nil { f.engine = FilmRecipe.currentEngine }
        film = f
    }

    /// The tuning to render with: the pinned one, else the one the edit was made with.
    var filmStock: FilmStock? { FilmStock.resolved(for: self) }

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
        r.rawFilmExposure = target.rawFilmExposure
        return r
    }

    /// Clears tone & color (used before applying a Look), keeping geometry and RAW settings.
    /// This grade as the one new shots start with: the look and every slider, without
    /// anything that belongs to one photo (crop, rotation, its RAW develop settings).
    var asDefaultGrade: EditRecipe {
        var r = self
        r.crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        r.straighten = 0
        r.quarterTurns = 0
        r.flipped = false
        r.useRAW = true
        r.rawInitialized = false
        r.rawFilmExposure = nil
        let fresh = EditRecipe()
        r.rawNoiseReduction = fresh.rawNoiseReduction
        r.rawLocalTone = fresh.rawLocalTone
        r.rawBoost = fresh.rawBoost
        return r
    }

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
        rawFilmExposure = keep.rawFilmExposure
    }
}

/// Settings of the film emulation that have no ordinary-edit equivalent.
struct FilmRecipe: Codable, Equatable {
    /// Which film stock (`FilmStock.all`). nil = Print (edits saved before stocks existed).
    var stock: String?
    /// The stock's full tuning, pinned when the look is picked (a few KB). Rendering uses it
    /// instead of the stock's current tuning in code, so retuning a look later never
    /// changes an older photo, even when it's reopened and re-saved in the editor.
    /// nil = an edit from before tunings were pinned: `FilmStock.resolved(for:)` finds the
    /// exact tuning it was made with in the frozen history (`FilmStock.Legacy`).
    /// Picking the look again pins its current tuning: how a photo moves to the newest.
    var tuning: FilmStock?
    /// The film math's version when the tuning was pinned (`FilmRecipe.currentEngine`).
    /// nil = before versioning. A future change to the film *math* (not just a stock's
    /// numbers) that would alter older photos must keep the old behaviour for older engines.
    var engine: Int?

    static let currentEngine = 1
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

    /// Every slider by id (the editor's sub-tabs pick from these).
    static let catalog: [String: Adjustment] = {
        var out: [String: Adjustment] = [:]
        for a in tune + filmDetails + details + raw where out[a.id] == nil { out[a.id] = a }
        return out
    }()

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
    /// One or two plain sentences shown in the look guide.
    let detail: String
    /// The camera shoots Bayer RAW for this look (Print). Other looks work on whatever
    /// the camera's processing setting produces, and develop from RAW when there is one.
    var capturesRAW = false
    let apply: (inout EditRecipe) -> Void

    /// A film-stock look: the stock (FilmStock+Stocks.swift) does tone, color, halation
    /// and grain; `extra` adds ordinary adjustments on top (B&W, vignette, texture).
    private static func film(_ stock: String, _ extra: @escaping (inout EditRecipe) -> Void = { _ in })
        -> (inout EditRecipe) -> Void {
        { r in
            // Pin the stock's tuning as it is right now (see FilmRecipe.tuning).
            r.film = FilmRecipe(stock: stock, tuning: FilmStock.named(stock), engine: FilmRecipe.currentEngine)
            r.grain = FilmRecipe.defaultGrain
            extra(&r)
        }
    }

    static let all: [Look] = [
        Look(id: "none", name: "Original", detail: "No look: the photo exactly as captured.") { _ in },
        // Negative printed to print film, applied to the RAW sensor data (FilmModel.swift).
        // Dense blacks, a long soft highlight shoulder, warm highlights over cool shadows,
        // film color, halation and grain.
        Look(id: "print", name: "Print", detail: "Film from the sensor: a cinema negative printed to print film. Dense blacks, soft highlights, warm-over-cool color, halation and fine grain. Shoots RAW.",
             capturesRAW: true) { r in
            // Pin Print's tuning as it is right now (see FilmRecipe.tuning).
            r.film = FilmRecipe(stock: FilmStock.printLook.id, tuning: FilmStock.printLook,
                                engine: FilmRecipe.currentEngine)
            r.grain = FilmRecipe.defaultGrain
        },
        Look(id: "punch", name: "Punch", detail: "Vivid color negative pushed hard: maximum color, bold contrast, bright and clean, with extra crunch.",
             apply: film("punch") { $0.structure = 15 }),
        // The rest are film stocks too (scripts/film-looks.json): each a film or a movie
        // grade with its own tone curve, color balance and crossover, dye behavior,
        // halation and grain. The looks they replaced (Natural, Warm 400, Skin, Cool Air,
        // Cine, Chrome, Faded, Mono 400, Silver) are retired: photos made with them keep
        // rendering from their pinned tuning or `FilmStock.Legacy` (see `Look.retired`).
        Look(id: "desert", name: "Desert", detail: "Inspired by desert epics: warm ochre and sand, quiet color, soft lifted blacks and a long, gentle highlight roll-off.",
             apply: film("desert") { $0.vignette = 14 }),
        Look(id: "pastel", name: "Pastel", detail: "A storybook grade: high key and soft, candy pinks, butter yellows, mint and warm cream whites.",
             apply: film("pastel") { $0.structure = -8 }),
        Look(id: "amber", name: "Amber Haze", detail: "Orange fog over a future city: nearly monochrome amber, smoky highlights and a wide, warm glow.",
             apply: film("amber") { $0.vignette = 18 }),
        Look(id: "sodium", name: "Sodium", detail: "A streetlight thriller: green-yellow sodium light, muddy desaturated shadows, cold skin and a low key.",
             apply: film("sodium") { $0.vignette = 24 }),
        Look(id: "neon", name: "Neon Night", detail: "Neon-lit romance: saturated reds against green shadows, crushed blacks and a strong red glow around lights.",
             apply: film("neon") { $0.vignette = 26 }),
        Look(id: "bleach", name: "Bleach Bypass", detail: "Silver left in the print: hard contrast, drained color, metallic highlights and gritty grain.",
             apply: film("bleach") { $0.structure = 20; $0.vignette = 12 }),
        Look(id: "slide", name: "Slide", detail: "Seventies slide film: rich reds, deep blue skies, dense blacks, warm light and hard contrast.",
             apply: film("slide") { $0.vignette = 12 }),
        Look(id: "noir", name: "Noir", detail: "Pushed black and white: inky cold-toned blacks, hard contrast, heavy grain, glow and a deep vignette.",
             apply: film("noir") { $0.mono = true; $0.vignette = 34 }),
    ]

    /// Looks that are no longer offered, by id: their names, so a photo made with one can
    /// still say which look it has, and the look a saved camera choice moves to (nil =
    /// Original). Their photos render exactly as before (pinned tuning or
    /// `FilmStock.Legacy`); only the camera's choice and the pickers move on.
    static let retired: [String: (name: String, successor: String?)] = [
        "natural": ("Natural", nil), "warm400": ("Warm 400", nil), "portrait": ("Skin", nil),
        "cool": ("Cool Air", nil), "cine": ("Cine", nil), "chrome": ("Chrome", "slide"),
        "faded": ("Faded", nil), "mono400": ("Mono 400", "noir"), "silver": ("Silver", "noir"),
    ]

    /// The name to show for a recipe's look id, retired looks included (nil = no look).
    static func displayName(_ id: String?) -> String? {
        guard let id else { return nil }
        return named(id)?.name ?? retired[id]?.name
    }
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

extension FilmStock {
    /// The tuning an edit renders with (nil = not a film look): its pinned tuning, or, for
    /// edits saved before tunings were pinned, the exact one it was made with. The stocks
    /// changed exactly once in that time (Print's grain, 0.012 → 0.008 in #20):
    /// - a stock id (the film-stock filters, #15+) → the stocks as shipped from #15/#20;
    /// - no stock id: Print, which never stored one. #9's Print set 15% luminance noise
    ///   reduction (kept in the recipe); from #20 the baker floors it at 50. So under 50 →
    ///   Print as shipped in #9, otherwise Print as shipped from #20.
    static func resolved(for recipe: EditRecipe) -> FilmStock? {
        guard let film = recipe.film else { return nil }
        if let pinned = film.tuning { return pinned }
        if let id = film.stock { return Legacy.v2[id] ?? named(id) }
        return recipe.rawNoiseReduction < EditRecipe.filmMinimumNoiseReduction
            ? Legacy.printV1 : (Legacy.v2[printLook.id] ?? printLook)
    }

    /// The stock for an id, including retired looks' stocks (as they last shipped, from
    /// the frozen history). For filling gaps in an older pinned tuning, never for picking.
    static func namedOrRetired(_ id: String?) -> FilmStock {
        if let id, all[id] == nil, let retired = Legacy.v2[id] { return retired }
        return named(id)
    }
}
