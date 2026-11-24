# Point & Shoot

A camera for people who think in stops and shutter speeds. You get a real camera when you
want one and a point-and-shoot when you don't, plus a Snapseed-style editor that never
destroys your originals.

Native SwiftUI + AVFoundation + Core Image on Metal. iPhone, iOS 17+.

## Photo

| Control | What it does |
|---|---|
| **RAW** (format pill) | Every photo is a RAW the app develops itself: **ProRAW · Cleaner** (default; Apple's multi-frame DNG, far less noise, zoom works, a moment longer per shot) or **RAW · Faster** (the Bayer sensor frame, ready in under half a second, real noise, zoom stays at 1×). On iPhones without ProRAW (anything but a Pro, 12 Pro or later) every photo is Bayer RAW, and the pickers say why. |
| **Resolution** | ProRAW at 12 MP or the full 48 MP, on phones with a 48 MP sensor; Bayer RAW is always 12 MP |
| Flash, self-timer | Dropdowns under the top bar: Off/Auto/On; Off/3s/10s |

Responsive capture and zero shutter lag are turned on wherever the hardware supports them.

- **The top bar** has big round buttons for flash, self-timer and settings (⚙︎), each with
  a haptic click; flash and self-timer drop down their choices. The **format pill** in the
  middle ("ProRAW · Phromagraph ▾") opens a panel with labelled choices for RAW and resolution.
- **One control row** under the viewfinder: FOCUS, WB, ISO, SHUTTER, EV and LOOK. White
  means the camera is deciding, yellow means you set it. Tap one to dial it in.
- **Double-tap any control** (FOCUS, WB, ISO, SHUTTER, EV, LOOK) to put it back on auto.
- **Looks at capture time.** Tap **LOOK** for live square previews of each look, and
  **About** to read what each one does. You see it live in the viewfinder, and every shot
  is saved with the look as an *editable edit*. The untouched original stays one tap away
  in the editor.
  - **Every look is a film or a movie grade,** not a tint or a saturation slider. Each is
    a film stock with its own tone curve and shoulder, color balance and crossover, its
    own rendering of each hue (skin, foliage, skies), film color (rich colors get denser
    and darker, not louder), real blacks, halation and grain.
    - **Named sets.** Looks come in sets you can switch between from the stack button at
      the left of the LOOK strip (and in the editor's Looks tool), so whole families can
      be compared. **About** groups them by set.
      - **Essentials:** **Phromagraph** (film from the sensor, below),
        **Punch** (a vivid negative pushed hard) and **Noir** (pushed black and white).
      - **Film Stocks:** **Portrait 400** (soft into real blacks, luminous skin, olive
        greens), **Evergreen** (Fuji-style emerald greens, pink-leaning skin), **Slide**
        (dense crimson and gold against muted greens and deep skies) and **Lush** (lush
        greens, deep violet-leaning skies).
      - **Movie:** **Three-Strip** (dye-transfer Technicolor: pure dense primaries, rosy
        skin), **Blockbuster** (teal and orange with skin locked, clean blacks), **Night
        800** (tungsten after dark: cyan shadows, amber light, red glow) and **Bleach
        Bypass** (drained color, hard contrast, inky blacks).
      - **Grades:** an earlier pass, kept to compare: Neon Night, Slide 70s and Bleach Grit.
  - **Each look has its own key, contrast, color and shadows,** spaced further apart than
    Instagram-style filters, so they're easy to tell apart at a glance.
  - **Photos keep the look they were made with.** Looks from earlier versions (Natural,
    Warm 400, Skin, Cool Air, Cine, Chrome, Faded, Mono 400, Silver, Desert, Pastel, Amber
    Haze, Sodium) are no longer offered, but photos made with them look exactly as before
    and keep their look's name. A camera or Default Grade left on one moves to the closest
    current look, or to Original.
  - **The live preview closely matches the saved photo.** The viewfinder undoes Apple's own
    rendering (its curve and extra saturation, measured on real shots) before applying
    the film, so the look you frame is the look you get. iPhones give apps only
    Apple's processed video live, never the RAW, so it's a close preview, not an exact one.
    It also corrects for how Apple renders night scenes darker and sunny ones brighter,
    using the camera's own light reading, so a night shot doesn't come out a stop brighter
    than you framed it. Manual ISO, shutter and exposure compensation preview exactly. Photos edited before this
    keep their original rendering.
- **Film from the sensor.** The film looks are a real film emulation rather than a set of
  slider moves.
  - **Developed from the RAW alone, at natural brightness:** each shot's brightness comes
    from its own ISO, shutter and aperture, about where the iPhone's camera puts the scene,
    a touch under, so dim rooms stay dim and sun never blows out past Chromagraph's level.
    Bayer RAW and ProRAW come out equally bright.
    Older photos keep theirs; picking the look again in the editor brings the current one.
  - **Plain live view** (Preferences → Camera, experimental): asks the camera for a plainer
    feed, with no video HDR and no local brightening, so the viewfinder tracks the RAW
    photo more closely.
  - **How it works:** the sensor data runs through a model of a Kodak Vision3 negative
    printed to print film:
    - dense blacks with a long, soft toe
    - a highlight shoulder that never clips harshly
    - warm highlights over cool shadows (color crossover)
    - film color, where rich colors get darker rather than louder and reds lean orange
    - a red-orange halation glow around bright lights
    - fine film grain that lives in the mid-tones
  - **In the editor:** Tone's sliders work inside the film model, and Texture adds
    **Grain** and **Halation**.
  - **Print**, the first film look (once also its own mode), is no longer offered:
    Phromagraph is the same rendering, fitted to Chromagraph. Photos made with Print look
    exactly as before and are still called Print; a camera or Default Grade left on Print
    moves to Phromagraph.
- **Phromagraph: Chromagraph's look, measured.** A look that's fitted to Chromagraph
  Camera's own renders of its own RAWs (13 shots of the same scenes, pixel for pixel).
  - Creamy highlights and skies, teal-leaning mid-tones, dense soft blacks and only a faint
    glow around lights.
  - Like every look, it develops from the RAW at Chromagraph's brightness.
  - Grain starts off, as in Chromagraph. The editor's **Grain** slider at 50 matches
    Chromagraph's grain 1.25, and **Grain Size** behaves like its Size (measured on its
    exports: crisp, about a pixel across, neutral on greys).
- The app reopens on the lens you used last.
- **Zoom stays at 1× with Bayer RAW.** It's the sensor's full frame, which can't be
  digitally zoomed; pick a lens instead, or shoot ProRAW. Pinching just tells you why.
- **Silent shutter by default.** No click, no sounds at all. Turn **Shutter sound** on in
  Settings if you want it. Muting needs iOS 18, and isn't allowed in some countries (e.g.
  Japan, Korea); there the click plays unless the phone is on silent.

## Exposure, like a camera body

- **P / S / M**: Auto with EV compensation, **shutter priority** (shutter held, ISO
  floats against the meter), and full **manual** with a light-meter readout.
- **Command-dial scrubbers** for ISO (⅓ stops), shutter (⅓ stops), EV, white balance in
  Kelvin, and manual focus. Each detent clicks with a haptic, you can fling to coast, and
  **A** returns that control to auto.
- **Tap** to focus and meter. **Hold** to lock AE/AF. **Pinch** to zoom.
- **Drag up/down on the viewfinder** for exposure compensation in ⅓-stop clicks, with a
  sun slider.
- **Lenses by zoom, like the Camera app:** 0.5, 1×, 2, 3 or 5 (relative to the main lens,
  depending on the phone), including the 2× crop from a 48 MP main sensor. The chosen lens
  shows the live zoom as you pinch (1.4×). Within the same glass the zoom ramps smoothly.
  Between lenses the preview blurs and settles instead of freezing.

## Assists

Focus peaking (in four colors), zebras with an adjustable threshold, a live RGB + luma
histogram (off by default; turn it on in Settings), a horizon level that appears only
when you're within about 12° of level and turns yellow when you're dead on, a rule-of-thirds grid, and frame lines (1:1, 4:5, 16:9, 1.85,
2.39) that follow how you're holding the phone. All of them are drawn on the GPU on the
live picture. If the phone gets hot, peaking, zebras and the histogram pause until it
cools down.

**Geotagging works in airplane mode.** Photos are tagged with GPS position,
altitude, and which way the camera was facing (compass). All of it uses the phone's GPS
chip and magnetometer, so no signal is needed. Without network help the first fix can take
a minute, and it works best outdoors. The location icon in the top bar shows the status:
green means locked, pulsing yellow means searching. Tap it to see the accuracy. The
location is written into the file itself (EXIF), so it survives sharing.

The **volume buttons** fire the shutter. On iPhone 16, **Camera Control** adjusts zoom and
exposure.

## Library & editor

Photos stay in the app's own library (RAW + your edit) until you export them, like
Chromagraph. Nothing reaches your camera roll until you tap Export, or turn on Auto Export.

**Shoot → tap the thumbnail → you're looking at that shot.** A shot still developing shows
"Developing…" over the camera's preview straight away, then the finished look.

- **Viewer**: the newest shot on the right and older ones to the left, as in Photos, with a
  filmstrip of every shot underneath. Swipe down to get back to shooting.
  - **Zoom like Photos**: pinch (zoom and move at the same time), double-tap to zoom in on
    a spot or back out. Zoomed in, it re-renders from the RAW at full resolution.
  - **Keep** (bookmark) saves a photo from the 30-day clean-up. **Trash** asks first, then
    offers Undo. **⋯** has Copy/Paste Grade and Archive RAW. **Export** (tan) saves the
    finished photo to Photos; **Share** sends it anywhere.
  - **Grid** (bottom left): the whole library by day, newest at the bottom right, as its
    own screen, with a camera button straight back to shooting; it opens on the photo you
    were looking at. **Select** to export, share, keep, apply a look, paste a grade,
    archive or trash several at once. The **Trash** keeps photos 30 days.
- **30 days by default**: photos you haven't tagged Keep move to the Trash 30 days after
  you took them (Preferences → General → Store New Photos Forever turns that off).
- **Edit** opens the editor: **Looks · Tone · Color · Texture · Crop**, each with labelled
  sliders (double-tap one to reset it; every drag is one Undo step).
  - **Looks**: Phromagraph (Chromagraph, measured), Punch and Noir; Film Stocks;
    Movie; and Grades, with live thumbnails and a set menu. Every look develops from the
    RAW. Under the looks:
    - a **Local Tone** slider that dodges and burns: shade comes up, skies come down, and
      detail stays;
    - for film looks on a RAW, an **Apple Tone** switch: the film prints Apple's own
      rendering of the RAW, its local tone mapping included, so the photo comes out the
      way the viewfinder showed it.
    Both stay as you try other looks.
  - **Optional controls** (each can be switched off in Preferences → Processing → Editor
    Controls): a **Film** tool for film looks (Printer Lights, Push/Pull, Flashing, Silver
    Retention, Grain Colour, Halation Size and Colour), plus **Colour Grading**, a **Tone
    Curve**, **Dehaze**, a **Sky** mask with its own exposure and saturation, and Local
    Tone & Apple Tone (Looks tool).
  - **Highlight Recovery** (Tone, film looks) brings back skies that print white: the RAW
    keeps its highlight headroom and the brightest parts of the scene are compressed before
    the film. Under a film look, **Sky Exposure** works like a graduated ND filter on the
    light, so darkening the sky brings back its clouds.
  - Ranges like Chromagraph's: **Exposure ±6 stops**; under a film look **Highlights** and
    **Shadows** re-expose whole regions of the scene (up to ±3 stops) and **Contrast** goes
    to ×2 around a **Pivot**; **Grain** up to 4× with its own **Grain Size**.
  - **ⓘ** on every tab says what each control does and how they work together.
  - **Pinch to zoom** while you edit; hold ◧ to compare with the original.
  - **✓** saves the grade (the RAW is never touched; Reset to Original is always there).
    **⋯** has Copy/Paste Grade, Set as Default Grade (new shots start from it), Reset and
    Discard.
- **Preferences** (⚙︎, or double-tap the viewfinder): General (storage, Auto Export,
  location, Import RAW Photos, Import Archive, Diagnostics), Camera (RAW format, shooting,
  viewfinder, controls) and Processing (Default Grade, export format, size and quality).
- **Import & archive**: bring RAW files in from Photos, archive RAWs to Photos or to a zip
  (with each photo's grade), and import that zip back later.

## Lock Screen, Control Center & the Action button (iOS 18)

There's a **Point & Shoot control** you can put in Control Center, swap in for the Lock
Screen's camera button, or assign to the Action button.

- **Phone locked:** a lightweight Point & Shoot camera opens instantly, with no unlock
  needed. You get a shutter, volume-button capture, and a "Full app" button that asks for
  Face ID and continues in the app.
- **Phone unlocked:** it opens the full app.

Lock Screen shots are held safely and move into the library, with your Default Grade, the
next time you open the app.

To set it up: long-press Control Center → **Add a Control** → Point & Shoot. On the Lock
Screen: long-press → Customize → Lock Screen → tap the camera button → Point & Shoot.

## Shortcuts & the Action button

**Take a Photo** appears in the Shortcuts app, Siri ("Take a photo with Point & Shoot")
and Spotlight. To set up the Action button, go to Settings → Action Button → Shortcut →
Point & Shoot. The app opens straight to the camera.

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
  Camera/         CameraController (session, lenses, exposure, capture),
                  PreviewRenderer (Metal preview + peaking/zebras/histogram/live look),
                  PhotoCaptureProcessor, PhotoPlanner, LensZoom, ZeroDeveloper, CaptureSettings
  UI/             CameraView, ControlStrip + DialPanel, ScrubDial, Overlays, SettingsView
  Editor/         EditorView, EditSession, EditPipeline (Core Image graph), EditRecipe,
                  CropOverlay, MetalImageView, FilmModel + FilmPipeline (the Print look)
scripts/          deploy-iphone.sh; print-look.py (preview, fit and export the Print look)
  Library/        ShotStore (the in-app library: shots, trash, develop queue, retention),
                  ShotRenderer, ShotExporter, ShotArchive (import/zip), PhotoViewer,
                  LibraryView (grid + Trash), PhotoLibrary (export to Photos)
```

### Why it stays smooth

- Session and device work run on a dedicated queue. The main thread only touches UI.
- The preview is rendered by us: each frame goes to a `CAMetalLayer` through Core Image.
  If the GPU is busy, the frame is dropped rather than queued, so the viewfinder never
  lags behind.
- Edits are a lazy Core Image graph on a downsampled, pre-decoded source. Dragging a
  slider costs one GPU pass per frame. Full resolution is rendered only when you save.
