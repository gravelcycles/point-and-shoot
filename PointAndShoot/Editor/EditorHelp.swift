import SwiftUI

/// What every editor control does and how each tab's controls work together, for the ⓘ
/// card on each tab (the owner: "would be great to understand each slider and how they
/// work together"). Film looks and Original differ in places (film tone controls act inside
/// the film model); the text says which. Written for a photographer: one to three plain
/// sentences, accurate to what the control does (EditPipeline, FilmControls, ExtraGrades,
/// ColorMixer); keep it so when a control changes (the owner: "update descriptions for what
/// each editing setting does").
enum EditorHelp {
    /// One control's explanation; `film` replaces `text` under a film look when given.
    struct Entry {
        let text: String
        var film: String? = nil
        func text(isFilm: Bool) -> String { isFilm ? (film ?? text) : text }
    }

    static let controls: [String: Entry] = [
        // Tone
        "exposure": Entry(
            text: "Brightens or darkens the whole photo, in stops (±6). On a RAW it's applied when the RAW is developed, like exposing differently, so going down can bring back highlights the sensor kept.",
            film: "Gives the film more or less light, in stops (±6), from the RAW. The film's curve rolls highlights softly into the print's white and shadows into its dense blacks, so it reads like a different exposure, not a brightness slider."),
        "contrast": Entry(
            text: "Steepens (+) or flattens (−) the tone curve: brighter lights and darker darks, or the reverse. Mid-grey stays put. Shown on Chromagraph's scale (±4).",
            film: "Makes the print harder (+, up to twice as steep) or softer (−). It turns around the Pivot: the brightness at the pivot stays put while lighter tones get lighter and darker ones darker. Shown on Chromagraph's scale (±4)."),
        "pivot": Entry(
            text: "Where Contrast turns, as a brightness from black (0) to white (1); 0.35 is about where mid-grey prints. Put it on what should stay the same, a face or the sky. Does nothing while Contrast is 0."),
        "fade": Entry(
            text: "Lifts the blacks toward grey and softens the whites a touch, like a faded print or a matte finish. Applied last, on top of the look."),
        "highlights": Entry(
            text: "− pulls back the bright areas region by region, bringing detail back into skies and windows; + brightens the lighter tones.",
            film: "Gives the brighter part of the scene more (+) or less (−) light before the film sees it, up to 3 stops. It's broad, like Chromagraph's: at +1 nearly everything but the deepest shadows gets brighter. For skies, use Highlight Recovery or Sky Exposure. Shown as ±1.00."),
        "shadows": Entry(
            text: "+ opens up the dark areas region by region, without moving the highlights much; − darkens the darker tones.",
            film: "Gives the darker part of the scene more light (+, up to 1 stop) or less (−, up to 2.2 stops, sinking it into the print's dense blacks) before the film sees it. The brightest tones barely move. Shown as ±1.00."),
        "whites": Entry(
            text: "Sets the white point: + makes the brightest tones reach pure white sooner (punchier), − holds them below white (softer, like a matte print). Applied on top of the look."),
        "blacks": Entry(
            text: "Sets the black point: + lifts the darkest tones toward grey, − sinks more of them into black. Applied on top of the look."),
        "curveHighlights": Entry(text: "Tone curve, the brightest quarter (around 85%): + brightens, − darkens. Black and white stay where they are."),
        "curveLights": Entry(text: "Tone curve, the upper midtones (around 60%): skin, bright walls, daylight foliage."),
        "curveDarks": Entry(text: "Tone curve, the lower midtones (around 40%): shaded faces, interiors."),
        "curveShadows": Entry(text: "Tone curve, the darkest quarter (around 15%), just above black."),
        "skyExposure": Entry(
            text: "Darkens or brightens only the sky, in stops (±2). The sky is found by colour (bright, blue or grey, not skin or leaves) and position (the top of the frame), with soft edges.",
            film: "Gives just the sky more or less light before the film sees it, like a graduated ND filter (±2 stops). Going down brings back the colour and clouds of a sky that prints white, because the RAW is developed with extra headroom. The sky is found by colour and position, with soft edges."),
        "skySaturation": Entry(text: "More or less colour in the sky only: deepen a blue sky, or take the colour out of a hazy one."),
        "highlightRecovery": Entry(text: "Brings back skies and other bright areas that print as plain white. The RAW is developed with extra headroom, then everything brighter than about a stop over mid-grey is compressed: at 100 a sky 4 stops over prints about where a 2-stop one did, clouds and all. Shadows and midtones stay put."),
        "rawLTM": Entry(text: "How much of Apple's local tone mapping the RAW develop uses: the iPhone camera's trick of lifting shade and holding skies. 0 is a flat, honest develop; more looks more like the Camera app."),
        "rawBoost": Entry(text: "How much of Apple's base tone curve the RAW develop applies: more is contrastier and brighter in the midtones, less is flatter and more neutral."),
        // Looks (under the looks strip)
        "localTone": Entry(
            text: "Dodges and burns: shaded areas come up and bright ones come down, region by region, while fine detail and texture stay. Like the iPhone's own processing (faces out of shade, skies holding their clouds), but you set how much. Stays as you try other looks.",
            film: "Dodges and burns the light before the film sees it, like a printer holding back the shade and burning in the sky, so it still prints like film. At 100 an area 3 stops darker than the average comes up about 1.8 stops; high values can leave a soft glow along hard edges. Stays as you try other looks."),
        "appleTone": Entry(text: "Prints Apple's own rendering of the RAW instead of its plain light, the way the viewfinder shows the film look: shade lifted, skies held, the viewfinder's brightness. Tone → RAW then sets how much of Apple's rendering is used. Stays as you try other looks."),
        // Color
        "warmth": Entry(
            text: "White balance, blue (−) to amber (+). On a RAW it changes the develop's colour temperature (about 40 K a step), the same as setting white balance in camera.",
            film: "White balance of the light before it reaches the film (about 40 K a step on a RAW): warmer or cooler light, which the film then renders in its own colours."),
        "tint": Entry(text: "White balance, green (−) to magenta (+): corrects fluorescent and LED casts, or adds one on purpose."),
        "saturation": Entry(
            text: "More or less colour everywhere. −100 is black and white.",
            film: "More or less colour in the film's dyes. More works like richer dyes: colours get deeper and a little darker, not brighter. Less pulls them toward grey."),
        "vibrance": Entry(text: "More or less colour, mostly in the muted colours, gentler than Saturation on colours that are already strong and on skin."),
        "mono": Entry(text: "Black and white, mixed a little more red-sensitive than the eye (skin lighter, foliage darker). Under a film look the stock tones it (Noir is cold). The Mixer keeps working, like coloured filters on the lens."),
        "mixerBands": Entry(text: "Pick a colour family (red, orange, yellow, green, aqua, blue, purple, magenta), then change just that family. A dot marks the bands you've changed. Greys are never touched."),
        "mixerChannel": Entry(text: "Which of the band's sliders to show: Hue shifts the colour toward its neighbours (up to 40°), Saturation makes it richer or greyer, Luminance lighter or darker. Each band keeps all three."),
        "crossover": Entry(text: "The look's own colour split between highlights and shadows (warm over cool, for most), strongest in the midtones and gone at black and white. −100 removes it, +100 doubles it."),
        "gradeShadowHue": Entry(text: "The colour of the shadows' tint, as a hue: 0° red, 60° yellow, 120° green, 180° cyan, 240° blue, 300° magenta. Shadows Tint sets how much."),
        "gradeShadowAmount": Entry(text: "How strong the shadows' tint is. It changes colour, not brightness, and fades out toward the midtones."),
        "gradeMidHue": Entry(text: "The colour of the midtones' tint, as a hue."),
        "gradeMidAmount": Entry(text: "How strong the midtones' tint is (gentler than the other two at the same number, since it covers most of the photo)."),
        "gradeHighlightHue": Entry(text: "The colour of the highlights' tint, as a hue."),
        "gradeHighlightAmount": Entry(text: "How strong the highlights' tint is. It fades out toward the midtones and leaves pure white white."),
        // Texture
        "grain": Entry(
            text: "Adds film-like grain over the photo. Shown on Chromagraph's scale (0–5).",
            film: "How strong the film's grain is, on Chromagraph's scale (0–5; 1.25 is the look as designed). It lives in the negative, so it's strongest in the midtones, fades into deep blacks and bright whites, and stays neutral on greys."),
        "grainSize": Entry(
            text: "How big the grain is, relative to the picture (1.00× is the default). Bigger reads like a faster film; its strength stays the same.",
            film: "How big the grain is, as a share of the picture (1.00× is the look's: about a pixel across at 2880 px, like Chromagraph's). Bigger grain is also a little stronger (about 1.4× at 3.00×); below 1.00× it can't get finer than a pixel, so it gets weaker instead."),
        "pixelGrain": Entry(text: "One-pixel grain at any size, like Chromagraph's Force Pixel Size Grain: crisp and digital-looking, the same at every export size. Grain Size then does nothing."),
        "halation": Entry(text: "The red glow film gets around bright lights and bright edges, from light bouncing off the back of the film. 50 is the look as designed, 0 none, 100 twice as strong."),
        "structure": Entry(text: "Mid-size local contrast: + brings out texture (stone, fabric, skin), − softens it for a gentler look."),
        "sharpen": Entry(text: "Sharpens fine edges, on brightness only so no colour fringes. A little goes a long way; film looks rarely need it."),
        "dehaze": Entry(text: "+ cuts through haze: broad local contrast, deeper blacks and a little more colour, so distant things come forward. − adds a pale blue-grey haze."),
        "vignette": Entry(text: "Darkens (+) or lightens (−) the corners and edges, drawing the eye to the middle."),
        "rawNR": Entry(text: "Noise reduction in the RAW develop: more smooths sensor noise (and some fine detail), less keeps both. Film looks start at 50 or more, since the film's contrast shows noise."),
        // Film tool
        "printerWarm": Entry(text: "Printer lights, warm/cool: like a lab timing a print, up to 2 printer points. The cast is strongest in the midtones and gone at black and white, so it reads as film colour, not a filter."),
        "printerMagenta": Entry(text: "Printer lights, magenta/green: the lab's other correction, for green fluorescent casts or a magenta push."),
        "push": Entry(text: "Push (+) or pull (−) processing, up to 2 stops: developing the negative longer or shorter. Push is contrastier, with deeper blacks, brighter highlights and coarser grain; pull is softer and flatter. Mid-grey stays put."),
        "flash": Entry(text: "Flashing: a small, even exposure of the negative before the shot, an old cinematographer's trick. It opens up and softens the deepest shadows without touching the midtones."),
        "silver": Entry(text: "Silver retention, or bleach bypass: silver left in the print. Colours drain toward grey, shadows get denser and contrast goes up, for a gritty, metallic look."),
        "grainColor": Entry(text: "How coloured the grain is: −100 pure monochrome, 0 the look's own, +100 strongly coloured, as if each dye layer had its own grain."),
        "halationSize": Entry(text: "How far the halation glow spreads (1.00× is the look's): smaller is a tight rim on edges, bigger a wide bloom around lights."),
        "halationColor": Entry(text: "The glow's colour: −100 pure red, 0 the look's own, +100 a warm white bloom, like a diffusion filter."),
    ]

    /// How a tab's controls work together.
    static func together(_ tab: String, isFilm: Bool) -> String? {
        switch tab {
        case "exposure":
            return isFilm ? "Set Exposure first, then shape the tones. Because the film rolls off, you can go further than on a digital develop before anything looks clipped." : nil
        case "contrast":
            return isFilm
                ? "Contrast sets how steep, Pivot where it turns. Put the pivot on what should stay the same (a face, the sky) and Contrast moves everything else around it. Fade (its own tab) lifts the blacks on top."
                : "Contrast shapes the midtones; Fade then lifts the blacks. Contrast for punch, Fade for a matte finish."
        case "shadowHighlight":
            return isFilm
                ? "Both change the light before the film, so the film's own curve and colours still apply: it looks like more or less light, not an edit. Highlights + with Shadows − is a harder picture; Highlights − with Shadows + a flatter one."
                : "Highlights − and Shadows + together tame a contrasty scene; set the end points afterwards with Whites and Blacks."
        case "whitesBlacks":
            return "Whites and Blacks set where the tone scale ends, after everything else. Set them last."
        case "curveLights", "curveDarks":
            return "The curve's four points each bend one quarter of the tone scale, after the look; black and white never move. Lights + with Darks − is a classic S-curve. Use the main tone controls first."
        case "local":
            return isFilm
                ? "Two ways to get what the iPhone's own processing does to a scene. Apple Tone prints Apple's rendering, as the viewfinder shows it (Tone → RAW tunes it); Local Tone is your own dodge and burn on the plain develop. Try one first; together they add up."
                : "Local Tone evens out light and shade region by region. On a RAW, Tone → RAW → Apple Local Tone does something similar the Camera app's way; the two add up."
        case "recovery":
            return "Highlight Recovery compresses every bright area evenly. For just the sky, Sky Exposure (Tone → Sky) darkens it before the film. Together: some Recovery for the whole picture, then Sky Exposure − for a dramatic sky. Highlights − darkens nearly the whole picture instead."
        case "sky":
            return isFilm
                ? "Sky Exposure changes the sky's light before the film, like a graduated ND filter, so darkening a bright sky brings its clouds back instead of turning white into grey. Sky Saturation applies after the film. Highlight Recovery (Tone) does the same for every bright area at once."
                : "Both apply only where the sky is, on top of the rest of the edit: a darker, deeper sky, or a lighter, softer one."
        case "raw":
            return isFilm
                ? "With Apple Tone on, these set how much of Apple's rendering the film prints: Apple Local Tone is the shade-lifting, sky-holding part, Film Contrast Apple's base curve. Lower both and it comes close to the plain develop."
                : "These set how the RAW is developed before anything else. Apple Local Tone and Film Contrast together make up Apple's own rendering; at 0 you get the RAW's plain, flat data."
        case "balance":
            return "Warmth and Tint together set white balance: Warmth for daylight vs. tungsten, Tint for green vs. magenta casts. Set them before colour grading."
        case "saturation":
            return isFilm
                ? "Saturation works inside the film's dyes (richer is darker); Vibrance works afterwards on the muted colours. B&W turns the whole picture black and white, and the Mixer then acts like coloured lens filters."
                : "Saturation changes every colour, Vibrance mostly the muted ones. B&W turns the photo black and white, and the Mixer then acts like coloured lens filters."
        case "crossover":
            return "Crossover belongs to the look: the stock's own split between highlight and shadow colour. Printer Lights (Film tool) shift the whole print warmer or cooler on top."
        case "mixer":
            return "Each band changes one family of colours, and greys are never touched. In B&W, Luminance works like a coloured filter: darken Blue for dramatic skies, lighten Orange for brighter skin."
        case "gradeShadows", "gradeMids", "gradeHighlights":
            return "Each tint adds a colour to its part of the tone scale without changing brightness. Classic pairs: teal shadows (≈190°) with orange highlights (≈40°), or warm shadows with cool highlights. They apply after the look, so keep them low on looks that already have a cast."
        case "grain":
            return isFilm
                ? "Grain sets the strength, Grain Size the size; bigger grain also reads stronger, so lower Grain a little as you raise Grain Size. Pixel Size Grain swaps the film grain for crisp one-pixel noise."
                : "Grain sets the strength, Grain Size the size."
        case "halation":
            return "Halation here sets how strong the glow is; the Film tool's Halation tab sets its size and colour."
        case "detail":
            return "Structure works on mid-size texture, Sharpening on the finest edges. Structure for character, Sharpening sparingly at the end."
        case "dehaze":
            return "Dehaze works on the whole picture; for just the sky, use Tone → Sky."
        case "noise":
            return "Noise Reduction cleans the sensor's noise in the RAW develop, before any grain is added: clean it here, then add the film's grain back in Grain."
        case "fade":
            return "Fade lifts the blacks after everything else, for a matte print. Film looks are known for their dense blacks, so use it lightly."
        case "printer":
            return "Warm/Cool and Magenta/Green are the two axes of a lab's colour timing; together they move the print's colour in any direction, mostly in the midtones."
        case "process":
            return "Push and Flashing pull the shadows opposite ways: push deepens them, flashing opens them up. Pushed and flashed gives punchy midtones with soft, open shadows."
        case "silver":
            return "Silver Retention changes the print's colour and contrast, Grain Colour the grain's. A bleach bypass usually pairs silver with monochrome grain (Grain Colour −)."
        case "halationShape":
            return "Size and Colour shape the glow; its strength is Texture → Halation. A wide, warm-white bloom reads as a diffusion filter, a tight red rim as classic film halation."
        default:
            return nil
        }
    }
}

/// The ⓘ card for one tab: each control's explanation, then how they work together.
struct ControlHelpSheet: View {
    let title: String
    let tabID: String
    /// (id, name) of each control in the tab.
    let controls: [(id: String, name: String)]
    let isFilm: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(controls, id: \.id) { control in
                    if let entry = EditorHelp.controls[control.id] {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(control.name).font(.headline)
                            Text(entry.text(isFilm: isFilm)).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                if let together = EditorHelp.together(tabID, isFilm: isFilm) {
                    Section("How they work together") {
                        Text(together).font(.subheadline)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }
}
