"""Reference implementation of the Print look (PointAndShoot/Editor/FilmModel.swift +
FilmPipeline.swift), in numpy. Keep the two in lockstep: tests compare their numbers.

Used by scripts/print-look.py to preview the look on DNGs and to fit its parameters to
reference images.
"""
from __future__ import annotations

import copy
import json
import math

import numpy as np

SHAPER_SCALE = 16.0
SHAPER_POWER = 4.0
DENSITY_SCALE = 4.0

SRGB_TO_REC2020 = np.array([
    [0.627404, 0.329283, 0.043313],
    [0.069097, 0.919540, 0.011362],
    [0.016391, 0.088013, 0.895595],
])
REC2020_TO_P3 = np.linalg.inv(np.array([
    [0.753833, 0.198597, 0.047570],
    [0.045744, 0.941777, 0.012479],
    [-0.001210, 0.017601, 0.983609],
]))  # inverse of P3 -> Rec.2020


def softplus(x, k):
    z = x / k
    return k * (np.maximum(z, 0) + np.log1p(np.exp(-np.abs(z))))


def _tangents(x, y):
    """Fritsch-Carlson monotone cubic tangents (same algorithm as FilmCurve.swift)."""
    n = len(x)
    d = [(y[i + 1] - y[i]) / (x[i + 1] - x[i]) for i in range(n - 1)]
    m = [d[0]] + [(d[i - 1] + d[i]) / 2 for i in range(1, n - 1)] + [d[-1]]
    for i in range(n - 1):
        if d[i] == 0:
            m[i] = m[i + 1] = 0.0
            continue
        a, b = m[i] / d[i], m[i + 1] / d[i]
        h = a * a + b * b
        if h > 9:
            t = 3 / math.sqrt(h)
            m[i], m[i + 1] = t * a * d[i], t * b * d[i]
    return m


def curve_density(c, logE):
    """FilmCurve.density: monotone cubic through (logE, density) knots, flat beyond the
    ends. c = dict(x=[...], y=[...], gamma=slope multiplier about logE 0)."""
    x, y = c["x"], c["y"]
    m = c.get("_m") or _tangents(x, y)
    u = np.asarray(logE, dtype=np.float64) * c.get("gamma", 1.0)
    u = np.clip(u, x[0], x[-1])
    xs = np.asarray(x); ys = np.asarray(y); ms = np.asarray(m)
    i = np.clip(np.searchsorted(xs, u, side="right") - 1, 0, len(xs) - 2)
    h = xs[i + 1] - xs[i]
    t = (u - xs[i]) / h
    t2, t3 = t * t, t * t * t
    return ((2 * t3 - 3 * t2 + 1) * ys[i] + (t3 - 2 * t2 + t) * h * ms[i]
            + (-2 * t3 + 3 * t2) * ys[i + 1] + (t3 - t2) * h * ms[i + 1])


LUM_P3 = np.array([0.2289746, 0.6917385, 0.0792869])
INVERSE_SAMPLES = 1024


def neg_log_exposure(c, d):
    """Inverse of a (monotone) negative curve: density → log exposure, by linear
    interpolation in a dense table (FilmCurve.logExposure in Swift)."""
    x0, x1 = c["x"][0], c["x"][-1]
    xs = x0 + (x1 - x0) * np.arange(INVERSE_SAMPLES + 1) / INVERSE_SAMPLES
    ds = curve_density(dict(c, gamma=1.0), xs)
    return np.interp(d, ds, xs)


def hue_matrix(stock):
    """Layer exposure → scene color in linear P3: undo the sensitivity matrix's
    interlayer saturation, then Rec.2020 → P3."""
    return REC2020_TO_P3 @ np.linalg.inv(np.array(stock["sensitivity"]).reshape(3, 3))


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def scene_from_display(x):
    v = np.clip(x, 0, 0.995)
    return v / (1.273 - 0.808 * v)


LUM2020 = np.array([0.2627, 0.6780, 0.0593])


CURRENT_ENGINE = 6   # FilmLUT.currentEngine (6: frame-sized grain, FilmPipeline only) (3: subtractive Saturation slider; 4: stronger Highlights/Shadows;
                     # 5: Highlights/Shadows re-expose scene regions, Contrast to x2 with a pivot; the un-render is engine 2's)

# Engine 2: the inverse of Apple's rendering, measured (FilmLUT.unrender*; docs/film-looks.md §5¾).
UNRENDER_DISPLAY_Y = np.array([0.0025, 0.004, 0.006, 0.01, 0.016, 0.025, 0.04, 0.06, 0.09, 0.13, 0.2,
                               0.28, 0.38, 0.48, 0.58, 0.66, 0.74, 0.81, 0.87, 0.92, 0.96, 0.995])
UNRENDER_SCENE_Y = np.array([0.014848, 0.01808, 0.021215, 0.026133, 0.032434, 0.040882, 0.053768, 0.069891, 0.092267, 0.119648, 0.18, 0.285852, 0.411258, 0.525263, 0.67323, 0.862166, 1.16483, 1.51356, 1.79013, 1.93731, 1.96963, 1.96964])
UNRENDER_SAT_Y = np.array([0.003, 0.01, 0.03, 0.08, 0.18, 0.35, 0.6, 0.85, 1.0])
UNRENDER_SAT_BOOST = np.array([3.357, 2.688, 1.944, 1.58, 1.397, 1.212, 1.124, 1.12, 1.0])


def scene_from_display_rgb(rgb2020, engine=CURRENT_ENGINE):
    """Display-referred color (linear Rec.2020) → scene light (FilmLUT.sceneFromDisplay(rgb:)).
    Both engines undo the tone curve on luminance (inverting per channel would read a
    saturated display red as a red channel stops overexposed). Engine 1: a guessed curve,
    channel ratios kept. Engine 2: Apple's measured curve, and its saturation divided out."""
    rgb = np.clip(rgb2020, 0, 1)
    y = rgb @ LUM2020
    if engine < 2:
        scale = scene_from_display(y) / np.maximum(y, 1e-6)
        return rgb * scale[..., None]
    yc = np.maximum(y, 1e-6)
    ly = np.log2(yc)
    s = np.where(ly < np.log2(UNRENDER_DISPLAY_Y[0]), UNRENDER_SCENE_Y[0] * yc / UNRENDER_DISPLAY_Y[0],
                 np.exp2(np.interp(ly, np.log2(UNRENDER_DISPLAY_Y), np.log2(UNRENDER_SCENE_Y))))
    k = np.interp(ly, np.log2(UNRENDER_SAT_Y), UNRENDER_SAT_BOOST)
    return np.maximum(1 + (rgb / yc[..., None] - 1) / k[..., None], 0) * s[..., None]


def display_from_scene_rgb(rgb2020):
    """Engine 2's forward model: roughly how Apple renders scene light (the inverse of
    scene_from_display_rgb). For standing DNGs in for processed photos."""
    rgb = np.maximum(rgb2020, 0)
    y = np.maximum(rgb @ LUM2020, 1e-9)
    ly = np.log2(y)
    d = np.where(ly < np.log2(UNRENDER_SCENE_Y[0]), UNRENDER_DISPLAY_Y[0] * y / UNRENDER_SCENE_Y[0],
                 np.exp2(np.interp(ly, np.log2(UNRENDER_SCENE_Y), np.log2(UNRENDER_DISPLAY_Y))))
    k = np.interp(np.log2(np.maximum(d, 1e-6)), np.log2(UNRENDER_SAT_Y), UNRENDER_SAT_BOOST)
    return np.clip((1 + (rgb / y[..., None] - 1) * k[..., None]) * d[..., None], 0, 1)


TWIST_CHROMA = 0.25      # log10 chroma at which a hue's brightness shift is 63% in
TWIST_OFFSET = 0.01      # log(x + offset): dark colors fade to neutral instead of exploding


def hue_twist(rgb, twists):
    """A film's own color rendering, per hue (FilmLUT.twist in Swift), on scene light
    (linear Rec.2020, ...x3) before the film sees it. It works on log exposure, so it's
    the same at every brightness, and it leaves neutrals alone: each twist
    [hue°, width°, rotate°, saturation, stops] bends the hues within `width` of `hue`
    (raised cosine): turns them, scales their chroma (×(1 + saturation)) and makes them
    brighter or darker. Hue 0 = red, 60 yellow, 120 green, 180 cyan, 240 blue, 300
    magenta (skin ≈ 35, foliage ≈ 80, sky ≈ 225). This is what separates film stocks by
    structure rather than by tint: cyan-leaning greens, golden skin, deep blue skies."""
    if not twists:
        return rgb
    L = np.log10(np.maximum(rgb, 0.0) + TWIST_OFFSET)
    m = L.mean(axis=-1)
    u = L[..., 0] - 0.5 * (L[..., 1] + L[..., 2])
    v = (math.sqrt(3) / 2) * (L[..., 1] - L[..., 2])
    c = np.hypot(u, v)
    h = np.degrees(np.arctan2(v, u))
    rot = np.zeros_like(c); sat = np.zeros_like(c); lum = np.zeros_like(c)
    for hue, width, r, s, stops in twists:
        d = np.abs((h - hue + 180.0) % 360.0 - 180.0)
        w = np.where(d < width, 0.5 + 0.5 * np.cos(np.pi * np.minimum(d / width, 1.0)), 0.0)
        rot += w * r; sat += w * s; lum += w * stops
    c2 = c * np.maximum(1.0 + sat, 0.0)
    a = np.radians(h + rot)
    u2, v2 = c2 * np.cos(a), c2 * np.sin(a)
    m2 = m + lum * math.log10(2.0) * (1.0 - np.exp(-c / TWIST_CHROMA))
    L2 = np.stack([m2 + (2 / 3) * u2, m2 - u2 / 3 + v2 / math.sqrt(3), m2 - u2 / 3 - v2 / math.sqrt(3)], -1)
    return np.maximum(10.0 ** L2 - TWIST_OFFSET, 0.0)


def negative_density(rgb2020, stock):
    """Scene light (linear Rec.2020, ...x3) -> negative density per layer."""
    rgb2020 = hue_twist(rgb2020, stock.get("hueTwists") or [])
    e = rgb2020 @ np.array(stock["sensitivity"]).reshape(3, 3).T
    out = np.empty_like(e)
    for c in range(3):
        out[..., c] = curve_density(stock["negative"][c], np.log10(np.maximum(e[..., c], 1e-6) / 0.18))
    return out


def grey_negative_density(stock):
    return np.array([float(curve_density(stock["negative"][c], 0.0)) for c in range(3)])


def contrast_gamma(controls):
    """FilmControls.contrastGamma: ±1 → ×0.71…1.41; engine 5 (toneRegions) ×0.59…2."""
    c = controls.get("contrast", 0)
    if controls.get("toneRegions", False):
        return 2 ** (c * (1.0 if c > 0 else 0.75))
    return 2 ** (c * 0.5)


# Engine 5's regions (FilmControls), stops from 18% grey.
HIGHLIGHT_STOPS, HIGHLIGHT_CENTER, HIGHLIGHT_WIDTH = 3.0, -3.0, 1.0
SHADOW_LIFT, SHADOW_CRUSH, SHADOW_CENTER, SHADOW_WIDTH = 1.0, 2.2, 0.75, 1.0


def shifts_exposure(controls):
    return controls.get("toneRegions", False) and (
        controls.get("highlights", 0) != 0 or controls.get("shadows", 0) != 0
        or (controls.get("pivot", 0) != 0 and controls.get("contrast", 0) != 0))


def exposure_shift(x, controls):
    """FilmControls.exposureShift: stops added to scene level x (stops from grey)."""
    h, s = controls.get("highlights", 0), controls.get("shadows", 0)
    d = controls.get("pivot", 0) * (1 / contrast_gamma(controls) - 1) + np.zeros_like(x)
    if h != 0:
        d = d + h * HIGHLIGHT_STOPS / (1 + np.exp(-(x - HIGHLIGHT_CENTER) / HIGHLIGHT_WIDTH))
    if s != 0:
        d = d + s * (SHADOW_LIFT if s > 0 else SHADOW_CRUSH) / (1 + np.exp((x - SHADOW_CENTER) / SHADOW_WIDTH))
    return d


def printer_lights(warm, magenta):
    """FilmControls.printerLights: log exposure per print layer (8 printer points at ±1)."""
    return (-0.05 * warm, 0.05 * magenta, 0.05 * warm)


def develop(dn, grey, controls):
    """FilmControls.develop: push/pull scales the negative's contrast about grey (per layer)."""
    p = controls.get("push", 0)
    if p == 0:
        return dn
    return grey + (dn - grey) * 2 ** (0.2 * p)


def flashed(le, controls):
    """FilmControls.flashed: a uniform pre-exposure (fraction of grey's exposure)."""
    f = controls.get("flash", 0)
    return np.log10(10.0 ** le + f) if f > 0 else le


def retain_silver(dm, neutral, amount):
    """FilmLUT.retainSilver: dyes pulled toward their mean, plus silver density in
    proportion to the print's neutral density."""
    if amount <= 0:
        return dm
    return dye_saturate(dm, -0.35 * amount) + 0.1 * amount * neutral


def print_curves(stock, controls):
    contrast = contrast_gamma(controls)
    split = stock["crossover"]
    amount = 1 + controls.get("crossover", 0)
    curves = []
    for i in range(3):
        c = dict(stock["print"][i])
        c["gamma"] = c.get("gamma", 1.0) * contrast * (1 + split[i] * amount)
        curves.append(c)
    return curves


NEUTRAL_MAX, NEUTRAL_SAMPLES = 100.0, 1024      # exposure rel. grey; table in exposure^(1/4)
NEUTRAL_ROOT = NEUTRAL_MAX ** 0.25


def neutral_table(stock, controls):
    """How the stock renders a neutral at each exposure (rel. 18% grey), tint included:
    [NEUTRAL_SAMPLES + 1, 3] linear P3, sampled evenly in exposure^(1/4) (cheap to index:
    two square roots). Hue protection keeps this cast."""
    s = NEUTRAL_ROOT * np.arange(NEUTRAL_SAMPLES + 1) / NEUTRAL_SAMPLES
    u = flashed(np.maximum(np.log10(np.maximum(s ** 4, 1e-12)), -6.0), controls)
    dn = np.stack([curve_density(stock["negative"][c], u) for c in range(3)], -1)
    return _display_core(dn, stock, controls)


def neutral_lookup(table, y):
    t = np.sqrt(np.sqrt(np.minimum(y, NEUTRAL_MAX))) / NEUTRAL_ROOT * NEUTRAL_SAMPLES
    i = np.minimum(t.astype(int), NEUTRAL_SAMPLES - 1)
    f = (t - i)[..., None]
    return table[i] + (table[i + 1] - table[i]) * f


def display(dn, stock, controls=None):
    """Negative density (...x3) -> linear Display P3 (white = 1)."""
    controls = controls or {}
    hp = stock.get("huePreserve", 0.0)
    shift = shifts_exposure(controls)
    flash = controls.get("flash", 0) > 0
    if shift or flash or hp > 0:
        le = np.stack([neg_log_exposure(stock["negative"][c], dn[..., c]) for c in range(3)], -1)
    if shift:
        # Engine 5: re-expose the negative by a smooth function of the neutral scene level.
        sh = exposure_shift(le.mean(axis=-1) / np.log10(2.0), controls) * np.log10(2.0)
        le = le + sh[..., None]
    if shift or flash:
        lf = flashed(le, controls)
        dn = np.stack([curve_density(dict(stock["negative"][c], gamma=1.0), lf[..., c]) for c in range(3)], -1)
    out = _display_core(dn, stock, controls)
    # Highlight hue protection: film's per-channel shoulder turns bright warm colors
    # yellow (red compresses first). Blend toward the scene's own hue — carrying the
    # stock's own neutral cast at that brightness — scaled to the same luminance.
    if hp > 0:
        e = 10.0 ** le
        e = np.maximum(e @ hue_matrix(stock).T, 0)     # scene color (P3), saturation boost undone
        ye = e @ LUM_P3
        tgt = e / np.maximum(ye, 1e-9)[..., None] * neutral_lookup(neutral_table(stock, controls), ye)
        yo, yt = out @ LUM_P3, tgt @ LUM_P3
        tgt = tgt * (yo / np.maximum(yt, 1e-9))[..., None]
        w = hp * smoothstep(0.2, 0.85, yo)
        out = out + (tgt - out) * w[..., None]
    return out


def dye_saturate(dm, amount):
    """The stock's dye saturation (FilmLUT.dyeSaturate). Film color is subtractive: purity
    costs density, so the most saturated colors are the darkest. > 0 spreads each color's
    densities away from its least dense channel: the dominant color stays and the others
    get denser, so colors get richer *and darker*, like a slide film's dyes. (Spreading
    about the mean, like the Saturation slider, would brighten the dominant channel
    instead.) < 0 is retained silver (bleach bypass): silver adds density in proportion to
    the mean density, and with the print re-timed so greys keep their tone, that is
    exactly a pull toward the mean density. A grey with three equal densities is untouched;
    a stock's printer lights or crossover give greys a cast, which this scales by 1 + amount."""
    if amount == 0:
        return dm
    pivot = dm.min(axis=-1, keepdims=True) if amount > 0 else dm.mean(axis=-1, keepdims=True)
    return pivot + (dm - pivot) * (1 + amount)


def _display_core(dn, stock, controls):
    curves = print_curves(stock, controls)
    grey = grey_negative_density(stock)
    printer = stock.get("printer", [0.0, 0.0, 0.0])
    lights = controls.get("printer", (0.0, 0.0, 0.0))     # the user's printer lights
    dp = np.empty_like(dn)
    for c in range(3):
        d = develop(dn[..., c], grey[c], controls)
        dp[..., c] = curve_density(curves[c], grey[c] + lights[c] - d + printer[c])
    X = np.array(stock["crosstalk"]).reshape(3, 3)
    dm = dp @ X.T
    base = X @ np.array([curves[c]["y"][0] for c in range(3)])
    # The tone sliders below weigh by the neutral density before the stock's dye
    # saturation (linear in the print densities, so the Swift cube can tabulate it).
    neutral = dm.mean(axis=-1, keepdims=True)
    dm = dye_saturate(dm, stock.get("dyeSaturation") or 0.0)
    dm = retain_silver(dm, neutral, controls.get("silver", 0))
    # The user's Saturation slider. From film engine 3 (`subtractive`), more saturation
    # works like the dyes: about each color's least dense channel, so richer is darker.
    # Engines 1-2 spread about the mean, which brightens saturated colors; older photos keep
    # it. Less saturation pulls toward the mean either way.
    sat = controls.get("saturation", 0)
    if sat > 0 and controls.get("subtractive", False):
        dm = dye_saturate(dm, 0.6 * sat)
    elif sat != 0:
        mean = dm.mean(axis=-1, keepdims=True)
        k = 1 + sat * (0.6 if sat > 0 else 1.0)
        dm = mean + (dm - mean) * k
    h, s = controls.get("highlights", 0), controls.get("shadows", 0)
    if (h != 0 or s != 0) and not controls.get("toneRegions", False):
        wh = np.exp(-((neutral - 0.25) / 0.45) ** 2)
        t = np.clip((neutral - 0.9) / (2.4 - 0.9), 0, 1)
        ws = t * t * (3 - 2 * t)
        strong = controls.get("strongTone", False)       # engine 4 (FilmControls.strongTone)
        dm = dm + (-(0.42 if strong else 0.22) * h * wh - (0.75 if strong else 0.45) * s * ws)
    t = 10.0 ** (-(dm - base))
    return t @ np.array(stock["display"]).reshape(3, 3).T


def encode_srgb(x):
    v = np.clip(x, 0, 1)
    return np.where(v <= 0.0031308, 12.92 * v, 1.055 * np.power(v, 1 / 2.4) - 0.055)


def decode_srgb(v):
    v = np.asarray(v, dtype=np.float64)
    return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)


def split_tone(enc, stock):
    """Shadow / highlight toning on the print's encoded output: the toe and the shoulder
    take on their own colors (cross-processed and toned prints, faded dyes), weighted
    (1 - Y)^2 and Y^2 by encoded luminance. The tints are luminance-neutral offsets, so
    the tone curve holds; a tint in the shadows also colors a lifted black."""
    st = stock.get("shadowTint", [0.0, 0.0, 0.0])
    ht = stock.get("highlightTint", [0.0, 0.0, 0.0])
    if not any(st) and not any(ht):
        return enc
    y = np.clip(enc @ LUM_P3, 0, 1)[..., None]
    return np.clip(enc + (1 - y) ** 2 * np.array(st) + y * y * np.array(ht), 0, 1)


def neutral_response(stops, stock, controls=None):
    x = 0.18 * 2.0 ** np.asarray(stops, dtype=np.float64)
    rgb = np.stack([x, x, x], axis=-1)
    return display(negative_density(rgb, stock), stock, controls)


# --- Cubes (what the app generates), for parity tests ---------------------------------

def negative_cube(stock, source="sceneLinear", n=48, engine=CURRENT_ENGINE, exposure=0.0):
    """FilmLUT.negativeCube. Display-referred: un-render with `engine`; from engine 2 the
    exposure (stops) is applied after the un-render, in scene light."""
    u = np.arange(n) / (n - 1)
    x = SHAPER_SCALE * u ** SHAPER_POWER
    b, g, r = np.meshgrid(x, x, x, indexing="ij")
    rgb = np.stack([r, g, b], axis=-1)
    if source != "sceneLinear":
        rgb = scene_from_display_rgb(rgb, engine)
        if engine >= 2:
            rgb = rgb * 2.0 ** exposure
    return negative_density(rgb, stock) / DENSITY_SCALE  # [b, g, r, 3]


def print_cube(stock, controls=None, n=48):
    d = np.arange(n) * (DENSITY_SCALE / (n - 1))
    b, g, r = np.meshgrid(d, d, d, indexing="ij")
    return split_tone(encode_srgb(display(np.stack([r, g, b], axis=-1), stock, controls)), stock)


# --- Full image render (mirrors FilmPipeline) ------------------------------------------

def _gauss(img, sigma):
    from scipy.ndimage import gaussian_filter
    if img.ndim == 3:
        return gaussian_filter(img, (sigma, sigma, 0), mode="nearest")
    return gaussian_filter(img, sigma, mode="nearest")


def halation(lin_srgb, stock, strength=1.0, source="sceneLinear"):
    """Light scattered back from the film base into the layers (mostly red), added in
    linear light, energy-conserving: E' = (E + a*glow) / (1 + a). Clipped highlights get
    boosted first, since the sensor clips where film wouldn't."""
    if strength <= 0:
        return lin_srgb
    hal = stock["halation_spread"]
    h, w = lin_srgb.shape[:2]
    unit = max(h, w) / 1000.0
    t = hal["threshold"] if source == "sceneLinear" else hal["display_threshold"]
    boost = hal["boost"] if source == "sceneLinear" else hal["display_boost"]
    src = lin_srgb + boost * np.clip(lin_srgb - t, 0, 64)
    glow = sum(wt * _gauss(src, s * unit) for s, wt in zip(hal["sigmas"], hal["weights"]))
    a = np.array(stock["halation"]) * strength
    return (lin_srgb + a * glow) / (1 + a)


FRAME_GRAIN_SCALE, FRAME_GRAIN_GAIN = 3.0, 0.88   # FilmPipeline.frameGrainScale / frameGrainGain


def grain_field(shape, stock, strength, seed=7, engine=CURRENT_ENGINE):
    """Zero-mean grain in negative density: a shared (monochrome) part plus a per-layer
    part, blurred to the grain size. Engine 6: sized to the frame and as strong at every
    size (Chromagraph's). Before: amplitude defined at a 4032 px long side, scaled down
    with resolution (smaller renders average the grain)."""
    from scipy.ndimage import gaussian_filter
    h, w = shape
    unit = max(h, w) / 1000.0
    frame = engine >= 6
    sigma_px = max(0.35, stock["grain_size"] * unit * (FRAME_GRAIN_SCALE if frame else 1.0))
    rng = np.random.default_rng(seed)
    def field():
        f = gaussian_filter(rng.standard_normal((h, w)), sigma_px)
        return f / (f.std() + 1e-9)
    shared = field()
    c = stock["grainChroma"]
    norm = math.sqrt((1 - c) ** 2 + c ** 2)
    sigma = stock["grainDensity"] * strength * (FRAME_GRAIN_GAIN if frame else min(1.0, unit / 4.032))
    return np.stack([((1 - c) * shared + c * field()) / norm for _ in range(3)], -1) * sigma


def render(lin_srgb, stock, controls=None, exposure_ev=0.0, halation_amount=1.0, grain_amount=1.0,
           source="sceneLinear", engine=CURRENT_ENGINE):
    """Scene-linear (or display-referred) sRGB-primaries image -> Display P3 linear image."""
    controls = dict(controls or {})
    controls.setdefault("subtractive", engine >= 3)      # engine 3's Saturation slider, like the app
    controls.setdefault("strongTone", engine >= 4)       # engine 4's Highlights/Shadows
    controls.setdefault("toneRegions", engine >= 5)      # engine 5's regions, contrast and pivot
    ev = exposure_ev + stock.get("exposure", 0.0)
    after = source != "sceneLinear" and engine >= 2      # engine 2: expose after un-rendering
    x = lin_srgb * (1.0 if after else 2.0 ** ev)
    x = halation(x, stock, halation_amount, source)
    if source == "sceneLinear":
        rgb2020 = x @ SRGB_TO_REC2020.T
    else:
        rgb2020 = scene_from_display_rgb(np.clip(x, 0, 1) @ SRGB_TO_REC2020.T, engine)
        if after:
            rgb2020 = rgb2020 * 2.0 ** ev
    rgb2020 = np.clip(rgb2020, 0, SHAPER_SCALE)
    dn = negative_density(rgb2020, stock)
    if grain_amount > 0:
        dn = dn + grain_field(dn.shape[:2], stock, grain_amount, engine=engine)
    return decode_srgb(split_tone(encode_srgb(display(dn, stock, controls)), stock))


def load_stock(path):
    with open(path) as f:
        return json.load(f)


def stock_copy(stock):
    return copy.deepcopy(stock)
