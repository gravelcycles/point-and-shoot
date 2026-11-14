"""Instagram-style reference filters: the 26 CSSgram recipes (github.com/una/CSSgram,
MIT, by Una Kravets), rendered the way a browser does, for comparing how far apart our
photo filters are (`print-look.py spread --cssgram`).

Browser semantics: the pseudo-element overlays are composited onto the image first
(::before, then ::after; W3C Compositing blend modes on sRGB-encoded values, mixed by
the layer's alpha x opacity), then the element's `filter:` chain runs on the result, left
to right (W3C Filter Effects shorthand matrices, clamped to 0..1 after each step).
Willow's ::before is invalid CSS (a gradient in background-color), so browsers drop it.
"""
import re

import numpy as np

# name: (filter chain, [(background, blend mode, opacity), ...] in paint order)
RECIPES = {
    "aden": ("hue-rotate(-20deg) contrast(0.9) saturate(0.85) brightness(1.2)", [('linear-gradient(to right, rgba(66, 10, 14, 0.2), transparent)', 'darken', 1.0)]),
    "inkwell": ("sepia(0.3) contrast(1.1) brightness(1.1) grayscale(1)", []),
    "perpetua": ("", [('linear-gradient(to bottom, #005b9a, #e6c13d)', 'soft-light', 0.5)]),
    "reyes": ("sepia(0.22) brightness(1.1) contrast(0.85) saturate(0.75)", [('#efcdad', 'soft-light', 0.5)]),
    "gingham": ("brightness(1.05) hue-rotate(-10deg)", [('lavender', 'soft-light', 1.0)]),
    "toaster": ("contrast(1.5) brightness(0.9)", [('radial-gradient(circle, #804e0f, #3b003b)', 'screen', 1.0)]),
    "walden": ("brightness(1.1) hue-rotate(-10deg) sepia(0.3) saturate(1.6)", [('#0044cc', 'screen', 0.3)]),
    "hudson": ("brightness(1.2) contrast(0.9) saturate(1.1)", [('radial-gradient(circle, #a6b1ff 50%, #342134)', 'multiply', 0.5)]),
    "earlybird": ("contrast(0.9) sepia(0.2)", [('radial-gradient(circle, #d0ba8e 20%, #360309 85%, #1d0210 100%)', 'overlay', 1.0)]),
    "mayfair": ("contrast(1.1) saturate(1.1)", [('radial-gradient(circle at 40% 40%, rgba(255, 255, 255, 0.8), rgba(255, 200, 200, 0.6), #111111 60%)', 'overlay', 0.4)]),
    "lofi": ("saturate(1.1) contrast(1.5)", [('radial-gradient(circle, transparent 70%, #222222 150%)', 'multiply', 1.0)]),
    "1977": ("contrast(1.1) brightness(1.1) saturate(1.3)", [('rgba(243, 106, 188, 0.3)', 'screen', 1.0)]),
    "brooklyn": ("contrast(0.9) brightness(1.1)", [('radial-gradient(circle, rgba(168, 223, 193, 0.4) 70%, #c4b7c8)', 'overlay', 1.0)]),
    "xpro2": ("sepia(0.3)", [('radial-gradient(circle, #e6e7e0 40%, rgba(43, 42, 161, 0.6) 110%)', 'color-burn', 1.0)]),
    "nashville": ("sepia(0.2) contrast(1.2) brightness(1.05) saturate(1.2)", [('rgba(247, 176, 153, 0.56)', 'darken', 1.0), ('rgba(0, 70, 150, 0.4)', 'lighten', 1.0)]),
    "lark": ("contrast(0.9)", [('#22253f', 'color-dodge', 1.0), ('rgba(242, 242, 242, 0.8)', 'darken', 1.0)]),
    "moon": ("grayscale(1) contrast(1.1) brightness(1.1)", [('#a0a0a0', 'soft-light', 1.0), ('#383838', 'lighten', 1.0)]),
    "clarendon": ("contrast(1.2) saturate(1.35)", [('rgba(127, 187, 227, 0.2)', 'overlay', 1.0)]),
    "willow": ("grayscale(0.5) contrast(0.95) brightness(0.9)", [('#d8cdcb', 'color', 1.0)]),
    "rise": ("brightness(1.05) sepia(0.2) contrast(0.9) saturate(0.9)", [('radial-gradient(circle, rgba(236, 205, 169, 0.15) 55%, rgba(50, 30, 7, 0.4))', 'multiply', 1.0), ('radial-gradient(circle, rgba(232, 197, 152, 0.8), transparent 90%)', 'overlay', 0.6)]),
    "slumber": ("saturate(0.66) brightness(1.05)", [('rgba(69, 41, 12, 0.4)', 'lighten', 1.0), ('rgba(125, 105, 24, 0.5)', 'soft-light', 1.0)]),
    "brannan": ("sepia(0.5) contrast(1.4)", [('rgba(161, 44, 199, 0.31)', 'lighten', 1.0)]),
    "valencia": ("contrast(1.08) brightness(1.08) sepia(0.08)", [('#3a0339', 'exclusion', 0.5)]),
    "kelvin": ("", [('#382c34', 'color-dodge', 1.0), ('#b77d21', 'overlay', 1.0)]),
    "maven": ("sepia(0.25) brightness(0.95) contrast(0.95) saturate(1.5)", [('rgba(3, 230, 26, 0.2)', 'hue', 1.0)]),
    "stinson": ("contrast(0.75) saturate(0.85) brightness(1.15)", [('rgba(240, 149, 128, 0.2)', 'soft-light', 1.0)]),
}
MONO = ("inkwell", "moon", "willow")
NAMED = {"transparent": (0, 0, 0, 0), "black": (0, 0, 0, 1), "white": (1, 1, 1, 1),
         "lavender": (230 / 255, 230 / 255, 250 / 255, 1)}


def encode_srgb(x):
    v = np.clip(x, 0, 1)
    return np.where(v <= 0.0031308, 12.92 * v, 1.055 * np.power(v, 1 / 2.4) - 0.055)


def decode_srgb(v):
    return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)


# --- colors & gradients --------------------------------------------------------------------
def parse_color(s):
    s = s.strip()
    if s in NAMED:
        return np.array(NAMED[s], float)
    if s.startswith("#"):
        h = s[1:]
        if len(h) == 3:
            h = "".join(c * 2 for c in h)
        return np.array([int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)] + [1.0])
    m = re.match(r"rgba?\(([^)]*)\)", s)
    v = [float(x) for x in m.group(1).split(",")]
    return np.array([v[0] / 255, v[1] / 255, v[2] / 255, v[3] if len(v) > 3 else 1.0])


def split_top(s):
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur.strip())
            cur = ""
        else:
            cur += ch
    out.append(cur.strip())
    return out


def color_stops(parts):
    stops = []
    for p in parts:
        m = re.match(r"(.*?)\s+(-?[\d.]+)%$", p)
        stops.append([parse_color(m.group(1) if m else p), float(m.group(2)) / 100 if m else None])
    if stops[0][1] is None:
        stops[0][1] = 0.0
    if stops[-1][1] is None:
        stops[-1][1] = 1.0
    i = 0
    while i < len(stops):           # evenly distribute unpositioned stops
        if stops[i][1] is None:
            j = i
            while stops[j][1] is None:
                j += 1
            a, b = stops[i - 1][1], stops[j][1]
            for k in range(i, j):
                stops[k][1] = a + (b - a) * (k - i + 1) / (j - i + 1)
            i = j
        i += 1
    return stops


def eval_stops(stops, t):
    """Premultiplied interpolation along the gradient line, like browsers."""
    pos = np.array([s[1] for s in stops])
    cols = np.array([np.r_[s[0][:3] * s[0][3], s[0][3]] for s in stops])
    out = np.stack([np.interp(t, pos, cols[:, c]) for c in range(4)], -1)
    a = out[..., 3:4]
    return np.concatenate([np.where(a > 0, out[..., :3] / np.maximum(a, 1e-9), 0), a], -1)


def layer(bg, h, w):
    """RGBA (straight alpha, sRGB-encoded) for a CSS background value."""
    yy, xx = np.mgrid[0:h, 0:w]
    u, v = (xx + 0.5) / w, (yy + 0.5) / h
    if bg.startswith("linear-gradient"):
        parts = split_top(bg[len("linear-gradient("):-1])
        direction = parts.pop(0)
        t = {"to right": u, "to bottom": v}[direction]
        return eval_stops(color_stops(parts), t)
    if bg.startswith("radial-gradient"):
        parts = split_top(bg[len("radial-gradient("):-1])
        shape = parts.pop(0)
        cx, cy = 0.5, 0.5
        m = re.search(r"at ([\d.]+)% ([\d.]+)%", shape)
        if m:
            cx, cy = float(m.group(1)) / 100, float(m.group(2)) / 100
        X, Y = (u - cx) * w, (v - cy) * h
        R = max(np.hypot(px * w, py * h) for px in (cx, 1 - cx) for py in (cy, 1 - cy))  # farthest-corner
        return eval_stops(color_stops(parts), np.hypot(X, Y) / R)
    return np.broadcast_to(parse_color(bg), (h, w, 4)).copy()



# --- blend modes (W3C Compositing Level 1) ---------------------------------------------
def lum(c):
    return c @ np.array([0.3, 0.59, 0.11])


def clip_color(c):
    l = lum(c)[..., None]
    n, x = c.min(-1, keepdims=True), c.max(-1, keepdims=True)
    c = np.where(n < 0, l + (c - l) * l / np.maximum(l - n, 1e-9), c)
    c = np.where(x > 1, l + (c - l) * (1 - l) / np.maximum(x - l, 1e-9), c)
    return c


def set_lum(c, l):
    return clip_color(c + (l - lum(c))[..., None])


def set_sat(c, s):
    mn, mx = c.min(-1, keepdims=True), c.max(-1, keepdims=True)
    return np.where(mx > mn, (c - mn) * s[..., None] / np.maximum(mx - mn, 1e-9), 0.0)


def sat(c):
    return c.max(-1) - c.min(-1)


def blend(mode, b, s):
    if mode == "multiply":
        return b * s
    if mode == "screen":
        return b + s - b * s
    if mode == "overlay":
        return np.where(b <= 0.5, 2 * b * s, 1 - 2 * (1 - b) * (1 - s))
    if mode == "darken":
        return np.minimum(b, s)
    if mode == "lighten":
        return np.maximum(b, s)
    if mode == "color-dodge":
        return np.where(b == 0, 0, np.where(s >= 1, 1, np.minimum(1, b / np.maximum(1 - s, 1e-9))))
    if mode == "color-burn":
        return np.where(b >= 1, 1, np.where(s <= 0, 0, 1 - np.minimum(1, (1 - b) / np.maximum(s, 1e-9))))
    if mode == "soft-light":
        d = np.where(b <= 0.25, ((16 * b - 12) * b + 4) * b, np.sqrt(b))
        return np.where(s <= 0.5, b - (1 - 2 * s) * b * (1 - b), b + (2 * s - 1) * (d - b))
    if mode == "exclusion":
        return b + s - 2 * b * s
    if mode == "hue":
        return set_lum(set_sat(s, sat(b)), lum(b))
    if mode == "color":
        return set_lum(s, lum(b))
    raise ValueError(mode)



# --- filter functions (W3C Filter Effects shorthand) -----------------------------------
def fmatrix(name, a):
    if name == "grayscale":
        k = 1 - min(a, 1)
        return np.array([[0.2126 + 0.7874 * k, 0.7152 - 0.7152 * k, 0.0722 - 0.0722 * k],
                         [0.2126 - 0.2126 * k, 0.7152 + 0.2848 * k, 0.0722 - 0.0722 * k],
                         [0.2126 - 0.2126 * k, 0.7152 - 0.7152 * k, 0.0722 + 0.9278 * k]])
    if name == "sepia":
        k = 1 - min(a, 1)
        return np.array([[0.393 + 0.607 * k, 0.769 - 0.769 * k, 0.189 - 0.189 * k],
                         [0.349 - 0.349 * k, 0.686 + 0.314 * k, 0.168 - 0.168 * k],
                         [0.272 - 0.272 * k, 0.534 - 0.534 * k, 0.131 + 0.869 * k]])
    if name == "saturate":
        s = a
        return np.array([[0.213 + 0.787 * s, 0.715 - 0.715 * s, 0.072 - 0.072 * s],
                         [0.213 - 0.213 * s, 0.715 + 0.285 * s, 0.072 - 0.072 * s],
                         [0.213 - 0.213 * s, 0.715 - 0.715 * s, 0.072 + 0.928 * s]])
    if name == "hue-rotate":
        c, s = np.cos(np.radians(a)), np.sin(np.radians(a))
        base = np.array([[0.213, 0.715, 0.072]] * 3)
        return (base + c * np.array([[0.787, -0.715, -0.072], [-0.213, 0.285, -0.072], [-0.213, -0.715, 0.928]])
                + s * np.array([[-0.213, -0.715, 0.928], [0.143, 0.140, -0.283], [-0.787, 0.715, 0.072]]))
    return None


def apply_filter(img, chain):
    for name, arg in re.findall(r"([a-z-]+)\(([^)]*)\)", chain):
        a = float(arg.replace("deg", ""))
        m = fmatrix(name, a)
        if m is not None:
            img = img @ m.T
        elif name == "brightness":
            img = img * a
        elif name == "contrast":
            img = (img - 0.5) * a + 0.5
        img = np.clip(img, 0, 1)
    return img



def render(name, srgb_lin):
    """(h, w, 3) linear sRGB in, linear sRGB out."""
    chain, layers = RECIPES[name]
    img = encode_srgb(np.clip(srgb_lin, 0, 1))
    h, w = img.shape[:2]
    for bg, mode, opacity in layers:
        lay = layer(bg, h, w)
        a = lay[..., 3:4] * opacity
        img = (1 - a) * img + a * np.clip(blend(mode, img, lay[..., :3]), 0, 1)
    return decode_srgb(np.clip(apply_filter(img, chain), 0, 1))
