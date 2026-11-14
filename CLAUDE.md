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

The film-look work has its own handoff notes: `docs/film-looks.md`.

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
  App/PointAndShootApp.swift      @main; owns CameraController + RollStore
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
  UI/ControlStrip.swift           FOCUS/WB/ISO/SHUTTER/EV/FILTER readouts + DialPanel
  UI/ScrubDial.swift              haptic tick-mark jog dial (reused in the editor's straighten)
  UI/PreviewView.swift            CAMetalLayer host + UIKit gestures; volume-button interaction
  UI/Overlays.swift               grid, frame lines, level, histogram, meter, reticle, EV slider, toast
  UI/SettingsView.swift           settings sheet
  UI/MotionManager.swift          gravity → level + icon rotation (UI is portrait-locked)
  Library/RollStore.swift         live camera roll (PHPhotoLibraryChangeObserver), latest thumbnail
  Library/PhotoViewer.swift       full-screen pager opened from the thumbnail; share/fav/delete/info
  Library/LibraryView.swift       RollGrid + AssetThumbnail
  Library/PhotoInfoSheet.swift    EXIF + map info panel
  Library/PhotoLibrary.swift      save/share/favorite/delete/RAW-fetch helpers (returns asset IDs)
  Library/LockedCaptureImporter.swift  imports Lock Screen shots parked by the extension
  Library/RollLogic.swift         pure viewer selection + thumbnail handoff rules — unit-tested
  App/TolerantJSON.swift          decodes saved settings/recipes from any app version (missing keys → defaults)
  App/TestHooks.swift             -uitest, unit-test host, -uitest-seed N photo seeding, roll.count probe
  Editor/EditorView.swift         Snapseed-style editor UI (swipe ↕ choose / ↔ adjust)
  Editor/EditSession.swift        loads asset (+RAW), preview graph, non-destructive save/copy/revert
  Editor/EditPipeline.swift       the edit as a Core Image graph (geometry → tone → color → detail → fx)
  Editor/EditRecipe.swift         Codable recipe, Adjustment lists, Looks, ColorBand, CropAspect
  Editor/ColorMixer.swift         8-band HSL → cached 32³ color cube
  Editor/RecipeBaker.swift        applies a recipe to a library asset (capture Looks; film looks from the DNG)
  Editor/FilmModel.swift          Print look math: film curves, LUT builders (Foundation only, testable anywhere)
  Editor/FilmStock+Stocks.swift   GENERATED film stocks: Print + every photo filter (from scripts/*.json)
  Editor/FilmPipeline.swift       Print look in Core Image: halation, neg cube, grain, print cube
  Editor/CropOverlay.swift, MetalImageView.swift
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
scripts/film-looks.json           the photo filters as compact film-stock specs (source of truth)
scripts/filmlooks.py              builds full stocks from film-looks.json (tone curve derivation)
scripts/cssgram.py                the 26 Instagram-style CSSgram filters, browser-exact: the yardstick
                                  for how far apart our filters are (`print-look.py spread --cssgram`)
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
- **Processing levels** map to `photoQualityPrioritization`: Apple → `.quality`, Balanced →
  `.balanced`, Natural → `.speed`. **Zero** captures Bayer RAW only and develops it with
  `ZeroDeveloper`: no local tone map, no luminance NR, a little chroma NR.
- **RAW+processed pairs: the DNG goes in as a file.** `PhotoLibrary.savePhoto` writes the
  RAW to a temp `.dng` and adds it with `addResource(with: .alternatePhoto, fileURL:)`
  (`shouldMoveFile`), like Apple's AVCam. Added as `Data`, Photos rejects the pair with
  PHPhotosErrorDomain 3300 (seen on device for Print). If a pair is still refused, the
  photo and the DNG are saved as two assets and a toast names the error code.
- **Bayer RAW forces `.speed` prioritization and 12 MP dimensions.** This is an assumption
  meant to avoid `NSInvalidArgumentException` from AVFoundation. ProRAW is enabled on the
  output only when selected.
- **Zoom is locked at 1× while shooting Bayer RAW** (`CameraSettings.zoomLocked`: Print,
  Zero, film filters, RAW = Bayer). AVFoundation throws on Bayer RAW when
  `videoZoomFactor > 1` (crashed on device: Print, front camera, pinch-zoomed). The owner
  chose "disable zoom" over falling back to the processed photo. Entering such a mode ramps
  back to 1×; pinch shows a toast instead of zooming; cropped lens chips (48 mm) and the
  Camera Control zoom slider are hidden. `makePhotoSettings` still skips Bayer RAW if the
  device is somehow zoomed, as a crash guard. ProRAW and video zoom normally.
- **Bursts:** no RAW, `.speed`, no flash, 12 MP. They fire every 0.11 s, at most 60 shots,
  and pause while 4 or more captures are in flight.
- **Exposure modes** are P / S / M. S (shutter priority) is implemented by us: a 15 Hz
  meter loop adjusts ISO from `exposureTargetOffset` in custom mode, with gain 0.6. The
  180° shutter lock in video uses S with shutter = 1/(2·fps).
- **`suspendForBrowsing()`:** opening the roll waits for `capturesInFlight == 0` before
  stopping the session, so a shot still being processed is never dropped.
- **Edits are non-destructive.** They use `PHContentEditingOutput` with adjustment data
  `formatIdentifier = "com.pointandshoot.recipe"`, version `"1"`, and the JSON-encoded
  `EditRecipe`. Reopening restores every slider; Photos can revert. **When adding recipe
  fields, make them optional or defaulted so old saved edits still decode** (see
  `mixer: [Double]?`).
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
- **Library sync:** `RollStore` (fetch limit 2000, images + videos) is the source of truth
  for the viewer, the grid and the camera thumbnail. Views key image caches on
  `PHAsset.revisionKey` (localIdentifier + modificationDate), so edits refresh everywhere.

### Deletes (every state)
`RollStore` (a `PHPhotoLibraryChangeObserver`, plus a refetch on every return to the app)
is the only source of truth for what exists. Everything else reacts to it.

| Where / when | What happens |
|---|---|
| Viewer trash | iOS shows its own (modal) confirmation. Confirm → the roll drops it → the viewer lands on the neighbour (`lastIndex`). Don't Allow → nothing. No busy flag: the modal alert already prevents a double delete. |
| Grid Select → Delete | One confirmation for the batch; Select mode ends on success and stays (same picks) on Don't Allow. Items deleted elsewhere drop out of the selection; an empty roll shows "No photos". |
| Deleted in Photos / another device, app open or backgrounded | Change observer (or the refetch on return) updates the roll → viewer moves to the neighbour, an open Info sheet closes, the camera thumbnail updates. |
| Already-deleted asset deleted again | `PhotoLibrary.delete` always asks Photos to delete exactly what was tapped; only if Photos refuses does it drop items that are gone (`isGone`) and retry. **Never pre-filter with `isGone`:** that made Delete silently do nothing on device (#19). |
| Open in the editor when deleted | Save/Revert fail, then `isGone` confirms it and the editor offers **Save as New Photo** (renders from the editing input) or Discard. |
| Camera thumbnail | A capture's own thumbnail shows instantly but only until the roll has the shot *and* has rendered it (`handOffThumbnail`); then the roll's newest item is shown, so deleting it anywhere updates the button (empty roll → empty button). A failed save clears it. Without read access the capture's thumbnail is all there is. |
| Shot with a filter / Print | The shot is reported saved as soon as the plain develop is in Photos (so the camera can suspend and the next shot isn't held up), and its ID goes into `camera.developingAssetIDs` until the look is baked. The viewer shows its page blurred under "Developing…" meanwhile, and the camera thumbnail waits for the developed version. Bakes run one at a time (`BakeQueue`); the overlay gives up after 45 s. Blocking capture completion on the bake (#25) left shots stuck on "Developing…" on device. `PhotoPage` cancels and ignores image requests for older revisions, so a slow load of the unedited image can't overwrite the edited one. |
| Shot still developing | Can't be deleted (no asset yet). If its save fails, `lastSavedAssetID` is cleared so the viewer's "Developing…" page doesn't wait forever. A Print bake on a shot deleted meanwhile fails quietly. |
| Lock Screen shots parked for import | Imported once: one import at a time, and imported file keys are remembered, so a deleted shot never comes back if its parked file couldn't be removed. |
| Recently Deleted | Deleted items sit there for 30 days (Photos' behaviour). Recovering one re-inserts it through the change observer. |

### Film looks: Print and every photo filter
- **Every filter except Original is a film stock** in the same model. Print is the
  original. Natural, Warm 400, Skin, Cool Air, Cine, Chrome, Faded, Punch, Mono 400, Noir
  and Silver each have their own:
  - tone curve: grey placement, contrast slope, shoulder, white, black floor
  - printer-light balance and crossover
  - interlayer saturation and dye crosstalk
  - halation and grain (Skin's "halation" is a neutral, wide bloom)
  - split toning (`shadowTint` / `highlightTint`): luminance-neutral offsets added to the
    print's *encoded* output with weight (1 − Y)² / Y². This is what gives each filter
    its own shadows. Without it every film black converges to the same neutral, which was
    the main reason the filters read as alike (Cine's teal shadows, Cool Air's blue,
    Warm 400's brown, Faded's indigo).
  - B&W filters are color stocks followed by the existing mono mix, so the color mixer
    still works like darkroom filters. The stock's `monoTone` gains tone the result: Noir
    is cold, Silver warm, Mono 400 neutral.
  - Signatures are deliberately far apart. Each filter owns 2–3 axes that survive a
    thumbnail: brightness (key), contrast, chroma, shadow tint, highlight tint and
    vignette. Grain and structure don't show at thumbnail size, so they never carry a
    filter on their own.
    - **Rule:** every filter's nearest neighbour is ≥ 0.06 mean ΔE (Oklab) in
      `scripts/print-look.py spread IMG… [--cssgram] [--sheet out.jpg]`, which prints
      the table, flags offenders, and can add CSSgram's table and a contact sheet. The
      tuning loop and pitfalls are in `docs/film-looks.md`.
    - Today the nearest pairs are 0.067–0.075 (B&W 0.063). That is more spread out than
      Instagram-style filters: CSSgram's 26 filters have a nearest-neighbour median of
      0.050 and a minimum of 0.021.
    - On a ColorChecker (CIE76) our colour filters are ≥ 14.9 from each other, vs a
      median of ~11 for CSSgram.
    - The first pass sat at 0.014–0.03 and the second at 0.032–0.055. Both read as "they
      all look the same".
  - Vignette, structure and so on stay as ordinary recipe extras (`Look.film(_:_:)`).
- **Only Print captures RAW** (`Look.capturesRAW`). The others apply to whatever Photo
  mode's processing produced, and develop from RAW when the shot has a DNG.
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
    (`neutralTable`), so warm or cool filters keep their cast in the highlights instead
    of being pulled back to neutral.
  - Print keeps 0 to stay faithful to Chromagraph. The color filters use 0.4–0.9.
- **Source of truth:**
  - `scripts/print-stock.json` holds Print (fitted).
  - `scripts/film-looks.json` holds the filters: compact specs, with anything left out
    inherited from Print. `scripts/filmlooks.py` derives each stock's print curve from
    its tone target.
  - `FilmStock+Stocks.swift` is generated from both: `scripts/print-look.py export-swift`.
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
  - The negative cube (48³, 1.8 MB) is fixed per stock and source, built once (~15 ms).
    At launch every stock's viewfinder cube is prewarmed in the background (~200 ms of
    CPU), so the FILTER strip's live previews never stall the viewfinder.
  - Both caches are small LRUs (16 negative, 18 print; 1.8 MB each).
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
  - `.displayReferred` (viewfinder, processed HEIFs) first undoes a generic phone tone
    curve inside the negative cube. It inverts **on luminance and keeps each color's
    channel ratios** (`FilmLUT.sceneFromDisplay(rgb:)`).
    - Inverting per channel read saturated display reds as stops over: they turned
      orange and faces yellow.
    - The curve is deliberately gentle (+3.5 stops at white), so a brightly rendered face
      isn't pushed into the shoulder.
- **Where Print appears:** `CameraSettings.printPlacement`, under Settings → Photo →
  "Print film look".
  - **Mode (default):** PHOTO · PRINT · VIDEO. `CaptureMode.print` is a still mode
    (`isStill`), so it uses the photo pipeline.
    - It drops the controls that don't apply: no format pill (always RAW), no FILTER
      cell (Print *is* the filter), and no burst (RAW can't burst).
    - Photo ↔ Print switches without rebuilding the session. Only a ProRAW on/off change
      reconfigures (`CameraController.proRAWActive`).
    - Print is left out of the FILTER list.
  - **Filter:** Print is the first item under FILTER, and there is no Print mode.
  - `CameraSettings.activeLook` is what actually gets applied: Print in Print mode,
    otherwise the chosen filter.
  - The editor's Filters tab always includes Print.
- **Capture:** the Print mode (or the Print filter) makes the camera shoot Bayer RAW and
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
    - a stock id (film-stock filters, #15+) → the stocks as shipped from #15/#20;
    - no stock id is Print, which never stored one before pinning: luminance NR under 50
      (#9's Print set 15%) → Print as shipped in #9 (grain 0.012); otherwise (the #20+
      baker floors NR at 50) → Print as shipped from #20 (grain 0.008).
    - Saving such an edit pins that same tuning. **Never edit or regenerate
      `FilmStock+Legacy.swift`**; `FrozenTuningTests` checks its fingerprints.
  - Picking the look again in the editor pins its current tuning: that's how a photo moves
    to the newest version.
  - `FilmRecipe.engine` records the film-math version (`currentEngine`, now 1). Pinning
    freezes a stock's numbers, not the code: a future change to the math that would alter
    older photos must keep the old behaviour for older engines.
  - Table caches key pinned tunings by id + value hash (`FilmPipeline.cacheKey`), so they
    never share LUTs with the current stock.
  - A pinned tuning missing fields that stocks gained later decodes with those fields taken
    from the current stock (`EditRecipe.decodeSaved`). Give new `FilmStock` fields values
    that keep older photos looking the same where possible.
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
| Film looks: inverse of a phone's tone curve (viewfinder, processed photos) | `FilmLUT.sceneFromDisplay` | display = 1.273·s/(1+0.808·s), applied to luminance |
| Photo filters' tone, color, split toning and texture | `scripts/film-looks.json` (+ vignette/structure in `Look.all`) | designed on two RAW files and two Apple-processed photos, spaced with `print-look.py spread`; tune on device, keep nearest ≥ 0.06 |

---

## 5. Feature inventory (what exists)

- **Photo:**
  - HEIF/JPEG; RAW off, Bayer RAW or ProRAW; RAW+processed pairs saved as one Photos asset
    (`.alternatePhoto`).
  - Processing levels Apple, Balanced, Natural, Zero; 12 MP or max resolution.
  - Flash, self-timer, responsive capture and zero shutter lag.
  - Silent shutter by default: `CameraSettings.shutterSound = false` sets
    `isShutterSoundSuppressionEnabled` (iOS 18+, only where
    `isShutterSoundSuppressionSupported`; `camera.canSilenceShutter` drives the Settings
    toggle). The Lock Screen extension is always silent where allowed. The app plays no
    other sounds.
  - Capture **Filters** (called Looks in code): film stocks (§4 "Film looks"), previewed
    live and baked on as an editable edit (needs full Photos access).
  - Hold the shutter for **burst**.
- **Controls:**
  - One control row: FOCUS/WB/ISO/SHUTTER/EV/FILTER (FILTER in Photo only). The owner wants
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
- **Roll:**
  - The viewer opens on the newest shot, with a "Developing…" placeholder while it saves.
  - Paging, pinch-to-peek, swipe down to dismiss.
  - Share sends the original file. Favorite and Delete are there too.
  - An Info sheet shows EXIF and a map.
- **Editor:**
  - Tools: Looks (11), Tune (10 sliders), Details (5), Color (8-band HSL), Crop (aspect,
    straighten, rotate, flip) and RAW (develop from DNG with WB, exposure, NR, local tone
    and boost).
  - Undo, hold-to-compare, copy/paste edits.
  - Save (non-destructive), Save as New Photo, Revert, and a discard guard for unsaved
    changes.
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
    filter through the film pipeline on the simulator GPU, and the real Photos library
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
  - Tests find controls by accessibility identifiers (`strip.*`, `topbar.*` incl. `topbar.format`, `format.done`, `grid.*`,
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
  - **Asking the owner for logs:** Settings → About → Diagnostics → Share (AirDrop the
    .txt to the Mac and attach it), or Copy. Settings → About → Version shows when the
    installed build was made.
- **Every device bug gets a test** where the simulator can reproduce it: a pure-logic
  rule (extract it, like `PhotoPlanner` / `ViewerSelection`), a Photos-library
  integration test, or a UI flow with seeded photos. The simulator has no camera, so
  AVFoundation capture itself stays device-only; test the decisions around it instead.

---

## 8. Device test plan (do this first)

Work top to bottom; earlier failures can mask later ones. ⚠️ marks assumptions most likely
to be wrong.

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
    - Each tool. Swipe gestures feel right. Color mixer: try Blue Luminance with Mono 400.
    - Save → shows Edited in Photos → reopen restores sliders → Revert works.
    - Save as New Photo; copy/paste between photos.
    - RAW tab on a RAW/Zero photo.
12. **Capture Looks:** pick one, shoot. The photo is edited in Photos; the editor shows the
    Look selected and lets you remove it.
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
    - Print mode shows no format pill, no FILTER cell, and doesn't burst. Flash, timer and
      exposure controls are still there.
    - Settings → Print film look → Filter: PRINT leaves the mode picker and appears under
      FILTER. The format pill then reads "Print · RAW" when it's picked.
    - Shoot, then check in Photos: the shot is Edited, and the DNG is kept. ⚠️ The saved
      photo should be about as bright as the viewfinder was (indoors, outdoors, at
      night). If it's consistently off, check `rawFilmExposure` in the edit's recipe and
      `FilmLUT.sceneKey`. If Print is too dark or bright everywhere, *including the
      viewfinder*, change `exposure` in `print-stock.json`, then run export-swift.
    - Look for red-orange halation around lamps and sunlit edges, and fine grain. Check
      there is no banding in skies or shadow gradients.
    - Indoors at night, the shot shouldn't look noisy. Fine grain should be visible
      only when you zoom in.
    - Editor: Print from the Filters tab. Details → Grain/Halation/Crossover respond;
      Tune sliders behave. Revert in Photos gives the neutral Zero develop.
    - Switch the look back to Natural: sharpening and the RAW tab's tone sliders return.
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
