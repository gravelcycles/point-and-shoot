#!/usr/bin/env python3
"""Phromagraph: a film stock fitted to Chromagraph Camera's own renders of its own RAWs.

Chromagraph (the reference app) shoots ProRAW and exports a HEIC. Given a folder of its
DNGs + HEICs (+ its settings.json export), this develops every DNG the way Point & Shoot
does under a film look (CIRAWFilter, scripts/raw-develop.swift; macOS only), aligns it to
the HEIC (pixel-exact; a digital-zoom crop is found by feature matching), and fits the
film model (scripts/filmmodel.py) to the pairs. The result is scripts/phromagraph-stock.json,
which print-look.py export-swift writes into FilmStock+Stocks.swift.

  phromagraph.py prep DIR [--work W]      develop, align, sample (cached in W)
  phromagraph.py fit [--work W]           fit, write scripts/phromagraph-stock.json
  phromagraph.py measure DIR [--work W]   viewfinder vs the fixed develop exposure; grain
  phromagraph.py sheet OUT.jpg [--work W] [--only a,b]
                                          neutral develop | Print | Phromagraph | Chromagraph
  phromagraph.py grain DIR [--work W] [--ev 1.86] [--assign FILE=AMP/SIZE ...]
                                          Chromagraph's grain vs ours, on one DNG and its exports
                                          at several grain settings (identified from the pixels
                                          unless --assign says): strength, spectrum, colour and
                                          strength by brightness. Renders ours through the app's
                                          own FilmPipeline.swift (scripts/film-render, macOS)
  phromagraph.py develop-ev RAW.dng EXPORT.heic [...] [--work W]
                                          the develop exposure (EV over the app's neutral
                                          CIRAWFilter develop) that makes Phromagraph match
                                          each export of that RAW: how bright Chromagraph
                                          (or anything) renders this file

What the fit covers: tone (grey, slope, shoulder, white, floor → print curve), printer
lights, crossover, the 3×3 layer sensitivity, dye crosstalk, split toning and hue
protection, plus one develop exposure shared by every pair. Shots with Chromagraph's
Shadows/Highlights/colour sliders moved are left out; its exposure slider is applied.
Halation and grain are measured separately (`measure`, and docs/film-looks.md §5½).

Needs: numpy scipy pillow opencv-python-headless pillow-heif; swiftc (Xcode).
"""
from __future__ import annotations

import argparse
import copy
import json
import os
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import filmlooks as FL  # noqa: E402
import filmmodel as F  # noqa: E402

PRINT = os.path.join(HERE, "print-stock.json")
OUT = os.path.join(HERE, "phromagraph-stock.json")
WORK = os.path.join(os.environ.get("TMPDIR", "/tmp"), "phromagraph-work")
LUM709 = np.array([0.2126, 0.7152, 0.0722])
LUM2020 = np.array([0.2627, 0.6780, 0.0593])
SRGB_TO_P3 = np.array([[0.822462, 0.177538, 0.0], [0.033194, 0.966806, 0.0], [0.017083, 0.072397, 0.910520]])
P3_TO_SRGB = np.linalg.inv(SRGB_TO_P3)
P3_TO_XYZ = np.array([[0.4865709, 0.2656677, 0.1982173], [0.2289746, 0.6917385, 0.0792869],
                      [0.0, 0.0451134, 1.0439444]])
OK1 = np.array([[0.8189330101, 0.3618667424, -0.1288597137], [0.0329845436, 0.9293118715, 0.0361456387],
                [0.0482003018, 0.2643662691, 0.6338517070]])
OK2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468], [1.9779984951, -2.4285922050, 0.4505937099],
                [0.0259040371, 0.7827717662, -0.8086757660]])

# Measured on the 2026-11-17 set (see `measure` and docs/film-looks.md §5½); not fitted by `fit`.
HALATION = [0.05, 0.012, 0.0]            # Chromagraph shows no measurable red glow; a third of Print's
HALATION_SPREAD = {"threshold": 1.0, "boost": 1.0, "display_threshold": 0.75, "display_boost": 2.0,
                   "sigmas": [2.0, 6.0], "weights": [0.55, 0.45]}
GRAIN = dict(grainDensity=0.017, grainChroma=0.15, grain_size=0.17)   # = Chromagraph grain 1.25 at slider 50


def oklab_srgb(rgb):
    return np.cbrt(np.maximum(rgb @ SRGB_TO_P3.T @ P3_TO_XYZ.T @ OK1.T, 0)) @ OK2.T


# --- inputs ----------------------------------------------------------------------------

def read_f32(p):
    b = open(p, "rb").read()
    w, h = np.frombuffer(b[:8], "<u4")
    return np.nan_to_num(np.frombuffer(b[8:], "<f4").reshape(h, w, 3).astype(np.float64), nan=0, posinf=0, neginf=0)


def read_heic(p):
    """Chromagraph's HEIC → linear sRGB. Its nclx colour box is 'unspecified', which iOS and
    macOS display as sRGB."""
    import pillow_heif
    from PIL import Image
    pillow_heif.register_heif_opener()
    return F.decode_srgb(np.asarray(Image.open(p).convert("RGB")).astype(np.float64) / 255)


def created(path):
    return subprocess.run(["mdls", "-raw", "-name", "kMDItemContentCreationDate", path],
                          capture_output=True, text=True).stdout.strip()


def list_pairs(d):
    """[(name, dng, heic, chromagraph settings)], matched by capture time (Chromagraph names
    its DNGs cgc_NNNNN and Photos names the HEICs IMG_NNNN)."""
    st = json.load(open(os.path.join(d, "settings.json")))
    by_date = {created(os.path.join(d, f)): f for f in os.listdir(d) if f.lower().endswith((".heic", ".heif", ".jpg"))}
    out = []
    for shot in st["shots"]:
        dng = os.path.join(d, shot["filename"])
        ref = by_date.get(created(dng))
        if ref:
            out.append((os.path.splitext(shot["filename"])[0], dng, os.path.join(d, ref), shot["settings"]))
        else:
            print("no export found for", shot["filename"])
    return out


def develop(dngs, out_dir, scale, apple=False):
    exe = os.path.join(WORK_DIR, "raw-develop")
    if not os.path.exists(exe):
        subprocess.run(["swiftc", "-O", "-o", exe, os.path.join(HERE, "raw-develop.swift")], check=True)
    subprocess.run([exe] + (["--apple"] if apple else []) + [out_dir, str(scale)] + dngs, check=True)


def prep(d):
    import cv2
    pairs = list_pairs(d)
    os.makedirs(WORK_DIR, exist_ok=True)
    w = max(read_heic(pairs[0][2]).shape[:2])
    develop([p[1] for p in pairs], os.path.join(WORK_DIR, "dev"), w / 4032)
    develop([p[1] for p in pairs], os.path.join(WORK_DIR, "apple"), 0.25, apple=True)
    meta = {}
    rng = np.random.default_rng(3)
    base = F.load_stock(PRINT)
    for name, dng, ref_path, s in pairs:
        lin, ref = read_f32(os.path.join(WORK_DIR, "dev", name + ".f32")), read_heic(ref_path)
        lin, mask = _align(lin, ref)
        np.savez_compressed(os.path.join(WORK_DIR, f"pair_{name}.npz"), lin=lin.astype(np.float32),
                            ref=ref.astype(np.float32), mask=mask)
        # Samples: blurred (grain, noise), 1/3 size, away from edges, clipping and halation.
        k = 3
        bl = lambda a: cv2.resize(cv2.GaussianBlur(a.astype(np.float32), (0, 0), 2.5), None, fx=1 / k, fy=1 / k,
                                  interpolation=cv2.INTER_AREA).astype(np.float64)
        l, r = bl(lin), bl(ref)
        mm = cv2.erode((cv2.resize(mask.astype(np.uint8), (l.shape[1], l.shape[0]),
                                   interpolation=cv2.INTER_NEAREST) > 0).astype(np.uint8), np.ones((9, 9), np.uint8)) > 0
        y = l @ LUM709 * 2 ** s["exposureStops"]
        norm = l * 2 ** s["exposureStops"] * 0.126 / max(np.median(y[mm]), 1e-6)
        hot = (np.abs(F.halation(norm, base, 2.0) - norm) / np.maximum(norm, 1e-4)).max(-1) > 0.04
        ry = F.encode_srgb(r @ LUM709).astype(np.float32)
        gm = np.hypot(cv2.Sobel(ry, cv2.CV_32F, 1, 0), cv2.Sobel(ry, cv2.CV_32F, 0, 1))
        ok = mm & ~hot & (gm < 0.12) & (r.max(-1) < 0.995) & (y > 1e-6)
        idx = np.flatnonzero(ok)
        yb = np.clip((ry.ravel()[idx] * 10).astype(int), 0, 9)   # stratified by brightness
        pick = np.concatenate([rng.choice(idx[yb == b], min((yb == b).sum(), 900), replace=False)
                               for b in range(10) if (yb == b).sum()])
        np.savez_compressed(os.path.join(WORK_DIR, f"samples_{name}.npz"), lin=l.reshape(-1, 3)[pick],
                            ref=r.reshape(-1, 3)[pick])
        meta[name] = s
        print(f"{name}: {len(pick)} samples")
    json.dump(meta, open(os.path.join(WORK_DIR, "meta.json"), "w"), indent=1)


def _align(lin, ref):
    """Similarity transform from SIFT matches; identity when the frames already line up."""
    import cv2

    def gray(x):
        g = F.encode_srgb(np.clip(x @ LUM709 / max(np.percentile(x, 99), 1e-6), 0, 1))
        return cv2.createCLAHE(2.0, (8, 8)).apply((g * 255).astype(np.uint8))
    sift = cv2.SIFT_create(4000)
    k1, d1 = sift.detectAndCompute(cv2.resize(gray(lin), None, fx=.5, fy=.5), None)
    k2, d2 = sift.detectAndCompute(cv2.resize(gray(ref), None, fx=.5, fy=.5), None)
    good = [a for a, b in cv2.BFMatcher().knnMatch(d1, d2, k=2) if a.distance < 0.7 * b.distance]
    p1 = np.float32([k1[a.queryIdx].pt for a in good]) * 2
    p2 = np.float32([k2[a.trainIdx].pt for a in good]) * 2
    A, _ = cv2.estimateAffinePartial2D(p1, p2, method=cv2.RANSAC, ransacReprojThreshold=2.0)
    h, w = ref.shape[:2]
    out = cv2.warpAffine(lin.astype(np.float32), A, (w, h), flags=cv2.INTER_AREA).astype(np.float64)
    mask = cv2.warpAffine(np.ones(lin.shape[:2], np.float32), A, (w, h)) > 0.999
    print(f"  aligned: scale {np.hypot(A[0, 0], A[1, 0]):.4f}, shift ({A[0, 2]:.1f}, {A[1, 2]:.1f}), {len(good)} matches")
    return out, mask


def load_work(fit_only=True):
    meta = json.load(open(os.path.join(WORK_DIR, "meta.json")))
    out = []
    for name, s in meta.items():
        moved = any(s.get(k, 0) != v for k, v in (("shadows", 0), ("highlights", 0), ("colorTemp", 0), ("tint", 0),
                                                    ("saturation", 1), ("crossover", 1), ("atanContrast", 0)))
        if fit_only and (moved or s.get("blackAndWhite")):
            print(f"  {name}: sliders moved, left out of the fit")
            continue
        z = np.load(os.path.join(WORK_DIR, f"samples_{name}.npz"))
        out.append((name, z["lin"] * 2 ** s["exposureStops"], oklab_srgb(z["ref"]), s))
    return out


# --- model -----------------------------------------------------------------------------

KNOBS = (["develop_ev", "grey", "slope", "shoulder", "white", "floor", "printer_r", "printer_g", "printer_b",
          "crossover_r", "crossover_b"] + [f"sens{i}" for i in range(9)] +
         ["crosstalk", "shadow_r", "shadow_b", "hilite_r", "hilite_b", "huePreserve"])
LO = [-1, 0.05, 0.8, 1.2, 0.6, 0.0] + [-0.4] * 3 + [-0.5] * 2 + [-1.5] * 9 + [0.0] + [-0.15] * 4 + [0.0]
HI = [4, 0.3, 2.5, 5.0, 1.0, 0.08] + [0.4] * 3 + [0.5] * 2 + [2.5] * 9 + [1.5] + [0.15] * 4 + [1.0]


def stock_from(p, base):
    """Parameter vector → stock. `exposure` holds the develop exposure while fitting."""
    st = copy.deepcopy(base)
    ev, grey, slope, shoulder, white, floor = p[:6]
    Y, w = FL.tone_target(dict(grey=grey, slope=slope, shoulder=shoulder, white=white, floor=floor), white)
    c = FL.derive_print_curve(base["negative"][1], Y, w)
    st.update(exposure=float(ev), print=[c, copy.deepcopy(c), copy.deepcopy(c)], display=[w, 0, 0, 0, w, 0, 0, 0, w],
              printer=[float(v) for v in p[6:9]], crossover=[float(p[9]), 0.0, float(p[10])],
              sensitivity=[float(v) for v in p[11:20]], huePreserve=float(p[25]))
    X = np.eye(3) + p[20] * (np.array(base["crosstalk"]).reshape(3, 3) - np.eye(3))
    st["crosstalk"] = [float(v) for v in X.ravel()]

    def neutral(r, b):   # luminance-neutral tint (filmlooks.build_stock does the same)
        t = np.array([r, 0.0, b])
        return [float(v) for v in t - t @ F.LUM_P3]
    st["shadowTint"], st["highlightTint"] = neutral(*p[21:23]), neutral(*p[23:25])
    return st


def render_samples(st, lin):
    x = np.clip(lin * 2 ** st.get("exposure", 0) @ F.SRGB_TO_REC2020.T, 0, F.SHAPER_SCALE)
    enc = F.split_tone(F.encode_srgb(F.display(F.negative_density(x, st), st)), st)
    return np.clip(F.decode_srgb(enc) @ P3_TO_SRGB.T, 0, 1)


def report(st, data, label):
    errs = []
    for name, lin, lab, _ in data:
        d = oklab_srgb(render_samples(st, lin)) - lab
        errs.append(np.linalg.norm(d, axis=-1).mean())
        print(f"  {name[:12]:12s} ΔE {errs[-1]:.4f}  bias L {d[:, 0].mean():+.3f} a {d[:, 1].mean():+.3f} b {d[:, 2].mean():+.3f}")
    print(f"{label}: mean ΔE (Oklab) {np.mean(errs):.4f}")
    return float(np.mean(errs))


def fit(out_path):
    from scipy.optimize import least_squares
    base = F.load_stock(PRINT)
    data = load_work()
    pr = dict(base)
    r0 = least_squares(lambda q: np.concatenate([(oklab_srgb(render_samples(dict(pr, exposure=q[0]), lin)) - lab).ravel()
                                                 for _, lin, lab, _ in data]), [1.5])
    before = report(dict(pr, exposure=float(r0.x[0])), data, f"Print (develop +{r0.x[0]:.2f} EV)")
    p0 = np.clip([r0.x[0], 0.115, 1.44, 2.73, base["display"][0], 0.0] + list(base["printer"]) +
                 [base["crossover"][0], base["crossover"][2]] + list(base["sensitivity"]) + [1.0, 0, 0, 0, 0, 0.0],
                 np.array(LO) + 1e-6, np.array(HI) - 1e-6)

    def resid(p):
        st = stock_from(p, base)
        return np.concatenate([((oklab_srgb(render_samples(st, lin)) - lab) * [1, 1.3, 1.3]).ravel()
                               for _, lin, lab, _ in data])
    r = least_squares(resid, p0, bounds=(LO, HI), x_scale="jac", max_nfev=300, diff_step=1e-3, verbose=1)
    for k, v in zip(KNOBS, r.x):
        print(f"  {k:12s} {v:+.4f}")
    st = stock_from(r.x, base)
    after = report(st, data, "Phromagraph")
    ev = st["exposure"]
    # The app develops a film look's RAW at a fixed EditRecipe.filmRAWExposure (+1.86, this
    # fit's develop exposure) rather than a stock exposure, which would also scale the
    # viewfinder's display-referred input and clip it.
    st["exposure"] = 0.0
    st["huePreserve"] = round(st["huePreserve"], 3) if st["huePreserve"] > 0.01 else 0.0
    st.update(halation=HALATION, halation_spread=HALATION_SPREAD, **GRAIN)
    st["name"] = "Phromagraph"
    st["about"] = (f"Fitted to Chromagraph Camera's own renders of {len(data)} of its ProRAW captures (iPhone 12 Pro, "
                   f"Chromagraph 1.6.1): mean ΔE (Oklab) {after:.4f}, against {before:.4f} for Print. Vision3 5219 "
                   f"negative; tone, printer lights, crossover, layer sensitivity, dye crosstalk and split toning fitted "
                   f"(scripts/phromagraph.py). Chromagraph develops {ev:+.2f} EV over a neutral CIRAWFilter develop; "
                   f"the app develops film looks' RAWs at that (EditRecipe.filmRAWExposure), so the stock's exposure is 0. Halation and grain measured "
                   f"separately (grain = Chromagraph grain 1.25 at slider 50).")
    st = json.loads(json.dumps(st, default=float))
    for c in st["print"]:
        c["x"] = [round(v, 5) for v in c["x"]]
        c["y"] = [round(v, 5) for v in c["y"]]
    for k in ("sensitivity", "crosstalk", "printer", "crossover", "shadowTint", "highlightTint", "display"):
        st[k] = [round(float(v), 5) for v in st[k]]
    with open(out_path, "w") as f:
        json.dump(st, f, indent=1)
    print("wrote", os.path.relpath(out_path), "- now run: scripts/print-look.py export-swift && scripts/print-look.py parity")


# --- measure ---------------------------------------------------------------------------

def measure(d):
    """How far the viewfinder (Apple's rendering, un-rendered) lands from the fixed develop
    exposure (Chromagraph's, EditRecipe.filmRAWExposure) per shot, and the grain
    Chromagraph adds (high-pass σ of encoded luminance in flat areas, /255)."""
    import cv2
    st = F.load_stock(OUT) if os.path.exists(OUT) else None
    ev_dev = None
    if st:
        about = st.get("about", "")
        ev_dev = float(about.split("Chromagraph develops ")[1].split(" EV")[0]) if "Chromagraph develops " in about else None

    def key(rgb, disp):   # FilmLUT.sceneKey on a 48 px sample
        s = 48 / max(rgb.shape[:2])
        rgb = cv2.resize(rgb.astype(np.float32), (max(1, round(rgb.shape[1] * s)), max(1, round(rgb.shape[0] * s))),
                         interpolation=cv2.INTER_AREA).astype(np.float64)
        c = np.clip(rgb.reshape(-1, 3) @ F.SRGB_TO_REC2020.T, 0, 16)
        if disp:
            c = F.scene_from_display_rgb(c)
        return float(np.exp(np.mean(np.log(np.maximum(c @ LUM2020, 1e-3)))))
    print("exposure: Apple's rendering stands in for the viewfinder")
    gaps = []
    for name, dng, ref, s in list_pairs(d):
        vf = key(np.clip(read_f32(os.path.join(WORK_DIR, "apple", name + ".f32")), 0, 1), True)
        raw = key(read_f32(os.path.join(WORK_DIR, "dev", name + ".f32")), False)
        rfe = np.log2(vf / raw)        # the develop exposure that would match the viewfinder
        line = f"  {name[:12]:12s} viewfinder ≙ develop {rfe:+.2f} EV"
        if ev_dev is not None:
            gap = rfe - (ev_dev + s["exposureStops"])
            line += f"   viewfinder vs photo {gap:+.2f} EV"
            if s["exposureStops"] == 0:
                gaps.append(gap)
        print(line)
    if gaps:
        print(f"  median {np.median(gaps):+.2f} EV, sd {np.std(gaps):.2f}")
    print("grain (σ /255 by encoded brightness; lag-1 autocorrelation):")
    for name, dng, ref, s in list_pairs(d):
        y = (F.encode_srgb(read_heic(ref)) @ LUM709).astype(np.float32)
        lo = cv2.GaussianBlur(y, (0, 0), 4)
        hp = y - lo
        g6 = cv2.GaussianBlur(y, (0, 0), 6)
        gm = np.hypot(cv2.Sobel(g6, cv2.CV_32F, 1, 0), cv2.Sobel(g6, cv2.CV_32F, 0, 1))
        loc = np.sqrt(cv2.GaussianBlur(hp * hp, (0, 0), 8))
        flat = (gm < 0.004) & (loc < np.percentile(loc, 40))
        cells = []
        for a in (0.15, 0.3, 0.45, 0.6):
            m = flat & (lo >= a) & (lo < a + 0.15)
            if m.sum() > 3000:
                v = hp[m]
                cells.append(f"{a:.2f}:{1.4826 * np.median(np.abs(v - np.median(v))) * 255:4.2f}")
        m = flat[:, :-1] & flat[:, 1:] & (lo[:, :-1] > 0.2) & (lo[:, :-1] < 0.8)
        ac = np.corrcoef(hp[:, :-1][m], hp[:, 1:][m])[0, 1]
        print(f"  {name[:12]:12s} grain {s['grainAmplitude']:.2f}  " + " ".join(cells) + f"  ac1 {ac:.2f}")


# --- sheet -----------------------------------------------------------------------------

def sheet(out, only=None):
    import cv2
    from PIL import Image
    pr = F.load_stock(PRINT)
    ph = F.load_stock(OUT)
    meta = json.load(open(os.path.join(WORK_DIR, "meta.json")))
    rows = []
    for name, s in meta.items():
        if only and not any(name.startswith(o) for o in only):
            continue
        z = np.load(os.path.join(WORK_DIR, f"pair_{name}.npz"))
        k = 0.2
        lin = cv2.resize(z["lin"], None, fx=k, fy=k, interpolation=cv2.INTER_AREA).astype(np.float64) * 2 ** s["exposureStops"]
        ref = cv2.resize(z["ref"], None, fx=k, fy=k, interpolation=cv2.INTER_AREA).astype(np.float64)
        about = ph.get("about", "")
        ev = float(about.split("Chromagraph develops ")[1].split(" EV")[0]) if "Chromagraph develops " in about else 1.8
        x = lin * 2 ** ev
        tiles = [np.clip(x * 0.5 / (1 + 0.5 * x), 0, 1)] + \
                [np.clip(F.render(x, stk, grain_amount=0) @ P3_TO_SRGB.T, 0, 1) for stk in (pr, ph)] + [ref]
        rows.append(np.concatenate([np.pad(F.encode_srgb(t), ((0, 0), (0, 4), (0, 0))) for t in tiles], 1))
    w = max(r.shape[1] for r in rows)
    img = np.concatenate([np.pad(r, ((0, 4), (0, w - r.shape[1]), (0, 0))) for r in rows], 0)
    Image.fromarray((img * 255 + 0.5).astype(np.uint8)).save(out, quality=90)
    print("wrote", out, "(columns: neutral develop | Print | Phromagraph | Chromagraph)")


def develop_ev(dng, exports):
    """Fits one exposure per export of the same RAW, with Phromagraph's look."""
    import cv2
    from scipy.optimize import least_squares
    os.makedirs(WORK_DIR, exist_ok=True)
    st = F.load_stock(OUT)
    name = os.path.splitext(os.path.basename(dng))[0]
    first = read_heic(exports[0])
    develop([dng], os.path.join(WORK_DIR, "ev"), max(first.shape[:2]) / 4032)
    lin0 = read_f32(os.path.join(WORK_DIR, "ev", name + ".f32"))
    for ref_path in exports:
        ref = read_heic(ref_path)
        lin, mask = _align(lin0, ref)
        k = 3
        bl = lambda a: cv2.resize(cv2.GaussianBlur(a.astype(np.float32), (0, 0), 2.5), None, fx=1 / k, fy=1 / k,
                                  interpolation=cv2.INTER_AREA).astype(np.float64)
        l, r = bl(lin), bl(ref)
        mm = cv2.resize(mask.astype(np.uint8), (l.shape[1], l.shape[0]), interpolation=cv2.INTER_NEAREST) > 0
        ok = mm & (r.max(-1) < 0.98) & (l @ LUM709 > 1e-5)
        idx = np.random.default_rng(0).choice(np.flatnonzero(ok), min(20000, int(ok.sum())), replace=False)
        lp, lab = l.reshape(-1, 3)[idx], oklab_srgb(r.reshape(-1, 3)[idx])
        fitres = least_squares(lambda q: (oklab_srgb(render_samples(dict(st, exposure=q[0]), lp)) - lab).ravel(), [1.0])
        ev = float(fitres.x[0])
        de = np.linalg.norm(oklab_srgb(render_samples(dict(st, exposure=ev), lp)) - lab, axis=1).mean()
        # per brightness band (scene stops vs 18% grey at that exposure): a tone mismatch shows as drift
        ys = lp @ LUM709 * 2 ** ev
        bands = []
        for lo, hi in ((-8, -3), (-3, -1), (-1, 1), (1, 4)):
            b = (np.log2(np.maximum(ys, 1e-9) / 0.18) >= lo) & (np.log2(np.maximum(ys, 1e-9) / 0.18) < hi)
            if b.sum() > 300:
                rb = least_squares(lambda q: (oklab_srgb(render_samples(dict(st, exposure=q[0]), lp[b]))[:, 0] - lab[b, 0]), [ev])
                bands.append(f"{lo:+d}..{hi:+d}: {rb.x[0]:+.2f}")
        print(f"{os.path.basename(ref_path):16s} develop {ev:+.2f} EV  (ΔE {de:.4f})   by band: " + "  ".join(bands))


# --- grain ------------------------------------------------------------------------------

def _decode8(p):
    """An export (HEIC/JPEG) or one of our 16-bit PNG renders as 0…255 floats (no colour
    conversion: Chromagraph's HEICs are untagged and read as sRGB; ours are written sRGB)."""
    import cv2
    if p.endswith(".png"):
        a = cv2.imread(p, cv2.IMREAD_UNCHANGED)[..., :3][..., ::-1].astype(np.float64)
        return a / 257 if a.dtype == np.float64 and a.max() > 255 else a
    import pillow_heif
    from PIL import Image
    pillow_heif.register_heif_opener()
    return np.asarray(Image.open(p).convert("RGB")).astype(np.float64)


def _flat_mask(base):
    import cv2
    y = (base.mean(-1) / 255).astype(np.float32)
    g = cv2.GaussianBlur(y, (0, 0), 3)
    gm = np.hypot(cv2.Sobel(g, cv2.CV_32F, 1, 0), cv2.Sobel(g, cv2.CV_32F, 0, 1))
    tex = np.sqrt(cv2.GaussianBlur((y - cv2.GaussianBlur(y, (0, 0), 2)) ** 2, (0, 0), 6))
    return (gm < 0.012) & (tex < 0.006)


def grain_stats(base, img, flat):
    """The grain an export adds over the grain-off export of the same RAW: per-pixel std of
    encoded luminance (/255) and per channel, autocorrelation at 1–4 px, inter-channel
    correlation and the radial power spectrum (10 bands to Nyquist, relative to the first),
    on the largest flat rectangle."""
    import cv2
    ys, xs = np.nonzero(cv2.erode(flat.astype(np.uint8), np.ones((41, 41), np.uint8)))
    r0, r1 = np.percentile(ys, [10, 90]).astype(int)
    c0, c1 = np.percentile(xs, [10, 90]).astype(int)
    d = (img - base)[r0:r1, c0:c1]
    d = d - np.stack([cv2.GaussianBlur(d[..., c].astype(np.float32), (0, 0), 40) for c in range(3)], -1)
    y = np.einsum("ijk,k->ij", d, LUM709)
    ac = [float(np.corrcoef(y[:, :-l].ravel(), y[:, l:].ravel())[0, 1]) for l in (1, 2, 3, 4)]
    p = np.abs(np.fft.fft2(y - y.mean())) ** 2 / y.size
    fy, fx = np.fft.fftfreq(y.shape[0]), np.fft.fftfreq(y.shape[1])
    rad = np.hypot(*np.meshgrid(fy, fx, indexing="ij"))
    b = np.linspace(0, 0.5, 11)
    sp = np.array([p[(rad >= lo) & (rad < hi)].mean() for lo, hi in zip(b[:-1], b[1:])])
    cc = np.corrcoef([d[..., c].ravel() for c in range(3)])
    return dict(std=float(y.std()), rgb=[float(d[..., c].std()) for c in range(3)], ac=ac,
                corr=[float(cc[0, 1]), float(cc[0, 2]), float(cc[1, 2])], spectrum=list(sp / sp[0]))


def grain_by_value(base, imgs, flat, edges=range(40, 256, 12)):
    """Grain std per channel, binned by that channel's own (blurred) value: Chromagraph's is
    one curve for R, G and B (a per-channel tone curve after the grain)."""
    import cv2
    out = {}
    for c in range(3):
        v = cv2.GaussianBlur(base[..., c].astype(np.float32), (0, 0), 6)
        ds = []
        for im in imgs:
            dd = (im[..., c] - base[..., c]).astype(np.float32)
            ds.append(dd - cv2.GaussianBlur(dd, (0, 0), 20))
        for lo, hi in zip(list(edges)[:-1], list(edges)[1:]):
            m = flat & (v >= lo) & (v < hi)
            if m.sum() > 3000:
                vals = np.concatenate([dd[m] for dd in ds])
                vals = vals[np.abs(vals) < 4 * vals.std()]
                out.setdefault((lo + hi) // 2, {})["RGB"[c]] = float(vals.std())
    return out


def grain(d, ev, assign):
    files = sorted(os.listdir(d))
    dng = [os.path.join(d, f) for f in files if f.lower().endswith(".dng")]
    exports = [os.path.join(d, f) for f in files if f.lower().endswith((".heic", ".heif", ".jpg", ".jpeg"))]
    if len(dng) != 1 or len(exports) < 2:
        sys.exit("grain: DIR needs one DNG and its exports at several grain settings")
    imgs = {os.path.basename(p): _decode8(p) for p in exports}
    # Grain off: the export the others differ from least.
    names = list(imgs)
    noise = {n: np.median([np.abs(imgs[n] - imgs[m]).mean() for m in names if m != n]) for n in names}
    off = min(noise, key=noise.get)
    flat = _flat_mask(imgs[off])
    stats = {n: grain_stats(imgs[off], imgs[n], flat) for n in names if n != off}
    settings = {}
    if assign:
        for a in assign:
            f, v = a.split("=")
            amp, size = v.split("/")
            settings[f] = (float(amp), float(size))
    else:
        # Amplitude 5 is ~4x the others; of the 1.25s, the most correlated is Size max and
        # the weakest Size min (same spectrum as Size 1, a pixel is as fine as it gets).
        lo = min(s["std"] for s in stats.values())
        strong = [n for n, s in stats.items() if s["std"] > 3 * lo]
        rest = sorted((n for n in stats if n not in strong), key=lambda n: stats[n]["ac"][0])
        for n in strong:
            settings[n] = (5.0, 1.0)
        if rest:
            settings[rest[-1]] = (1.25, 3.0)
            rest = sorted(rest[:-1], key=lambda n: stats[n]["std"])
            if len(rest) == 2:
                settings[rest[0]], settings[rest[1]] = (1.25, 0.25), (1.25, 1.0)
            elif len(rest) == 1:
                settings[rest[0]] = (1.25, 1.0)
    print(f"grain off: {off} (mean |difference| to the others {noise[off]:.2f}/255)")
    print("Chromagraph (std /255 of encoded luminance; R G B; autocorrelation at 1–4 px; channel correlation; spectrum):")
    for n, s in stats.items():
        a = settings.get(n)
        print(f"  {n:14s} {'amp %.2f size %.2f' % a if a else 'unassigned':20s} " + _fmt(s))
    # Ours, through the app's own pipeline at the same settings.
    exe = os.path.join(WORK_DIR, "film-render")
    os.makedirs(WORK_DIR, exist_ok=True)
    root = os.path.join(HERE, "..")
    ed = os.path.join(root, "PointAndShoot", "Editor")
    subprocess.run(["swiftc", "-O", "-o", exe, os.path.join(HERE, "film-render", "main.swift"),
                    os.path.join(ed, "FilmModel.swift"), os.path.join(ed, "FilmStock+Stocks.swift"),
                    os.path.join(ed, "FilmPipeline.swift")], check=True, capture_output=True)
    long = max(imgs[off].shape[:2])

    def ours(name, amp, size, engine=F.CURRENT_ENGINE):
        out = os.path.join(WORK_DIR, f"grain-{name}.png")
        subprocess.run([exe, dng[0], out, "--long", str(long), "--ev", str(ev), "--stock", "phromagraph",
                        "--grain", str(amp / 1.25), "--size", str(size), "--engine", str(engine)],
                       check=True, capture_output=True)
        return _decode8(out)
    base = ours("off", 0, 1)
    print(f"Ours (Phromagraph, engine {F.CURRENT_ENGINE}; slider = amplitude × 40):")
    mine = {}
    for n, (amp, size) in sorted(settings.items(), key=lambda kv: kv[1]):
        mine[n] = ours(n, amp, size)
        print(f"  {'at ' + n:14s} {'amp %.2f size %.2f' % (amp, size):20s} " + _fmt(grain_stats(base, mine[n], flat)))
    strong = [n for n, a in settings.items() if a == (5.0, 1.0)]
    if strong:
        print("Strength by each channel's own value at amplitude 5 (Chromagraph | ours):")
        theirs = grain_by_value(imgs[off], [imgs[n] for n in strong], flat)
        us = grain_by_value(base, [mine[strong[0]]], flat)
        for v in sorted(set(theirs) | set(us)):
            t, u = theirs.get(v, {}), us.get(v, {})
            print(f"  {v:3d}  " + "  ".join(f"{ch} {t.get(ch, float('nan')):5.1f} | {u.get(ch, float('nan')):5.1f}" for ch in "RGB"))


def _fmt(s):
    return (f"std {s['std']:5.2f}  RGB {' '.join('%5.2f' % v for v in s['rgb'])}  ac {' '.join('%+.3f' % v for v in s['ac'])}"
            f"  corr {' '.join('%.2f' % v for v in s['corr'])}  spectrum {' '.join('%.2f' % v for v in s['spectrum'])}")


def main():
    global WORK_DIR
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--work", default=WORK)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("prep").add_argument("dir")
    f = sub.add_parser("fit")
    f.add_argument("--out", default=OUT)
    sub.add_parser("measure").add_argument("dir")
    e = sub.add_parser("develop-ev")
    e.add_argument("dng")
    e.add_argument("exports", nargs="+")
    g = sub.add_parser("grain")
    g.add_argument("dir")
    g.add_argument("--ev", type=float, default=1.86, help="develop exposure (Chromagraph's fixed ProRAW develop)")
    g.add_argument("--assign", nargs="*", help="FILE=AMPLITUDE/SIZE, e.g. IMG_4587.HEIC=1.25/1")
    s = sub.add_parser("sheet")
    s.add_argument("out")
    s.add_argument("--only")
    a = ap.parse_args()
    WORK_DIR = a.work
    if a.cmd == "prep":
        prep(a.dir)
    elif a.cmd == "fit":
        fit(a.out)
    elif a.cmd == "measure":
        measure(a.dir)
    elif a.cmd == "develop-ev":
        develop_ev(a.dng, a.exports)
    elif a.cmd == "grain":
        grain(a.dir, a.ev, a.assign)
    elif a.cmd == "sheet":
        sheet(a.out, a.only.split(",") if a.only else None)


WORK_DIR = WORK
if __name__ == "__main__":
    main()
