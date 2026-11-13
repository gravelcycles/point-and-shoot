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

Git history: PRs #1 (whole app), #2 (color mixer) and #3 (Lock Screen camera + Control
Center) are merged into `main`.

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
  Camera/PhotoCaptureProcessor.swift  AVCapturePhotoCaptureDelegate; GPS EXIF; save; bake Look
  Camera/ZeroDeveloper.swift      "Zero" processing: neutral CIRAWFilter develop of Bayer DNG
  Camera/VideoRecorder.swift      AVAssetWriter recorder (video+audio, location metadata)
  Camera/LocationTagger.swift     CoreLocation GPS + compass; EXIF/ISO6709 builders
  UI/CameraView.swift             main screen, top bar, lens picker, shutter (tap/hold-burst),
                                  thumbnail, gestures, hints, launch-request handling
  UI/ControlStrip.swift           FOCUS/WB/ISO/SHUTTER/EV/LOOK readouts + DialPanel
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
  Editor/EditorView.swift         Snapseed-style editor UI (swipe ↕ choose / ↔ adjust)
  Editor/EditSession.swift        loads asset (+RAW), preview graph, non-destructive save/copy/revert
  Editor/EditPipeline.swift       the edit as a Core Image graph (geometry → tone → color → detail → fx)
  Editor/EditRecipe.swift         Codable recipe, Adjustment lists, Looks, ColorBand, CropAspect
  Editor/ColorMixer.swift         8-band HSL → cached 32³ color cube
  Editor/RecipeBaker.swift        applies a recipe to a library asset (capture Looks)
  Editor/CropOverlay.swift, MetalImageView.swift
PointAndShootUITests/             simulator UI tests (tap targets, tap-through); run with -uitest
Shared/CameraCaptureIntent.swift  CameraCaptureIntent (compiled into app + both extensions)
Shared/OpenVideoControlIntent.swift  "Record Video" control's intent (opens the app in Video mode)
PointAndShootWidgets/             ControlWidget extension: Camera + Record Video controls (Control Center /
                                  Lock Screen / Action button)
PointAndShootLockedCapture/       LockedCameraCapture extension: lean Lock Screen camera
Config/*-Info.plist               NSExtension dicts for the two extensions (merged with generated plist)
.github/workflows/build.yml       unsigned compile on every push + PRs (free: repo is public)
.github/workflows/testflight.yml  sign + upload to TestFlight on push (skips until secrets exist)
codemagic.yaml                    optional alternative CI
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
- **Bayer RAW forces `.speed` prioritization and 12 MP dimensions.** This is an assumption
  meant to avoid `NSInvalidArgumentException` from AVFoundation. ProRAW is enabled on the
  output only when selected.
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

---

## 5. Feature inventory (what exists)

- **Photo:**
  - HEIF/JPEG; RAW off, Bayer RAW or ProRAW; RAW+processed pairs saved as one Photos asset
    (`.alternatePhoto`).
  - Processing levels Apple, Balanced, Natural, Zero; 12 MP or max resolution.
  - Flash, self-timer, responsive capture and zero shutter lag.
  - Capture **Looks**: previewed live and baked on as an editable edit (needs full Photos
    access).
  - Hold the shutter for **burst**.
- **Controls:**
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
- **Assists:** peaking (4 colors), zebras, RGB+luma histogram, level, grid, frame lines
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

- **`build.yml`:** unsigned `xcodebuild build -target PointAndShoot -sdk iphoneos` on every
  push (to app paths) and on PRs, using the newest Xcode on `macos-15`. A second job,
  `ui-tests`, runs `xcodebuild test` on the newest iPhone simulator
  (`.github/scripts/pick-simulator.py`). When it fails, the
  errors appear in the run summary. The `build-log` artifact holds the full log; grep it for
  `SwiftCompile` / `in target '…'` to confirm what was actually built.
- **`testflight.yml`:** on push to `main` or `claude/**`, it archives with automatic signing
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
  "you're in control", haptics on meaningful events, springs for motion. Never block the
  main thread.
- **Tap targets (learned the hard way on device):** SwiftUI hit-tests only what's drawn, so
  transparent padding inside a button is dead space. Taps there fall through to the
  viewfinder's UIKit recognizers and trigger focus.
  - Every custom button needs a full-frame `contentShape` and at least a ~36–44 pt target.
    `PressScaleStyle` adds `contentShape(Rectangle())` automatically; `.plain` buttons must
    add their own.
  - The bottom controls have a near-invisible hit-testable background so gaps between
    controls never reach the viewfinder.
- **Re-render discipline:** values that change several times a second (histogram, meter
  offset, audio level, ISO/shutter in auto) must be read inside small leaf views, e.g.
  `LiveHistogram(camera:)`, never in `CameraView`'s body. Reading them there re-renders the
  whole screen on every tick and makes controls feel sticky.
- **UI tests:** `PointAndShootUITests` runs in the simulator with the `-uitest` launch
  argument (`TestHooks.isUITest`). That mode skips the camera session, permission prompts
  and the tour, and loads default settings.
  - Tests find controls by accessibility identifiers (`strip.*`, `badge.*`, `topbar.*`,
    `mode.*`, `dial.auto`, `viewfinder`, `focus.reticle`).
  - New controls should get an identifier and, if they're custom, an off-center tap test.
  - CI runs them in the `ui-tests` job.

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
15. **Robustness:**
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
