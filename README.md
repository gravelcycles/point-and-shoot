# Point & Shoot

A camera for people who think in stops and shutter angles. You get a real camera when you
want one and a point-and-shoot when you don't, plus a Snapseed-style editor that never
destroys your originals.

Native SwiftUI + AVFoundation + Core Image on Metal. iPhone, iOS 17+.

## Photo

| Control | What it does |
|---|---|
| **RAW** (`RAW` badge) | Off / **RAW** (Bayer DNG straight off the sensor, with no Apple pipeline) / **ProRAW** (Apple's linear DNG, with fusion) |
| **RAW + HEIF** | Saves the DNG and a processed HEIF/JPEG as one pair in Photos, or RAW only |
| **Processing** (badge) | **Apple**: Deep Fusion / Smart HDR, full pipeline · **Balanced** · **Natural**: lightest ISP touch, less HDR flattening and smoothing · **Zero**: no computational photography. Shoots Bayer RAW and develops it in-app with a neutral, film-like curve (no local tone mapping, no luminance NR, no oversharpening). You can keep the DNG too. |
| **Format** | HEIF or JPEG |
| **Resolution** | 12 MP or the sensor max (48 MP on Pro main cameras) |
| Flash, self-timer | Off/Auto/On; 3s/10s |

Responsive capture and zero shutter lag are turned on wherever the hardware supports them.

## Exposure, like a camera body

- **P / S / M**: Auto with EV compensation, **shutter priority** (shutter held, ISO
  floats against the meter), and full **manual** with a light-meter readout.
- **Command-dial scrubbers** for ISO (⅓ stops), shutter (⅓ stops), EV, white balance in
  Kelvin, and manual focus. Each detent clicks with a haptic, you can fling to coast, and
  **A** returns that control to auto.
- **Tap** to focus and meter. **Hold** to lock AE/AF. **Pinch** to zoom.
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
- Audio meter, recording clock

## Assists

Focus peaking (in four colors), zebras with an adjustable threshold, a live RGB + luma
histogram, a horizon level, a rule-of-thirds grid, and frame lines (1:1, 4:5, 16:9, 1.85,
2.39) that follow how you're holding the phone. All of them are drawn on the GPU from the
same frames being recorded.

The **volume buttons** fire the shutter. On iPhone 16, **Camera Control** adjusts zoom and
exposure.

## Editor (Snapseed-style)

Tap the thumbnail to open the Roll, then tap a photo.

- **Swipe ↕ on the photo** to choose a parameter and **↔** to dial it in. A pill shows the
  value, and a haptic ticks when you cross zero. Hold ◧ to compare with the original.
- **Looks**: Natural, Warm 400, Skin, Cool Air, Cine, Chrome, Faded, Punch, Mono 400, Noir,
  Silver, with live thumbnails
- **Tune**: exposure, contrast, highlights, shadows, whites, blacks, saturation, vibrance,
  warmth, tint
- **Details**: structure, sharpening, fade, grain, vignette
- **Crop**: free or locked aspect, straighten dial, rotate, flip
- **RAW**: if the photo has a DNG, the edit develops from the sensor data. You get real
  white balance and exposure, plus Apple's noise reduction and local tone mapping as
  sliders you can turn down to zero.
- **Non-destructive**: edits are saved as Photos adjustment data. Reopen one to keep
  tweaking, or *Revert to Original* in the editor or in Photos. *Save as Copy* makes a new
  HEIF instead.

## Build

1. Open `PointAndShoot.xcodeproj` in **Xcode 16 or newer**.
2. Select the *PointAndShoot* target → *Signing & Capabilities* → choose your team (and
   change the bundle ID if you need to).
3. Run on a real iPhone. The simulator has no camera.

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
                  CropOverlay, MetalImageView
  Library/        LibraryView (roll grid), PhotoLibrary (save/fetch helpers)
```

### Why it stays smooth

- Session and device work run on a dedicated queue. The main thread only touches UI.
- The preview is rendered by us: each frame goes to a `CAMetalLayer` through Core Image.
  If the GPU is busy, the frame is dropped rather than queued, so the viewfinder never
  lags behind.
- Edits are a lazy Core Image graph on a downsampled, pre-decoded source. Dragging a
  slider costs one GPU pass per frame. Full resolution is rendered only when you save.
