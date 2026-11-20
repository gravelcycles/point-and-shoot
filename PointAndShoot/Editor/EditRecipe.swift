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
    /// Grain size in percent of the look's own (100 = as designed). nil = 100, so older
    /// edits decode and an untouched slider leaves the edit unchanged.
    var grainSize: Double?
    /// Where Contrast turns (film looks, engine 5+): 0…100 display brightness, like
    /// Chromagraph's Pivot 0…1. nil = 35, about where 18% grey prints (as before).
    var contrastPivot: Double?
    /// Colour grading: the shadows' tint hue (degrees) and amount (0…100); midtones, highlights.
    /// nil = the default (210), so older edits decode and an untouched slider changes nothing.
    var gradeShadowHue: Double?
    var gradeShadowAmount: Double?
    var gradeMidHue: Double?
    var gradeMidAmount: Double?
    var gradeHighlightHue: Double?
    var gradeHighlightAmount: Double?
    /// Parametric tone curve, −100…100 each (Lightroom's Highlights, Lights, Darks, Shadows).
    /// nil = the default (0), so older edits decode and an untouched slider changes nothing.
    var curveHighlights: Double?
    var curveLights: Double?
    var curveDarks: Double?
    var curveShadows: Double?
    /// Dehaze, −100…100.
    /// nil = the default (0), so older edits decode and an untouched slider changes nothing.
    var dehaze: Double?
    /// Masks: exposure (50 per stop, ±2) and saturation (−100…100) of the sky and of the subject.
    /// nil = the default (0), so older edits decode and an untouched slider changes nothing.
    var skyExposure: Double?
    var skySaturation: Double?
    var subjectExposure: Double?
    var subjectSaturation: Double?
    /// Local Tone, 0…100: dodging and burning (dark areas lifted, bright ones held back,
    /// region by region, fine detail untouched; `ExtraGrades.localTone`). Every look.
    /// nil = 0, so older edits decode and render unchanged.
    var localTone: Double?
    /// Apple Tone (film looks, RAW only): develop the RAW with Apple's own rendering (its
    /// local tone mapping and tone curve: the RAW tab's two sliders), undo Apple's average
    /// curve and print that on the film, exactly as the viewfinder does with the live video.
    /// So the photo keeps what Apple's local tone mapping does to a scene (faces lifted out of
    /// shade, skies held), as the viewfinder shows it. nil = off: the plain scene-light develop.
    /// Kept when the look changes, like the RAW tab's settings.
    var appleTone: Bool?
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
    /// Stops added to the RAW develop under a film look. Picking a film look leaves it nil;
    /// the photo's first develop (or the editor) settles it to the fixed value for its RAW
    /// type (`filmRAWExposure(bayer:)`), and it's kept from then on, so a photo keeps the
    /// brightness it was made with and picking the look again brings it up to date. Edits
    /// from before 2026-11-14 have none (developed ~2 stops dark); photos baked between #22
    /// and #42 carry a per-shot value matched to the viewfinder. Optional so older edits decode.
    var rawFilmExposure: Double?
    /// The film looks' RAW develop exposure, from the RAW and its saved camera settings
    /// alone (docs/film-looks.md §5⅞): natural brightness, about where Apple's camera puts
    /// the scene, a touch under ("def not too bright").
    /// - The scene's light, EV100 from the photo's ISO, shutter and aperture, sets it: Apple
    ///   renders dim scenes darker and bright ones brighter. Measured on 12 ProRAWs, the
    ///   develop that lands at Apple's brightness is 1.83 + 0.122·(EV100 − 10)
    ///   (correlation 0.81); EV100 is clamped to the measured 3…15.
    /// - `naturalBias` (−0.2 EV) keeps it just under Apple's, and it never goes past
    ///   Chromagraph's fixed +1.86 (`brightestFilmExposure`): bright scenes come out as
    ///   Chromagraph's, dim ones darker (Apple renders sun brighter still, up to +2.4).
    /// - A Bayer RAW develops ~0.63 EV brighter than a ProRAW of the same scene, so it gets
    ///   that much less (`bayerScale`): the two look the same.
    /// - Without exposure metadata, EV100 10 (a bright interior).
    /// Chromagraph instead develops ProRAW at a fixed +1.86 (bright and lifted in dim
    /// scenes) and Bayer files at +0.54 (dark and flat): matched exactly in #34–#52, and too
    /// bright for the owner.
    static func filmRAWExposure(bayer: Bool, ev100: Double?) -> Double {
        let ev = min(max(ev100 ?? 10, 3), 15)
        return min(appleMatchedExposure(ev100: ev) + naturalBias, brightestFilmExposure) - (bayer ? bayerScale : 0)
    }
    static let brightestFilmExposure = 1.86
    /// The ProRAW develop exposure that lands at Apple's brightness for a scene this bright.
    static func appleMatchedExposure(ev100: Double) -> Double { 1.83 + 0.122 * (ev100 - 10) }
    static let naturalBias = -0.2
    static let bayerScale = 0.63
    /// The automatic values earlier builds pinned: #42's fixed +1.86 (any RAW) and #52's
    /// Bayer +0.54. A photo still on one of them was never set by hand.
    static let earlierFixedExposures: [Double] = [1.86, 0.54]

    /// This edit with its film develop exposure settled for the photo (its RAW type and
    /// scene light, `filmRAWExposure(bayer:ev100:)`). Picking or pasting a film look leaves
    /// it nil, so the photo decides; this fills it in (store, renderer and editor, which know
    /// the shot), rounded to 0.01 EV. Also:
    /// - photos from before film looks had one (shot before 2026-11-14) developed ~1.9 EV
    ///   dark; the editor opens them this way, as an unsaved change;
    /// - a photo still on an earlier automatic value (`earlierFixedExposures`) moves to
    ///   the natural one. Any other value (a viewfinder match from #22–#41, a later pin) stays.
    /// One line for Diagnostics: how this edit develops (look, the RAW develop's exposure
    /// split into the film's and the slider's, noise reduction, film engine). A film look on
    /// a RAW with no film exposure renders ~2 stops dark, so it's flagged.
    var developSummary: String {
        var parts = ["look \(look ?? "none")"]
        if film != nil {
            if let ev = rawFilmExposure {
                parts.append(String(format: "develop %+.2f EV (film %+.2f, slider %+.2f)", ev + exposure / 50, ev, exposure / 50))
            } else {
                parts.append(String(format: "develop %+.2f EV (film exposure MISSING, slider %+.2f)", exposure / 50, exposure / 50))
            }
            parts.append("engine \(film?.renderEngine ?? 1)")
        } else {
            parts.append(String(format: "exposure %+.2f EV", exposure / 50))
        }
        parts.append(useRAW ? String(format: "RAW NR %.0f", rawNoiseReduction) : "processed")
        return parts.joined(separator: ", ")
    }

    func withFilmDevelopExposure(hasRAW: Bool, bayer: Bool, ev100: Double?) -> EditRecipe {
        guard hasRAW, useRAW, film != nil else { return self }
        let auto = EditRecipe.filmRAWExposure(bayer: bayer, ev100: ev100)
        let isEarlierDefault = rawFilmExposure.map { v in EditRecipe.earlierFixedExposures.contains { abs($0 - v) < 1e-9 } } ?? false
        guard rawFilmExposure == nil || (isEarlierDefault && rawFilmExposure != auto) else { return self }
        var r = self
        r.rawFilmExposure = (auto * 100).rounded() / 100
        return r
    }

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

    var filmPixelGrain: Bool {
        get { film?.pixelGrain ?? false }
        set { film?.pixelGrain = newValue ? true : nil }
    }

    /// Slider views of the optional fields: the default is stored as nil.
    var gradeShadowHueValue: Double {
        get { gradeShadowHue ?? 210 }
        set { gradeShadowHue = newValue == 210 ? nil : newValue }
    }
    var gradeShadowAmountValue: Double {
        get { gradeShadowAmount ?? 0 }
        set { gradeShadowAmount = newValue == 0 ? nil : newValue }
    }
    var gradeMidHueValue: Double {
        get { gradeMidHue ?? 30 }
        set { gradeMidHue = newValue == 30 ? nil : newValue }
    }
    var gradeMidAmountValue: Double {
        get { gradeMidAmount ?? 0 }
        set { gradeMidAmount = newValue == 0 ? nil : newValue }
    }
    var gradeHighlightHueValue: Double {
        get { gradeHighlightHue ?? 45 }
        set { gradeHighlightHue = newValue == 45 ? nil : newValue }
    }
    var gradeHighlightAmountValue: Double {
        get { gradeHighlightAmount ?? 0 }
        set { gradeHighlightAmount = newValue == 0 ? nil : newValue }
    }
    var curveHighlightsValue: Double {
        get { curveHighlights ?? 0 }
        set { curveHighlights = newValue == 0 ? nil : newValue }
    }
    var curveLightsValue: Double {
        get { curveLights ?? 0 }
        set { curveLights = newValue == 0 ? nil : newValue }
    }
    var curveDarksValue: Double {
        get { curveDarks ?? 0 }
        set { curveDarks = newValue == 0 ? nil : newValue }
    }
    var curveShadowsValue: Double {
        get { curveShadows ?? 0 }
        set { curveShadows = newValue == 0 ? nil : newValue }
    }
    var localToneValue: Double {
        get { localTone ?? 0 }
        set { localTone = newValue == 0 ? nil : newValue }
    }
    var appleToneValue: Bool {
        get { appleTone ?? false }
        set { appleTone = newValue ? true : nil }
    }
    /// The film look prints Apple's rendering of the RAW (Apple Tone on), not plain scene
    /// light: the RAW develops with Apple's tone settings and goes in display-referred.
    /// Needs engine 2's measured un-render (engine 1's guessed one never saw a RAW).
    var printsAppleRender: Bool { appleTone == true && (film?.renderEngine ?? 0) >= 2 }

    var dehazeValue: Double {
        get { dehaze ?? 0 }
        set { dehaze = newValue == 0 ? nil : newValue }
    }
    var skyExposureValue: Double {
        get { skyExposure ?? 0 }
        set { skyExposure = newValue == 0 ? nil : newValue }
    }
    var skySaturationValue: Double {
        get { skySaturation ?? 0 }
        set { skySaturation = newValue == 0 ? nil : newValue }
    }
    var subjectExposureValue: Double {
        get { subjectExposure ?? 0 }
        set { subjectExposure = newValue == 0 ? nil : newValue }
    }
    var subjectSaturationValue: Double {
        get { subjectSaturation ?? 0 }
        set { subjectSaturation = newValue == 0 ? nil : newValue }
    }
    var filmPrinterWarm: Double {
        get { film?.printerWarm ?? 0 }
        set { film?.printerWarm = newValue == 0 ? nil : newValue }
    }
    var filmPrinterMagenta: Double {
        get { film?.printerMagenta ?? 0 }
        set { film?.printerMagenta = newValue == 0 ? nil : newValue }
    }
    var filmPush: Double {
        get { film?.push ?? 0 }
        set { film?.push = newValue == 0 ? nil : newValue }
    }
    var filmFlash: Double {
        get { film?.flash ?? 0 }
        set { film?.flash = newValue == 0 ? nil : newValue }
    }
    var filmSilver: Double {
        get { film?.silver ?? 0 }
        set { film?.silver = newValue == 0 ? nil : newValue }
    }
    var filmGrainColor: Double {
        get { film?.grainColor ?? 0 }
        set { film?.grainColor = newValue == 0 ? nil : newValue }
    }
    var filmHalationSize: Double {
        get { film?.halationSize ?? 100 }
        set { film?.halationSize = newValue == 100 ? nil : newValue }
    }
    var filmHalationColor: Double {
        get { film?.halationColor ?? 0 }
        set { film?.halationColor = newValue == 0 ? nil : newValue }
    }

    var grainSizeValue: Double {
        get { grainSize ?? 100 }
        set { grainSize = newValue == 100 ? nil : newValue }
    }
    var contrastPivotValue: Double {
        get { contrastPivot ?? FilmControls.defaultPivot }
        set { contrastPivot = newValue == FilmControls.defaultPivot ? nil : newValue }
    }

    /// The film's tone and colour controls for this edit, as its engine renders them.
    var filmControls: FilmControls {
        let engine = film?.renderEngine ?? FilmRecipe.currentEngine
        return FilmControls(contrast: contrast / 100, saturation: saturation / 100,
                            crossover: (film?.crossover ?? 0) / 100,
                            highlights: highlights / 100, shadows: shadows / 100,
                            subtractiveSaturation: engine >= 3, strongTone: engine >= 4,
                            toneRegions: engine >= 5,
                            pivot: engine >= 5 ? FilmControls.pivotStops(contrastPivotValue) : 0)
            .withFilmTool(film)
    }

    /// The colour grade and tone curve for `ExtraGrades.applyGrade`.
    var gradeParams: ExtraGrades.GradeParams {
        ExtraGrades.GradeParams(
            curve: [curveHighlightsValue, curveLightsValue, curveDarksValue, curveShadowsValue].map { $0 / 100 },
            tints: [gradeShadowHueValue, gradeShadowAmountValue / 100, gradeMidHueValue, gradeMidAmountValue / 100,
                    gradeHighlightHueValue, gradeHighlightAmountValue / 100])
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
                // since: take those from the current stock of the same id, except fields
                // whose absence means "off" (hue twists, dye saturation): filling those
                // from today's stock would change how the older photo looks.
                if let tuning = film["tuning"] as? [String: Any],
                   var current = TolerantJSON.object(FilmStock.namedOrRetired((tuning["id"] as? String) ?? (film["stock"] as? String))) {
                    for key in FilmStock.offWhenMissing { current.removeValue(forKey: key) }
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
        // No engine means it was made before versioning, with engine 1's math (rendering
        // reads nil as 1). Pin that, never the current engine, or re-saving would change it.
        if f.engine == nil { f.engine = 1 }
        film = f
    }

    /// The tuning to render with: the pinned one, else the one the edit was made with.
    var filmStock: FilmStock? { FilmStock.resolved(for: self) }

    var isGeometryIdentity: Bool {
        crop == CGRect(x: 0, y: 0, width: 1, height: 1) && straighten == 0 && quarterTurns % 4 == 0 && !flipped
    }

    /// This recipe's look (tone, color, detail, effects) on top of `target`'s crop and RAW
    /// settings — for pasting an edit onto another photo.
    /// This edit with a look picked: tone and colour reset to the look's, crop and RAW
    /// develop kept (the editor's Looks tool, and Apply Look on several photos).
    func withLook(_ look: Look) -> EditRecipe {
        var r = self
        r.resetTone()
        look.apply(&r)
        r.look = look.id == "none" ? nil : look.id
        return r
    }

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
        // A film look's develop exposure depends on the target's RAW type: left for the
        // target to settle (`withFilmDevelopExposure`).
        if r.film != nil {
            r.rawFilmExposure = nil
        } else {
            r.rawFilmExposure = target.rawFilmExposure
        }
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
        // A film look's develop exposure depends on each new shot's RAW type: settled per shot.
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
        // How the RAW is developed, like the settings above: it stays as the look changes.
        appleTone = keep.appleTone
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
    /// 1: the original math (also nil). 2: display-referred input (processed photos, the
    /// viewfinder) un-rendered with Apple's measured curve and saturation, exposure after.
    /// 3: engine 2 plus a subtractive Saturation slider (richer is darker, like the dyes).
    var engine: Int?

    static let currentEngine = FilmLUT.currentEngine
    /// The engine an edit renders with: nil means it predates versioning, i.e. engine 1.
    var renderEngine: Int { engine ?? 1 }
    /// 0…100; 50 = the look as designed.
    var halation: Double = 50
    /// -100…100; 0 = the look's own color crossover (warm highlights, cool shadows),
    /// -100 = none, +100 = double.
    var crossover: Double = 0

    // The Film tool (nil = off; older edits decode, untouched sliders change nothing).
    /// Printer lights: warm/cool and magenta/green, −100…100 (±2 printer points).
    var printerWarm: Double?
    var printerMagenta: Double?
    /// Push/pull, −100…100 = −2…+2 stops of development.
    var push: Double?
    /// Flashing, 0…100 (a pre-exposure up to 8% of grey's).
    var flash: Double?
    /// Silver retention (bleach bypass), 0…100.
    var silver: Double?
    /// Grain colour, −100 (monochrome) … 0 (the look's) … 100 (strongly coloured).
    var grainColor: Double?
    /// Halation spread in percent (25…300, nil = 100) and colour (−100 red … 100 warm white).
    var halationSize: Double?
    var halationColor: Double?
    /// Grain one pixel across at any size (Chromagraph's "Force Pixel Size Grain"). nil = off.
    var pixelGrain: Bool?

    /// Grain amount the look starts with (EditRecipe.grain, 0…200; 50 = as designed).
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
    /// How the value reads (nil: a whole number, signed when the slider is bipolar).
    var format: ((Double) -> String)? = nil

    var isBipolar: Bool { range.lowerBound < 0 }

    func label(_ value: Double) -> String {
        if let format { return format(value) }
        let i = Int(value.rounded())
        return isBipolar && i > 0 ? "+\(i)" : "\(i)"
    }

    /// Exposure is stored 50 per stop: ±6 stops, like Chromagraph's.
    static func stops(_ v: Double) -> String { String(format: "%+.1f", v / 50) }
    /// Chromagraph's scales, so numbers can be compared slider for slider: Contrast ±4.00
    /// (our +100 measured like its S-Curve 4.00), Highlights/Shadows ±1.00, grain amplitude
    /// 0…5.00 (our 50 = its 1.25).
    static func contrastScale(_ v: Double) -> String { String(format: "%+.2f", v / 25) }
    static func unitScale(_ v: Double) -> String { String(format: "%+.2f", v / 100) }
    static func grainScale(_ v: Double) -> String { String(format: "%.2f", v / 40) }

    static let tune: [Adjustment] = [
        .init(id: "exposure", name: "Exposure", range: -300...300, keyPath: \.exposure, format: Adjustment.stops),
        .init(id: "contrast", name: "Contrast", range: -100...100, keyPath: \.contrast, format: Adjustment.contrastScale),
        .init(id: "pivot", name: "Pivot", range: 0...100, keyPath: \.contrastPivotValue,
              format: { String(format: "%.2f", $0 / 100) }),
        .init(id: "highlights", name: "Highlights", range: -100...100, keyPath: \.highlights, format: Adjustment.unitScale),
        .init(id: "shadows", name: "Shadows", range: -100...100, keyPath: \.shadows, format: Adjustment.unitScale),
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
        .init(id: "grain", name: "Grain", range: 0...200, keyPath: \.grain, format: Adjustment.grainScale),
        .init(id: "grainSize", name: "Grain Size", range: 25...300, keyPath: \.grainSizeValue,
              format: { String(format: "%.2f×", $0 / 100) }),
        .init(id: "vignette", name: "Vignette", range: -100...100, keyPath: \.vignette),
    ]

    /// Details for a film look: the film's own grain and halation come first.
    static let filmDetails: [Adjustment] = [
        .init(id: "grain", name: "Grain", range: 0...200, keyPath: \.grain, format: Adjustment.grainScale),
        .init(id: "grainSize", name: "Grain Size", range: 25...300, keyPath: \.grainSizeValue,
              format: { String(format: "%.2f×", $0 / 100) }),
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
        for a in tune + filmDetails + details + raw + filmTool + extras where out[a.id] == nil { out[a.id] = a }
        return out
    }()

    static func degrees(_ v: Double) -> String { "\(Int(v.rounded()))°" }
    static func times(_ v: Double) -> String { String(format: "%.2f×", v / 100) }

    /// The Film tool (film looks only).
    static let filmTool: [Adjustment] = [
        .init(id: "printerWarm", name: "Warm / Cool", range: -100...100, keyPath: \.filmPrinterWarm),
        .init(id: "printerMagenta", name: "Magenta / Green", range: -100...100, keyPath: \.filmPrinterMagenta),
        .init(id: "push", name: "Push / Pull", range: -100...100, keyPath: \.filmPush, format: Adjustment.stops),
        .init(id: "flash", name: "Flashing", range: 0...100, keyPath: \.filmFlash),
        .init(id: "silver", name: "Silver Retention", range: 0...100, keyPath: \.filmSilver),
        .init(id: "grainColor", name: "Grain Colour", range: -100...100, keyPath: \.filmGrainColor),
        .init(id: "halationSize", name: "Halation Size", range: 25...300, keyPath: \.filmHalationSize, format: Adjustment.times),
        .init(id: "halationColor", name: "Halation Colour", range: -100...100, keyPath: \.filmHalationColor),
    ]

    /// Colour grading, tone curve, dehaze and masks (every look).
    static let extras: [Adjustment] = [
        .init(id: "gradeShadowHue", name: "Shadows Hue", range: 0...360, keyPath: \.gradeShadowHueValue, format: Adjustment.degrees),
        .init(id: "gradeShadowAmount", name: "Shadows Tint", range: 0...100, keyPath: \.gradeShadowAmountValue),
        .init(id: "gradeMidHue", name: "Midtones Hue", range: 0...360, keyPath: \.gradeMidHueValue, format: Adjustment.degrees),
        .init(id: "gradeMidAmount", name: "Midtones Tint", range: 0...100, keyPath: \.gradeMidAmountValue),
        .init(id: "gradeHighlightHue", name: "Highlights Hue", range: 0...360, keyPath: \.gradeHighlightHueValue, format: Adjustment.degrees),
        .init(id: "gradeHighlightAmount", name: "Highlights Tint", range: 0...100, keyPath: \.gradeHighlightAmountValue),
        .init(id: "curveHighlights", name: "Curve Highlights", range: -100...100, keyPath: \.curveHighlightsValue),
        .init(id: "curveLights", name: "Curve Lights", range: -100...100, keyPath: \.curveLightsValue),
        .init(id: "curveDarks", name: "Curve Darks", range: -100...100, keyPath: \.curveDarksValue),
        .init(id: "curveShadows", name: "Curve Shadows", range: -100...100, keyPath: \.curveShadowsValue),
        .init(id: "dehaze", name: "Dehaze", range: -100...100, keyPath: \.dehazeValue),
        .init(id: "localTone", name: "Local Tone", range: 0...100, keyPath: \.localToneValue),
        .init(id: "skyExposure", name: "Sky Exposure", range: -100...100, keyPath: \.skyExposureValue, format: Adjustment.stops),
        .init(id: "skySaturation", name: "Sky Saturation", range: -100...100, keyPath: \.skySaturationValue),
        .init(id: "subjectExposure", name: "Subject Exposure", range: -100...100, keyPath: \.subjectExposureValue, format: Adjustment.stops),
        .init(id: "subjectSaturation", name: "Subject Saturation", range: -100...100, keyPath: \.subjectSaturationValue),
    ]

    static let raw: [Adjustment] = [
        .init(id: "rawNR", name: "Noise Reduction", range: 0...100, keyPath: \.rawNoiseReduction),
        .init(id: "rawLTM", name: "Apple Local Tone", range: 0...100, keyPath: \.rawLocalTone),
        .init(id: "rawBoost", name: "Film Contrast", range: 0...100, keyPath: \.rawBoost),
        .init(id: "exposure", name: "Exposure", range: -300...300, keyPath: \.exposure, format: Adjustment.stops),
        .init(id: "warmth", name: "Temperature", range: -100...100, keyPath: \.warmth),
        .init(id: "tint", name: "Tint", range: -100...100, keyPath: \.tint),
    ]
}

/// Named sets of looks, so whole families can be tried side by side: the camera's LOOK
/// picker and the editor's Looks tool show one set (or all), and the guide groups by set.
/// Stored by id (`CameraSettings.lookSet`), so an unknown id just means "all".
enum LookSet: String, CaseIterable, Identifiable {
    case essentials, stocks, movie, grades
    var id: String { rawValue }

    var name: String {
        switch self {
        case .essentials: "Essentials"
        case .stocks: "Film Stocks"
        case .movie: "Movie"
        case .grades: "Grades"
        }
    }

    /// What the set is, for the picker and the guide's section header.
    var detail: String {
        switch self {
        case .essentials: "Print (when it isn't a mode), Phromagraph, Punch and Noir."
        case .stocks: "Real film stocks: each renders skin, foliage and skies its own way, with dense blacks and dye-dense color."
        case .movie: "Movie grades built like film: Technicolor, teal and orange, tungsten night, bleach bypass."
        case .grades: "An earlier, softer pass: color casts, split toning and lifted blacks. Here to compare."
        }
    }

    /// The looks in this set, in order (Original isn't in any set; pickers add it).
    var looks: [Look] { Look.all.filter { $0.set == self && $0.id != "none" } }

    static func named(_ id: String?) -> LookSet? { id.flatMap(LookSet.init(rawValue:)) }
}

struct Look: Identifiable {
    let id: String
    let name: String
    /// One or two plain sentences shown in the look guide.
    let detail: String
    /// The named set the pickers group it under.
    var set: LookSet = .essentials
    /// The camera shoots Bayer RAW for this look (Print). Other looks work on whatever
    /// the camera's processing setting produces, and develop from RAW when there is one.
    var capturesRAW = false
    let apply: (inout EditRecipe) -> Void

    /// A film-stock look: the stock (FilmStock+Stocks.swift) does tone, color, halation
    /// and grain; `extra` adds ordinary adjustments on top (B&W, vignette, texture).
    private static func film(_ stock: String, _ extra: @escaping (inout EditRecipe) -> Void = { _ in })
        -> (inout EditRecipe) -> Void {
        { r in
            // Pin the stock's tuning as it is right now (see FilmRecipe.tuning). The RAW
            // develop's exposure depends on the photo's RAW type: left for it to settle.
            r.film = FilmRecipe(stock: stock, tuning: FilmStock.named(stock), engine: FilmRecipe.currentEngine)
            r.rawFilmExposure = nil
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
            r.rawFilmExposure = nil   // settled per photo, by its RAW type
            r.grain = FilmRecipe.defaultGrain
        },
        // Fitted to Chromagraph Camera's own renders of its RAWs (scripts/phromagraph.py),
        // separate from Print: Print is our film model tuned by eye; Phromagraph is the
        // measured match. Grain starts off, as in Chromagraph; the Grain slider at 50
        // gives Chromagraph's grain 1.25.
        Look(id: "phromagraph", name: "Phromagraph", detail: "Matched to Chromagraph's own renders: creamy highlights, teal-leaning mid-tones, dense soft blacks and a faint glow. Grain off; add it with the Grain slider. Shoots RAW.",
             capturesRAW: true, apply: film("phromagraph") { $0.grain = 0 }),
        Look(id: "punch", name: "Punch", detail: "Vivid color negative pushed hard: maximum color, bold contrast, bright and clean, with extra crunch.",
             apply: film("punch") { $0.structure = 15 }),
        Look(id: "noir", name: "Noir", detail: "Pushed black and white: inky cold-toned blacks, hard contrast, heavy grain, glow and a deep vignette.",
             apply: film("noir") { $0.mono = true; $0.vignette = 34 }),
        // The rest are film stocks too (scripts/film-looks.json), in named sets (`LookSet`)
        // so whole families can be compared on the phone. Film Stocks and Movie are built
        // on structure, not tint: each has its own color rendering by hue
        // (`FilmStock.hueTwists`: emerald greens, a slide film's deep skies, teal and orange
        // with skin locked), dye saturation in density (saturated colors get darker, as
        // with dyes), its own tone curve and crossover, real blacks, halation and grain.
        // The looks they replaced (Natural, Warm 400, Skin, Cool Air, Cine, Chrome, Faded,
        // Mono 400, Silver) are retired: photos made with them keep rendering from their
        // pinned tuning or `FilmStock.Legacy` (see `Look.retired`).
        Look(id: "portrait400", name: "Portrait 400", detail: "Portrait negative: soft contrast into real blacks, warm luminous skin, olive-leaning greens, pale cyan skies and a long, forgiving highlight roll-off.",
             set: .stocks, apply: film("portrait400") { $0.structure = -6 }),
        Look(id: "evergreen", name: "Evergreen", detail: "Fuji-style negative: cool and crisp, emerald greens, pink-leaning skin, magenta highlights over green shadows.",
             set: .stocks, apply: film("evergreen") { $0.vignette = 8 }),
        Look(id: "classicslide", name: "Slide", detail: "Classic slide film: dense blacks, hard contrast, intense reds and golden yellows against muted olive greens and deep blue skies.",
             set: .stocks, apply: film("classicslide") { $0.vignette = 12 }),
        Look(id: "lush", name: "Lush", detail: "Vivid landscape slide: lush greens, deep violet-leaning skies, warm colors pushed toward red and a hard white clip.",
             set: .stocks, apply: film("lush") { $0.vignette = 14; $0.structure = 8 }),
        Look(id: "threestrip", name: "Three-Strip", detail: "Dye-transfer Technicolor: high key, pure dense primaries, rosy skin, warm light and solid blacks.",
             set: .movie, apply: film("threestrip") { $0.vignette = 10 }),
        Look(id: "blockbuster", name: "Blockbuster", detail: "Teal and orange done like a colorist: skin locked and warmed, greens and skies turned teal, purples muted, blacks kept clean.",
             set: .movie, apply: film("blockbuster") { $0.vignette = 18; $0.structure = 10 }),
        Look(id: "night800", name: "Night 800", detail: "Tungsten 800 after dark: cyan shadows under amber light, a red glow around every light, pushed contrast and grain.",
             set: .movie, apply: film("night800") { $0.vignette = 22 }),
        Look(id: "bleachbypass", name: "Bleach Bypass", detail: "Silver left in the print: drained color, hard contrast, inky blacks and gritty grain.",
             set: .movie, apply: film("bleachbypass") { $0.structure = 20; $0.vignette = 12 }),
        // Grades: the first cinematic pass (PR #35), kept to compare against the two sets
        // above. Same ids, tunings and extras as it shipped, so its photos and saved
        // choices keep meaning the same look; only its Slide and Bleach Bypass are renamed
        // (Slide 70s, Bleach Grit) next to the new ones (classicslide, bleachbypass).
        // Never reuse an id for a different look.
        Look(id: "desert", name: "Desert", detail: "Inspired by desert epics: warm ochre and sand, quiet color, soft lifted blacks and a long, gentle highlight roll-off.",
             set: .grades, apply: film("desert") { $0.vignette = 14 }),
        Look(id: "pastel", name: "Pastel", detail: "A storybook grade: high key and soft, candy pinks, butter yellows, mint and warm cream whites.",
             set: .grades, apply: film("pastel") { $0.structure = -8 }),
        Look(id: "amber", name: "Amber Haze", detail: "Orange fog over a future city: nearly monochrome amber, smoky highlights and a wide, warm glow.",
             set: .grades, apply: film("amber") { $0.vignette = 18 }),
        Look(id: "sodium", name: "Sodium", detail: "A streetlight thriller: green-yellow sodium light, muddy desaturated shadows, cold skin and a low key.",
             set: .grades, apply: film("sodium") { $0.vignette = 24 }),
        Look(id: "neon", name: "Neon Night", detail: "Neon-lit romance: saturated reds against green shadows, crushed blacks and a strong red glow around lights.",
             set: .grades, apply: film("neon") { $0.vignette = 26 }),
        Look(id: "slide", name: "Slide 70s", detail: "Seventies slide film: rich reds, deep blue skies, dense blacks, warm light and hard contrast.",
             set: .grades, apply: film("slide") { $0.vignette = 12 }),
        Look(id: "bleach", name: "Bleach Grit", detail: "Silver left in the print: hard contrast, drained color, metallic highlights and gritty grain.",
             set: .grades, apply: film("bleach") { $0.structure = 20; $0.vignette = 12 }),
    ]

    /// Looks that are no longer offered, by id: their names, so a photo made with one can
    /// still say which look it has, and the look a saved camera choice moves to (nil =
    /// Original). Their photos render exactly as before (pinned tuning or
    /// `FilmStock.Legacy`); only the camera's choice and the pickers move on.
    static let retired: [String: (name: String, successor: String?)] = [
        "natural": ("Natural", nil), "warm400": ("Warm 400", nil), "portrait": ("Skin", "portrait400"),
        "cool": ("Cool Air", "evergreen"), "cine": ("Cine", "blockbuster"), "chrome": ("Chrome", "classicslide"),
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

// FilmModel.swift stays Foundation-only (parity compiles it alone), so the recipe →
// controls glue lives here.
extension FilmControls {
    /// These controls with the Film tool's settings from a photo's film recipe.
    func withFilmTool(_ f: FilmRecipe?) -> FilmControls {
        guard let f else { return self }
        var c = self
        (c.printerR, c.printerG, c.printerB) = FilmControls.printerLights(warm: (f.printerWarm ?? 0) / 100,
                                                                          magenta: (f.printerMagenta ?? 0) / 100)
        c.push = (f.push ?? 0) / 50
        c.flash = 0.08 * (f.flash ?? 0) / 100
        c.silver = (f.silver ?? 0) / 100
        return c
    }
}
