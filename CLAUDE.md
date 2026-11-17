# CLAUDE.md: Point & Shoot

Handoff and working notes for any Claude session on this repo. Claude Code loads this file
automatically. **Read it fully before changing anything.**

---

## 1. What this is

**Point & Shoot** is a native iPhone camera app (SwiftUI + AVFoundation + Core Image on
Metal, iOS 17+). It's built for someone who thinks like a photographer and
cinematographer.

**The owner's brief:**
- "Smooth as butter."
- RAW on/off, and Apple's computational processing on/off.
- All the normal camera features.
- A Snapseed-style editor that saves back to the camera roll.
- Video for cinematographers.
- GPS that works in airplane mode.
- Updates that land on the phone with no effort (TestFlight).

**Status:** feature-complete first version. It compiles in CI (Xcode 26.3, unsigned). On
2026-11-13 `scripts/deploy-iphone.sh` built, signed (Xcode 26.6, the owner's free Personal
Team `D5STMWZ849`) and installed all three targets on the owner's iPhone 12 Pro (iOS 18.7.3).
**Nothing has been exercised on the device yet.** The next phase is device testing, with one
fix PR per problem. Expect runtime issues even though it builds cleanly; see §8.

Git history: merged into `main` so far:

| PRs | What |
|---|---|
| #1 | the whole app |
| #2 | colour mixer |
| #3 | Lock Screen camera and Control Center |
| #4–#7, #13 | docs, deploy script, icons |
| #8 | tap targets and simulator UI tests |
| #9 | the Print look and Print mode |
| #10 | CI runner usage |
| #11 | top-bar redesign, filters, multi-select |
| #12, #14 | one-row controls, PRO toggle dropped |
| #15 | every filter a film stock, with split toning |
| #16 | silent shutter |
| #17 | the Print/Zero "Couldn't save" fix |
| #18 | crash shooting zoomed in with Bayer RAW (zoom locks at 1×) |
| #20 | grainy Print photos: noise reduction and grain |
| #34 | Phromagraph: a filter fitted to Chromagraph's own renders |

The film-look work has its own handoff notes: `docs/film-looks.md`.

**Redesign branch (`claude/raw-studio`).** A Chromagraph-style rework lives on this
integration branch until the owner has compared it with `main` on device. Reference for
what was copied: `docs/chromagraph-reference.md`.
- **What it is:** RAW-only capture, an in-app library with Keep/Trash/30-day retention,
  export to Photos, a Tone/Color/Texture editor, three-tab Preferences, RAW import and zip
  archives, and the cinematic looks.
- **Merged into it so far:** #32 library, #33 editor, #39 Preferences, #40 import/archive,
  #35 + #37 looks, plus everything on `main`.
- **CI state:** green. The full stack passed build + 119 tests (run 44161283672), and #37 on
  top passed 137 (run 44164624577). Three independent review passes found ~45 issues, all
  fixed.
- **Not tested on the phone yet.**
- **Sub-PRs merge into it, not into `main`.**
- **Side-by-side install:** it builds as **"P&S Studio"**,
  `APP_BUNDLE_ID = io.github.gravelcycles.pointandshoot.studio`, with a tan icon, so both
  apps can be on the phone. `scripts/deploy-iphone.sh` reads the bundle ID from the project.
  **Revert those three (bundle ID, display name, icon) when the branch merges to `main`.**
- **On this branch, §3–§5 and §8 describe the redesign.** `main` still has the Photos-based
  roll.

---

## 2. First session on the Mac: start here

### Prerequisites
- **Xcode 16 or newer.** The project uses `objectVersion 77` with synchronized folders;
  CI uses Xcode 26.3.
- **An iPhone on iOS 17+.** The Lock Screen / Control Center features need iOS 18. The
  simulator has no camera, so it's only useful for UI layout.
- **Developer Mode** on the iPhone: Settings → Privacy & Security → Developer Mode. Trust
  the Mac when you first plug in.
- **An Apple ID signed in to Xcode:** Settings → Accounts. A free Personal Team works, but
  installs expire after 7 days. The paid Apple Developer Program enables TestFlight.

### One-time project setup
1. **Bundle ID.** The default is `io.github.gravelcycles.pointandshoot` (was the likely-taken
   `com.pointandshoot.camera`). All three targets derive from one setting:
   - Project → Build Settings → *User-Defined* → `APP_BUNDLE_ID`. Change it only if Xcode says
     the ID is unavailable, e.g. to `com.<you>.pointandshoot`.
   - The extensions automatically become `$(APP_BUNDLE_ID).widgets` and
     `$(APP_BUNDLE_ID).lockedcapture`.
2. **Signing & Capabilities:** pick the team for **all three targets**: `PointAndShoot`,
   `PointAndShootWidgets` and `PointAndShootLockedCapture`. Leave "Automatically manage
   signing" on.
3. Select your iPhone as the destination → **Run**.

### Command-line equivalents (Claude can run these)
```sh
scripts/ui-tests.sh             # simulator UI tests, same as CI, no queue
scripts/deploy-iphone.sh        # finds team + phone, builds Release, signs, installs, launches
                                # overrides: TEAM=… DEVICE=<udid> BUNDLE_ID=… CONFIG=Debug
```
```sh
# Exactly what CI runs: compile everything, no signing
xcodebuild build -project PointAndShoot.xcodeproj -target PointAndShoot -sdk iphoneos \
  -configuration Debug CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""

# Signed build for a connected phone
xcrun devicectl list devices                     # find the device identifier
xcodebuild build -project PointAndShoot.xcodeproj -scheme PointAndShoot \
  -destination 'platform=iOS,id=<DEVICE_UDID>' -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=<TEAM_ID> APP_BUNDLE_ID=com.<you>.pointandshoot \
  -derivedDataPath build/dd

# Install + launch (Xcode 15+ devicectl)
xcrun devicectl device install app --device <DEVICE_UDID> build/dd/Build/Products/Debug-iphoneos/PointAndShoot.app
xcrun devicectl device process launch --device <DEVICE_UDID> com.<you>.pointandshoot
```
For crash logs and console output, use Xcode's debugger (Run from Xcode) or
Console.app with the phone selected. Claude can't tap the phone. **The owner tests and
reports; Claude reads logs, fixes, and opens PRs.**

### Suggested kickoff prompt for the first local session
> Read CLAUDE.md. Build Point & Shoot for my connected iPhone and fix any signing/build
> issues. Then walk me through the device test plan in §8 one section at a time. For each
> problem I report, make a focused fix on a new `claude/fix-…` branch, verify it builds,
> open a PR, and merge it once CI is green.

---

## 3. Repository map

```
PointAndShoot/                    app target (synchronized folder: new files auto-included)
  App/PointAndShootApp.swift      @main; owns CameraController + ShotStore (loads it, runs retention)
  App/Shortcuts.swift             App Intents: "Take a Photo"/"Record a Video" (Action button, Siri)
  Camera/CameraController.swift   ★ the engine: session, lenses, exposure/focus/WB, capture, burst,
                                  recording, metering timer, storage/thermal, Camera Control
  Camera/CaptureSettings.swift    all persisted settings + enums + photographic stop tables
  Camera/PreviewRenderer.swift    Metal viewfinder: CI pipeline, peaking, zebras, histogram, Log LUT,
                                  live capture Look, lens-switch blur
  Camera/PhotoCaptureProcessor.swift  AVCapturePhotoCaptureDelegate; GPS EXIF; save; bake Look (BakeQueue)
  Camera/PhotoPlanner.swift       pure capture decisions (RAW kind, prioritization, flash, 12 MP) — unit-tested
  Camera/ZeroDeveloper.swift      "Zero" processing: neutral CIRAWFilter develop of Bayer DNG
  Camera/VideoRecorder.swift      AVAssetWriter recorder (video+audio, location metadata)
  Camera/LocationTagger.swift     CoreLocation GPS + compass; EXIF/ISO6709 builders
  UI/CameraView.swift             main screen, top bar, lens picker, shutter (tap/hold-burst),
                                  thumbnail, gestures, hints, launch-request handling
  UI/TopBar.swift                 top bar: flash/timer/settings buttons, format pill, format panels
  UI/ControlStrip.swift           FOCUS/WB/ISO/SHUTTER/EV/LOOK readouts + DialPanel
  UI/ScrubDial.swift              haptic tick-mark jog dial (reused in the editor's straighten)
  UI/PreviewView.swift            CAMetalLayer host + UIKit gestures; volume-button interaction
  UI/Overlays.swift               grid, frame lines, level, histogram, meter, reticle, EV slider, toast
  UI/SettingsView.swift           Preferences: General · Camera · Processing (default grade, export,
                                  import, resets); double-tap the viewfinder opens it
  UI/MotionManager.swift          gravity → level + icon rotation (UI is portrait-locked)
  Library/Shot.swift              one photo's record (shot.json) + ShotRetention (the 30-day rules, pure)
  Library/ShotStore.swift         ★ the in-app library: shots, trash, develop queue, grades, retention
  Library/ShotRenderer.swift      develops a shot's DNG with its grade (previews, export, zoom detail);
                                  settles a fresh grade (RAW NR, film exposure matched to the viewfinder)
  Library/ShotExporter.swift      export to Photos (add-only access) / share files; Auto Export
  Library/ShotArchive.swift       Import RAW (system picker), Archive RAW (Photos or zip), Import Archive
  Library/ZipArchive.swift        minimal zip writer (stored) / reader (stored + deflate), CRC-checked
  Library/PhotoViewer.swift       viewer: filmstrip, Keep, trash + Undo, export, zoom (RAW detail render)
  Library/LibraryView.swift       grid by day, Select (export/share/keep/grade/archive/trash), Trash view
  Library/ZoomableImageView.swift Photos-style zoom for viewer pages (UIScrollView: pinch+pan, double-tap)
  Library/PhotoLibrary.swift      Photos helpers (save for export/archive, video save)
  Library/LockedCaptureImporter.swift  moves Lock Screen shots (parked DNGs) into the library
  Library/RollLogic.swift         pure viewer selection + thumbnail handoff rules — unit-tested
  App/TolerantJSON.swift          decodes saved settings/recipes from any app version (missing keys → defaults)
  App/TestHooks.swift             -uitest, unit-test host, -uitest-seed N (library) / -uitest-photos N
                                  (Photos) seeding, roll.count probe, viewer gesture probes
  Editor/EditorView.swift         editor: Looks · Tone · Color · Texture · Crop, sub-tabs, GradeSlider
  Editor/EditSession.swift        loads a shot (RAW off main), preview graph, saves the grade to the store
  Editor/EditPipeline.swift       the edit as a Core Image graph (geometry → tone → color → detail → fx)
  Editor/EditRecipe.swift         Codable recipe, Adjustment lists, Looks, ColorBand, CropAspect
  Editor/ColorMixer.swift         8-band HSL → cached 32³ color cube
  Editor/RecipeBaker.swift        applies a recipe to a library asset (capture Looks; film looks from the DNG)
  Editor/FilmModel.swift          Print look math: film curves, LUT builders (Foundation only, testable anywhere)
  Editor/FilmStock+Stocks.swift   GENERATED film stocks: Print + every look (from scripts/*.json)
  Editor/FilmPipeline.swift       Print look in Core Image: halation, neg cube, grain, print cube
  Editor/CropOverlay.swift, MetalImageView.swift  (MetalImageView: Metal canvas + pinch/pan zoom)
  UI/ZoomMath.swift               pure zoom math (anchor, settle, rubber band, double-tap) — unit-tested
PointAndShootTests/               unit + integration tests, hosted in the app (@testable import): settings,
                                  recipe back-compat, capture planner, roll logic, film pipeline, Photos library
PointAndShootUITests/             simulator UI tests (tap targets, tap-through, roll/viewer/delete flows); -uitest
Shared/CameraCaptureIntent.swift  CameraCaptureIntent (compiled into app + both extensions)
Shared/OpenVideoControlIntent.swift  "Record Video" control's intent (opens the app in Video mode)
PointAndShootWidgets/             ControlWidget extension: Camera + Record Video controls (Control Center /
                                  Lock Screen / Action button)
PointAndShootLockedCapture/       LockedCameraCapture extension: lean Lock Screen camera
Config/*-Info.plist               NSExtension dicts for the two extensions (merged with generated plist)
.github/workflows/build.yml       unsigned compile on every push + PRs (free: repo is public)
.github/workflows/testflight.yml  sign + upload to TestFlight on push (skips until secrets exist)
codemagic.yaml                    optional alternative CI
scripts/print-look.py             film-look tools: preview on DNGs, fit to reference pairs, export-swift, parity
scripts/filmmodel.py              reference (numpy) implementation of FilmModel/FilmPipeline
scripts/print-stock.json          the Print look's parameters (source of truth)
scripts/film-looks.json           the looks as compact film-stock specs (source of truth)
scripts/phromagraph-stock.json    Phromagraph (fitted to Chromagraph's own renders; source of truth)
scripts/phromagraph.py            fits Phromagraph to Chromagraph DNG+HEIC pairs; measures exposure/grain
scripts/raw-develop.swift         macOS CIRAWFilter develop exactly as the app does (for the Python tools)
scripts/filmlooks.py              builds full stocks from film-looks.json (tone curve derivation)
scripts/cssgram.py                the 26 Instagram-style CSSgram filters, browser-exact: the yardstick
                                  for how far apart our looks are (`print-look.py spread --cssgram`)
docs/looks-contact-sheet.jpg      the looks on 8 test images (Original, Print, Punch, then the 2026-11-17 set)
docs/film-looks-research.md       ★ why film looks read as film (Yedlin, subtractive colour, stocks, labs), with sources
docs/film-looks.md                ★ handoff notes for the film looks: history, tuning loop, pitfalls,
                                  unknowns, test images, environment tricks
CLOUD_BUILD.md                    browser-only TestFlight setup for the owner
```

---

## 4. Architecture & invariants

### Threading (important)
- **`sessionQueue`** (serial): all `AVCaptureSession` / `AVCaptureDevice` configuration,
  plus `lockForConfiguration` via `withLockedDevice`.
- **`dataQueue`** (serial): video and audio sample buffers, plus every `VideoRecorder`
  call.
- **`PreviewRenderer.renderQueue`**: GPU rendering. Frames are **dropped, never queued**,
  while the renderer is busy. Histograms run on a utility queue every 5th frame.
- **Main thread:** every `@Observable` UI property. The controller hops back with
  `DispatchQueue.main.async`.
- **Language mode:** `SWIFT_VERSION = 5.0` on purpose. Strict Swift 6 concurrency would
  flag this design everywhere. Don't flip it casually.

### Key design decisions (and why)
- **Physical lenses, not the virtual multi-cam device.** Manual controls and Bayer RAW are
  reliable per physical lens. Lenses are labelled by 35 mm-equivalent focal length, computed
  from the FOV and snapped to marketing values (13/24/48/77/120). The "48 mm" option is the
  main lens at 2× zoom on 48 MP sensors.
- **Custom Metal preview** (video data output → Core Image → `CAMetalLayer`) instead of
  `AVCaptureVideoPreviewLayer`. This is what makes peaking, zebras, histogram, Log assist
  and live Looks possible. Orientation is fixed portrait: back camera `.right`, front
  `.leftMirrored`. `devicePoint(fromViewPoint:)` maps taps to sensor coordinates and must
  stay consistent with that orientation.
- **AVAssetWriter** for video (not `AVCaptureMovieFileOutput`), so the same buffers feed
  the preview and the file. Writer settings start from
  `recommendedVideoSettings(forVideoCodecType:…)`. HEVC/H.264 bitrate is pixels × fps ×
  0.16 bits per pixel (0.22 for 10-bit).
- **RAW only.** Every photo is a RAW the app develops itself (`PhotoPlanner.decide`):
  - **ProRAW is the default.** `CameraSettings.shootsProRAW` = `rawMode != .bayer`, so
    `.off` from older settings counts as ProRAW. `CameraController.proRAWActive` must equal
    it: when it didn't, every "ProRAW" shot silently came out Bayer.
  - **Bayer RAW** (the sensor's single frame) is the opt-in.
  - **Fallbacks, each with a toast:**
    - zoomed Bayer → ProRAW;
    - no ProRAW on the lens → Bayer;
    - no RAW at all (some front cameras, or zoomed with only Bayer) → a processed HEIF
      stored as the original.
  - The old processing levels (Apple/Balanced/Natural/Zero) are gone from the UI.
- **Bayer RAW forces `.speed` prioritization and 12 MP dimensions** (avoids
  `NSInvalidArgumentException`). ProRAW uses `.quality`, at 12 MP or max.
- **Zoom is locked at 1× only with Bayer RAW** (`zoomLocked` = still mode && Bayer).
  AVFoundation throws on Bayer RAW when `videoZoomFactor > 1` (crashed on device). ProRAW
  and video zoom normally; the planner never requests Bayer while zoomed.
- **No burst:** RAW can't burst. `CameraController.burstEnabled` is false; the code stays.
- **The camera's quick preview is kept.** Each capture keeps a 1440 px preview
  (`capture.jpg`): the instant thumbnail, the RAW stand-in where it can't decode (the
  simulator), and a film look's brightness reference when there's no viewfinder key.
- **Exposure modes** are P / S / M. S (shutter priority) is implemented by us: a 15 Hz
  meter loop adjusts ISO from `exposureTargetOffset` in custom mode, with gain 0.6. The
  180° shutter lock in video uses S with shutter = 1/(2·fps).
- **`suspendForBrowsing()`:** opening the roll waits for `capturesInFlight == 0` before
  stopping the session, so a shot still being processed is never dropped.
- **Edits are a grade.** A shot's edit is its `EditRecipe` in `recipe.json`; the RAW is
  never touched, and "Reset This Image" / "Reset to Original" are always available.
  - Export renders it into Photos.
  - **When adding recipe fields, make them optional or defaulted so old grades still
    decode** (see `mixer: [Double]?`).
- **Settings persistence:** `CameraSettings.load()` merges the saved JSON over the defaults,
  so new fields never wipe the user's setup. Keep it that way.
- **Saved data is decoded tolerantly.** Swift's synthesized `Decodable` fails on any missing
  key, even for properties with defaults. Decode stored settings with
  `CameraSettings.decodeSaved` and stored edits with `EditRecipe.decodeSaved` (both via
  `TolerantJSON`), never plain `JSONDecoder`. Tests remove each key in turn to enforce it.
- **Capture decisions live in `PhotoPlanner.decide`** (pure). `makePhotoSettings` only
  applies them. Change rules there, and `PhotoPlannerTests` checks every combination of
  settings × hardware × burst × zoom against the crash invariants.
- **Bundle IDs:** the project-level `APP_BUNDLE_ID` drives the app and both extensions.
  CI overrides `APP_BUNDLE_ID`. Never override `PRODUCT_BUNDLE_IDENTIFIER` on the command
  line: that would give the extensions the app's ID.
- **`APP_EXTENSION` compile condition** is set on both extension targets. Code in `Shared/`
  that touches app-only types (e.g. `LaunchRequests`) must sit inside `#if !APP_EXTENSION`.
- **Project file:** `PBXFileSystemSynchronizedRootGroup` folders. Adding a Swift file to
  `PointAndShoot/`, `Shared/` or an extension folder needs no `.pbxproj` edit. Info.plists
  live in `Config/` (outside the synced folders) to avoid "multiple commands produce
  Info.plist".
- **The library is `ShotStore`** (main-actor), the only source of truth for the viewer, the
  grid, the filmstrip and the camera thumbnail.
  - **Files:** a shot is a folder `Application Support/Shots/<uuid>/` holding `shot.json`,
    `original.dng`, `recipe.json`, `capture.jpg`, `preview.jpg` (2048 px) and `thumb.jpg`
    (360 px). `shot.json` is written last and atomically.
  - **Caches:** image caches key on id + `Shot.revision`, which is bumped after every
    render.
  - **Developing:** renders run one at a time (`BakeQueue`). `developing` lasts until a
    shot's last queued render finishes.
  - **A fresh shot's first develop settles its grade** (`ShotRenderer.prepare`): the
    camera's RAW noise reduction (floored for film looks), and a film look's exposure
    matched to the viewfinder (`rawFilmExposure`).
  - **A settle never overwrites a grade saved meanwhile.** It is applied only if
    `recipes[id]` is unchanged.
  - **Editor saves settle `.rawOnly`.** They never change the brightness the editor showed,
    and pin a film grade's `rawFilmExposure` to 0 if it had none.
  - **Videos still go straight to Photos.**

### Library, trash and retention (every state)
| Where / when | What happens |
|---|---|
| Capture | `ShotStore.add` writes the files and inserts the shot at once (the camera's preview shows), then develops it. A failed write removes the folder. A failed save clears `lastSavedShotID`, so the viewer never sticks on "Saving…". |
| Viewer / grid trash | `moveToTrash` (no iOS prompt). The viewer lands on the neighbour, and a banner offers Undo. |
| Trash view (grid → Trash) | Tap to put back; Empty deletes the files for good (with a confirmation). |
| Retention | Each shot's 30 days run from `retentionStart` = the latest of taken, added (imports) and restored from the Trash past due. Then, unless tagged Keep or Store New Photos Forever is on, `applyRetention` (at launch and every return to the app) moves it to the Trash. Trash older than 30 days is deleted. An Undo keeps a shot's remaining days. |
| Store Forever | Turning it off asks first if photos would move to the Trash right away. Reset General Settings leaves it alone. |
| Editor open when the shot is trashed | Save reports "moved to the Trash" instead of saving. |
| Edit while developing | Edit waits only for a RAW shot's first settle (`awaitingFirstSettle`). Export waits for the develop (up to a minute), then settles itself if needed. |
| Launch | `load()` merges with shots added meanwhile (Lock Screen imports race it). Folders with no `shot.json` and over an hour old are swept. Shots without a preview (backgrounded mid-render) re-develop, and do again on every return to the app. |
| Lock Screen shots | The extension parks a Bayer DNG (embedded preview, atomic write). On next open the app imports each one once, with the default grade. An unreadable parked file keeps its folder. |
| Import RAW / Import Archive | Imported shots get `added` = now, so older RAWs aren't trashed on arrival. An archive skips shots already in the library and puts back ones in the Trash. Parsing runs off the main thread. |
| Auto Export | After the first develop; skipped if the shot was trashed meanwhile. |

### Film looks: Print and every other look
- **Every look except Original is a film stock** in the same model, and is meant to read
  as a film or a movie grade, never an Instagram filter (the owner's brief, 2026-11-17:
  "as original looks as 'print'"). Print is the original; Phromagraph is Chromagraph
  measured; Punch is kept as is.
  - **Named sets** (`LookSet`, `Look.set`; `set` in `film-looks.json`). The camera's LOOK
    strip (stack button, `CameraSettings.lookSet`, nil = all) and the editor's Looks tool
    (`@AppStorage("editor.lookSet")`) show one set or all; the guide groups by set. The
    owner compares whole families on the phone.
    - Essentials: Original, Print, Phromagraph, Punch, Noir.
    - Film Stocks: Portrait 400, Evergreen, Slide, Lush.
    - Movie: Three-Strip, Blockbuster, Night 800, Bleach Bypass.
    - Grades: PR #35's first pass, with its ids and tunings untouched (Desert, Pastel, Amber
      Haze, Sodium, Neon Night, and #35's Slide and Bleach Bypass, renamed "Slide 70s" and
      "Bleach Grit" but still ids `slide` / `bleach`). The new Slide and Bleach Bypass are
      `classicslide` / `bleachbypass`: an id always means one look, or saved choices, default
      grades and the editor's highlight would point at the wrong one.
    - Adding a look: give it a `set` in both places. `export-swift` refuses a JSON set that
      disagrees with `Look.all` (or a look with no stock), and `SettingsTests` pins the
      Essentials and checks every film look's stock exists.
  - **What makes them film and not filters is structure, not tint** (the owner: nothing
    "super faded / just turned up the tint"; research and sources in
    `docs/film-looks-research.md`): dense blacks (`floor` 0), colour that depends on hue
    and brightness, and saturated colours that get *darker*.
  Each has its own:
  - tone curve: grey placement, contrast slope, shoulder, white, black floor
  - printer-light balance and crossover (per-channel print gamma: casts that differ in
    shadows and highlights and die out at black and white; preferred over split toning)
  - **hue twists** (`FilmStock.hueTwists`, `FilmLUT.twist`): the film's colour rendering
    by hue.
    - Each twist is `[hue°, width°, rotate°, saturation, stops]`, applied on scene light in
      log(x + 0.01) before the sensitivity matrix, so it's the same at every brightness
      and neutrals are untouched.
    - `filmlooks.py` refuses twists that fold or squeeze the hue order: d(hue out)/d(hue in)
      must stay ≥ 0.2 all round (a twist's steepest slope is rotation·π/(2·width), and
      overlapping twists add). Blockbuster's first greens twist (+70° over ±60°) reversed
      the hue order of foliage; `PipelineTests` checks the shipped stocks too.
    - Examples: Evergreen's emerald greens, Blockbuster's skin lock with teal greens and
      skies, Three-Strip's pull to pure primaries.
    - Built only into the negative cube (~35 ms per stock vs ~14), so nothing changes per
      frame.
  - **dye saturation** (`FilmStock.dyeSaturation`, `FilmLUT.dyeSaturate`), in print
    density:
    - > 0 pivots on each colour's least dense channel, so richer colours get *darker*, as
      with real dyes.
    - < 0 pulls toward the mean density: retained silver, a bleach bypass.
    - Spreading about the mean, like the Saturation slider, would *brighten* saturated
      colours.
    - Stocks that use it take a per-cell path in `printCube` (~5–9 ms), since the pivot
      isn't a product of per-axis terms.
    - A grey with three equal densities is untouched, but printer lights and crossover give
      a stock's greys a cast, which dye saturation scales by 1 + amount, and it darkens
      grey a little (Slide's by ~0.08 stop against the same stock without it). The looks
      were tuned on the real output, so `grey` is approximate: Lush lands ~0.12 stop and
      Night 800 ~0.21 stop under their `grey` targets.
  - interlayer saturation, an optional scene channel mix (`channel_mix`, folded into the
    sensitivity matrix), dye crosstalk, and Technicolor's key black (`key_black`, folded
    into crosstalk; Three-Strip). None of these three needs app code.
  - halation and grain (Night 800's red halation is wide, with a low threshold)
  - split toning (`shadowTint` / `highlightTint`): luminance-neutral offsets added to the
    print's *encoded* output with weight (1 − Y)² / Y².
    - It gave the first filters their own shadows; without it every film black converged
      to the same neutral.
    - It reads as a tint, so the new looks use crossover and hue twists instead (at most
      a trace).
  - **Film engines** (`FilmLUT.currentEngine`, pinned per photo in `FilmRecipe.engine`;
    `renderEngine` reads nil as 1):
    - 1: the original.
    - 2 (#36): the measured un-render of processed and viewfinder input.
    - 3 (now): adds the subtractive Saturation slider (`FilmControls.subtractiveSaturation`).
      More saturation pivots on each colour's least dense channel, as dye saturation does.
      Engines 1–2 spread about the mean and *brightened* rich colours: a yellow at +50
      went from 0.34 to 0.57 luminance.
    - Engines 2+ share engine 2's un-render and its tables (`FilmLUT.unrenderEngine`). At
      Saturation 0, engine 3 renders exactly like engine 2.
    - `freezeFilmTuning` pins engine 1 on unversioned edits, never the current engine.
    - With the slider above 0 on engine 3, the print cube takes the per-cell path.
    - Hue twists and dye saturation are stock fields (off when absent), so they need no
      engine.
  - **Table caches** (`FilmPipeline.tableCapacity` = stock count + 6, ~1.8 MB a table).
    The LOOK strip's "All" previews touch every stock every 2 s (on their own queue), so a
    cache smaller than the stock count would evict the viewfinder's tables, which then
    rebuild on the render queue and stall it. Adding stocks grows it automatically.
  - **Older photos:** `hueTwists` and `dyeSaturation` are optional, and nil means off.
    `EditRecipe.decodeSaved` never fills them in from today's stock
    (`FilmStock.offWhenMissing`), so tunings pinned before they existed render as they did.
  - B&W looks are color stocks followed by the existing mono mix, so the color mixer
    still works like darkroom filters. The stock's `monoTone` gains tone the result: Noir
    is cold.
  - Signatures are deliberately far apart. Each look owns 2–3 axes that survive a
    thumbnail: brightness (key), contrast, chroma, shadow tint, highlight tint and
    vignette. Grain and structure don't show at thumbnail size, so they never carry a
    look on their own.
    - **Caveat:** mean ΔE rewards tints. Most pixels are near-neutral, so hue-selective
      looks measure closer than they read. Meet the rule with key, contrast, dye density
      and hue signatures, never casts or lifted floors (`docs/film-looks.md` §4,
      pitfalls).
    - **Rule:** within each set (measured together with the essentials), every look's
      nearest neighbour is ≥ 0.06 mean ΔE (Oklab) in
      `scripts/print-look.py spread IMG… [--cssgram] [--sheet out.jpg] [--looks OLD.json]`,
      which prints one table per set (each with the essentials; one table if the JSON
      has no sets), flags offenders, and can add CSSgram's table and a contact sheet. The
      tuning loop and pitfalls are in `docs/film-looks.md`.
    - Today (engine 2's un-render for the JPEGs) the nearest within-set pairs are
      0.060–0.079 (Three-Strip–Punch 0.060 is the closest). The exception is
      Print–Phromagraph (0.023): the same rendering by design, never retuned from each
      other. CSSgram's 26 Instagram-style filters have a nearest-neighbour median of
      0.050 and a minimum of 0.021.
  - **Retired looks** (Natural, Warm 400, Skin, Cool Air, Cine, Chrome, Faded, Mono 400,
    Silver; 2026-11-17) are out of `Look.all` and `FilmStock.all` but every photo made
    with one renders exactly as before: pinned tuning, else `FilmStock.Legacy.v2`
    (`resolved(for:)`; `namedOrRetired` fills gaps in an older pinned tuning from that
    retired stock, not from Print). `Look.retired` keeps their names (`displayName`, the
    editor's info row) and moves a saved camera choice on: Chrome → Slide (`classicslide`), Skin → Portrait
    400, Cool Air → Evergreen, Cine → Blockbuster, Mono 400 / Silver → Noir, the rest →
    Original (`CameraSettings.decodeSaved`). Never reuse a
    retired id for a different look.
  - Vignette, structure and so on stay as ordinary recipe extras (`Look.film(_:_:)`).
- **Only Print and Phromagraph capture RAW** (`Look.capturesRAW`). The others apply to
  whatever Photo mode's processing produced, and develop from RAW when the shot has a DNG.
- **Phromagraph** (`phromagraph`, a look, never a mode) is a separate stock *fitted* to
  Chromagraph Camera's own exports of its own ProRAWs, where Print was calibrated from
  public samples. Keep the two separate: don't retune Print from Phromagraph's data or
  vice versa. Details, numbers and caveats: `docs/film-looks.md` §5½.
  - Mean ΔE (Oklab) to Chromagraph 0.0070 on 12 pairs (Print: 0.019).
  - Its stock `exposure` is 0 on purpose: the viewfinder match (`rawFilmExposure`)
    supplies Chromagraph's +1.8 EV develop exposure. A non-zero stock exposure also scales
    the viewfinder's display-referred input and would clip it.
  - Grain starts at 0 (`Look` sets `grain = 0`, Chromagraph's default); slider 50 =
    Chromagraph grain 1.25 (`grainDensity` 0.017, size 0.17).
  - Halation is a third of Print's: Chromagraph shows no measurable red glow.
- **Signal path:** scene-linear light → exposure → halation → shaper → negative cube →
  + grain → print cube → Display P3. See the header of `FilmModel.swift`.
  - Halation and grain are spatial, so they sit outside the two 3D LUTs.
  - Grain is added in *negative density*, so the print curve shapes it the way a real
    print does.
  - The grain path keeps every image opaque, because `CIRandomGenerator`'s alpha is
    random and any filter that un-premultiplies would turn the grain into speckle.
    Grain under 1 px is softened with an explicit 3×3 Gaussian
    (`CIConvolution3X3`), whose effect on amplitude is known exactly; Core Image's blur
    isn't guaranteed at sub-pixel σ.
- **Highlight hue protection** (`huePreserve`, per stock): film's per-channel shoulder
  turns bright warm colors yellow, because red compresses first. Bright skin goes gold.
  - The print cube blends toward the scene's own color, with the interlayer saturation
    undone, as luminance rises.
  - The scene color is carried by the stock's own neutral cast at that exposure
    (`neutralTable`), so warm or cool looks keep their cast in the highlights instead
    of being pulled back to neutral.
  - Print keeps 0 to stay faithful to Chromagraph. Most color looks use 0.2–0.8;
    desaturated ones (Bleach Bypass) use 0, because hue protection restores
    the scene's colour (it undoes the interlayer and any `channel_mix`).
- **Source of truth:**
  - `scripts/print-stock.json` holds Print (fitted).
  - `scripts/phromagraph-stock.json` holds Phromagraph, written by
    `scripts/phromagraph.py fit` (a full stock, not a compact spec).
  - `scripts/film-looks.json` holds the other looks: compact specs, with anything left out
    inherited from Print. `scripts/filmlooks.py` derives each stock's print curve from
    its tone target.
  - `FilmStock+Stocks.swift` is generated from all three: `scripts/print-look.py export-swift`.
  - `derive_print_curve` used to deduplicate exactly tied knots after an unstable
    `np.argsort`, so a different numpy picked a different last knot (Natural's print cube
    moved by up to 23/255). It now sorts with `kind="stable"`; regenerating keeps Print,
    Phromagraph, Punch and Noir byte-identical. Still compare the stocks you didn't mean
    to change after any regenerate.
  - `scripts/filmmodel.py` mirrors the Swift math exactly.
  - After touching either side, run `scripts/print-look.py parity`. It compiles
    FilmModel.swift with `swiftc`, works on Linux too, and fails on any difference
    above 1e-5.
- **Where the numbers come from:**
  - Negative curve: Kodak Vision3 5219 datasheet.
  - Dye crosstalk: Kodak 2383 dye densities.
  - Print curve: derived so the neutral scale matches Chromagraph Camera's tone response,
    recovered from its in-app exposure sweep (a near power law, slope ≈ 1.44, into a
    shoulder capped at 0.83 white).
  - Printer-light balance, crossover and interlayer saturation: fitted to public
    Chromagraph samples (neutral-axis tint vs. lightness, ColorChecker chroma ≈ 0.85×).
  - Grain (mostly monochrome, ~0.5 px) and halation: matched by eye/measurement to the
    same samples.
- **Tables** (per stock):
  - The negative cube (48³, 1.8 MB) is fixed per stock and source, built once (~15 ms,
    ~35 ms with hue twists). At launch every stock's viewfinder cube is prewarmed in the
    background (~0.5 s of CPU for 19 stocks), so the LOOK strip's live previews never
    stall the viewfinder.
  - Both caches are LRUs sized `FilmPipeline.tableCapacity` = stock count + 6 (1.8 MB a
    table, ~45 MB each at 19 stocks). Print-cube keys use `FilmControls.canonical`, so
    prewarmed tables serve engine-3 looks. Tables with an edit's exposure baked in have
    their own 4-slot cache, so an Exposure drag can't evict the viewfinder's (unless the
    viewfinder's own look carries an exposure, as a default grade can).
  - LOOK-strip thumbnails render on their own utility queue and Metal command queue from
    a small copy of the frame (`PreviewRenderer.filterThumbnails`), never on the
    viewfinder's, and stop refreshing while the session is stopped (roll or editor open).
  - The print cube (48³) depends on `FilmControls` (contrast, saturation, crossover,
    highlights, shadows) and is cached. It rebuilds in ~2 ms (Print) to ~7 ms (hue
    protection + split toning), only when a film slider moves, so editor sliders don't hitch. `printCube` factors the math into per-axis terms (crosstalk and saturation
    are linear in density), with a 1-D table for highlights/shadows and a √-space table
    for the sRGB encode.
  - Don't shrink below 48³: at 40³ the grey ramp stops being monotone (banding).
  - The interpolation error of the two-table path vs. direct math is < 0.007 ΔE (Oklab)
    on the grey scale.
- **Sources:**
  - `.sceneLinear` is a RAW develop with `boostAmount = 0`, no local tone mapping and no
    sharpening (`EditPipeline.configure` does this whenever `recipe.film != nil`).
  - `.displayReferred` (viewfinder, processed HEIFs) is un-rendered first, inside the
    negative cube, **on luminance** (`FilmLUT.sceneFromDisplay(rgb:engine:)`). Inverting
    per channel read saturated display reds as stops over: they turned orange and faces
    yellow.
    - **Engine 2 (and 3, which shares it):** Apple's rendering, *measured* on the owner's ProRAWs
      (`FilmLUT.unrender*` tables; `docs/film-looks.md` §5¾).
      - The curve is the median scene light behind each display level (anchored
        display 0.20 = scene 0.18).
      - Apple's saturation boost (×3.4 in the toe to ×1.1 in the shoulder) is divided
        out.
      - Exposure is applied *after* the un-render, in the table (one cached table per
        1/100 stop).
      - The viewfinder now matches the saved RAW photo ~35% better (median ΔE 0.043 →
        0.028 across looks); what's left is Apple's local tone mapping, which no global
        inverse can undo.
    - **Engine 1** (edits pinned before it, and `engine == nil`): a guessed curve
      `display = 1.273·s/(1+0.808·s)`, channel ratios kept (so Apple's saturation stacked
      under the film's), and exposure applied *before* un-rendering (+1 EV clipped
      everything above display 0.5). Kept bit-exact for older edits.
- **Where Print appears:** `CameraSettings.printPlacement`, under Settings → Photo →
  "Print film look".
  - **Mode (default):** PHOTO · PRINT · VIDEO. `CaptureMode.print` is a still mode
    (`isStill`), so it uses the photo pipeline.
    - It drops the controls that don't apply: no format pill (always RAW), no LOOK
      cell (Print *is* the look), and no burst (RAW can't burst).
    - Photo ↔ Print switches without rebuilding the session. Only a ProRAW on/off change
      reconfigures (`CameraController.proRAWActive`).
    - Print is left out of the LOOK list.
  - **Look:** Print is the first item under LOOK, and there is no Print mode.
  - `CameraSettings.activeLook` is what actually gets applied: Print in Print mode,
    otherwise the chosen look.
  - The editor's Looks tool always includes Print (under Essentials, or All).
- **Capture:** the Print mode (or the Print look) makes the camera shoot Bayer RAW and
  keep the DNG (`CameraSettings.developsBayerRAW`). `RecipeBaker` then renders the edit
  from the in-memory DNG.
  - **Noise.** A Bayer RAW is a single frame with none of Apple's multi-frame noise
    reduction, so the develop has to clean it up.
    - The baker starts from the camera's own luminance NR for the shot, never below
      `EditRecipe.filmMinimumNoiseReduction` (50).
    - Film looks also get ≥ 0.5 chroma NR.
    - Print used to force 15%. Indoor shots came out "super grainy" on device: sensor
      noise, amplified by the film's contrast, with the synthetic grain on top.
  - **Brightness matches the viewfinder.**
    - The problem: the viewfinder renders Apple's processed video through the film's
      display-referred path, but the photo develops the linear RAW. On device the photo
      came out much darker than the viewfinder, which the owner likes.
    - How the match works: under a film look, `PreviewRenderer` measures a scene key a
      few times a second. That's the geometric-mean scene luminance as the film sees it
      (`FilmLUT.sceneKey`, on a 48 px sample).
    - The key rides along with the shot (`PhotoPlan.viewfinderKey`). The baker measures
      the same key on a small RAW develop and stores the difference as
      `EditRecipe.rawFilmExposure`, clamped to −1.5…+2.5 EV. `EditPipeline.configure`
      adds it to the RAW exposure under film looks, so the editor reproduces it, and
      switching looks keeps it.
    - Flash shots, and shots with no recent viewfinder key, match the processed photo
      instead.
- **Photos keep the tuning they were made with.** `FilmRecipe.tuning` stores the whole
  `FilmStock` (~4.2 KB), pinned the moment a look is picked (`Look.film`) and kept through
  every save. Rendering uses `FilmStock.resolved(for:)`, so retuning a stock in code (or
  regenerating `FilmStock+Stocks.swift`) never changes an older photo, even when it's
  reopened and re-saved in the editor.
  - **Photos from before pinning** (no `tuning`) resolve to the exact tuning they were made
    with, from the frozen history in `FilmStock+Legacy.swift`:
    - a stock id (film-stock looks, #15+) → the stocks as shipped from #15/#20 (this is
      also how the retired looks keep rendering);
    - no stock id is Print, which never stored one before pinning: luminance NR under 50
      (#9's Print set 15%) → Print as shipped in #9 (grain 0.012); otherwise (the #20+
      baker floors NR at 50) → Print as shipped from #20 (grain 0.008).
    - Saving such an edit pins that same tuning. **Never edit or regenerate
      `FilmStock+Legacy.swift`**; `FrozenTuningTests` checks its fingerprints.
  - Picking the look again in the editor pins its current tuning: that's how a photo moves
    to the newest version.
  - `FilmRecipe.engine` records the film-math version (`FilmLUT.currentEngine`, now 3;
    `renderEngine` treats nil as 1, and `freezeFilmTuning` pins nil as 1). Pinning
    freezes a stock's numbers, not the code: a change to the math that would alter older
    photos must keep the old behaviour for older engines (engines 2 and 3 did: see
    "Sources" and "Film engines").
  - Table caches key pinned tunings by id + value hash (`FilmPipeline.cacheKey`), so they
    never share LUTs with the current stock.
  - A pinned tuning missing fields that stocks gained later decodes with those fields taken
    from the current stock (`EditRecipe.decodeSaved`), except `FilmStock.offWhenMissing`
    (hueTwists, dyeSaturation), which stay nil = off. Give new `FilmStock` fields values
    that keep older photos looking the same where possible, or make them optional and add
    them to `offWhenMissing`.
- **Recipe:** `EditRecipe.film` (optional, so old edits decode).
  - Tune's exposure, contrast, highlights, shadows and saturation act inside the film
    model; grain is the film grain.
  - Halation and crossover are `FilmRecipe` fields.
- **Refit to real pairs** (most accurate):
  1. Put `NAME.dng` (from Point & Shoot) and `NAME.jpg/heic` (the reference) in a folder.
  2. Run `scripts/print-look.py fit DIR`. Add `--same-raw` if both come from the same DNG,
     which also fits the grey placement.
  3. Run `scripts/print-look.py export-swift` and then `scripts/print-look.py parity`.

### Tunables that are educated guesses (tune on device)
| What | Where | Value |
|---|---|---|
| Peaking edge intensity / threshold | `PreviewRenderer.peakingOverlay` | 5.0 / 0.2 |
| Zebra threshold (default) | `CameraSettings.zebraThreshold` | 0.95 display, converted with gamma 2.2 |
| Shutter-priority ISO gain / deadband | `shutterPriorityStep` | 0.6 / 0.08 EV |
| EV drag sensitivity | `CameraView.handlePan` | 170 pt per EV, snapped to ⅓ stop |
| Editor swipe sensitivity | `EditorView.adjustGesture` | full range over 860 pt |
| Apple Log view LUT | `PreviewRenderer.makeAppleLogToRec709Cube` | Apple's published Log curve + Rec.2020→709 + simple filmic shoulder (not an official LUT) |
| Zero develop NR / sharpening | `ZeroDeveloper.configureNeutral` | chroma NR 0.3, sharpness 0.1 |
| Storage reserve / auto-stop | `updateStorage` | 1 GB reserve / stop under 600 MB |
| GPS "good" / max staleness | `LocationTagger` | ≤ 50 m / 10 min |
| Print: brightness | `RecipeBaker.matchedExposure`, `FilmLUT.sceneKey` | each shot's RAW develop is matched to the viewfinder (geometric-mean scene luminance), −1.5…+2.5 EV. `print-stock.json` `exposure` (0) still sets the look's own grey placement (~11.5% display for scene grey) |
| Print: halation strength / radii | `print-stock.json` `halation`, `halation_spread` | R 0.15, G 0.04, B 0.005; σ 2 + 6 ‰ of long side |
| Print: grain | `print-stock.json` `grainDensity`, `grain_size`, `grainChroma` | 0.008 D at 4032 px (was 0.012, "super grainy" on device), 0.13 ‰, 15% color |
| Film looks: RAW noise reduction | `RecipeBaker`, `EditPipeline.configure` | camera default, floored at 50 luminance / 0.5 chroma |
| Film looks: inverse of Apple's rendering (viewfinder, processed photos) | `FilmLUT.unrender*` (engine 2) | measured from CIRAWFilter's default render of 13 iPhone 12 Pro ProRAWs, a stand-in for the video feed; refit with real viewfinder frames when possible |
| Looks' tone, color, split toning and texture | `scripts/film-looks.json` (+ vignette/structure in `Look.all`) | designed on two RAW files and two Apple-processed photos, spaced with `print-look.py spread`; tune on device, keep nearest ≥ 0.06 |

---

## 5. Feature inventory (what exists)

- **Photo:**
  - RAW only: ProRAW (default; 12 MP or max) or Bayer RAW (12 MP, zoom locked at 1×). Kept
    in the app's library until exported; export is HEIF/JPEG at 1920/2880/3840 px or
    actual size, at a chosen quality (default HEIF, 2880, 100%).
  - Flash, self-timer, responsive capture and zero shutter lag.
  - Silent shutter by default: `CameraSettings.shutterSound = false` sets
    `isShutterSoundSuppressionEnabled` (iOS 18+, only where
    `isShutterSoundSuppressionSupported`; `camera.canSilenceShutter` drives the Settings
    toggle). The Lock Screen extension is always silent where allowed. The app plays no
    other sounds.
  - Capture **Looks**: film stocks and movie grades (§4 "Film looks"), previewed live.
    New shots start from the **Default Grade** (a look plus sliders, Preferences →
    Processing) while its look is the one picked; the viewfinder shows it too.
  - No burst (RAW can't burst).
- **Controls:**
  - One control row: FOCUS/WB/ISO/SHUTTER/EV/LOOK (LOOK in Photo only). The owner wants
    all of them visible at once; don't hide them behind a "more"/PRO toggle (tried in #12,
    reverted). White = auto, yellow = manual.
  - Scrub dials for ISO (⅓ stops), shutter (⅓ stops), EV, Kelvin WB and manual focus.
  - Tap to focus/meter, hold to lock AE/AF, drag ↕ for EV, swipe ↔ for Photo/Video, pinch
    to zoom.
  - Remembers the last lens used.
- **Video:**
  - HD/4K at 24–120 fps (filtered per lens); SDR, HLG or Apple Log; HEVC, H.264 or ProRes
    (422 / 422 HQ).
  - Stabilization modes, 180° shutter lock, Log view assist.
  - Audio meter, recording time left with auto-stop when storage is low, thermal pause of
    the assists.
- **Assists:** peaking (4 colors), zebras, RGB+luma histogram (default off), level (shown
  only within ~12° of level), grid, frame lines
  (1:1, 4:5, 16:9, 1.85, 2.39). Frame lines follow the phone's held orientation.
- **Hardware:**
  - Volume buttons fire the shutter (`AVCaptureEventInteraction`).
  - iPhone 16 Camera Control gets system zoom and EV sliders.
  - The Action button works via App Shortcuts or the Control.
- **GPS:** works offline. Written to EXIF (position, altitude, speed, compass heading),
  QuickTime ISO 6709 metadata, and `PHAsset.location`.
- **Library** (§4 "Library, trash and retention"):
  - The viewer opens on the newest shot, with a "Developing…" placeholder while it saves.
    A filmstrip of every shot sits under the photo. Paging, swipe down to dismiss.
  - Header: grid, camera, share · Keep (bookmark), trash. An info line shows RAW type,
    date, exposure and days left. Bottom: edit and export (tan).
  - Zoom like Photos (`ZoomableImageView`, a UIScrollView): pinch anchored under the
    fingers with pan at the same time, rubber-banding, double-tap fit ↔ 2.5×, up to 2×
    native pixels (4–8×). At 1× the scroll view has nothing to scroll, so swipes page and
    swipe-down dismisses; zoomed in, drags pan and never dismiss. A full-size copy (long
    side ≤ 4096), rendered from the RAW with its grade, loads once zoomed past 1.3× and is
    dropped when the page leaves.
  - Grid by day; Select → export, share, Keep, copy/paste grade, Archive RAW, trash; Trash
    view.
  - Import RAW Photos (system picker, no permission) and Import Archive in Preferences →
    General.
- **Editor:**
  - Tools: Looks (19 plus Original, in named sets) · Tone (Exposure, Contrast + Fade,
    Shadow/Highlight, Whites/Blacks, RAW) · Color (Balance, Saturation + B&W, Crossover,
    Mixer) · Texture (Grain, Halation, Detail, Vignette, Noise) · Crop. Each tool has
    sub-tab pills and labelled `GradeSlider`s: a default mark and detent, double-tap to
    reset, one undo step per drag.
  - ✓ saves the grade. ⋯ offers Copy/Paste Grade, Set as Default Grade, Reset This Image,
    Reset to Original and Discard. The export button sits in the tool bar. Undo,
    hold-to-compare.
  - Zoom: pinch + two-finger pan (UIKit recognizers on `MetalImageView`), double-tap fit ↔
    2.5×; one finger pans when zoomed. Zoom is a transform in the renderer, so Core Image renders
    only the visible region; zoomed in, `EditSession` switches to a sharper source
    (`loadDetail`, long side ≤ 4096, RAW at the matching scale). Off in Crop.
  - A discard guard for unsaved changes.
- **iOS 18 Lock Screen camera + Control Center control:**
  - The extension writes to Photos when allowed. Otherwise it parks files in
    `sessionContentURL`, which the app imports on launch.

---

## 6. CI/CD

- **`build.yml`:** unsigned `xcodebuild build -target PointAndShoot -sdk iphoneos` on PRs and
  on pushes to `main` (feature branches build only through their PR: one run per change),
  using the newest Xcode on `macos-15`. The same job (one Mac, one queue wait) then runs
  every test on the newest iPhone simulator (`.github/scripts/pick-simulator.py`):
  - `PointAndShootTests` (unit + integration, hosted in the app): settings and recipe
    back-compat, the capture planner's crash invariants, viewer/thumbnail logic, every
    look through the film pipeline on the simulator GPU, and the real Photos library
    (save, RAW pairs with a generated DNG, Zero develop orientation, baking a look).
  - `PointAndShootUITests`: tap targets, Print zoom lock, settings, and the roll flows
    (viewer, delete with iOS's confirmation, Don't Allow, grid batch delete) against
    photos seeded with `-uitest-seed N`.
  - Photos access: the seeding app asks for full access and `LibraryFlowTests` taps
    "Allow Full Access" (the warm-up's `simctl privacy` grant didn't reach the app in CI).
    The scheme runs the UI tests first, so the integration unit tests inherit that access.
    `TEST_RUNNER_CI=1` makes both fail rather than skip without it.
  - When it fails, the errors appear in the run summary. The `build-log` artifact holds the full log; grep it for
  `SwiftCompile` / `in target '…'` to confirm what was actually built.
- **macOS runners are scarce on the free plan** (a few concurrent Mac jobs per account).
  Don't add Mac jobs that could run on Linux, and cancel superseded runs; queued Mac jobs
  can wait many minutes.
- **`testflight.yml`:** a tiny Linux job checks for the Apple secrets first; the Mac job
  runs only when they exist. On push to `main` or `claude/**`, it archives with automatic signing
  through an App Store Connect API key and uploads to TestFlight. The build number is
  `run_number.run_attempt`.
  - **It skips cleanly until these repo secrets exist:** `ASC_KEY_ID`, `ASC_ISSUER_ID`,
    `ASC_KEY_P8`, `APPLE_TEAM_ID`, `BUNDLE_ID`.
  - Setup for the owner is in `CLOUD_BUILD.md`.
  - **It has never run with real secrets.** The first run may need fixes (cloud-managed
    certificates need an Admin key, and the two extension App IDs must register).
- **The repo is public,** so GitHub Actions macOS minutes are free. Secrets stay secret.
- **The owner's Apple Developer Program status is unknown.** If they don't have it, local
  free-team installs (7-day) are the path.

---

## 7. Working conventions

- **One focused PR per fix or feature,** on a `claude/<topic>` branch, branched from
  up-to-date `main`. Push, wait for the green **Build** check, then merge.
- **The owner has authorized merging your own PRs once CI is green.** Use merge commits.
  If you stack PRs, retarget each to `main` before merging it.
- **Verify, don't assume.** A green CI run means it compiles; it doesn't mean it works. Say
  which one you know.
- Keep `README.md` (user-facing features) and this file updated when behaviour changes.
- **Commit messages:** a short imperative subject, plus a bullet body explaining what
  changed and why. Don't put model names in commits or PRs.
- **Style:** small views, `PressScaleStyle` for tappable controls, yellow as the accent for
  "you're in control", haptics on meaningful events (through `Haptics` / `camera.haptic`, which reuse
  pre-warmed generators; don't allocate feedback generators per tap), springs for motion.
  Keep the default screen uncluttered: rarely changed options go behind the format pill or
  Settings, and every hidden state should be visible at a glance. Never block the
  main thread.
- **Tap targets (learned the hard way on device):** SwiftUI hit-tests only what's drawn, so
  transparent padding inside a button is dead space. Taps there fall through to the
  viewfinder's UIKit recognizers and trigger focus.
  - Every custom button needs a full-frame `contentShape` and at least a ~36–44 pt target.
    `PressScaleStyle` adds `contentShape(Rectangle())` automatically; `.plain` buttons must
    add their own.
  - The bottom controls have a near-invisible hit-testable background so gaps between
    controls never reach the viewfinder.
- **One presentation per view:** never chain several `.sheet` / `.fullScreenCover` modifiers
  on the same view. On iOS 26 that silently stopped the Settings sheet from appearing.
  Attach each one to its own anchor: the button that opens it, or a `Color.clear` in a
  `.background { … }` (see `PhotoViewer`).
- **Re-render discipline:** values that change several times a second (histogram, meter
  offset, audio level, ISO/shutter in auto) must be read inside small leaf views, e.g.
  `LiveHistogram(camera:)`, never in `CameraView`'s body. Reading them there re-renders the
  whole screen on every tick and makes controls feel sticky.
- **UI tests:** `PointAndShootUITests` runs in the simulator with the `-uitest` launch
  argument (`TestHooks.isUITest`). That mode skips the camera session, permission prompts
  and the tour, and loads default settings.
  - Tests find controls by accessibility identifiers (`strip.*`, `topbar.*` incl. `topbar.format`, `format.done`, `grid.*`, `viewer.*` (incl. `viewer.photo`, `viewer.edit`), `editor.*` (`editor.canvas`, `editor.save`, `editor.tool.<tool>`),
    `mode.*`, `dial.auto`, `viewfinder`, `focus.reticle`).
  - New controls should get an identifier and, if they're custom, an off-center tap test.
  - **Run them locally first: `scripts/ui-tests.sh`** (a few minutes, no queue). Pass
    `-only-testing:PointAndShootUITests/<Class>/<test>` to run a single test. CI runs the
    same tests after the device build.
- **The simulator can't decode RAW** (CIRAWFilter returns an empty image, native size 0×0),
  so the Zero/Print *develop* is device-only; its tests skip there. Saving RAW pairs, the
  capture decisions and baking from processed photos are all tested in the simulator.
- **Diagnostics log (`Diag`, App/Diagnostics.swift).** While the app is in development,
  log every meaningful event and every failure with `Diag.log(area, …)` /
  `Diag.error(area, …, error)` (errors carry the NSError domain and code). Never per frame.
  - Lines go to the unified log (category = area) and to a ring buffer persisted at
    `Application Support/diagnostics.log`, so the run before a crash survives.
  - Uncaught ObjC exceptions (AVFoundation's instant crashes) are written synchronously
    before the app dies; MetricKit crash/hang reports are added on a later launch.
  - Already logged: launch (build, device, permissions), foreground/background, memory
    and thermal, session errors and interruptions, each shot's capture plan, capture and
    save results (incl. the RAW-pair fallback), Zero develop time, every bake with timing
    and errors, roll size changes, deletes (outcome, error code, access), editor errors,
    Lock Screen imports, and every toast/banner the user sees.
  - **Asking the owner for logs:** Preferences → General → Diagnostics → Share (AirDrop the
    .txt to the Mac and attach it), or Copy. Preferences → General → Version shows when the
    installed build was made.
- **Every device bug gets a test** where the simulator can reproduce it: a pure-logic
  rule (extract it, like `PhotoPlanner` / `ViewerSelection`), a Photos-library
  integration test, or a UI flow with seeded photos. The simulator has no camera, so
  AVFoundation capture itself stays device-only; test the decisions around it instead.

---

## 8. Device test plan (do this first)

**On `claude/raw-studio` (P&S Studio), check these first.** ⚠️ = most likely to be wrong.

1. **Capture.** ProRAW is the default and zoom works. Bayer RAW (Preferences → Camera)
   locks zoom at 1×. ⚠️ The first shots after launch show the camera's preview, then the
   developed look.
2. **Viewer.** The filmstrip follows paging. Keep tags the photo. Trash + Undo works.
   Export puts a 2880 px HEIF in Photos with the look. Zooming in sharpens from the RAW.
3. **Editor.** Each tool and sub-tab works; ✓ saves, and the viewer and grid refresh.
   Set as Default Grade, then new shots and the viewfinder use it. ⚠️ Film-look brightness
   matches the viewfinder (`rawFilmExposure`).
4. **Retention.** "N days left" shows on unkept shots. The Trash restores. Turning off
   Store Forever asks first.
5. **Import/archive.** Import RAWs from Photos. Archive a few to a zip, delete them, and
   Import Archive brings them back with their grades.
6. **Lock Screen.** The shot appears in the library with the default grade after opening
   the app.
7. **Preferences.** A double-tap on the viewfinder opens it; tap-to-focus is still instant.

1. **Launch & preview**
   - The camera permission prompt appears.
   - The preview is upright for the back camera, and upright and mirrored for the front.
   - The preview is smooth; check with peaking on.
2. **Focus mapping**
   - Tapping a subject focuses *there*. If the wrong spot focuses, check
     `devicePoint(fromViewPoint:)` against the renderer orientation.
   - Hold to lock AE/AF; the reticle stays.
3. **Photo capture, every combination**
   - Processing: Apple, Balanced, Natural, Zero. RAW: off, Bayer RAW, ProRAW. With and
     without the HEIF companion. 12 MP vs max. Flash.
   - ⚠️ AVFoundation throws ObjC exceptions (instant crash) on invalid
     `AVCapturePhotoSettings` combos. Check `makePhotoSettings` first if the shutter
     crashes.
   - ⚠️ Silent shutter: with the ringer ON, a photo, a burst and a Lock Screen shot make
     no click; turning Settings → Shutter sound on brings the click back.
   - In Photos, confirm: RAW+HEIF shows as one asset with RAW badge; Zero output looks
     natural and isn't rotated twice; EXIF orientation is right in portrait and landscape.
4. **Manual exposure**
   - ISO, shutter and EV dials, and the M-mode meter.
   - ⚠️ S mode assumes `exposureTargetOffset` keeps metering in custom exposure mode. If
     ISO doesn't float, rethink `shutterPriorityStep`.
   - Kelvin WB and manual focus (peaking appears in MF).
5. **Lenses:** every focal-length chip; the 2× crop ramps smoothly; the blur transition
   between lenses; the app reopens on the last lens.
6. **Burst:** holding gives a counter; no crash with RAW selected (burst should skip RAW);
   all burst shots appear in Photos.
7. **Video**
   - 4K and HD at 24/30/60; HLG; Apple Log on 15 Pro+ (view assist on/off); HEVC vs ProRes.
   - Recorded orientation is correct, audio is in sync, the file plays in Photos with
     correct color (HDR badge for HLG).
   - The time-left estimate is plausible; peaking and zebras work in video.
8. **Assists:** histogram responds; zebras on blown highlights; level; frame lines rotate
   with landscape.
9. **GPS:** test in airplane mode outdoors. The icon turns green, and the photo shows its
   location in the Info sheet and in Photos.
10. **Roll / viewer**
    - Shoot, then tap the thumbnail immediately: the placeholder resolves to the new shot.
    - Paging, swipe down, share (original file), favorite, delete (lands on the neighbour),
      Info sheet with map.
    - Deletes (§4 "Deletes"): delete the newest shot in the app, then in Photos, and check
      the camera thumbnail each time; delete everything; delete in Photos while the viewer,
      the grid in Select mode, the Info sheet or the editor is open; tap Don't Allow.
11. **Editor**
    - Each tool. Swipe gestures feel right. Color mixer: try Blue Luminance with Noir.
    - Save → shows Edited in Photos → reopen restores sliders → Revert works.
    - Save as New Photo; copy/paste between photos.
    - RAW tab on a RAW/Zero photo.
12. **Capture Looks:** pick one, shoot. The photo is edited in Photos; the editor shows the
    Look selected and lets you remove it.
    - The set menu (stack button, left of the LOOK strip) switches the strip between
      Essentials, Film Stocks, Movie, Grades and All. The editor's Looks tool has the same
      menu.
    - Each Film Stocks and Movie look reads as a film or movie grade in the viewfinder, on
      skin, and in daylight and night scenes, with no faded blacks or global tint. Compare
      against Grades, PR #35's pass. The LOOK strip's thumbnails are easy to tell apart.
    - The Saturation slider on a new edit makes rich colours deeper, not brighter. An
      older edit's slider behaves as before.
      - Night 800 at night: red glow around lights, cyan shadows. It was designed only on
        daylight and sun-flare images.
      - Skin under Portrait 400, Evergreen and Blockbuster (the twists were designed on
        film scans and two iPhone photos).
      - Viewfinder smoothness on switching looks: the twisted negative cubes take ~35 ms
        to build (prewarmed).
    - A photo made with a retired look (e.g. Cine, Warm 400) still looks the same and the
      editor still names its look. A camera left on a retired look opens on its
      successor: Chrome → Slide, Skin → Portrait 400, Cool Air → Evergreen,
      Cine → Blockbuster, Mono 400 / Silver → Noir. The rest open on Original.
13. **Shortcuts / Action button:** "Take a Photo" and "Record a Video" in the Shortcuts app
    open the right mode.
14. **iOS 18 Control + Lock Screen camera**
    - Add the control to Control Center and the Lock Screen.
    - Locked: the extension opens without unlock and captures.
    - ⚠️ Whether the extension can write to Photos directly. If not, shots should appear
      after opening the app (`LockedCaptureImporter`).
    - "Full app" hands off after Face ID.
15. **Print look**
    - Tap PRINT (or swipe from PHOTO). It switches instantly with no session blur, and the
      viewfinder shows the look live with moving grain at full frame rate.
    - Print mode shows no format pill, no LOOK cell, and doesn't burst. Flash, timer and
      exposure controls are still there.
    - Settings → Print film look → Look: PRINT leaves the mode picker and appears under
      LOOK. The format pill then reads "Print · RAW" when it's picked.
    - Shoot, then check in Photos: the shot is Edited, and the DNG is kept. ⚠️ The saved
      photo should be about as bright as the viewfinder was (indoors, outdoors, at
      night). If it's consistently off, check `rawFilmExposure` in the edit's recipe and
      `FilmLUT.sceneKey`. If Print is too dark or bright everywhere, *including the
      viewfinder*, change `exposure` in `print-stock.json`, then run export-swift.
    - Look for red-orange halation around lamps and sunlit edges, and fine grain. Check
      there is no banding in skies or shadow gradients.
    - Indoors at night, the shot shouldn't look noisy. Fine grain should be visible
      only when you zoom in.
    - Editor: Print from the Looks tool. Details → Grain/Halation/Crossover respond;
      Tune sliders behave. Revert in Photos gives the neutral Zero develop.
    - Switch the look back to Original: sharpening and the RAW tab's tone sliders return.
16. **Robustness:**
    - Background/foreground while recording; incoming call; low storage.
    - Deny each permission (camera, mic, photos, location) and confirm graceful messages.

---

## 9. Backlog / ideas (not started)

- Live Photos capture.
- Home-screen widget showing the latest shot.
- A "safe mode" that disables RAW/extras if the session fails to start.
- Editor: selective/brush adjustments, healing, curves UI, LUT import.
- Video: looks / LUT on record, false color, waveform, timecode.
- Deferred photo processing (iOS 17 `isAutoDeferredPhotoDeliveryEnabled`) for even faster
  shot-to-shot.
- App Store submission workflow (unlisted distribution). Apps installed from the App Store
  keep working even if the developer membership lapses.
- Localization; accessibility pass (VoiceOver labels on all controls); iPad layout.
- Print look:
  - Multi-frame highlight-retention capture (bracket and merge, ~2 stops) so halation and
    the shoulder see real highlights.
  - A contrast pivot.
  - A Print-mode default exposure placement tuned on device.
  - An "optical" (white bloom) halation mode.
  - Grain amplitude that varies with density.
  - Fitting against real reference pairs (see §4).

---

## 10. Tips for agents (learned the hard way)

The film-look specifics are in `docs/film-looks.md` §8. Repo-wide:

- **Other sessions merge to `main` constantly.** Always branch from a freshly fetched
  `origin/main`. Merge `main` into any PR that lives longer than an hour before trusting
  its CI.
- **A PR with merge conflicts gets no CI at all** (no `pull_request` run). If Build never
  starts, check `mergeable_state`; "dirty" means merge main in.
- **The cloud container has no iOS toolchain.**
  - `swiftc` for Linux (see `docs/film-looks.md` §8) compiles the Foundation-only files
    (`FilmModel.swift`, `FilmStock+Stocks.swift`) for parity.
  - Anything that imports UIKit, AVFoundation or Core Image can only be checked with
    `swiftc -parse`.
  - CI is the first real compile, so say "parses" or "compiles in CI", never "works".
- **GitHub:** `gh api` REST works and GraphQL is blocked, so `gh pr create` and
  `gh pr merge` may fail. Use REST: `pulls` POST to open, `pulls/N/merge` PUT with
  `merge_method=merge` and `sha`.
- **Clones are shallow and single-branch.** Fetch other branches by name. Push new branches
  with `-u` so the stop hook sees a remote branch.
- **Watch CI in the background** by head SHA (`actions/runs?head_sha=…`, workflow "Build").
  Mac runs take 20–30 min plus queueing, so batch your pushes.
- **Generated files** (`FilmStock+Stocks.swift`): on a merge conflict, regenerate with
  `export-swift`; never hand-merge them.
- **Show, don't tell.** For anything visual, send the owner a before/after sheet
  (SendUserFile). They react to pictures.
- **The scratchpad is not durable.** Tools you'll want again belong in `scripts/`; notes
  belong here or in `docs/`.
