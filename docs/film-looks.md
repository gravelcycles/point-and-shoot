# Film looks: handoff notes

Working notes for whoever picks up the Print look and the photo filters next. CLAUDE.md
§4 ("Film looks") is the reference for *what* the code does. This file covers *how we got
here*, how to tune, what's still unknown, and the tricks that save hours. Written
2026-11-14.

---

## 1. Where things stand

| PR | What | State |
|---|---|---|
| #9 | Print look (Chromagraph-style film emulation) and Print mode (PHOTO · PRINT · VIDEO) | merged |
| #15 | Every photo filter is a film stock, plus split toning, spaced apart with a metric | merged |
| #20 | Grainy Print photos: real RAW noise reduction, exact grain, finer grain | merged |

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

**What to ask the owner next:**
- Do indoor Print shots look clean now?
- Is there still visible grain at 100%? If there's none at all, see §6.
- Do the filters now read as different at thumbnail size?
- Does the saved Print photo now match the viewfinder's brightness, including at night?

## 2. The owner's taste (from their own words)

- **"Smooth as butter" / "silky smooth everything".**
  - The viewfinder must never stall.
  - Tables are prewarmed in the background.
  - Frames are dropped, never queued.
  - Cube rebuilds stay in single-digit ms.
- **Modes should be easy to pick, with no superfluous controls.** Print mode hides the
  format pill, the FILTER cell and burst, and always shoots RAW.
- **Filters must be obviously different at a glance.** They compare against Snapseed and
  Instagram.
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
  - `displayReferred` is the viewfinder or a processed HEIF. It is un-rendered first,
    *on luminance with channel ratios kept*, by a gentle inverse phone curve.
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

## 4. Tuning a filter: the loop

```sh
# 1. Edit scripts/film-looks.json (anything left out inherits from Print)
# 2. Measure and look
python3 scripts/print-look.py spread A.dng B.dng C.jpg D.jpg --cssgram --sheet /tmp/sheet.jpg
# 3. Regenerate Swift and prove it matches the Python model
python3 scripts/print-look.py export-swift
python3 scripts/print-look.py parity            # needs swiftc; see §8
# 4. If the character changed: Look.all detail strings and extras (EditRecipe.swift),
#    README filter list, CLAUDE.md §4
```

**The rule: every filter's nearest neighbour is at least 0.06 mean ΔE (Oklab) in `spread`.**

Today:

| Set | Nearest pair | Median nearest |
|---|---|---|
| Colour filters | 0.067 | 0.070 |
| B&W filters | 0.063 | – |
| CSSgram (26 Instagram-style) | 0.021 | 0.050 |

The research agent's ColorChecker test (CIE76) agrees: ours are at least 14.9 apart,
against about 11 typical for CSSgram.

**What makes filters read as different** (from the CSSgram and Snapseed research, and
confirmed by measurement):
- **Signature axes.** Each filter should own 2–3 that survive a thumbnail:
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
| `grey` | Display luminance of 18% grey: the key | 0.10 (Cine) – 0.28 (Skin) |
| `slope` | Log-log contrast below the shoulder | 0.85 (Skin) – 2.25 (Noir) |
| `shoulder` | How hard the highlights roll off | 1.6 – 3.0 |
| `white` / `floor` | Display white / lifted black (matte) | 0.82–1.0 / 0–0.06 |
| `printer` | `[r, b]` or `[r, g, b]` log-exposure offsets. **+ means *less* of that colour.** A green + reads magenta (that gave Skin lavender skies). | ±0.17 |
| `crossover` | `[r, b]` gamma split: warm highlights over cool shadows, or the reverse | ±0.26 |
| `interlayer` | Saturation in the negative | −0.45 (Faded) – 1.7 (Punch) |
| `crosstalk` | 0–1 print-dye coupling: dense colours get darker | 0.1 – 1.0 |
| `halation`, `halation_spread` | Red glow by default. Equal R/G/B with wide sigmas and a low threshold gives a neutral bloom (Skin). | – |
| `shadow_tint` / `highlight_tint` | Split toning: encoded RGB offsets weighted (1−Y)² / Y², made luminance-neutral by `filmlooks.py` | ±0.08 |
| `grain` | Density std at 4032 px (Print uses 0.008) | 0.0027 – 0.0133 |
| `huePreserve` | Keeps bright warm colours from turning yellow (0 = pure film) | 0.35 – 0.9 (Print 0) |
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

## 6. Grain and noise: what's known and what isn't

**Known:**
- **Synthetic grain** is added in negative density. It's mostly monochrome
  (`grainChroma` 0.15), σ ≈ 0.5 px at 4032 px, and 0.008 D for Print. Its amplitude
  scales down for smaller renders, so the viewfinder shows about half.
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
