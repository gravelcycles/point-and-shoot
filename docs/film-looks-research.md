# Film and movie looks: what makes them film, and how we build them

Research brief behind the looks lineup of 2026-11-17 (`claude/beautiful-noether-ccuezc`).
It answers the owner's worry that the looks were still "instagramified": faded blacks and
a tint washed over everything. `docs/film-looks.md` is the tuning handbook and CLAUDE.md
§4 is the code reference. This file holds the *why*, with sources.

---

## 1. The short answer

An Instagram-style filter is a global operation on an already rendered image. It lifts
the blacks, washes a tint over every pixel, and scales saturation around luminance, so
saturated colours get *brighter*.

A real negative-to-print chain does nearly the opposite:
- **Dense blacks.** 2383 print D-max is about 4.0. A lifted black only comes from
  deliberate flashing (about +0.1 D).
- **Neutral highlights.** The print's three toes are matched.
- **Subtractive colour.** Purity costs density, so the most saturated colours are the
  darkest.
- **Colour that depends on hue and brightness.** Different hues bend differently, and
  casts appear at specific points on the luminance ramp. There is no single tint.

Looks differ by *structure*, meaning how colour and tone interact, far more than by tint.

## 2. What separates a film or movie look from a filter

Each principle below is backed by the sources in §7.

1. **Saturated colours get darker.**
   - Art Adams: on film "the most saturated [colors] are always the darkest", while in
     additive video "the most saturated colors are the brightest".
   - Yedlin's "Two Kinds of Saturation": film desaturation of a garish red makes it "dim
     and more yellow, but not washed out".
2. **Highlights lose colour as they brighten.** They roll off "gently to a desaturated
   white" on the print toe. Some hue drift remains: bright reds go orange.
3. **Blacks are dense, never milky.**
   - Kodak promises "rich blacks and neutral highlights" (2383).
   - Even Kamiński's flashing on *Saving Private Ryan* only kept blacks from being
     "totally sharp".
4. **Colour depends on hue and brightness.**
   - Juan Melara's breakdown of the blockbuster grade finds "several hues that appear at
     specific places on the luminosity ramp".
   - Print emulation pushes warm colours toward gold only above a certain luminance.
   - Deakins's *O Brother* grade turned the greens dry brown-yellow, hue-selectively
     (they rejected bleach bypass precisely because it was global).
5. **Memory colours are protected.** Skin varies in saturation and lightness but is "very
   similar in hue" (Prolost). Lock it, and move everything else.
6. **Little global tint: colour comes from light.**
   - Deakins's show LUT changes only "the contrast curve and the amount of color
     saturation". *Blade Runner 2049*'s colour came from filters and gels.
   - Technicolor's own advisers preached restraint.
7. **Fewer, more coherent colours.** A print "removes a lot of colour contrast and hue
   variation" and slots memory colours "into a sweet spot" (Melara, Cullen Kelly).
8. **Texture follows exposure.** Halation appears only around bright sources, on the red
   layer. Grain grows with push processing.

Yedlin's overarching claim, on display preparation:
> "The substantial part of the perceptual look comes from the mathematical preparation of
> the image for display."

That is the colour and density transform. Grain and halation matter less: the film look
survives SD resolution. Chromagraph's own description lists "tonality and chromaticity"
first, with grain and halation in parentheses.

## 3. Mechanisms, and where they live in our model

| Mechanism | What it does | Our model |
|---|---|---|
| Negative and print density curves, D-max | Contrast, shoulder, dense blacks | Tone target → derived print curve (`grey`, `slope`, `shoulder`, `white`; `floor` kept at 0 for every new look) |
| Crossover in density | Different casts in shadows and highlights, dying out at black and white | `crossover` (per-channel print gamma). Preferred over split toning |
| **Subtractive dye saturation** | Richer colours get *darker* | **New: `dyeSaturation` > 0.** It spreads density away from each colour's least dense channel |
| **Silver retention** (bleach bypass, ENR, CCE) | Desaturates and darkens rich colours; greys keep their tone | **New: `dyeSaturation` < 0** pulls toward the mean density. Silver ∝ mean density, with the print re-timed for grey, works out to exactly this |
| **Interimage / DIR effects and spectral sensitivity** | Hue-specific saturation and hue twists: Fuji's emerald greens, Kodak's golden skin, slide films' deep skies | **New: `hueTwists`**, a parametric stand-in (see below). The physical version is a 3×3 inhibition matrix K in density, iterated; not built yet |
| Technicolor key image | Extra black under colours that pass little green | **New: `key_black`**, folded into the crosstalk matrix in `filmlooks.py`. No app code |
| Print dye crosstalk | Out-of-band absorption darkens dense colours | `crosstalk` (existing) |
| Halation (red layer, no rem-jet) | Red-orange glow at bright edges only | `halation`, `halation_spread`, thresholded on highlights (existing) |
| Reversal (slide) films | ~5 stops, hard white clip, slope ~1.8–2.0, D-max 3.4–3.8 | Steep `slope`, hard `shoulder` (2.8–3.0), dark `grey`, dye saturation |
| Push processing | +~15% negative gamma per stop, more grain | `slope` and `grain` |
| Tungsten stock in daylight | Cool ambient, amber practicals | Printer lights plus a strong crossover, so highlights stay amber while shadows go cyan |
| Split toning on the encoded output | Tint by luminance | Kept for older looks only; new looks use at most a trace |

**Hue twists** (`FilmStock.hueTwists`, `FilmLUT.twist`, `filmmodel.hue_twist`):
- **Where they apply:** on scene light (linear Rec.2020), before the film's sensitivity
  matrix.
- **The space:** log(x + 0.01). Hue and chroma are measured in the plane perpendicular to
  the neutral axis, so a twist is the same at every brightness and neutrals are untouched.
- **Each twist:** `[hue°, width°, rotate°, saturation, stops]`, applied with a raised
  cosine around `hue`. The brightness shift fades in with chroma, so near-greys never jump.
- **Hue angles in this space,** measured on a ColorChecker: red ≈ 5, skin ≈ 28, orange
  ≈ 40, yellow ≈ 56, foliage ≈ 80, green ≈ 97, cyan ≈ 200, sky ≈ 224, blue ≈ 242,
  purple ≈ 274, magenta ≈ 312.
- **Why scene light and not the layer exposures:** after the sensitivity matrix, saturated
  yellows and oranges clamp one channel to zero, and they all read as hue 60.
- **Cost:** twists are built only into the negative cube, so nothing changes per frame.
  The negative cube build goes from ~14 to ~35 ms per stock and source, prewarmed in the
  background. The print cube for dye-saturated stocks takes ~5–9 ms (2–5 ms factored).

**Older photos:** both new fields are optional, and nil means off. `EditRecipe.decodeSaved`
never fills them in from today's stock (`FilmStock.offWhenMissing`), so a tuning pinned
before they existed renders exactly as it did. `FrozenTuningTests` checks this.

## 4. The looks, and what defines each

The table gives every look's reference, the traits the research pinned down, and how the
stock builds them. Hue numbers are twist centres.

| Look | Reference | Defining traits (research) | Built with |
|---|---|---|---|
| **Portrait 400** | Kodak Portra 400 | Soft toe and very long shoulder; warm, peachy-magenta highlights; greens toward yellow with less chroma; "bold yet reserved" saturation; real blacks | Key 0.25, slope 1.2, shoulder 1.5, floor 0. Skin +0.2 stops (luminous); greens −14° and −25% chroma; cyans toward yellow; magentas −15%. Slight warm and magenta printer lights |
| **Evergreen** | Fuji Superia / Pro 400H | Cooler than Kodak; greens toward emerald or cyan with chroma kept; magenta highlights over green shadows, which is a *crossover*; pink, cooler skin | Crossover [+0.05, +0.05] (red and blue steeper: green shadows, magenta highlights). Greens +25° toward cyan; skin −8° toward pink and lighter; reds toward crimson; yellows lemon. Cool printer lights |
| **Slide** | Kodachrome 64 | Intense reds and yellows against *muted* blues and greens; high contrast; dense blacks; clean clip | Key 0.11, slope 2.2, shoulder 2.8, dye saturation +0.35. Reds +30% and −0.2 stops (dense crimson); yellows golden +25%; greens olive (−14°, −25%, −0.2 stops); skies deep but not electric (−0.4 stops) |
| **Lush** | Velvia 50 | Intensely vivid greens; warm hues rotated toward red (yellows redder, skin ruddy); deep violet-leaning blues; hard white clip | Shoulder 3.0, dye saturation +0.3, interlayer 0.5. Greens +50%; skies +12° toward violet, +35%, −0.35 stops; oranges −10° and yellows −8° toward red; magentas +45% |
| **Three-Strip** | Technicolor dye transfer | Dense, pure primaries that darken as they saturate; deep blacks; *high key* (it needed huge light); rosy skin; warm highlights | Key 0.25, dye saturation +0.55, `key_black` 0.3. Hues pulled toward the primaries (yellow-green +22° → green, teal −15° → green, cyan +18° → blue, violet −15° → blue, magenta-red +14° → red); skin −12° rosy; warm crossover |
| **Blockbuster** | Modern teal and orange, done by a colourist | Skin hue *locked* and warmed; greens toward teal with less chroma; blues toward cyan; yellows toward orange; luminance-gated warm highlights; *neutral blacks* | Twists converge 15–50° onto skin (+35% chroma); greens +70° → teal at −0.3 stops; blues −35° → cyan; purples muted −45%. Crossover [+0.12, −0.22] gives warm highlights over cool shadows. No shadow tint |
| **Night 800** | CineStill 800T (Vision3 500T without rem-jet) | Tungsten balance: cool ambient, amber practicals; red halation only around bright sources; pushed contrast and grain | Cool printer lights plus a strong crossover [+0.16, −0.24]. Reds +30% and brighter (glow); ambers +20%; greens → teal. Red halation 0.55 with a wide spread and a low threshold. Key 0.085, grain 0.012 |
| **Bleach Bypass** | *Saving Private Ryan* (ENR), *Se7en* (CCE) | 40–70% desaturation; harder contrast; inky blacks; blood and warm colours go darker; grit | Dye saturation −0.55 (silver), slope 2.2, crosstalk 1.0. Skin kept a touch (+30% chroma). Grain 0.012; structure +20 |

The rest are unchanged:
- **Print**: Chromagraph, by eye.
- **Phromagraph**: Chromagraph, measured.
- **Punch**: the owner likes it.
- **Noir**: B&W.

**Replaced:** PR #35's Desert, Pastel, Amber Haze, Sodium and Neon Night. They were mostly
printer-light casts, split tones, lifted floors (0.01–0.045) and global channel mixes:
exactly the "faded / turned-up tint" pattern.

## 5. A measurement trap: mean ΔE rewards tints

The project's spacing rule is a nearest-neighbour **mean** ΔE (Oklab) over all pixels, at
least 0.06. Most pixels in a photo are near-neutral:
- A look that leaves greys and blacks alone and bends only skies, foliage and skin
  scores *low*, even when it reads as clearly different.
- A tint moves every pixel and scores *high*.

So the rule quietly pushes tuning toward casts and lifted blacks, which is probably part of
how the earlier rounds ended up "instagrammy".

What we did:
- Kept the rule, and met it on the official four images: nearest ≥ 0.061, median 0.065.
- Met it with *non-tint* separations: key, contrast, dye density and hue signatures.
- Tuned the tone axes with a small bounded search (scratch tool; the bounds keep each
  look's character).

On a wider 16-image set (portraits, foliage, a ColorChecker, sun flare, saturated toys):

| Set | Nearest-neighbour range |
|---|---|
| New looks | 0.056–0.071 |
| Today's app filters | 0.052–0.070 |
| PR #35 | 0.060–0.081 |

**Suggested refinement** (not adopted yet; the owner decides):
- Also report ΔE over *coloured pixels only*, and a ColorChecker vectorscope.
- A tint shows as parallel arrows on the vectorscope; film shows arrows going different
  ways.

## 6. Next steps (not built)

- **A physical interimage model:** logE_eff = logE − K·(D − Dmin), iterated two or three
  times, with an asymmetric K per stock (a Reala-like green-inhibits-red row, for
  example). Hue twists are its parametric stand-in. K would also make inhibition fade
  naturally in the toe and shoulder.
- **Spectral sensitivities.** Fit each stock's 3×3 sensitivity matrix by integrating its
  datasheet curves against ColorChecker spectra. Film layers are narrower and better
  separated than phone sensors.
- **Push and pull** as a control (negative gamma about ×1.15 per stop, plus grain).
- **Two-strip Technicolor** (red against cyan-green, no true blue): very distinctive.
- **Density-dependent grain.**
- **An optical white-bloom halation mode.**
- **Device test.** Everything here was designed on 2 iPhone DNGs, 4 more iPhone DNGs
  (raw.pixls.us, CC0), 2 Apple JPEGs and 9 Kodak test images, which are display-referred
  film scans. Skin under real phone processing is the first thing to check.

## 7. Sources

**Yedlin and Chromagraph:**
- [On Color Science](https://www.yedlin.net/NerdyFilmTechStuff/OnColorScience/)
- [Display Prep Demo FAQ](https://www.yedlin.net/NerdyFilmTechStuff/DispPrepDemoFAQ/)
- [Two Kinds of Saturation](https://yedlin.net/NerdyFilmTechStuff/TwoKindsOfSatuartion.html)
- [Well-meaning Muddled Article pt 2](https://yedlin.net/NerdyFilmTechStuff/WellmeaningMuddledArticle_Pt2.html)
- [Newsshooter on Chromagraph](https://www.newsshooter.com/2026/10/28/chromagraph-camera-ios-app-by-steve-yedlin-asc/)

**Subtractive colour:**
- Art Adams, [Alexa colour](https://www.theblackandblue.com/2014/02/06/art-adams-alexa-color)
- Art Adams, [film look](https://www.provideocoalition.com/film-look-two/)
- [Cullen Kelly on print emulation](https://daejeonchronicles.com/2021/08/24/moving-beyond-traditional-film-print-emulation/)
- [darktable AgX](https://docs.darktable.org/usermanual/development/en/module-reference/processing-modules/agx/)
- [darktable spektrafilm](https://docs.darktable.org/usermanual/development/en/module-reference/processing-modules/spektrafilm/)

**Stocks:**
- Kodak [2383](https://www.kodak.com/content/products-brochures/Film/KODAK-VISION-Color-Print-Film-2383-3383-data-sheet.pdf)
- Kodak [Vision3 500T](https://www.kodak.com/content/products-brochures/Film/VISION3-500T-Color-Negative-Film-7219-TECHNICAL-DATA.pdf)
- Kodak [Portra 400](https://imaging.kodakalaris.com/sites/default/files/files/products/e4050_portra_400.pdf)
- Kodak [Ektar 100](https://imaging.kodakalaris.com/sites/default/files/files/products/e4046_ektar_100.pdf)
- Kodak [E100](https://imaging.kodakalaris.com/sites/default/files/files/products/e4000_ektachrome_100.pdf)
- Fujifilm [Velvia 50](https://asset.fujifilm.com/www/jp/files/2024-04/7d7888aab11c548b2acd50f0fee9e504/datasheet_velvia50_01.pdf)
- [Kodachrome](https://pacificrimcamera.com/rl/03708/03708.pdf)
- [Fuji vs Kodak (Phoblographer)](https://www.thephoblographer.com/?p=137725)
- [Portra 400 (Casual Photophile)](https://casualphotophile.com/2015/06/12/film-profile-kodak-portra-400/)

**Interimage:**
- [US4830954](https://patents.google.com/patent/US4830954A/en)
- [Fujifilm 4th layer, 1989](https://www.jstage.jst.go.jp/article/photogrst1964/52/1/52_1_41/_article/-char/ja)
- [agx-emulsion thread](https://discuss.pixls.us/t/spectral-film-simulations-from-scratch/48209)

**Lab processes:**
- [Kodak processing techniques](https://www.kodak.com/en/motion/page/processing-techniques/)
- [AC 1998 custom processes](https://cinematographyquotes.blogspot.com/2009/05/soup-de-jour-custom-processes-defined.html)
- [Saving Private Ryan (ASC)](https://theasc.com/articles/saving-private-ryan-the-last-great-war)
- [CCE on Se7en](https://thefincheranalyst.com/2020/05/04/beverly-wood-former-vp-of-technical-services-at-deluxe-and-the-cce-process-on-seven/)
- [Minority Report](https://www.tcm.com/articles/648300/minority-report)

**Grading:**
- [Juan Melara, blockbuster](https://juan-melara.squarespace.com/blog/the-summer-blockbuster-colour-grading-tutorial)
- [Juan Melara, 2393](https://juan-melara.squarespace.com/products/kodak-2393-powergrade)
- [Prolost on skin hue](https://prolost.com/maschwikipedia/porange)
- [Deakins on LUTs](https://www.rogerdeakins.com/forums/topic/luts/)
- [O Brother (ASC)](https://theasc.com/articles/o-brother-cinematography-deakins)
- [Blade Runner 2049 (ASC)](https://theasc.com/articles/uncanny-valley-blade-runner-2049)

**Technicolor:**
- [filmcolors.org](https://filmcolors.org/timeline-entry/1301/)
- [David Mullen on 3-strip](https://cinematography.net/edited-pages/3StripTechnicolor.htm)
- [Over Journal](https://overjournal.org/article/between-the-layers)

**CineStill:**
- [FAQ](https://dealers.cinestill.film/pages/frequently-asked-questions)
- [CineD on halation](https://www.cined.com/chasing-the-glow-understanding-halation-and-why-filmmakers-keep-coming-back-to-it/)

**Test images:** raw.pixls.us iPhone DNGs (CC0); the
[Kodak Lossless True Color suite](http://r0k.us/graphics/kodak/) (kodim04, 15, 23 and
others; download them, don't commit them).
