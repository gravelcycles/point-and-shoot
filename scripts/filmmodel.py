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


def scene_from_display_rgb(rgb2020):
    """Undo a phone's tone curve on luminance and keep each color's channel ratios
    (FilmLUT.sceneFromDisplay(rgb:)). Inverting per channel would read a saturated
    display red as a red channel stops overexposed and push it into the shoulder."""
    rgb = np.clip(rgb2020, 0, 1)
    y = rgb @ LUM2020
    scale = scene_from_display(y) / np.maximum(y, 1e-6)
    return rgb * scale[..., None]


def negative_density(rgb2020, stock):
    """Scene light (linear Rec.2020, ...x3) -> negative density per layer."""
    e = rgb2020 @ np.array(stock["sensitivity"]).reshape(3, 3).T
    out = np.empty_like(e)
    for c in range(3):
        out[..., c] = curve_density(stock["negative"][c], np.log10(np.maximum(e[..., c], 1e-6) / 0.18))
    return out


def grey_negative_density(stock):
    return np.array([float(curve_density(stock["negative"][c], 0.0)) for c in range(3)])


def print_curves(stock, controls):
    contrast = 2 ** (controls.get("contrast", 0) * 0.5)
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
    u = np.maximum(np.log10(np.maximum(s ** 4, 1e-12)), -6.0)
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
    out = _display_core(dn, stock, controls)
    # Highlight hue protection: film's per-channel shoulder turns bright warm colors
    # yellow (red compresses first). Blend toward the scene's own hue — carrying the
    # stock's own neutral cast at that brightness — scaled to the same luminance.
    hp = stock.get("huePreserve", 0.0)
    if hp > 0:
        e = 10.0 ** np.stack([neg_log_exposure(stock["negative"][c], dn[..., c]) for c in range(3)], -1)
        e = np.maximum(e @ hue_matrix(stock).T, 0)     # scene color (P3), saturation boost undone
        ye = e @ LUM_P3
        tgt = e / np.maximum(ye, 1e-9)[..., None] * neutral_lookup(neutral_table(stock, controls), ye)
        yo, yt = out @ LUM_P3, tgt @ LUM_P3
        tgt = tgt * (yo / np.maximum(yt, 1e-9))[..., None]
        w = hp * smoothstep(0.2, 0.85, yo)
        out = out + (tgt - out) * w[..., None]
    return out


def _display_core(dn, stock, controls):
    curves = print_curves(stock, controls)
    grey = grey_negative_density(stock)
    printer = stock.get("printer", [0.0, 0.0, 0.0])
    dp = np.empty_like(dn)
    for c in range(3):
        dp[..., c] = curve_density(curves[c], grey[c] - dn[..., c] + printer[c])
    X = np.array(stock["crosstalk"]).reshape(3, 3)
    dm = dp @ X.T
    base = X @ np.array([curves[c]["y"][0] for c in range(3)])
    sat = controls.get("saturation", 0)
    if sat != 0:
        mean = dm.mean(axis=-1, keepdims=True)
        k = 1 + sat * (0.6 if sat > 0 else 1.0)
        dm = mean + (dm - mean) * k
    h, s = controls.get("highlights", 0), controls.get("shadows", 0)
    if h != 0 or s != 0:
        neutral = dm.mean(axis=-1, keepdims=True)
        wh = np.exp(-((neutral - 0.25) / 0.45) ** 2)
        t = np.clip((neutral - 0.9) / (2.4 - 0.9), 0, 1)
        ws = t * t * (3 - 2 * t)
        dm = dm + (-0.22 * h * wh - 0.45 * s * ws)
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

def negative_cube(stock, source="sceneLinear", n=48):
    u = np.arange(n) / (n - 1)
    x = SHAPER_SCALE * u ** SHAPER_POWER
    b, g, r = np.meshgrid(x, x, x, indexing="ij")
    rgb = np.stack([r, g, b], axis=-1)
    if source != "sceneLinear":
        rgb = scene_from_display_rgb(rgb)
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


def grain_field(shape, stock, strength, seed=7):
    """Zero-mean grain in negative density: a shared (monochrome) part plus a per-layer
    part, blurred to the grain size. Amplitude is defined at a 4032 px long side and
    scales down with resolution (smaller renders average the grain)."""
    from scipy.ndimage import gaussian_filter
    h, w = shape
    unit = max(h, w) / 1000.0
    sigma_px = max(0.35, stock["grain_size"] * unit)
    rng = np.random.default_rng(seed)
    def field():
        f = gaussian_filter(rng.standard_normal((h, w)), sigma_px)
        return f / (f.std() + 1e-9)
    shared = field()
    c = stock["grainChroma"]
    norm = math.sqrt((1 - c) ** 2 + c ** 2)
    sigma = stock["grainDensity"] * strength * min(1.0, unit / 4.032)
    return np.stack([((1 - c) * shared + c * field()) / norm for _ in range(3)], -1) * sigma


def render(lin_srgb, stock, controls=None, exposure_ev=0.0, halation_amount=1.0, grain_amount=1.0,
           source="sceneLinear"):
    """Scene-linear sRGB-primaries image -> Display P3 linear image."""
    controls = controls or {}
    x = lin_srgb * 2.0 ** (exposure_ev + stock.get("exposure", 0.0))
    x = halation(x, stock, halation_amount, source)
    if source == "sceneLinear":
        rgb2020 = x @ SRGB_TO_REC2020.T
    else:
        rgb2020 = scene_from_display_rgb(np.clip(x, 0, 1) @ SRGB_TO_REC2020.T)
    rgb2020 = np.clip(rgb2020, 0, SHAPER_SCALE)
    dn = negative_density(rgb2020, stock)
    if grain_amount > 0:
        dn = dn + grain_field(dn.shape[:2], stock, grain_amount)
    return decode_srgb(split_tone(encode_srgb(display(dn, stock, controls)), stock))


def load_stock(path):
    with open(path) as f:
        return json.load(f)


def stock_copy(stock):
    return copy.deepcopy(stock)
