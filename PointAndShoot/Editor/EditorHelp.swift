import SwiftUI

/// What every editor control does and how each tab's controls work together, for the ⓘ
/// card on each tab (the owner: "would be great to understand each slider and how they
/// work together"). Film looks and Original differ in places (film tone controls act inside
/// the film model); the text says which.
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
            text: "Brightens or darkens the whole photo in stops (±6), like changing the exposure in camera. On a RAW it's applied in the RAW develop, so highlights the sensor kept can come back when you go down.",
            film: "Exposes the film more or less, in stops (±6). Like real film, more exposure doesn't clip: highlights roll softly into the print's white, and less exposure sinks into its dense blacks. On a RAW it's applied in the develop, so recovered highlights are real."),
        "contrast": Entry(
            text: "Steepens or flattens the tone curve around the midtones. Shown on Chromagraph's scale (±4).",
            film: "Changes the print's contrast (its gamma): up to ×2 steeper or ×0.6 flatter. It turns around the Pivot, so the brightness at the pivot stays put while everything above gets brighter and everything below darker (or the reverse). Shown on Chromagraph's scale (±4)."),
        "pivot": Entry(
            text: "Where Contrast turns, as a brightness from black (0) to white (1). 0.35 is about mid-grey. Low pivot: more contrast also brightens the photo; high pivot: it darkens it. Does nothing while Contrast is 0."),
        "fade": Entry(
            text: "Lifts the blacks toward grey, like a faded print or a matte finish. It's a curve on top of everything else, so it works the same on any look."),
        "highlights": Entry(
            text: "Recovers (−) or brightens (+) the bright parts of the photo, locally: bright areas are treated on their own so detail comes back in skies.",
            film: "Re-exposes the brighter part of the scene before the film sees it: + up to 3 stops more light on everything above the deep shadows, − up to 3 less. Like Chromagraph's, it's broad: at +1 it lifts nearly the whole picture while the darkest shadows stay put. Shown as ±1.00."),
        "shadows": Entry(
            text: "Lifts (+) or deepens (−) the dark parts of the photo, locally, without moving the highlights much.",
            film: "Re-exposes the darker part of the scene before the film: + up to 1 stop more light in the shadows and lower midtones, − up to 2.2 stops less (crushing them into the print's dense blacks). The brightest tones barely move. Shown as ±1.00."),
        "whites": Entry(
            text: "Moves the white point: + makes the brightest tones reach white sooner (punchier), − holds them back below white (softer, like a matte print)."),
        "blacks": Entry(
            text: "Moves the black point: + lifts the darkest tones, − sinks more of them into black."),
        "curveHighlights": Entry(text: "Tone curve, brightest quarter (around 85% brightness): + brightens, − darkens, leaving black and white where they are."),
        "curveLights": Entry(text: "Tone curve, upper midtones (around 60%): skin, bright walls, daylight foliage."),
        "curveDarks": Entry(text: "Tone curve, lower midtones (around 40%): shaded faces, interiors."),
        "curveShadows": Entry(text: "Tone curve, darkest quarter (around 15%), just above black."),
        "skyExposure": Entry(
            text: "Brightens or darkens only the sky, in stops (±2). The sky is found by colour (bright, blue or neutral, not warm skin or green leaves) and position (top of the frame), with soft edges.",
            film: "Gives the sky more or less light before the film sees it, like a graduated ND filter (±2 stops): − brings back the colour and clouds of a sky that prints white, because the RAW keeps its brightest detail and the film then renders the sky below its white. The sky is found by colour and position (top of the frame), with soft edges."),
        "skySaturation": Entry(text: "More or less colour in the sky only: deepen a blue sky, or take the colour out of a hazy one."),
        "subjectExposure": Entry(text: "Brightens or darkens only the main subject (people, animals, objects in front), in stops (±2). The subject is found by Apple's foreground detection; if it finds none, nothing changes."),
        "subjectSaturation": Entry(text: "More or less colour on the subject only."),
        "rawLTM": Entry(text: "How much of Apple's local tone mapping the RAW develop uses: the trick that lifts shadows and holds skies in the iPhone camera. 0 is a flat, honest develop; more looks more like the Camera app."),
        "highlightRecovery": Entry(text: "Brings back skies and other bright areas that print as plain white. The RAW is developed with extra headroom so nothing clips before the film, and everything brighter than about a stop over mid-grey is compressed before printing: at 100 a sky 4 stops over grey prints where a 2-stop one used to, with its clouds. Shadows and mid-tones stay put; very bright whites come down a little. It's like giving the film more latitude, so it still reads as film, not an HDR effect."),
        "localTone": Entry(
            text: "Dodges and burns the photo: darker areas come up and bright ones come down, region by region, toward the picture's average, while fine detail and texture stay as they are. Like Apple's local tone mapping (faces lifted out of shade, skies holding their clouds), but yours to set. At 100 an area 3 stops under the average comes up about 1.8 stops.",
            film: "Dodges and burns the scene before the film sees it, like a printer holding back the shade and burning in the sky: darker areas get more light and bright ones less, region by region, while fine detail stays. The film then prints it like any exposure, so it still looks like film. At 100 an area 3 stops under the average comes up about 1.8 stops; on a hard edge (a face against a bright sky) high values can leave a soft glow."),
        "appleTone": Entry(text: "Prints Apple's own rendering of the RAW instead of its plain light: the RAW is developed the way the Camera app would (its local tone mapping and tone curve), then that is un-rendered and printed on the film, exactly what the viewfinder does with the live video. The photo comes out the way the viewfinder showed it: shade lifted, skies held, the same brightness. The RAW tab's Apple Local Tone and Film Contrast then set how much of Apple's rendering is used."),
        "rawBoost": Entry(text: "How much of Apple's base tone curve the RAW develop applies (its 'boost'): more is contrastier and brighter in the midtones, less is flatter and more neutral."),
        // Color
        "warmth": Entry(
            text: "White balance, blue (−) to amber (+). On a RAW it changes the develop's colour temperature (about 40 K per step), the same as setting white balance in camera.",
            film: "White balance of the scene before it reaches the film (about 40 K per step on a RAW): warmer or cooler light, which the film then renders in its own colours."),
        "tint": Entry(text: "White balance, green (−) to magenta (+): corrects fluorescent and LED casts, or adds a cast on purpose."),
        "saturation": Entry(
            text: "More or less colour everywhere. −100 is black and white.",
            film: "More or less colour inside the film's dyes. More works like richer dyes: a colour gets deeper and a little darker, not brighter (subtractive, like real film). Less pulls the dyes toward grey."),
        "vibrance": Entry(text: "More or less colour, mostly in the muted colours, leaving already-saturated ones and skin tones gentler than Saturation does."),
        "mono": Entry(text: "Black and white, mixed a little red-sensitive like classic B&W film (skin lighter, skies darker). Under a film look it's toned by the stock (Noir is cold). The Mixer still works, like coloured filters on the lens."),
        "mixerBands": Entry(text: "Pick a colour band (red, orange, yellow, green, aqua, blue, purple, magenta), then change just that family of colours with its Hue, Saturation and Luminance sliders."),
        "mixerChannel": Entry(text: "Which of the band's three sliders to show: Hue shifts the colour toward its neighbours (±40°), Saturation makes it richer or greyer, Luminance brighter or darker. Each band remembers all three."),
        "crossover": Entry(text: "The look's colour crossover: warm highlights over cool shadows (or whatever the stock does), which fades out at black and white. −100 removes it, +100 doubles it."),
        "gradeShadowHue": Entry(text: "The colour of the shadows' tint, as a hue (0° red, 60° yellow, 120° green, 180° cyan, 240° blue, 300° magenta). Set the amount with Shadows Tint."),
        "gradeShadowAmount": Entry(text: "How strong the shadows' tint is. The tint changes colour, not brightness, and fades out toward the midtones."),
        "gradeMidHue": Entry(text: "The colour of the midtones' tint, as a hue."),
        "gradeMidAmount": Entry(text: "How strong the midtones' tint is (gentler than the shadows' and highlights' at the same number, since it covers most of the photo)."),
        "gradeHighlightHue": Entry(text: "The colour of the highlights' tint, as a hue."),
        "gradeHighlightAmount": Entry(text: "How strong the highlights' tint is. It fades out toward the midtones and leaves pure white white."),
        // Texture
        "grain": Entry(
            text: "Adds fine film grain. Shown on Chromagraph's scale (0–5).",
            film: "How strong the film's grain is, on Chromagraph's scale (0–5; 1.25 is the look as designed, 5 four times as strong). Grain lives in the negative, so the print shapes it: strongest in the midtones, fading into the deep blacks and the brightest whites, as on a real print. On greys it's neutral, never tinted."),
        "grainSize": Entry(
            text: "How big the grain is, relative to the picture (1.00× is the look's). Bigger grain is coarser and reads as a faster, pushed film; smaller is finer, like a slow stock. Grain's strength stays the same as its size changes.",
            film: "How big the grain is, as a share of the picture (1.00× is the look's: about a pixel across at 2880 px, crisp, like Chromagraph's). As on Chromagraph, bigger grain is also stronger (about 1.4× at 3.00×); below 1.00× it can't get finer than a pixel, so it mostly gets weaker (about half at 0.25×)."),
        "pixelGrain": Entry(text: "Makes the grain one pixel across at any size, like Chromagraph's Force Pixel Size Grain: crisp, digital-looking grain that's the same at every export size, instead of grain that scales with the picture. Grain Size then does nothing."),
        "halation": Entry(text: "The glow film gets around bright lights and hard bright edges: light that passes through the film reflects off its back and re-exposes it, mostly in red. 50 is the look as designed."),
        "structure": Entry(text: "Mid-size local contrast: + brings out texture and detail (stone, fabric, skin pores), − softens it for a gentler, glowy look."),
        "sharpen": Entry(text: "Fine-edge sharpening, the last step. A little goes a long way; film looks usually need none."),
        "dehaze": Entry(text: "+ clears haze: wide-radius contrast, deeper blacks and a little more colour, so distant things come forward. − adds a pale blue-grey haze."),
        "vignette": Entry(text: "Darkens (+) or lightens (−) the corners and edges, drawing the eye to the middle."),
        "rawNR": Entry(text: "Noise reduction in the RAW develop: more smooths sensor noise (and some fine detail), less keeps detail and noise. Film looks never go below 50, since the film's contrast would amplify the noise."),
        // Film tool
        "printerWarm": Entry(text: "Printer lights, warm/cool: like a lab timing a print, it changes how much light each colour layer of the print paper gets (up to 2 printer points). The cast is strongest in the midtones and dies out at black and white, so it reads as film colour, not a filter."),
        "printerMagenta": Entry(text: "Printer lights, magenta/green: the other lab correction, for green casts from fluorescent light or a magenta push."),
        "push": Entry(text: "Push (+) or pull (−) processing, in stops: developing the negative longer or shorter. Push gives more contrast (deeper blacks, brighter highlights, coarser grain); pull is softer and flatter with finer grain. Grey stays where it is."),
        "flash": Entry(text: "Flashing: a small, even pre-exposure of the negative before the shot, an old cinematographer's trick. It lifts and softens only the deepest shadows, opening them up without touching the midtones."),
        "silver": Entry(text: "Silver retention, or bleach bypass: leaving silver in the print. Colours drain toward grey, shadows get denser and contrast goes up: the gritty, metallic look of war films and Seven."),
        "grainColor": Entry(text: "How coloured the grain is: −100 is pure monochrome grain, 0 the look's own, +100 strongly coloured, like each dye layer has its own grain."),
        "halationSize": Entry(text: "How far the halation glow spreads (1.00× is the look's): smaller is a tight rim on edges, bigger a wide bloom around lights."),
        "halationColor": Entry(text: "The halation glow's colour: −100 pure red, 0 the look's (red-orange), +100 a warm white bloom, like light scattering in the lens."),
    ]

    /// How a tab's controls work together.
    static func together(_ tab: String, isFilm: Bool) -> String? {
        switch tab {
        case "exposure":
            return isFilm ? "Exposure is the film's exposure: set it first, then shape the tones. Because the film rolls off, you can push it further than on a digital develop." : nil
        case "contrast":
            return isFilm
                ? "Contrast and Pivot work as a pair: Contrast sets how steep, Pivot where it turns. Put the pivot on what should stay the same (a face, the sky) and Contrast moves everything else around it. Fade then lifts the blacks on top."
                : "Contrast shapes the midtones; Fade lifts the blacks afterwards. Use Contrast for punch and Fade for a matte finish."
        case "shadowHighlight":
            return isFilm
                ? "Both re-expose parts of the scene before the film, so the film's own curve and colours still apply: it looks like more or less light, not an edit. They overlap in the midtones: Highlights + with Shadows − is a harder, contrastier picture; Highlights − with Shadows + flattens it (careful: both at full is very flat)."
                : "Highlights works on the bright areas, Shadows on the dark ones, each locally. Together, Highlights − and Shadows + compress a contrasty scene; use Whites and Blacks after them to set the end points."
        case "whitesBlacks":
            return "Whites and Blacks set where the tone scale ends, after everything else. Set them last, after Exposure, Contrast and Shadows/Highlights."
        case "curveLights", "curveDarks":
            return "The tone curve's four regions (Highlights, Lights, Darks, Shadows) each bend one quarter of the scale, after the look and the other tone controls; black and white never move. Lights + with Darks − is a classic S-curve; the reverse is a soft, flat one. It's a final shaping tool: use the main tone controls first."
        case "local":
            return isFilm
                ? "Two ways to get what the iPhone's own processing does to a scene. Apple Tone prints Apple's rendering, as the viewfinder shows it (Apple decides how much, scene by scene; the RAW tab tunes it). Local Tone is our own dodge and burn on the plain develop, where you set how much. Try one or the other first; together they add up. Highlights and Shadows (and Whites/Blacks) still work on top."
                : "Local Tone dodges and burns: shade comes up, bright areas come down, detail stays. The RAW tab's Apple Local Tone does something similar the Camera app's way; Local Tone adds to it."
        case "recovery":
            return "Highlight Recovery compresses every bright area evenly. For just the sky, Sky Exposure (Tone → Sky) darkens it before the film, like a graduated ND filter. Together: some Recovery for the whole picture, then Sky Exposure − for a dramatic sky. Highlights − darkens nearly the whole picture instead; use it for overall brightness, not for skies."
        case "sky" where isFilm:
            return "Under a film look Sky Exposure works on the light before the film, like a graduated ND filter on the lens: darkening a bright sky brings its clouds back through the film's curve instead of turning white into grey. Saturation applies afterwards. Highlight Recovery (Tone) does the same for every bright area at once."
        case "sky", "subject":
            return "Masks apply on top of the whole edit, only where the sky or the subject is. Exposure and Saturation combine: a darker, deeper sky; a brighter subject with a little less colour to sit it in front."
        case "raw":
            return isFilm
                ? "With Apple Tone on, these set how much of Apple's rendering the film prints: Apple Local Tone is the shade-lifting, sky-holding part, Film Contrast Apple's base curve. Lower both and it's close to the film's plain develop."
                : "These choose how the RAW is developed before any look. Apple Local Tone and Film Contrast together make up Apple's own rendering; at 0 you get the RAW's plain, flat data."
        case "balance":
            return "Warmth and Tint together set white balance: Warmth for daylight vs. tungsten, Tint for green vs. magenta casts. Set them before colour grading."
        case "saturation":
            return isFilm
                ? "Saturation works inside the film's dyes (richer is darker); Vibrance works afterwards on muted colours. B&W turns the whole thing to black and white, and the Mixer then acts like coloured lens filters."
                : "Saturation changes every colour; Vibrance mostly the muted ones. B&W turns the photo black and white, and the Mixer then acts like coloured lens filters."
        case "crossover":
            return "Crossover belongs to the look: it's the stock's own split between highlight and shadow colour. Printer Lights (Film tool) then shift the whole print warmer or cooler on top."
        case "mixer":
            return "Each band changes one family of colours: Hue shifts it toward its neighbours, Saturation and Luminance make it richer or brighter. Greys are never touched. In B&W, Luminance works like a coloured filter (darken Blue for dramatic skies)."
        case "gradeShadows", "gradeMids", "gradeHighlights":
            return "Shadows, Midtones and Highlights Tint each add a colour to their part of the scale without changing brightness. Classic pairs: teal shadows (≈190°) with orange highlights (≈40°), or warm shadows with cool highlights for a cross-processed look. They apply after the look, so keep amounts low on film looks that already have a cast."
        case "grain":
            return isFilm
                ? "Grain sets the strength and Grain Size the size; as on Chromagraph, bigger grain also reads stronger, so lower Grain a little as you raise Grain Size to keep it subtle. Together: fine and strong reads as a sharp, gritty stock; big and gentle as a soft, pushed one. Pixel Size Grain swaps the film-like grain for crisp one-pixel noise."
                : "Grain sets the strength and Grain Size the size."
        case "halation":
            return "Halation here sets how strong the glow is; the Film tool's Halation tab sets its size and colour."
        case "detail":
            return "Structure works on mid-size texture, Sharpening on the finest edges. Use Structure for character, Sharpening sparingly at the end."
        case "dehaze":
            return "Dehaze works on the whole picture's large-scale contrast and colour; for just the sky, use the Sky mask in Tone."
        case "vignette":
            return nil
        case "noise":
            return "Noise Reduction works in the RAW develop, before any grain is added: clean the sensor noise here, then add the film's grain back in Texture."
        case "fade":
            return "Fade lifts the blacks after everything else, for a matte print. With a film look it softens the dense blacks the stock is known for, so use it lightly."
        case "printer":
            return "Warm/Cool and Magenta/Green are the two axes of a lab's colour timing. Together they move a print's colour in any direction, the way a colour timer would. They're strongest in the midtones."
        case "process":
            return "Push/Pull and Flashing pull in opposite directions in the shadows: push deepens them, flashing opens them up. Pushed and flashed is a classic way to get punchy midtones with soft, open shadows."
        case "silver":
            return "Silver Retention changes the print's colour and contrast; Grain Colour the grain's. A bleach bypass look usually pairs silver with monochrome grain (Grain Colour −)."
        case "halationShape":
            return "Size and Colour shape the glow; its strength is Texture → Halation. A wide, warm-white bloom reads as a diffusion filter; a tight red rim as classic film halation."
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
