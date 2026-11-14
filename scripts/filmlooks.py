"""Builds film stocks for the photo filters from compact specs (scripts/film-looks.json).

Every filter is the same negative → print model as the Print look (FilmModel.swift),
with its own:
  - tone: where 18% grey lands, contrast (log-log slope through the shadows and mids),
    shoulder hardness, white level and black floor. The print curve is derived so the
    neutral scale hits exactly that target, the same way Print's curve was derived from
    Chromagraph's measured response.
  - color: printer lights (balance), color crossover, interlayer saturation, and how
    much print-dye crosstalk darkens dense colors.
  - texture: halation and grain.
Anything a spec leaves out comes from the Print stock (scripts/print-stock.json).
"""
from __future__ import annotations

import copy
import json
import math
import os

import numpy as np

import filmmodel as F

HERE = os.path.dirname(os.path.abspath(__file__))
LOOKS = os.path.join(HERE, "film-looks.json")
LUM2020 = np.array([0.2627, 0.6780, 0.0593])
DMIN = 0.06
DMAX = 4.08


def tone_target(spec, base_white):
    """Display luminance of a neutral `s` stops from 18% grey:
    floor + (white − floor) · (x^g / (x^g + 1))^n, x = 2^(s + offset).
    slope = g·n is the log-log contrast below the shoulder; g sets how hard the
    shoulder turns; offset puts 18% grey at `grey`."""
    white = spec.get("white", base_white)
    floor = spec.get("floor", 0.0)
    g = spec.get("shoulder", 2.73)
    n = spec.get("slope", 1.44) / g
    grey = spec.get("grey", 0.115)
    q0 = ((grey - floor) / (white - floor)) ** (1 / n)
    off = math.log2((q0 / (1 - q0)) ** (1 / g))

    def Y(s):
        x = 2.0 ** (np.asarray(s, dtype=np.float64) + off)
        return floor + (white - floor) * (x ** g / (x ** g + 1)) ** n
    return Y, white


def derive_print_curve(neg_curve, Y, white):
    """Print curve (log exposure rel. grey → density) that makes the neutral scale
    display as Y(s), with print D-min shown at `white`."""
    s = np.linspace(-10, 10, 81)
    N = F.curve_density(neg_curve, s * np.log10(2))
    N0 = float(F.curve_density(neg_curve, 0.0))
    x = -(N - N0)
    Dp = np.minimum(DMIN - np.log10(np.maximum(Y(s), 1e-9) / white), DMAX)
    order = np.argsort(x)
    x, Dp = x[order], Dp[order]
    keep = np.concatenate([[True], np.diff(x) > 1e-4])
    x, Dp = x[keep], Dp[keep]
    Dp = np.maximum.accumulate(Dp + np.arange(len(Dp)) * 1e-6)   # strictly increasing
    return {"x": [round(float(v), 5) for v in x], "y": [round(float(v), 5) for v in Dp]}


def build_stock(name, spec, base):
    st = copy.deepcopy(base)
    st["name"] = name
    st["about"] = spec.get("about", "")
    st["exposure"] = spec.get("exposure", 0.0)
    if any(k in spec for k in ("grey", "slope", "shoulder", "white", "floor")):
        Y, white = tone_target(spec, base["display"][0])
        curve = derive_print_curve(base["negative"][1], Y, white)
        st["print"] = [curve, copy.deepcopy(curve), copy.deepcopy(curve)]
        st["display"] = [round(white, 5), 0, 0, 0, round(white, 5), 0, 0, 0, round(white, 5)]
    if "printer" in spec:
        r, b = spec["printer"]
        st["printer"] = [r, 0.0, b]
    if "crossover" in spec:
        r, b = spec["crossover"]
        st["crossover"] = [r, 0.0, b]
    if "interlayer" in spec:
        k = spec["interlayer"]
        st["sensitivity"] = [round(float(v), 5) for v in (np.eye(3) * (1 + k) - k * LUM2020[None, :]).ravel()]
    if "crosstalk" in spec:
        c = spec["crosstalk"]
        X = np.eye(3) + c * (np.array(base["crosstalk"]).reshape(3, 3) - np.eye(3))
        st["crosstalk"] = [round(float(v), 5) for v in X.ravel()]
    if "halation" in spec:
        st["halation"] = spec["halation"]
    if "halation_spread" in spec:
        st["halation_spread"] = {**base["halation_spread"], **spec["halation_spread"]}
    st["huePreserve"] = spec.get("huePreserve", 0.0)
    for k_spec, k_stock in (("grain", "grainDensity"), ("grain_chroma", "grainChroma"), ("grain_size", "grain_size")):
        if k_spec in spec:
            st[k_stock] = spec[k_spec]
    return st


def load_looks(path=LOOKS):
    with open(path) as f:
        return json.load(f)


def all_stocks(print_stock, looks_path=LOOKS):
    """{id: stock} for Print plus every filter in film-looks.json."""
    out = {"print": print_stock}
    for lid, spec in load_looks(looks_path)["looks"].items():
        out[lid] = build_stock(spec.get("name", lid), spec, print_stock)
    return out
