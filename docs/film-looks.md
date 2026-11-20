# Film looks: handoff notes

Working notes for whoever picks up the Print look and the other looks next (the "photo
filters" until 2026-11-17, when they were renamed Looks and rebuilt as movie grades,
§1½). CLAUDE.md §4 ("Film looks") is the reference for *what* the code does. This file covers *how we got
here*, how to tune, what's still unknown, and the tricks that save hours. Written
2026-11-14.

---

## 1. Where things stand

| PR | What | State |
|---|---|---|
| #9 | Print look (Chromagraph-style film emulation) and Print mode (PHOTO · PRINT · VIDEO) | merged |
| #15 | Every photo filter is a film stock, plus split toning, spaced apart with a metric | merged |
| #20 | Grainy Print photos: real RAW noise reduction, exact grain, finer grain | merged |
| #34 | Phromagraph: a look fitted to Chromagraph's own renders (§5½) | merged |
| #35 | Filters → **Looks**: seven cinematic grades replace the Instagram-ish filters (§1½) | open, into `claude/raw-import` |
| #36 | Engine 2: the viewfinder un-render, measured (§5¾) | merged |
| #38 | Looks with structure (hue twists, dye saturation), named look sets, engine 3's subtractive Saturation slider (§1¾); #37 is the same for P&S Studio | merged |
| #41 | Brightness against Chromagraph: editor matching, cap +4 EV (§5⅞) | merged, superseded by #42 |
| #42 | Film looks develop from the RAW alone at a fixed +1.86 EV; the viewfinder match is gone (§5⅞) | merged |
| #43 | Plain live view: video HDR off and global tone mapping in Print/Zero (§5⅞) | this PR |

**Not yet verified on the phone:** everything in #15 and #20. Device feedback so far, in
order:

1. "the photo filters look fairly bland". They were slider presets, so they were rebuilt as
   film stocks.
2. "they all look v similar". Pass 2 made them bolder; the nearest pair went from 0.014 to
   0.032 ΔE.
3. "these seem closer together compared to ie snapseed filters". Research and
   measurement showed the cause: identical shadows. Split toning plus a retune fixed it;
   the nearest pair is now 0.067 ΔE.
4. "normal print mode photos are super grainy". Print forced 15% noise reduction on a
   single-frame RAW; #20 fixes this.
5. "what I see through the viewfinder is a lot brighter than what actually is published.
   I like what I see through the viewfinder". The viewfinder (Apple's processed video,
   un-rendered by a gentle inverse curve) and the photo (linear RAW) landed at different
   brightness. Each shot is now matched to the viewfinder (`rawFilmExposure`; CLAUDE.md §4,
   "Brightness matches the viewfinder").

6. "We've gone too far into instagram filter. We should rename it to 'looks' and aim to
   have as original looks as 'print'. 'Punch' is good too. But the others are meh (washed
   out or just playing with saturation or tint etc)… we def want to be more
   chromagraph-y", with a wish for movie looks ("a 'Wes Anderson' look", "a look per
   movie (dune)"). See §1½.
7. "with the new changes and photo calibrations our looks are a ton darker than
   chromagraph", with screenshots of the same tram scene in both apps: ours had about a
   sixth of Chromagraph's light (geometric-mean display luminance 0.021 vs 0.125). That
   shot predated the viewfinder match, and the editor could never add one. See §5⅞.
8. "the viewfinder workaround seems...bad. the inputs for the photo should just be the
   raw photo imo. nothing else… can we change the viewport to match the photo?" Agreed:
   #42 develops every film look's RAW at a fixed exposure. The viewfinder already
   previews that within ~0.1 EV at mid-grey; what's left is Apple's per-scene video
   rendering (§5⅞).

**What to ask the owner next:**
- Do the new looks feel like films or movie grades? Which ones would they cut or push
  further? (Send `docs/looks-contact-sheet.jpg`.)
- Do indoor Print shots look clean now?
- Is there still visible grain at 100%? If there's none at all, see §6.
- Do the looks read as different at thumbnail size?
- Shot side by side with Chromagraph, is a new shot as bright? If every shot is off by
  the same amount, change `EditRecipe.filmRAWExposure`.
- How far is the viewfinder from the saved photo, and in which scenes (sun, overcast,
  night)?
- Re-picking the look on an older, dark Print photo should bring it up ~2 stops.

## 1½. Filters → Looks (2026-11-17)

The owner found every filter but Print and Punch "meh": washed out, or just a tint or a
saturation change. The brief became *film or movie grades with real character*, the way
Print has it: a tone curve with a shoulder, dense or deliberately lifted blacks, a colour
crossover, halation and grain.

**Kept untouched:** Original, Print, Phromagraph (#34) and Punch. Noir stays as the one
black-and-white look (unchanged numbers).

**Retired** (no longer offered, but every photo made with them renders exactly as before
from its pinned tuning or `FilmStock.Legacy.v2`): Natural, Warm 400, Skin (`portrait`),
Cool Air, Cine, Chrome, Faded, Mono 400, Silver. `Look.retired` keeps their names (the
editor still says which look a photo has) and where a saved camera choice moves:
Chrome → Slide, Mono 400 and Silver → Noir, the rest → Original.

**The new looks** (names are evocative, never film titles, directors or trademarks;
inspiration goes in the `detail` text at most). *Superseded before shipping by §1¾:*
Desert, Pastel, Amber Haze, Sodium and Neon Night were replaced; Bleach Bypass and
Slide were rebuilt.

| Look (`id`) | Intent | How the stock gets there |
|---|---|---|
| Desert (`desert`) | Desert epic: warm ochre and sand, quiet colour, soft lifted blacks, a long gentle roll-off, no teal | Warm printer lights (−r, +b), *positive* blue crossover so shadows stay brown, not teal; brown shadow and sand highlight tints; interlayer −0.2; soft shoulder 1.5 |
| Pastel (`pastel`) | Storybook grade: high key, soft, candy pinks, butter yellows, mint, cream whites | Key 0.27, slope 0.95, floor 0.03; `channel_mix` adds red to the blue layer (reds go pink) and a little blue to greens (mint); rose shadows, cream highlights |
| Amber Haze (`amber`) | Orange fog over a future city: nearly monochrome amber, smoky highlights | Interlayer −0.8 (almost mono), strong orange printer lights and tints, white 0.86 and floor 0.045 (smoke), a wide warm bloom (σ 6/20 ‰); `huePreserve` 0 or hue protection would re-saturate it |
| Sodium (`sodium`) | Streetlight thriller: green-yellow cast, muddy desaturated shadows, cold skin, low key | Printer lights −g, +b; olive shadow tint; `channel_mix` takes red from green (cold skin); interlayer −0.35; key 0.12 |
| Neon Night (`neon`) | Neon-lit romance: saturated reds against green shadows, crushed blacks, strong glow | Interlayer 0.9, slope 2.0, key 0.085, floor 0; green shadow tint, red highlight tint; red halation 0.45 |
| Bleach Bypass (`bleach`, now "Bleach Grit") | Silver retained: hard contrast, drained colour, metallic highlights, grit | Slope 2.1, interlayer −0.35, full dye crosstalk, steel shadow tint, grain 0.012, structure +20 in `Look.all` |
| Slide (`slide`, now "Slide 70s") | Seventies slide film: rich reds, deep blue skies, dense blacks, warm light | Slope 2.0, floor 0, interlayer 1.1 with crosstalk 0.9 (dense colours darken: deep skies), cool shadows under warm highlights |

**New tool: `channel_mix`** (`film-looks.json`): a 3×3 mix of scene RGB (linear
Rec.2020), rows normalised to 1 so neutrals stay neutral, folded into the stock's
sensitivity matrix by `filmlooks.py`. It needs no app code: the sensitivity matrix was
always a full 3×3. Hue protection inverts that matrix, so it partly undoes a mix in the
highlights; keep `huePreserve` low on looks that depend on a mix or on desaturation.

**Spread** (`spread` now measures every look in one table, Print, Phromagraph and B&W
included, and takes `--looks OLD.json` to measure an older set):

| Look | Nearest | ΔE |
|---|---|---|
| Print | Phromagraph | 0.023 |
| Phromagraph | Print | 0.023 |
| Desert | Sodium | 0.074 |
| Pastel | Amber Haze | 0.075 |
| Amber Haze | Pastel | 0.075 |
| Sodium | Desert | 0.074 |
| Neon Night | Print | 0.067 |
| Bleach Bypass | Slide | 0.065 |
| Slide | Phromagraph | 0.063 |
| Punch | Slide | 0.079 |
| Noir | Bleach Bypass | 0.070 |

Every new look clears 0.06 (nearest 0.063, median 0.070). Print and Phromagraph sit at
0.023 on purpose: both are Chromagraph's rendering, one tuned by eye, one measured, and
neither may be retuned from the other. Measured the same way, the old set failed once
Print was counted (Print–Cine 0.044, Warm 400–Silver 0.057).

**Reproducibility fix:** `derive_print_curve` now sorts with `kind="stable"`, so which of
two exactly tied knots survives no longer depends on numpy's sort (the cause of the
cross-machine drift noted in CLAUDE.md). With it, Print, Phromagraph, Punch and Noir
regenerate byte-identical (numpy 2.5.3).

**Contact sheet:** `docs/looks-contact-sheet.jpg` now shows §1¾'s set (Original, Print and Punch,
then the new looks) on eight test images, film only (no vignette or structure).

## 1¾. Structure, not tint (2026-11-17, second pass)

The owner worried the looks were "still instagramified... not film-esque or movie-esque",
liked Punch, and wanted nothing that "seem[s] super faded/just turned up the tint". The
research behind this pass, with sources, is in **`docs/film-looks-research.md`**.

**The diagnosis:** most of §1½'s looks were the Instagram pattern:
- printer-light casts and split tones over every pixel;
- lifted floors of 0.01–0.045;
- a global `channel_mix`.

Film looks differ instead by how colour and tone *interact*. Three new mechanisms do that
(CLAUDE.md §4). All three are point-wise and baked into the two LUTs, so nothing changes
per frame:
- **`hue_twists`:** each film's colour rendering by hue, on scene light in log space.
  Neutrals are untouched. Emerald greens, golden or rosy skin, deep skies, teal and orange
  with skin locked.
- **`dye_saturation`:** saturation in print density. Above 0, richer colours get *darker*
  (subtractive). Below 0, it's retained silver (bleach bypass).
- **`key_black`:** Technicolor's black key image, which adds density under colours that
  pass little green.

**The looks** (details and research in `docs/film-looks-research.md` §4). Every new look
has `floor` 0, and split toning is gone or a trace.

| Look (`id`) | Reference | Signature |
|---|---|---|
| Portrait 400 (`portrait400`) | Portra 400 | High key, soft contrast into real blacks, luminous warm skin, olive greens, pale cyan skies |
| Evergreen (`evergreen`) | Fuji 400 | Emerald greens, pink skin, magenta highlights over green shadows (crossover [+.05, +.05]) |
| Slide (`classicslide`) | Kodachrome | Dark key, hard contrast, dense crimson reds and gold against muted olive greens and deep skies |
| Lush (`lush`) | Velvia | Lush greens, violet-leaning deep skies, warm hues pushed to red, hard white clip |
| Three-Strip (`threestrip`) | Technicolor dye transfer | High key, pure dense primaries (key black), rosy skin, warm light |
| Blockbuster (`blockbuster`) | Teal and orange, done by a colourist | Skin hue locked, greens and skies turned teal, purples muted, neutral blacks |
| Night 800 (`night800`) | CineStill 800T | Cyan shadows under amber light, red halation, low key, grain |
| Bleach Bypass (`bleachbypass`) | ENR / CCE | Dye saturation −0.6 (silver), hard contrast, inky blacks, grit |

**Unchanged:** Print, Phromagraph, Punch and Noir (they regenerate byte-identical).

**Named sets (same day, at the owner's request: "create diff sets of looks... so i can try
and test"):** every look stays available and the pickers switch between sets (`LookSet`;
CLAUDE.md §4).
- Essentials: Print, Phromagraph, Punch, Noir.
- Film Stocks and Movie: the looks above.
- Grades: §1½'s pass, ids and tunings untouched. Its Slide and Bleach Bypass keep ids
  `slide` / `bleach`, shown as "Slide 70s" / "Bleach Grit"; the new ones are
  `classicslide` / `bleachbypass`. (A first version reused `slide` / `bleach` for the new
  looks; a review caught that saved choices, photos' edits and the editor would then
  point at the wrong look.)

`spread` measures each set together with the essentials, and every set clears 0.06
(nearest 0.060–0.079, re-measured after #36's engine-2 un-render moved the JPEG
columns: Three-Strip and Night 800 were retuned for it).

**Retired camera choices now land on a successor:** Skin → Portrait 400, Cool Air →
Evergreen, Cine → Blockbuster.

**The Saturation slider was additive, and is fixed from film engine 3.** It spread density
about the mean, which brightens a saturated colour's dominant channel (a yellow at +50 went
from 0.34 to 0.57 luminance). From engine 3 it pivots on the least dense channel like
`dye_saturation`. Edits from engines 1–2, or with no engine, keep the old slider. Engine 2
is #36's measured un-render; engine 3 keeps that un-render and renders exactly like engine 2
at Saturation 0.

**Spread** (official four images, before #36's un-render; see above for today's): every new look's nearest was ≥ 0.061, with a median of
0.065. Print and Phromagraph stay close by design.

On a wider 16-image set (Kodak portraits, parrots, a ColorChecker DNG, sun flare,
aerial):

| Set | Nearest-neighbour range |
|---|---|
| New looks | 0.056–0.071 |
| Today's app filters | 0.052–0.070 |
| §1½'s looks | 0.060–0.081 |

**Read §4's "mean ΔE rewards tints" before chasing the 0.06 rule.**

**Not checked:** a real night scene for Night 800 (only daylight and sun flare), and
anything on the device.

## 2. The owner's taste (from their own words)

- **"Smooth as butter" / "silky smooth everything".**
  - The viewfinder must never stall.
  - Tables are prewarmed in the background.
  - Frames are dropped, never queued.
  - Cube rebuilds stay in single-digit ms.
- **Modes should be easy to pick, with no superfluous controls.** Print mode hides the
  format pill, the LOOK cell and burst, and always shoots RAW.
- **Looks must be obviously different at a glance.** They compare against Snapseed and
  Instagram.
- **Looks must be films or movie grades, never Instagram filters.** Print and Punch are the
  bar; "washed out" or "just playing with saturation or tint" is what they reject.
  Chromagraph is the reference for *how* (a real curve, dense blacks, halation, grain).
- **Grain must stay subtle.** Digital noise is never "character".
- **How they test:** on an iPhone 12 Pro (iOS 18), looking at results in Photos and the
  in-app viewer. Send them contact sheets (SendUserFile) when you change looks; they
  react to pictures, not numbers.

## 3. Mental model in one screen

```
scene light ─ exposure ─ halation ─ shaper ─ [negative cube 48³] ─ + grain ─ [print cube 48³] ─ Display P3
                (spatial)                    per stock, per source    (spatial,      per stock × FilmControls;
                                             (sceneLinear | display-  in density)    ends with split toning)
                                              Referred)
```

- **Two sources.**
  - `sceneLinear` is a RAW develop: boost 0, no local tone map, no sharpening.
  - `displayReferred` is the viewfinder or a processed HEIF. It is un-rendered first, on
    luminance, with Apple's measured curve and its saturation divided out (engine 2,
    §5¾; engine 1 used a guessed curve and kept channel ratios).
- **The negative cube** holds the stock's sensitivity (interlayer), the negative curve
  (Vision3 5219) and the density.
- **The print cube** holds, in order: printer lights, the print curve (derived from the
  tone target), crossover, dye crosstalk, highlight hue protection, the display matrix,
  then split toning on the encoded output.
- **Black and white** is a colour stock, then the editor's mono mix, then `monoTone`. That
  keeps the colour mixer working like darkroom filters.
- **Vignette and structure** are not in the stock. They're recipe extras in
  `Look.all` (EditRecipe.swift).
- **Source of truth:** JSON (`scripts/print-stock.json` and `scripts/film-looks.json`),
  then `filmlooks.py`, then `print-look.py export-swift`, which writes
  `FilmStock+Stocks.swift`.
  - `scripts/filmmodel.py` mirrors `FilmModel.swift` exactly.
  - `parity` proves the two agree.

## 4. Tuning a look: the loop

```sh
# 1. Edit scripts/film-looks.json (anything left out inherits from Print)
# 2. Measure and look
python3 scripts/print-look.py spread A.dng B.dng C.jpg D.jpg --cssgram --sheet /tmp/sheet.jpg
# 3. Regenerate Swift and prove it matches the Python model
python3 scripts/print-look.py export-swift
python3 scripts/print-look.py parity            # needs swiftc; see §8
# 4. If the character changed: Look.all detail strings and extras (EditRecipe.swift),
#    README look list, CLAUDE.md §4
```

**The rule: every look's nearest neighbour is at least 0.06 mean ΔE (Oklab) in `spread`**
(Print and Phromagraph excepted: they're the same rendering by design, §1½).

Today (all looks in one table):

| Set | Nearest pair | Median nearest |
|---|---|---|
| Looks (excluding the Print/Phromagraph pair) | 0.063 | 0.070 |
| The retired filters (#15, B&W separately, Print not counted) | 0.067 (B&W 0.063) | 0.070 |
| CSSgram (26 Instagram-style) | 0.021 | 0.050 |

**What makes looks read as different** (from the CSSgram and Snapseed research, and
confirmed by measurement):
- **Signature axes.** Each look should own 2–3 that survive a thumbnail:
  - key (overall brightness)
  - contrast
  - chroma
  - **shadow tint** (the biggest one)
  - highlight tint
  - vignette
- **Grain, structure and sharpening are invisible at thumbnail size.** They're secondary
  character only, which is why `spread` renders with grain 0.
- **Snapseed separates its families by *mechanism*:** tone mapping (HDR Scape, Drama),
  band-limited local contrast (Tonal Contrast), glow (Glamour Glow), textures (Grunge),
  light leaks and scratches (Retrolux), coloured vignettes (Vintage) and toned mono
  (Noir). We have halation/bloom, vignette, structure and toned mono. The rest are ideas
  (§9).

**Parameter cheat sheet** (`film-looks.json`; ranges that worked):

| Key | Does | Range used |
|---|---|---|
| `grey` | Display luminance of 18% grey: the key | 0.085 (Neon Night) – 0.28 (retired Skin) |
| `slope` | Log-log contrast below the shoulder | 0.85 (Skin) – 2.25 (Noir) |
| `shoulder` | How hard the highlights roll off | 1.5 – 3.0 |
| `white` / `floor` | Display white / lifted black (matte, smoke) | 0.82–1.0 / 0–0.06 |
| `printer` | `[r, b]` or `[r, g, b]` log-exposure offsets. **+ means *less* of that colour.** A green + reads magenta (that gave Skin lavender skies); a green − is Sodium's cast. | −0.15 – +0.3 (Amber Haze) |
| `crossover` | `[r, b]` gamma split. Blue − = teal shadows under amber highlights; blue + = warm shadows, cooler highlights (Desert: "no teal") | ±0.26 |
| `interlayer` | Saturation in the negative | −0.8 (Amber Haze) – 1.7 (Punch) |
| `channel_mix` | 3×3 scene RGB mix, rows normalised to 1 (§1½) | Pastel, Sodium |
| `crosstalk` | 0–1 print-dye coupling: dense colours get darker | 0.1 – 1.0 |
| `halation`, `halation_spread` | Red glow by default. Equal R/G/B with wide sigmas and a low threshold gives a neutral bloom (Skin). | – |
| `shadow_tint` / `highlight_tint` | Split toning: encoded RGB offsets weighted (1−Y)² / Y², made luminance-neutral by `filmlooks.py` | ±0.08 |
| `grain` | Density std at 4032 px (Print uses 0.008) | 0.0027 – 0.0133 |
| `hue_twists` | Film colour by hue: `[hue°, width°, rotate°, saturation, stops]` each, on scene light in log space (neutrals untouched). Hues: red 5, skin 28, orange 40, yellow 56, foliage 80, green 97, cyan 200, sky 224, blue 242, magenta 312. Converging rotations compress a palette (Blockbuster: 15–50° onto skin; Three-Strip: onto the primaries) | widths 20–60°, rotations ±70°, saturation −0.45…+0.5, stops −0.5…+0.25 |
| `dye_saturation` | Saturation in print density. > 0 pivots on each colour's least dense channel, so richer colours get *darker*. < 0 pulls toward the mean density (silver) | −0.55 (Bleach) … +0.55 (Three-Strip) |
| `key_black` | Technicolor's key: green-record density added under every channel (rows renormalised), so reds, blues and magentas get extra black | 0.3 (Three-Strip) |
| `huePreserve` | Keeps bright warm colours from turning yellow (0 = pure film). Re-saturates desaturated looks and partly undoes a `channel_mix`: keep it low there | 0 (Amber Haze, Bleach) – 0.9 (Print 0) |
| `mono_tone` | B&W toning gains | Noir [.90,.97,1.13]; Silver [1.1,1,.82] |

**Pitfalls we hit** (don't rediscover them):
- **Film blacks converge to the same neutral.** Without `shadow_tint`, all filters had
  identical shadows. This was the main cause of "they all look the same".
- **Yellow or gold faces.** Saturation plus red channel clipping in the shoulder caused
  them. `huePreserve` blends bright colours back toward the scene hue.
- **Hue protection erasing filter casts.** The fix carries each stock's own neutral cast
  (`neutralTable`).
- **Un-rendering processed images per channel** read saturated reds as overexposed: reds
  went orange and faces yellow. Always invert on luminance.
- **Olive skies from a yellow highlight tint** (luminance-neutralizing pulls green in).
  Add red: Warm 400 uses `[0.05, 0, −0.07]`.
- **The metric depends on test-image exposure.** `spread` normalises DNGs (median 0.7 ×
  18% grey). Raw sample DNGs are often dark, and a dark frame measures mostly shadows.
- **Don't shrink the cubes below 48³.** At 40³ the grey ramp stops being monotone
  (banding).
- **A desaturated look plus hue protection gets its colour back in the highlights.**
  `huePreserve` blends toward the scene colour with the interlayer undone; Amber Haze and
  Bleach Bypass use 0.
- **Mean ΔE rewards tints.** The spread rule averages over all pixels, and most pixels are
  near-neutral.
  - A look that leaves greys alone and bends only skies, foliage and skin scores low
    (0.035–0.05) even when it reads as clearly different.
  - A cast moves every pixel and scores high.
  - Chasing 0.06 with printer lights, split tones and floors is how looks become
    Instagram filters.
  - Separate looks by key, contrast, dye density and hue signature instead. Check with
    `print-look.py scope OUT.jpg`, a ColorChecker vectorscope: a tint shows as parallel
    arrows or a collapse to one blob. A bounded
    search over grey, slope and dye saturation helps (the 2026-11-17 pass used a scratch
    tool; the bounds keep each look's character).
- **Density saturation about the mean *brightens* saturated colours.** Spreading a red's
  densities about their mean lowers the cyan density, which is the red channel, and red
  transmittance shoots up: Y 0.07 → 0.22 at +0.4. Engines 1–2's Saturation slider does this;
  engine 3's pivots like `dye_saturation`.
  The stock's `dyeSaturation` pivots on the least dense channel instead, so purity costs
  density, as with real dyes.
- **Hue twists can fold the hue order.** A raised-cosine twist's steepest slope is
  rotation·π/(2·width); past 1 the output hue runs backwards (Blockbuster's first greens
  twist, +70° over ±60°, made yellow-greens come out more teal than greens: seams in
  foliage gradients). `filmlooks.py` now refuses any stock whose d(hue out)/d(hue in)
  drops below 0.2; keep |rotation| under ~0.5·width and widen twists that converge.
- **Hue measured after the sensitivity matrix is useless for yellows.** Interlayer pushes
  their blue exposure below zero, and it clamps, so every saturated yellow and orange
  reads as hue 60. Twists therefore measure hue on scene light, in log(x + 0.01).
- **"Washed out" is a floor and a white, not a mood.** The first Desert (floor 0.04,
  white 0.93, slope 1.0) read grey and flat; the fix was contrast (slope 1.6) with a small
  floor, letting the warm cast carry the look.

## 5. Print calibration (Chromagraph)

Chromagraph Camera (Oct 2026; Rian Johnson and Steve Yedlin) is the reference. The numbers
come from:

- **Negative curve:** Kodak Vision3 5219 datasheet.
- **Dye crosstalk:** Kodak 2383 dye densities.
- **Tone response:** recovered from Chromagraph's in-app exposure sweep: a near power law,
  slope ≈ 1.44, into a shoulder capped at 0.83 white.
- **Colour:** printer lights, crossover and interlayer saturation fitted to public
  Chromagraph samples. Neutral tint vs lightness; ColorChecker chroma ≈ 0.85×.
- **Grain and halation:** by eye against the same samples.

**Reference images** (download them; don't commit them, since they're other people's
photos):
- **Chromagraph vs Apple pairs** from a public Substack review (iPhone 17 Pro Max):
  - `jg1_chroma` https://substack-post-media.s3.amazonaws.com/public/images/5ae8ada8-0d35-4cfd-ad75-5f99244cadfd_2880x1620.jpeg
  - `jg1_apple` https://substack-post-media.s3.amazonaws.com/public/images/e6a50501-679b-4dde-87d1-4d69953b7449_5712x3213.jpeg
  - `jg2_chroma` https://substack-post-media.s3.amazonaws.com/public/images/928f139f-6a91-4b96-9958-b12124969c37_2880x1623.jpeg
  - `jg2_apple` https://substack-post-media.s3.amazonaws.com/public/images/9b7fae9b-9169-4e94-b258-a9fdc5f2b635_4032x2268.jpeg
- **More Chromagraph samples:**
  - CineD: https://www.cined.com/steve-yedlin-and-rian-johnson-release-chromagraph-camera-film-color-pipeline-for-iphone-stills-grain-halation-and-a-raw-gallery/
  - Newsshooter: `media.newsshooter.com/wp-content/uploads/2026/10/IMG_6668.jpg` and neighbours
  - Gadget Lab: `gadgetlab.online/wp-content/uploads/2026/11/IMG_6700.jpeg` and neighbours

**The most accurate next step** is refitting to real pairs (CLAUDE.md §4, "Refit to real
pairs"): the same scene shot with Point & Shoot (DNG kept) and with Chromagraph, then
`print-look.py fit DIR [--same-raw]`.

## 5½. Phromagraph: Chromagraph, measured (2026-11-17)

A separate stock, `phromagraph`, fitted to **Chromagraph's own renders of its own RAWs**.
Print stays as it is: it was calibrated from public samples, and the two are kept apart on
purpose.

**The data.** The owner exported 13 Chromagraph shots: the DNG Chromagraph keeps, the HEIC
it saved, and `settings.json` (Chromagraph 1.6.1's per-shot settings), all from an
iPhone 12 Pro on iOS 18.7.3. Not committed (personal photos). Ask the owner for the folder
"Chromagraph RAW + Settings 2026-11-17", or a new one.
- The pairs match by capture time (`cgc_NNNNN.dng` ↔ `IMG_NNNN.HEIC`). One DNG is from
  another app (VisionCamera) and was imported into Chromagraph.
- Settings moved, from `settings.json` (and confirmed in the pixels: per-shot exposure
  agrees to ±0.04 EV, no hidden colour bias): cgc_00014 has +0.44 EV and **Shadows 1**
  (left out of the fit); 1303DFCB has −1.48 EV (applied). The first 8 shots have grain
  1.25 / size 1; the last 5 have grain off (Chromagraph's default). One shot has a
  digital-zoom crop, which the alignment finds.

**What we learned about Chromagraph:**
- **It shoots ProRAW** (linear DNGs, `PhotometricInterpretation` = Linear Raw), not Bayer.
- **Its HEICs are untagged** (nclx with unspecified primaries and transfer); iOS and macOS
  display them as sRGB. They're 8-bit 4:2:2 at 2880 px.
- **No local tone mapping.** Once a global tone curve is applied, the residual maps are
  flat. So a global transform (our film model) can match it.
- **The look:** blue skies turn cream, mid-tones lean teal, blacks are dense, the curve is
  steep (log-log slope ≈ 2.0) into a soft shoulder (white ≈ 0.88).
- **Exposure:** it develops at a fixed +1.8 EV over a neutral CIRAWFilter develop of the
  ProRAW, with no per-shot auto exposure.
- **Halation is barely there.** No measurable red excess near lamps or bright edges. Our
  model with *no* halation matches better than Print's. Phromagraph uses about a third of
  Print's (`[0.05, 0.012, 0]`, boost 1).
- **Grain 1.25** adds σ ≈ 3.6/255 of encoded luminance in the mid-tones at 2880 px, with
  lag-1 autocorrelation 0.23 (fine and slightly sharpened). In our model that's
  `grainDensity` 0.017, about twice Print's grain. Phromagraph ships it at Grain slider 50,
  with the look's default grain at 0. Measured properly (amplitude, size, colour,
  brightness) on 2026-11-20: §6 and CLAUDE.md, film engine 7.
- **Chromagraph's Shadows 1** ≈ our `shadows` 0.9 (one shot, so it's rough).

**How it's fitted** (`scripts/phromagraph.py`, macOS):
1. `prep DIR` develops each DNG with `scripts/raw-develop.swift`: CIRAWFilter exactly as
   `EditPipeline.configure` does under a film look (boost 0, no local tone map, no
   sharpening, NR floored). It then aligns to the HEIC (SIFT similarity transform) and
   takes ~7k blurred samples per pair. The samples are stratified by brightness and kept
   away from edges, clipping and halation.
2. `fit` runs least squares in Oklab (chroma weighted 1.3) over tone (grey, slope,
   shoulder, white, floor → derived print curve), printer lights, crossover, a full 3×3
   layer sensitivity, crosstalk, split toning and hue protection, plus one develop
   exposure shared by every pair. It writes `scripts/phromagraph-stock.json`. Then run
   `print-look.py export-swift` and `parity`.
3. `measure DIR` prints, per shot, how far the viewfinder (Apple's render, un-rendered)
   lands from the fixed develop exposure, and the grain statistics. `sheet OUT.jpg` draws neutral | Print |
   Phromagraph | Chromagraph.

**Results:** mean ΔE (Oklab) **0.0070** across the 12 fitted pairs (per pair
0.005–0.013), against **0.0193** for Print with its best exposure.
- What's left sits in near-whites (slightly dark and yellow) and blues (slightly flat).
- More freedom bought little:
  - a free 16-knot tone spline reached 0.0065, but ran above white where there's no data;
  - per-channel paper white reached 0.0068, with a greenish white.
  - Neither was kept.

**Caveats:**
- **Brightness.** Since #42 the app develops every film look's RAW at Chromagraph's fixed
  +1.86 EV (`EditRecipe.filmRAWExposure`), so the stock's exposure is 0. Before that it
  matched each shot to the viewfinder. With Apple's default render standing in for the
  viewfinder (engine 1), the viewfinder sits +0.09 EV from that fixed develop (median),
  ±0.5 EV per shot:
  - night alley: the viewfinder is ~1.4 EV darker;
  - overcast: ~0.6 EV darker;
  - bright day: ~0.3 EV brighter.
- **Bayer vs ProRAW.** We fitted on ProRAW developed by CIRAWFilter; the app shoots Bayer
  RAW. Both develop through Apple's colour pipeline, but Bayer is noisier and its exposure
  scale may differ. The owner's side-by-side (§5⅞) put Bayer at Print exposure 0 at
  1.9–2.1 EV under Chromagraph, so the scales agree to ~0.1 EV. Colour should carry over.
  - **Best next data:** the same scenes shot with Point & Shoot Phromagraph (DNG kept)
    and Chromagraph back to back, from a tripod or steady hands.
- **Highlights above the develop's clip** (CIRAWFilter with boost 0 tops out at 1.0) aren't
  in the data, so the shoulder's very top is extrapolated.

## 5¾. The viewfinder un-render, measured (engine 2, 2026-11-17)

The viewfinder and processed photos reach the film already rendered by Apple, so the
film first has to undo that rendering ("un-render"). Engine 1's undo was a guess. The
Chromagraph DNGs made it measurable.

**The method:**
- Each DNG is developed twice with CIRAWFilter:
  - Apple's defaults (`raw-develop.swift --apple`), a stand-in for the processed
    photo and the video feed;
  - neutral, exactly as the app develops a RAW.
- Each shot's exposure is solved, then Apple's display luminance is compared with
  scene luminance pixel by pixel. Scratch scripts did this; the numbers are in the
  tables.

**What Apple does, and what engine 1 got wrong:**
- **Shadows are crushed hard.** −4 stops renders at 0.003, where engine 1 assumed 0.014.
  Un-rendering read dark areas 1–2 stops too dark.
- **Highlights roll off much sooner.** +3 stops renders at about 0.65; engine 1 put
  +3.5 stops at white.
- **Saturation is boosted, following the curve's slope:** ×3.4 in the toe, ×1.4 at grey,
  ×1.1 in the shoulder. Engine 1 kept display channel ratios, so the un-rendered
  picture was ~1.45× more saturated than the scene, and the film added its own on top.
- Neither a per-channel curve nor a luminance curve alone reproduces Apple's colour. A
  luminance curve plus the saturation boost does (chroma 0.036 vs Apple's 0.037).
- **Exposure was applied before un-rendering,** so +1 EV in the editor on a processed
  photo clipped everything above display 0.5 to white.

**What engine 2 does** (`FilmLUT.sceneFromDisplay(rgb:engine:)`, mirrored in
`filmmodel.py`):
- un-renders luminance through the measured table;
- divides chroma by the boost;
- applies exposure afterwards, in scene light.

**Why the table is E[scene | display]:** it holds the median scene light behind each
display level, rather than the inverse of the forward curve. With Apple's local tone
mapping scattering pixels ±0.6–1 stop, inverting the forward curve over-stretches the
ends. End to end, viewfinder against saved photo:

| Inverse | Median ΔE (Oklab) |
|---|---|
| Engine 1 | 0.043 |
| Inverted forward curve | 0.045 |
| E[scene \| display] | 0.028 |

It flattens near white at +3.5 stops, which is right here, because the RAW develop clips
there too.

**Kept for older photos:** edits pinned with engine 1 (or with no engine) render exactly
as before, and `FrozenTuningTests` checks engine 1's un-render bit for bit.

**Unknowns:**
- The tables come from CIRAWFilter's rendering of ProRAW, not from the live video feed.
  Best next data is real viewfinder frames saved next to each DNG (a diagnostic capture).
- The fit covers one phone (iPhone 12 Pro) and Apple's default style.
- What's left (median ~0.03) is Apple's local tone mapping, which no global un-render can
  remove.

## 5⅞. Brightness against Chromagraph (2026-11-18)

**The complaint:** our photos were "a ton darker than chromagraph". The owner's screenshots
of one tram scene, measured in display light: geometric-mean luminance 0.021 for ours
against 0.125 for Chromagraph (2.6 stops), 95th percentile 0.11 against 0.53.

**Why that shot was dark:**
- It was taken at 08:46 CET on 2026-11-14, 46 minutes before #22 (the viewfinder match)
  merged. So it has no `rawFilmExposure` and developed at the RAW's own exposure.
- A neutral iPhone RAW develop sits about 2 stops under Apple's rendering. Chromagraph
  develops +1.86 EV over it (§5½). The missing ~1.9 EV, through a film curve with a
  log-log slope of 1.4–2, is the 2.6 display stops in the screenshots.
- Nothing else could fix it. The match was only measured by the capture-time bake, so
  re-picking a look in the editor, or giving any RAW photo a film look there (Phromagraph
  included, whose stock exposure is 0 because it relies on the match), developed ~1.9 EV
  dark.

**Fixes:**
- **#41** (superseded the same day) matched photos without a match in the editor, against
  the photo's own original. It also raised the cap from +2.5 to +4 EV, because engine 2
  reads a viewfinder frame's key 0.2–1.5 stops higher than engine 1 did (22 Apple JPEGs:
  +0.16 for a bright day to +1.48 for a dim street).
- **#42, the owner's call:** "the inputs for the photo should just be the raw photo".
  - **It's the RAW converters' practice.** Lightroom, Capture One and Chromagraph render
    a RAW at a fixed default brightness, or one derived from the RAW itself.
  - **Matching hid the real problem.** Borrowing each shot's brightness from Apple's
    video made the photo follow Apple's rendering choices.
  - **What #42 does:**
    - Film looks develop at `EditRecipe.filmRAWExposure` = +1.86 EV.
    - Picking a look pins it in `rawFilmExposure` (`Look.film`, Print), next to the
      tuning: older photos keep theirs, and re-picking the look brings the current one.
    - The viewfinder key (`FilmLUT.sceneKey`, `PreviewRenderer`, `PhotoPlan.viewfinderKey`),
      the baker's match and #41's editor match are all removed.
  - **The constant, checked on the owner's scene:** both screenshots inverted through
    their own neutral curves (ours through Print, Chromagraph's through Phromagraph) are
    1.92 EV apart at the median and 2.14 at the geometric mean, against Phromagraph's
    fitted +1.86.

**The viewfinder against the photo:**
- iOS gives third-party apps only Apple's processed video live, never RAW. So the
  viewfinder can only approximate the photo.
- At mid-grey, engine 2's un-render agrees with engine 1, and engine 1 measured within
  +0.09 EV (median) of the fixed develop (§5½).
- Per scene, Apple's video brightness drifts with its own rendering:
  - bright day ≈ +0.3 EV;
  - overcast ≈ −0.6;
  - night ≈ −1.4 at mid-tones.
- Engine 2 reads shadows brighter than engine 1, so dim scenes should look closer than
  those engine-1 numbers.
- Not measured on the device. Levers if it matters:
  - **#43's Plain live view** (Settings, off by default). In Print and Zero it turns
    video HDR off and `AVCaptureDevice.isGlobalToneMappingEnabled` on (iOS 13+, where
    the format supports it).
    - Apple documents that global tone map as still adapting to each scene, so it should
      narrow the per-region drift more than the per-scene one.
    - If the owner likes it, re-measure the un-render for it: the engine-2 table was
      built with Apple's local tone mapping on.
  - Viewfinder frames saved next to DNGs, to measure the drift per scene.

**The viewfinder correction (2026-11-18, stacked on #42).** The owner's rule: the photo
comes only from the RAW and its saved camera settings; the viewfinder may predict the
photo, never feed it.
- With engine 2's un-render and the fixed develop, the viewfinder's gap against the photo
  (Apple's still render standing in for the video; + = viewfinder brighter) against the
  scene's EV100 from each DNG's EXIF:

  | Shot | EV100 | Gap | After correction |
  |---|---|---|---|
  | night alley (cgc_00143) | 4.7 | −0.96 | −0.28 |
  | overcast parliament (00105) | 5.3 | −0.50 | +0.11 |
  | overcast parliament (00098) | 5.6 | −0.58 | −0.01 |
  | tram, dusk (00089) | 7.6 | −0.11 | +0.21 |
  | playground (00120) | 10.6 | −0.60 | −0.65 |
  | arches, dark frame (00132) | 10.6 | +0.61 | +0.56 |
  | train window (1303DFCB) | 11.0 | +0.12 | +0.03 |
  | street (00021) | 12.1 | +0.61 | +0.38 |
  | trees (00011) | 13.3 | +0.30 | −0.07 |
  | tram, crop (00009) | 13.7 | +0.05 | −0.38 |
  | street (00016) | 14.0 | +0.64 | +0.18 |
  | old town gate (00023) | 15.2 | +0.53 | −0.08 |

- Gap = −0.03 + 0.122·(EV100 − 10), correlation 0.81; sd ±0.53 → ±0.32 EV after
  correcting. The two shots at EV 10.6 going opposite ways are Apple's local tone mapping
  (a dark frame around a bright view gets lifted), which no single number predicts.
- `ViewfinderMatch` reads the scene's light from the meter, not the settings alone:
  EV100 = log2(N²/t) − log2(ISO/100) + `exposureTargetOffset` + `exposureTargetBias`.
  So a manual exposure a stop under (offset −1), or EV −1 in auto (bias −1, offset ≈ 0),
  reads the same scene, and the correction stays put while the preview gets a stop darker,
  exactly like the RAW. If iOS measures the offset in custom mode against the unbiased
  target, a leftover bias shifts the reading by that bias: 0.12 EV per EV of bias.
- Unknowns: the live video may render differently from CIRAWFilter's still render, and
  the fit is 12 shots on one phone. Check on the device: viewfinder vs saved photo at
  night, indoors, overcast and in sun, also with manual ISO/shutter and EV compensation.
  Viewfinder frames saved next to DNGs would let us refit it exactly.

**Bayer vs ProRAW (2026-11-18, the owner's "chromagraph def isn't this bright").** The
owner imported this app's Bayer DNGs into Chromagraph, and a Chromagraph ProRAW into
this app (`Chromagraph RAW 2026-11-18/`, git-ignored; `phromagraph.py develop-ev`):

| RAW | Chromagraph's develop | Ours (fixed +1.86) |
|---|---|---|
| sunset, Chromagraph's ProRAW (baseline +1.01) | +1.85 (two exports) | +1.84 (ΔE 0.006) |
| street, our Bayer | +0.64 | +1.86 |
| tree, our Bayer | +0.50 (two exports) | +1.78 |
| TV room, our Bayer | +0.47 | +1.96 |

- **On ProRAW we match Chromagraph** (a third baseline-exposure value, so that tag isn't
  the cause). **On Bayer files Chromagraph develops 1.3 EV darker** (+0.54 ± 0.09) and
  flatter: its deep shadows sit as if at +1.8 while mids are at +0.45, so the Phromagraph
  fit is looser there (ΔE 0.024–0.033).
- #52 then developed per RAW type: ProRAW +1.86, Bayer +0.54; Print always shoots ProRAW;
  ProRAW is the default ("Cleaner"). Superseded by natural brightness (below).
- Against Apple's rendering (CIRAWFilter defaults, scene keys through engine 2) a Bayer
  RAW sits at a constant +1.2 in all three scenes (+1.20, +1.21, +1.18), while ProRAW
  follows the scene (+0.5…+2.5): relative to Apple, a Bayer RAW is ~0.65 EV brighter
  than a ProRAW in these scenes (0.63 at EV 10): that's `EditRecipe.bayerScale`, so a
  Bayer and a ProRAW shot of one scene develop equally bright.

**Natural brightness (2026-11-18, after "chromagraph sucks for RAW").** Chromagraph's
fixed +1.86 lifts dim scenes far past what the eye saw (the owner's ISO 640 bunk-bed room,
EV ≈ 3.4: "an overexposed monstrosity"). The develop now follows the scene's light from
the photo's saved settings, the way Apple's rendering does, a touch under, capped at
Chromagraph's +1.86: min(1.83 + 0.122·(EV100 − 10) − 0.2, 1.86), minus 0.63 for Bayer
(EV100 clamped to 3…15). On the reference shoots: TV room (Bayer, EV 6.4) +0.56, street
(Bayer, EV 11.1) +1.13, tree (Bayer, EV 13) +1.23, sunset (ProRAW, EV 15.2) +1.86. The
viewfinder correction follows from the same function: −0.2 up to ~EV 11.9, darker above.
The Bayer scale (0.63) is an estimate from Apple's renderings; a ProRAW and a Bayer shot of
one scene should look equally bright, and the owner's side-by-side will check it.

## 6. Grain and noise: what's known and what isn't

**Chromagraph's grain, measured (film engine 7, 2026-11-20).** The owner exported one of
our ProRAW DNGs from Chromagraph at five grain settings (folder "Chromagraph RAW grain
2026-11-20", git-ignored; `scripts/phromagraph.py grain DIR` reruns everything below and
renders ours through the app's own FilmPipeline.swift via `scripts/film-render`).
- **Identifying the files.** No settings in EXIF/XMP (only `Software: Chromagraph 1.6.1`).
  Grain off is the file the others differ from least; Amplitude 5 is 4.0× the others' std
  (two exports, each with its own random pattern: the pattern isn't seeded per photo); of
  the 1.25s, the most correlated is Size max and the weakest Size min.
- **Method.** Subtract the grain-off export (same render otherwise), remove slow drift
  (σ 40 px blur), measure on the flat wall: std, autocorrelation at 1–4 px, radial power
  spectrum, inter-channel correlation, and std per channel binned by that channel's value.
  HEIC encoding was checked by encoding synthetic grain at quality 0.9–1.0: transparent.
- **Amplitude:** linear (13.50 / 3.37 = 4.0).
- **Size:** Size 1 and Size min share one spectrum (flat to ~¼ cycle/px, ⅓ power at
  Nyquist, negative lobe at 2 px: noise resampled with a sharp cubic); Size min is ×0.52
  as strong. Size max is broader (lag-1 0.61) and ×1.42 as strong. A Catmull-Rom kernel of
  1.20 px (Size 1) and 1.735 px (Size 3) reproduces both spectra; Gaussians don't (no
  negative lobe, and a Gaussian with the same lag-1 rolls off too early).
- **Colour:** neutral; channel correlation ~0.98 once the encoder's noise is removed
  (our `grainChroma` 0.15 gives 0.97).
- **Brightness:** the std is one function of each channel's own value, the same for R, G
  and B: flat from ~100 to 145/255, then 18.0 at 166, 14.9 at 190, 10.9 at 214 (at
  Amplitude 5; 19.4 flat). That's a print curve's shoulder acting per channel after the
  grain, so grain in negative density is right, but our monochrome density grain had
  per-channel output slopes R 20 / G 18 / B 14 on grey. Engine 7 weights layers by the
  print's inverse Jacobian at grey.
- **Resolution:** unmeasured (Chromagraph only exports 2880 px).
- **What's left:** our red fades less toward white (warm highlights ~20% more red grain);
  lag-2 −0.05 vs −0.09 (slightly less crisp); one scene, mostly mid-to-light tones (no data
  under ~94/255).

**Known:**
- **Synthetic grain** is added in negative density, mostly monochrome (`grainChroma`
  0.15). Engine 7: Catmull-Rom cell 0.417‰ × Size^0.336 (floor 1.2 px), strength the
  same per pixel at every render size, neutral on grey. Engines ≤ 5: σ ≈ 0.5 px at
  4032 px, scaled down for smaller renders (the viewfinder showed about half); engine 6:
  Gaussian 0.51‰ of the frame.
- **In the Python model** on an iPhone 12 Pro DNG in daylight, the grain is 2.8/255 per
  pixel against 0.9/255 sensor noise. That's subtle.
- **"Super grainy" on device was almost certainly sensor noise.** Print shoots a
  single-frame Bayer RAW (`.speed`, 12 MP, no multi-frame NR), and the baker forced 15%
  luminance NR. Now it uses the camera's own default for the shot, floored at 50, and
  film looks get at least 0.5 chroma NR.

**Viewfinder brightness match: assumptions to check on device:**
- The video frames and the Bayer RAW share the same exposure (one device, continuous
  AE). If the photo output exposes differently, the match is off by that difference.
- Video frames are a slightly different crop than the 4:3 photo. That's harmless for a
  geometric mean unless the edges are very different from the centre.
- How it was checked: simulated on the iPhone 12 Pro DNG with viewfinder curves brighter
  than assumed. The saved brightness came out within ±0.01 of the viewfinder, against
  0.08–0.2 too dark before.

**Unverified Core Image assumptions** (only the device can tell):
- The grain path makes noise opaque with `settingAlphaOne` and adds it with
  `CIAdditionCompositing`, then `settingAlphaOne` again. That's correct if `settingAlphaOne`
  just overwrites alpha.
  - Before #20 the grain mixed in `CIRandomGenerator`'s random alpha through
    `CIColorMatrix`. Whether `CIColorMatrix` un-premultiplies is undocumented.
  - If it does, the old grain was either zero or heavy-tailed speckle. The new path
    doesn't care.
  - **If Print shows no grain at all at 100%, or the image comes out half as bright,**
    an alpha assumption is wrong. Look at `FilmPipeline.addGrain` first.
- **Sub-pixel blur** now uses an explicit `CIConvolution3X3`, so its amplitude is exact.
  `CIGaussianBlur` is used only for σ ≥ 1 px (48 MP sensors).
- **The default `luminanceNoiseReductionAmount`** for iPhone DNGs (by ISO) isn't
  documented. Read it on device if NR needs tuning (`EditPipeline.readDefaults`).

**Ideas if noise is still a problem:**
- Shoot **ProRAW** for Print on Pro phones. It's multi-frame merged and much cleaner, but
  slower and about 25 MB per shot, and `CIRAWFilter` treats it differently.
- Reduce synthetic grain at high ISO, since the sensor already supplies texture.

## 7. Performance budgets (measured)

**Print-cube rebuild**, best of 15, on one Linux x86 core:

| Stock | ms |
|---|---|
| Print | 2 |
| Natural | 5 |
| Hue-protected and split-toned stocks | 6–7.5 |

- Split toning costs about 1.5 ms of that. Hoisting the tints into scalars (no array
  subscripts in the inner loop) mattered.
- The negative cube takes about 20 ms per stock and source, prewarmed at launch.
- The caches are LRUs: 16 negative and 18 print cubes, 1.8 MB each.
- The most expensive spatial effect is Skin's bloom (σ 8 and 24 ‰ of the long side). On
  device, watch viewfinder smoothness with Skin selected.

**Benchmark pattern:** compile `FilmModel.swift` and `FilmStock+Stocks.swift` with a
`main.swift` that times `FilmLUT.printCube(stock:controls:)`. The parity harness in
`scripts/film-parity/main.swift` already prints build times.

## 7½. Older photos keep their tuning

Each photo's recipe pins the full stock it was rendered with (`FilmRecipe.tuning`, ~4.2 KB,
pinned when the look is picked), so retuning a look and regenerating
`FilmStock+Stocks.swift` changes new shots and the viewfinder, never existing photos (see
CLAUDE.md §4 "Film looks"). Photos from before pinning resolve to the frozen history in
`FilmStock+Legacy.swift` (never edit it). To push a retune onto an old photo, pick the look
again in the editor. When adding a `FilmStock` field, older pinned tunings get the current
stock's value for it on decode, so prefer fields whose current values don't change how
older photos look. Changing the film *math* is different: gate it on `FilmRecipe.engine`.

## 8. Environment tricks (cloud container)

- **Python deps:** `numpy scipy pillow rawpy opencv-python-headless` (plus `pillow-heif`
  for HEIC). Run Python that reads downloaded files with `-I`.
- **Swift on Linux for parity.** Only `FilmModel.swift` and `FilmStock+Stocks.swift` are
  Foundation-only. Core Image files can only be parse-checked:
  `swiftc -parse PointAndShoot/Editor/FilmPipeline.swift`. Install the toolchain into the
  scratchpad:
  ```sh
  curl -sSfL -o swift.tar.gz https://download.swift.org/swift-6.1.2-release/ubuntu2404/swift-6.1.2-RELEASE/swift-6.1.2-RELEASE-ubuntu24.04.tar.gz
  tar xzf swift.tar.gz && export PATH=$PWD/swift-6.1.2-RELEASE-ubuntu24.04/usr/bin:$PATH
  ```
  The scratchpad can be wiped mid-session, so reinstall when `swiftc` disappears.
- **Test DNGs (CC0)** from raw.pixls.us:
  - https://raw.pixls.us/data/Apple/iPhone%2012%20Pro/IMG_1361.DNG (the owner's phone model)
  - https://raw.pixls.us/data/Apple/iPhone%20XS/IMG_1105.dng
  - Pair them with the two `*_apple` JPEGs above for the display-referred path.
- **No iOS toolchain here.** CI compiles and runs the UI tests; device behaviour needs the
  owner.
- **GitHub via `gh api` (REST only; GraphQL is blocked in this proxy):**
  - Open a PR: `gh api repos/OWNER/REPO/pulls -f title=… -f head=… -f base=main -F body=@file`
  - Merge: `gh api -X PUT repos/OWNER/REPO/pulls/N/merge -f merge_method=merge -f sha=<head>`
  - Mark ready for review: `POST repos/OWNER/REPO/pulls/N/ccr/ready_for_review`
- **Clones are shallow and single-branch.** `origin/<other-branch>` doesn't exist until
  you fetch it by name. For a branch you create and push, `git push -u` sets tracking;
  otherwise the stop hook complains about "no remote branch".
- **A PR with merge conflicts gets no `pull_request` CI.** If Build never starts, check
  `gh api repos/OWNER/REPO/pulls/N --jq .mergeable_state`. "dirty" means merge main in.
- **Other sessions merge to main all the time** (#16 silent shutter, #17 Print save fix,
  delete-state fixes…). Branch from a fresh `origin/main`. Before relying on CI for a
  long-lived PR, merge main into it, and resolve `FilmStock+Stocks.swift` by regenerating
  it rather than hand-merging.
- **Watch CI by head SHA**, in the background:
  `gh api "repos/OWNER/REPO/actions/runs?head_sha=$SHA"`; the workflow is named "Build".
  Mac runners queue, and a run takes about 20–30 min. Don't stack throwaway pushes.
- **Send pictures.** `SendUserFile` with before/after sheets is how the owner reviews
  looks.

## 9. Ideas not started

- **Snapseed-style mechanisms** for families that differ by more than colour:
  - band-limited local contrast ("Tonal Contrast" or "Drama")
  - glow styles with coloured glow
  - light leaks
  - coloured vignettes
  - paper textures
- **Snapseed 3.0's Film presets** are modelled on real stocks: Portra 400 and 160, Gold
  200, E200, Superia 200 and 800, Pro 400H, Optima 200, Scala 200, Polaroid 600 and
  Technicolor. They'd make good next stocks; the model can express all but Polaroid's
  chemistry.
- **From CLAUDE.md §9:**
  - a contrast pivot
  - multi-frame highlight retention for Print
  - an "optical" white halation mode
  - density-dependent grain
  - fitting to real reference pairs
