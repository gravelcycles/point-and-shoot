# Point & Shoot

A camera for people who think in stops and shutter angles. You get a real camera when you
want one and a point-and-shoot when you don't, plus a Snapseed-style editor that never
destroys your originals.

Native SwiftUI + AVFoundation + Core Image on Metal. iPhone, iOS 17+.

## Photo

| Control | What it does |
|---|---|
| **RAW** (format pill) | Off / **RAW** (Bayer DNG straight off the sensor, with no Apple pipeline) / **ProRAW** (Apple's linear DNG, with fusion) |
| **RAW + HEIF** | Saves the DNG and a processed HEIF/JPEG as one pair in Photos, or RAW only |
| **Processing** (format pill) | **Apple**: Deep Fusion / Smart HDR, full pipeline · **Balanced** · **Natural**: lightest ISP touch, less HDR flattening and smoothing · **Zero**: no computational photography. Shoots Bayer RAW and develops it in-app with a neutral, film-like curve (no local tone mapping, no luminance NR, no oversharpening). You can keep the DNG too. |
| **Format** | HEIF or JPEG |
| **Resolution** | 12 MP or the sensor max (48 MP on Pro main cameras) |
| Flash, self-timer | Off/Auto/On; 3s/10s |

Responsive capture and zero shutter lag are turned on wherever the hardware supports them.

- **The top bar** has big round buttons for flash, self-timer and settings (⚙︎), each with
  a haptic click. The **format pill** in the middle ("HEIF · Natural ▾") opens a panel with
  labelled choices for file type, RAW and processing.
- **Clean by default, pro on tap.** The strip under the viewfinder shows EV and FILTER.
  Tap **PRO** to reveal FOCUS, WB, ISO and SHUTTER; it stays that way until you fold it
  again. A yellow dot on PRO means something is still on manual.
- **Double-tap any control** (FOCUS, WB, ISO, SHUTTER, EV, FILTER) to put it back on auto.
- **Filters at capture time.** Tap **FILTER** for live square previews of each filter, and
  **About** to read what each one does. You see it live in the viewfinder, and every shot
  is saved with the look as an *editable edit*. The untouched original stays one tap away
  in the editor or Photos.
  - **Every filter is a film stock,** not a set of slider moves. Each has its own tone
    curve, color balance, film color (rich colors get denser, not louder), halation and
    grain.
    - **Natural:** a clean negative scan.
    - **Warm 400:** golden hour: amber light, matte brown blacks, grain.
    - **Skin:** bright, soft and peachy, with a gentle glow.
    - **Cool Air:** airy, with blue-cyan shadows.
    - **Cine:** low key, teal shadows under amber highlights, a red glow around lights.
    - **Chrome:** slide film: dark, dense and richly saturated.
    - **Faded:** a sun-faded print with milky indigo blacks.
    - **Punch:** maximum color.
    - **Mono 400, Noir, Silver:** black and white (neutral; inky and cold; soft sepia).
  - **Each filter has its own shadows, brightness and color,** spaced at least as far
    apart as Instagram-style filters, so they're easy to tell apart at a glance.
  - **Bright skin stays skin-colored** instead of going gold.
- **Print: film, from the sensor.** Print is a real film emulation rather than a set of
  slider moves.
  - **It's a mode:** **PHOTO · PRINT · VIDEO**. Tap it or swipe to it.
  - **It's single-purpose:** Print mode always shoots RAW, so there's no format or filter
    to fiddle with. Flash, timer and exposure stay.
  - **Or make it a filter:** Settings → Photo → **Print film look** → Filter puts it in the
    FILTER list instead.
  - **How it works:** the camera shoots Bayer RAW and keeps the DNG, like Zero. Print runs
    the sensor data through a model of a Kodak Vision3 negative printed to print film:
    - dense blacks with a long, soft toe
    - a highlight shoulder that never clips harshly
    - warm highlights over cool shadows (color crossover)
    - film color, where rich colors get darker rather than louder and reds lean orange
    - a red-orange halation glow around bright lights
    - fine film grain that lives in the mid-tones
  - **In the editor:** Tune's sliders work inside the film model, and Details adds
    **Grain**, **Halation** and **Crossover**.
- **Hold the shutter for burst.** Shots fire as fast as the camera keeps up, with a
  counter on the button. Burst frames skip RAW so they stay fast.
- The app reopens on the lens you used last.

## Exposure, like a camera body

- **P / S / M**: Auto with EV compensation, **shutter priority** (shutter held, ISO
  floats against the meter), and full **manual** with a light-meter readout.
- **Command-dial scrubbers** for ISO (⅓ stops), shutter (⅓ stops), EV, white balance in
  Kelvin, and manual focus. Each detent clicks with a haptic, you can fling to coast, and
  **A** returns that control to auto.
- **Tap** to focus and meter. **Hold** to lock AE/AF. **Pinch** to zoom.
- **Drag up/down on the viewfinder** for exposure compensation in ⅓-stop clicks, with a
  sun slider. **Swipe sideways** to switch Photo/Video.
- **Lenses by focal length** (13 / 24 / 48 / 77 / 120 mm, depending on the phone),
  including the 48 mm crop from the 48 MP main sensor. Within the same glass the zoom
  ramps smoothly. Between lenses the preview blurs and settles instead of freezing.

## Video, for cinematographers

- 4K / HD at 24, 25, 30, 48, 50, 60, 100 or 120 fps (whatever the lens supports)
- **SDR (Rec.709), HDR (HLG), or Apple Log** (iPhone 15 Pro and later)
- **HEVC, H.264, ProRes 422 / 422 HQ**, at higher-than-phone bitrates
- **180° shutter lock**: shutter = 1/(2×fps) with auto ISO, so motion blur looks natural
- Stabilization off / standard / cinematic / cinematic extended
- **Log view assist**: preview Apple Log through a Rec.709 transform while the file stays Log
- Audio meter and recording clock
- **Recording time left** for your current settings. If storage runs low, recording
  stops and saves cleanly before the phone is full.
- If the phone gets hot, peaking, zebras and the histogram pause so recording stays
  smooth.

## Assists

Focus peaking (in four colors), zebras with an adjustable threshold, a live RGB + luma
histogram (off by default; turn it on in Settings), a horizon level that appears only
when you're within about 12° of level and turns yellow when you're dead on, a rule-of-thirds grid, and frame lines (1:1, 4:5, 16:9, 1.85,
2.39) that follow how you're holding the phone. All of them are drawn on the GPU from the
same frames being recorded.

**Geotagging works in airplane mode.** Photos and videos are tagged with GPS position,
altitude, and which way the camera was facing (compass). All of it uses the phone's GPS
chip and magnetometer, so no signal is needed. Without network help the first fix can take
a minute, and it works best outdoors. The location icon in the top bar shows the status:
green means locked, pulsing yellow means searching. Tap it to see the accuracy. The
location is written into the file itself (EXIF / QuickTime), so it survives sharing.

The **volume buttons** fire the shutter. On iPhone 16, **Camera Control** adjusts zoom and
exposure.

## Roll & editor

**Shoot → tap the thumbnail → you're looking at that shot.** If it's still developing (a
Zero RAW develop, say), you see a blurred preview that sharpens the moment it's saved. The
camera waits for every in-flight shot to finish saving before it pauses, so nothing is lost.

- **Info** (ⓘ in the viewer): lens, focal length, aperture, shutter, ISO, EV,
  resolution, file type and size, and a map of where you took the shot, with altitude and
  which way you were facing.
- **Viewer**: swipe sideways through your camera roll (photos and videos), pinch to peek
  at focus, tap to hide the controls, and swipe down to get back to shooting. It also has
  Share (the original full-quality file, RAW included), Favorite, Delete (iOS asks you to
  confirm), and a grid of the whole roll.
- **Edit** opens the editor on that photo, with a preview showing instantly while the
  full-quality source loads.
  - **Swipe ↕ on the photo** to choose a parameter and **↔** to dial it in. A pill shows
    the value, and a haptic ticks when you cross zero. Hold ◧ to compare with the original.
  - **Filters** (with an **About** guide explaining each): Print (the film emulation above),
    Natural, Warm 400, Skin, Cool Air, Cine, Chrome, Faded, Punch, Mono 400, Noir, Silver,
    with live thumbnails. On a photo with a DNG, every filter develops from the sensor data.
  - **Tune**: exposure, contrast, highlights, shadows, whites, blacks, saturation,
    vibrance, warmth, tint.
  - **Details**: structure, sharpening, fade, grain, vignette.
  - **Color**: an 8-band mixer (red, orange, yellow, green, aqua, blue, purple,
    magenta), each with hue, saturation and luminance. Greys stay neutral. In B&W looks it
    works like darkroom colour filters, e.g. drag Blue Luminance down for dramatic skies.
  - **Crop**: free or locked aspect, straighten dial, rotate, flip.
  - **RAW**: if the photo has a DNG, the edit develops from the sensor data. You get real
    white balance and exposure, plus Apple's noise reduction and local tone mapping as
    sliders you can turn down to zero.
  - **Copy Edits / Paste Edits**: carry a look from one photo to the next. Crop isn't
    copied.
- **Saving goes straight to your camera roll.**
  - **Save** (one tap) updates the photo in Photos the same way Apple's own editor does.
    The original is kept, the edit shows as *Edited* everywhere, and you can *Revert* in
    Photos or here. Reopen the photo here and every slider is where you left it.
  - **Save as New Photo** keeps the original untouched and adds a new full-resolution
    HEIF next to it.
  - Closing with unsaved changes asks whether to save or discard.
- **Everything stays in sync**: the app watches your photo library. New shots, saved
  edits, favorites, deletes, and edits made in Apple's Photos app show up immediately in
  the viewer, the grid, and the camera's thumbnail.

## Lock Screen, Control Center & the Action button (iOS 18)

There's a **Point & Shoot control** you can put in Control Center, swap in for the Lock
Screen's camera button, or assign to the Action button.

- **Phone locked:** a lightweight Point & Shoot camera opens instantly, with no unlock
  needed. You get a shutter, volume-button capture, and a "Full app" button that asks for
  Face ID and continues in the app.
- **Phone unlocked:** it opens the full app.

Lock Screen shots go straight into Photos. If iOS doesn't allow that from the Lock Screen,
they're held safely and imported the next time you open the app.

To set it up: long-press Control Center → **Add a Control** → Point & Shoot. On the Lock
Screen: long-press → Customize → Lock Screen → tap the camera button → Point & Shoot.

A second control, **Record Video**, opens the full app straight into Video mode (after Face
ID if the phone is locked). Put it in Control Center, on the other Lock Screen button, or on
the Action button (Settings → Action Button → Controls).

## Shortcuts & the Action button

**Take a Photo** and **Record a Video** appear in the Shortcuts app, Siri ("Take a photo
with Point & Shoot") and Spotlight. To set up the Action button, go to Settings → Action
Button → Shortcut → Point & Shoot. The app opens straight into that mode.

## Developing

`CLAUDE.md` is the full engineering handoff: architecture, threading rules, design
decisions, tunables, CI/CD, and a device test plan. Claude Code reads it automatically.
Start a local session from there.

## Build

**Quickest:** plug in the iPhone and run `scripts/deploy-iphone.sh`. It finds your team and
phone, builds, signs, installs and launches. If the bundle ID is taken:
`BUNDLE_ID=com.yourname.pointandshoot scripts/deploy-iphone.sh`.

**Or in Xcode:**
1. Open `PointAndShoot.xcodeproj` in **Xcode 16 or newer**.
2. Choose your team under *Signing & Capabilities* for all three targets (*PointAndShoot*,
   *PointAndShootWidgets*, *PointAndShootLockedCapture*). To change the bundle ID, edit the
   project's `APP_BUNDLE_ID` build setting (default `io.github.gravelcycles.pointandshoot`);
   the extensions follow it.
3. Run on a real iPhone. The simulator has no camera.

**No Mac?** Every change can build itself and auto-install on your iPhone via TestFlight. See
[CLOUD_BUILD.md](CLOUD_BUILD.md).

The project uses Xcode's synchronized folders, so new files in `PointAndShoot/` are picked
up automatically.

## Layout

```
PointAndShoot/
  App/            entry point
  Camera/         CameraController (session, lenses, exposure, capture, recording),
                  PreviewRenderer (Metal preview + peaking/zebras/histogram/Log LUT),
                  PhotoCaptureProcessor, ZeroDeveloper, VideoRecorder, CaptureSettings
  UI/             CameraView, ControlStrip + DialPanel, ScrubDial, Overlays, SettingsView
  Editor/         EditorView, EditSession, EditPipeline (Core Image graph), EditRecipe,
                  CropOverlay, MetalImageView, FilmModel + FilmPipeline (the Print look)
scripts/          deploy-iphone.sh; print-look.py (preview, fit and export the Print look)
  Library/        RollStore (live camera roll), PhotoViewer (full-screen pager),
                  LibraryView (RollGrid), PhotoLibrary (save/share/fetch helpers)
```

### Why it stays smooth

- Session and device work run on a dedicated queue. The main thread only touches UI.
- The preview is rendered by us: each frame goes to a `CAMetalLayer` through Core Image.
  If the GPU is busy, the frame is dropped rather than queued, so the viewfinder never
  lags behind.
- Edits are a lazy Core Image graph on a downsampled, pre-decoded source. Dragging a
  slider costs one GPU pass per frame. Full resolution is rendered only when you save.
