# Chromagraph Camera: reference spec (observed)

What Chromagraph Camera 1.6.1 (build 138) does, written down from a 2.5-minute screen
recording the owner made on 2026-11-14 (iPhone, iOS 18, silent). This file describes
behaviour only; it is not a feature list for Point & Shoot. Which parts we adopt is decided
separately.

Confidence markers:
- **Seen**: on screen, text quoted verbatim where readable.
- **Inferred**: strongly implied by the UI or its copy, but the flow wasn't shown.
- **Unknown**: not shown; listed so nobody fills it in from imagination.

---

## 1. The model in one paragraph

Chromagraph is a **RAW-first camera with its own library**.
- **Every shot is a RAW file stored inside the app**, together with a per-photo **grade**
  (Chromagraph's word for the edit settings). There are no filters or presets: one film
  rendering, and the grade adjusts it.
- **New shots start from the Default Grade.** You can change the default in Settings, or
  set it from any photo.
- **Photos reach the iOS photo library only on export:** one photo, a batch, or
  automatically after each shot (Auto Export).
- **Unkept RAWs are trashed after 30 days** unless Store New Photos Forever is on.
- **You can archive RAWs** to the photo library, or to a zip that carries each photo's
  settings, and import them back.

---

## 2. Screens and navigation

```
Camera ──thumbnail──▶ Viewer (single photo + filmstrip) ──grid──▶ Gallery grid
   ▲                    │  ├─ sliders ▶ Editor (Tone · Color · Texture · Crop)
   └──── camera button ─┘  ├─ export ▶ Photos
                           └─ gear ▶ Preferences (sheet; reachable from every screen)
```

- **Navigation:** the camera, viewer, grid and editor each have a camera button that
  returns to the camera, and a gear button that opens Preferences (Seen). Preferences is a
  sheet over the current screen, with **Done** at the top right.
- **Double-tap:** the owner reports that double-tapping (the viewfinder, presumably) opens
  Preferences. **Unknown** from the video: the recording only shows the gear button.
- **Look:** the UI is dark throughout. The accent is a muted tan/gold, used for the
  selected lens chip, toggles, slider fill, the export button, the editor's ✓ button and
  menu emphasis. Icons are thin SF Symbols.

---

## 3. Camera screen

### Layout (Seen)

- **Top bar**
  - Left: a flash button (shown slashed = off) and an aspect-ratio button (a rectangle icon).
  - Right: a self-timer button and the gear.
- **Viewfinder**
  - Sits between the bars, 3:4 at the Native aspect ratio, not full-bleed.
  - Rule-of-thirds grid (Grid on).
- **Overlays in the viewfinder**
  - A small **circle** in the centre, with a **chevron ^** above it and a **+** below it.
    - Inferred: the circle is the focus/exposure point and the ^ suggests dragging up
      for exposure.
    - Unknown: what dragging does. No tap-to-focus was shown.
  - **Level:** horizon marks `≻—   —≺` appear at the sides when the phone is near level. A
    short orange tick shows the tilt; the marks hide when the phone is far from level.
- **Lens chips:** `0.5×` `1×` `2×` pills, the selected one filled tan.
- **Bottom row:** last-shot thumbnail (left), a large white shutter ring (centre), a
  flip-camera button (right).
- **What's absent:** no mode picker (no video), no ISO, shutter, white balance or focus
  readouts, no histogram, no format pill. Very minimal.

### Zoom (Seen)

- **Zoom ruler**
  - Dragging along the lens chips replaces them with a horizontal **zoom ruler**: labelled
    ticks at 0.5, 1, 2 and 10, minor ticks between, and a thumb with the live value above
    it (e.g. "2.6×", "1.1×", "0.9×").
  - The thumb has small triangles above and below.
  - Range: 0.5–10×.
- **After release**
  - The ruler collapses back to chips. The chip nearest the value shows the custom value,
    highlighted: `0.9×` replaced `0.5×` while `1×` and `2×` stayed.
  - Tapping a chip jumps to that lens.
- **Readout units:** values are in the Lens Size Readout basis (§6.2). The video shows the
  default, Apple "Zoom Factor".

### Rotation (Seen)

When the phone turns to landscape, the top-bar and chip icons rotate. The UI stays laid
out in portrait.

### Capture (Inferred)

- **What a shot produces:** a RAW, which the gallery lists as "RAW Photo".
- **File format:** every gallery item is a RAW. Whether it's a DNG (Bayer or ProRAW) is
  **Unknown**.
- **EXIF line** shown in the viewer: `1/121 s | f/1.6 | ISO 40 | 6080 K`. That's shutter,
  aperture, ISO and white-balance Kelvin. The lens chip shows `≋ 1×`.

---

## 4. Gallery

### Grid (Seen)

- **Header:**
  - camera button (left);
  - a **Select** pill (centre);
  - a **trash** button and the gear (right).
  - Inferred: the trash button opens the 30-day trash.
- **Layout:**
  - **5 columns**, square thumbnails, no gaps, newest last (chronological, top to bottom).
  - Grouped by day under section titles ("Today").
  - Preferences mentions "the gallery's grid density", so the column count is configurable
    somewhere. **Unknown** where.
- **Thumbnails** show the graded rendering.
- **Select mode**
  - Header: **Cancel**, **Select All**, and a red **trash**.
  - Each cell gets a circle that becomes a ✓ when selected.
  - Footer toolbar:
    - a count ("1 photo");
    - **Export to Photos** (photo icon with a down arrow);
    - **Share**;
    - **⋯ More** (a menu: **Archive RAW…**, **Reset All Settings** (red), **Paste Grade**,
      **Copy Grade**).
- **Archive RAW…** opens an alert:
  - Title: "Archive 1 RAW Photo". Message: "Save original RAW files. If you choose zip, it
    also includes each photo's Chromagraph settings."
  - Buttons: **Save to Photo Library** · **Save or Share Zip…** · **Cancel**.
  - Saving to the library shows a bottom sheet: "**Saved to Photos** · 1 RAW photo was
    added to your Photo Library · [Done]".

### Viewer (Seen)

- **Header:** grid button, camera button, Share (left); trash, gear (right).
- **Photo:** fills the width, letterboxed vertically. Swipe left/right to page.
- **Below the photo**, left to right:
  - an optional **⌖ bracket icon**. It's shown on some photos and not others. **Unknown**
    meaning; possibly "this photo has a crop/aspect: show full frame".
  - an **edit** button (sliders icon), centre;
  - an **Export to Photos** button (tan circle), right.
- **Filmstrip:** a strip of thumbnails at the bottom. The current photo is outlined in
  white, and the strip scrolls in sync with paging.
- **Export:** the button turns into a spinner while rendering, then a small toast "**Saved
  to Photos.**" appears under the header for about 2 s.

---

## 5. Editor

Opened from the viewer's sliders button. The photo stays in the same place (Seen).

### Chrome

- **Header**
  - Left: **✓** (tan circle; leaves the editor, keeping changes), camera, Share.
  - Right: **⋯** and the gear.
- **Info row** under the header:
  - Left: the lens readout `≋ 1×` and an **ⓘ** button. Unknown: what ⓘ shows (presumably
    full metadata).
  - Right: a capsule with the date ("Nov 14, 2026 at 15:26") and the EXIF line.
- **⋯ menu:** **Copy Grade** · **Paste Grade** (disabled when nothing is copied) · **Set as
  Default Grade** (★) · **Reset This Image** (red, ↺).
  - "Reset" restores the Default Grade, per the Processing footer: "what is restored when
    using the editor's 'Reset' function".
- **Bottom tool bar:** **Tone** · **Color** · **Texture** · **Crop**, plus the tan **Export
  to Photos** button at the far right.
  - The active tool's icon is white; the others are dim.
  - While a change renders, the tool icon briefly becomes a spinner.
- **Sub-tabs:** each tool has sub-tab pills (white = active) above one or two labelled
  sliders. The label and value sit above the track, e.g. "Exposure −1.2".
  - A small dot on the track marks the default.

### Tools (Seen; ranges inferred from thumb positions)

| Tool | Sub-tab | Controls | Default | Range (inferred) |
|---|---|---|---|---|
| Tone | Exposure | Exposure (stops) | +0.0 (this photo: −1.2) | symmetric, ± a few stops |
| | Contrast | S-Curve Contrast | 0.00 | −1…+1 |
| | | Pivot | 0.35 | 0…1 |
| | Shadow/Highlight | Highlights | +0.00 | −1…+1 |
| | | Shadows | +0.00 | −1…+1 |
| Color | Balance | Cool/Warm | 0.00 | −1…+1 |
| | | Tint | 0.00 | −1…+1 |
| | Saturation | Saturation Nudge | +0.00 | −1…+1 |
| | | B&W (toggle) | off | |
| | Crossover | Crossover | +1.00 | 0…1 (default at max) |
| Texture | Grain | Amplitude | 0.00 | 0…1 (a tick near 0.25) |
| | | Grain Size | 0.25 | 0.25…1? (the thumb sits at the left at 0.25) |
| | | Force Pixel Size Grain (toggle) | off | |
| | Halation | Halation (toggle) | on | |
| | | Photochemical / Optical (segmented) | Photochemical | |
| Crop | n/a | Straighten slider (+0.0°), aspect label ("3:4"), rotate 90°, flip horizontal, flip vertical; Cancel / Done | | |

Notes:
- **Exposure on this photo:** it read **−1.2** while the default grade's exposure is +0.0.
  Either the owner had adjusted it, or Chromagraph auto-normalises exposure per shot.
  **Unknown**.
- **Crossover:** defaults to full strength. It's the film's colour crossover.
- **Halation:** "Photochemical" is film halation (the red-orange fringe). "Optical"
  presumably means lens bloom (a white glow).
- **Grain:** defaults to 0 amplitude; grain is opt-in.
- **Crop mode:** replaces the header with Cancel / rotate icon / Done. It shows corner
  handles, edge handles and thirds lines, and the straighten slider sits below. The image
  isn't cropped while editing.
- **Not present:** no colour mixer, no sharpening or clarity, no vignette, no presets.

---

## 6. Preferences

A sheet titled "Preferences", with three segments: **General · Camera · Processing**. It's
reachable from the gear on every screen. Each group has a short grey footer explaining it.
The footers are quoted where legible. The footer at the bottom reads "Chromagraph Camera
1.6.1 (138)".

### 6.1 General

| Section | Setting | Type | Value seen | Footer |
|---|---|---|---|---|
| RAW File Storage | **Store New Photos Forever** | toggle | **off** | "When disabled, photos are automatically moved to trash 30 days after being taken unless you manually tag them for retention." |
| Auto Export to Photo Library | **Auto Export** | toggle | on (the owner's setting; factory default unknown) | "Automatically renders every shot immediately after capture with your default grade and saves it to your Photo Library." |
| Location | **Geotag Photos** | toggle | on | "Records the location a photo was taken at into the RAW file, and carries it through to anything you export or share." |
| App Icon | Chromagraph (colour) / Monograph (mono) | radio list | Chromagraph | |
| Import from Photos | **Import RAW Photos…** | action (opens the system photo picker) | | "Choose RAW files from your Photo Library to copy into Chromagraph's library, leaving the originals where they are." |
| Import Archive | **Import Archive…** | action (file picker) | | "Brings back a zip made with Archive RAW… in the gallery, with each photo's Chromagraph settings. Photos already in your library are skipped." |
| Lock Screen | **Lock Screen Camera Setup…** | action (guide) | | "Learn how to set up access to Chromagraph from the Lock Screen, Action Button, or in Control Center." |
| Help | **Show Introduction** | action | | |
| | **Reset General Settings** | destructive action | | "Apply factory settings for RAW storage, auto export, geotagging, and the gallery's grid density." |

**Import RAW Photos…** opens the system picker (the PHPicker "Photos | Collections" sheet
with a "Private Access to Photos" banner). That means it **needs no Photos permission**.
A "Loading…" sheet shows while it copies.

### 6.2 Camera

| Section | Setting | Type | Options | Value seen | Footer |
|---|---|---|---|---|---|
| Aspect Ratio | **Aspect Ratio** | menu | Native (sensor) · Portrait (4:5) · Square (1:1) · Academy (1.37:1) · Stills 35 (3:2) · HD/UHD (16:9) · Cinema (flat) (1.85:1) · Cinema (anamorphic) (2.39:1) · Custom | Native (sensor) | "Sets the aspect ratio for the camera preview and for initial crop in the gallery, but the entire image is still always recorded and can be uncropped later. When an aspect ratio is set, the crop area will always use a fixed orientation: the one which allows for the most pixels to be included." |
| Default Lens | **Lens** | menu | Ultra Wide (0.5×) · Wide (1×) · Telephoto (2×) · Front · Custom | Wide (1×) | "The lens (or custom setting) the camera starts on each time it opens." |
| Front Camera | **Mirror Front Camera** | toggle | | off | "Saves front camera photos as they appear in the viewfinder (mirrored), instead of as others see you." |
| Lens Size Readout | **Basis** | menu | Super8 · Super16 · Micro-Four Thirds · Super35 / APS-C · VistaVision / Stills 35 · 5-perf 65mm · 15-perf 65mm · Apple "Zoom Factor" · Distance-To-Width Ratio · Field of View (°) · Custom | Apple "Zoom Factor" | "Selects how the angle-of-view is displayed throughout the app. Can be virtual focal length, AoV (in degrees), Apple 'zoom factor', or distance-to-width ratio. Calculated based on frame width (not height or diagonal)." |
| Viewfinder | **Grid** | toggle | | on | (an untranslated key shows: "preferences.camera.viewfinderGuidesFooter") |
| | **Level** | toggle | | on | |
| Scanning | **Scan QR Codes** | toggle | | on | "Reads QR codes (and ordinary barcodes) in the viewfinder and allows you to open links they point to." |
| Sound | **Mute Shutter Sound** | toggle | | on | "Silences the shutter click on capture (if that is allowed in the current region)." |
| | **Reset Camera Settings** | destructive action | | | "Apply factory settings for aspect ratio, lens readout, exposure limit, barcode scanning, and sound." |

The reset footer mentions an **"exposure limit"** setting that isn't on this screen.
**Unknown**; possibly a max-shutter or max-ISO cap that appears only on some devices or
in a later version.

Format names in the Basis list are film/sensor gates. A "virtual focal length" is the
focal length that would give the same horizontal angle of view on that gate.

### 6.3 Processing

**Export Options**

| Setting | Type | Options | Value seen | Footer |
|---|---|---|---|---|
| File format | segmented | JPEG · HEIF | HEIF | "File format for all exports." |
| **Export Size** | menu | 1,920 px · 2,880 px · 3,840 px · Actual Size · Custom | 2,880 px | "The length of the longest side of exported images. Actual Size keeps each photo's own (cropped) resolution. Custom sizes run from 720 to 6144 px." |
| **Export Quality** | slider | 0–100% | 100% | "Compression quality for exports." |
| Reset to Defaults | action (dimmed when already at defaults) | | | |

**Default Grade Settings**

- Three collapsible rows, each with a summary on the right:
  - **Tone** "+0.0 Stops · Contrast 0.00"
  - **Color** "Color · Sat +0.00"
  - **Texture** "Grain 0.00 · Photochemical"
- Expanding a row shows the **same controls as the editor**:
  - Tone: Exposure, S-Curve Contrast, Pivot, Highlights, Shadows.
  - Color: Cool/Warm, Tint, Saturation Nudge, B&W, Crossover.
  - Texture: Grain Amplitude, Grain Size, Force Pixel Size Grain, Halation and
    Photochemical/Optical.
- **Reset to Defaults** sits under the rows.
- Footer: "The settings every new photo starts with, and what is restored when using the
  editor's 'Reset' function. Changing this does not affect existing shots."

**Caches**

| Setting | Type | Value seen | Footer |
|---|---|---|---|
| **Cache Proxies to Disk** | toggle | on | "Speeds up re-opening the same photo (or the same folder on next launch) by keeping the fast-quality preview bytes on disk. Off = every visit re-decodes from the RAW file (still fast, just not instant). Cache is capped at ~1 GB and self-trims oldest entries." |
| **Clear All Caches** | destructive action | | "Wipes all cached data. Nothing is permanently lost -- everything re-decodes from the RAW files on the next visit." |

The cache footer mentions "the same folder", which hints that the library may have folders
or albums. **Unknown**.

---

## 7. Flows

1. **Shoot**
   - Tap the shutter. The RAW is stored in the app and appears in the gallery with the
     Default Grade, and the thumbnail updates.
   - With Auto Export on, a rendered JPEG/HEIF (default grade, export size and quality) is
     also saved to Photos right away. With it off, nothing reaches Photos.
2. **Review:** tap the thumbnail to open the viewer on the newest shot. Swipe or use the
   filmstrip to move between photos. The grid button shows all shots.
3. **Grade**
   - Open the editor with the sliders button and change tools and sub-tabs. Edits apply live
     and are stored per photo, non-destructively.
   - ✓ leaves the editor.
   - The ⋯ menu copies or pastes a grade, makes this photo's grade the default for future
     shots, or resets the photo to the default grade.
4. **Export one photo:** tap the tan button in the viewer or editor. It renders with the
   photo's grade, export format, size and quality, saves to Photos, and shows the toast
   "Saved to Photos." The original stays in the app.
5. **Batch:** in the grid, tap Select, pick photos (or Select All), then:
   - Export to Photos;
   - Share;
   - ⋯ → Copy Grade, Paste Grade (applies to all selected), Reset All Settings (back to
     the default grade), or Archive RAW…;
   - the red trash deletes them.
6. **Archive**
   - Archive RAW… → Save to Photo Library adds the *original RAW files* to Photos, with no
     settings.
   - Save or Share Zip… makes a zip of RAWs plus each photo's settings, via the share sheet
     or Files.
   - Import Archive… restores it, skipping photos already in the library (so photos have
     stable identity).
7. **Import:** Import RAW Photos… opens the system picker; the chosen RAWs are *copied* into
   the library and the originals stay in Photos. They then grade like native shots.
8. **Retention**
   - With Store New Photos Forever off, each photo moves to the trash 30 days after it was
     taken unless it's "tagged for retention".
   - **Unknown:** the tagging UI, which wasn't shown (maybe a long-press or the viewer's ⓘ),
     and how long trash keeps items or how to empty it.
   - The grid's trash button is probably the trash view.
9. **Delete:** trash in the viewer or the Select bar. Inferred: deleting moves to the in-app
   trash, not straight to permanent deletion.

---

## 8. Things worth noting for Point & Shoot

- **No Photos permission needed for the core loop.**
  - Storage is in-app, and export only needs *add* access (the system asks once).
  - Import goes through the system picker, which needs no permission.
  - This sidesteps the whole Limited/Full access problem (#19–#30).
- **One look, many grades.**
  - Chromagraph's distinctiveness comes from one strong film rendering plus a *small* grade
    vocabulary: exposure, S-curve contrast with pivot, shadows/highlights, cool/warm and
    tint, saturation, B&W, crossover, grain, halation type.
  - The Default Grade is the "preset".
- **The aspect ratio is a crop, never a capture limit.** The full sensor is always recorded,
  and the crop can be undone in the gallery.
- **Exports are sized.** The 2,880 px longest side is a deliberate default: smaller files,
  and grain looks right at that size.
- **Settings copy is excellent.** Every option explains itself in one or two sentences,
  including what isn't affected ("Changing this does not affect existing shots").
- **Polish details:**
  - the zoom ruler on the lens chips;
  - a custom zoom value becomes a chip;
  - level marks only near level;
  - a spinner in place of the tool icon while rendering;
  - dimmed Reset when already at defaults.

## 9. Open questions (couldn't be answered from the video)

- Is the RAW a Bayer DNG or ProRAW? Does Chromagraph do any multi-frame merging?
- What do the viewfinder circle, ^ and + do (drag to expose, tap to focus, AE/AF lock)?
- Where are the double-tap and other viewfinder gestures?
- What does the "tag for retention" UI look like? How long does trash keep items, and can
  it be emptied?
- Where is the grid density setting? What do folders/albums look like (mentioned by the
  cache footer)?
- Is there an auto exposure normalisation per shot (the −1.2 exposure on the sample photo)?
- What is the "exposure limit" camera setting?
- What does the viewer's ⌖ bracket icon do, and what does the ⓘ panel show?
- What does the Show Introduction tour contain?
- Is there video? None was seen; it seems to be stills-only.
