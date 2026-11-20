// Dumps FilmModel numbers for scripts/print-look.py parity (compiled with swiftc on any
// platform: FilmModel.swift and FilmStock+Stocks.swift are Foundation-only).
import Foundation

func sample(_ cube: [Float], _ n: Int, _ idx: [(Int, Int, Int)]) -> [[Double]] {
    idx.map { (r, g, b) in let o = ((b * n + g) * n + r) * 4; return [Double(cube[o]), Double(cube[o + 1]), Double(cube[o + 2])] }
}
let idxNeg = [(0, 0, 0), (10, 20, 30), (40, 40, 40), (47, 47, 47), (44, 12, 33), (21, 22, 23), (5, 46, 31)]
let idxPrint = [(0, 0, 0), (10, 20, 30), (24, 24, 24), (47, 47, 47), (40, 9, 25), (16, 17, 18), (3, 45, 23), (12, 30, 8)]
var ctl = FilmControls()
ctl.contrast = 0.4; ctl.saturation = 0.5; ctl.crossover = -0.5; ctl.highlights = 0.3; ctl.shadows = -0.4
var ctl2 = ctl      // engine 3: the Saturation slider adds saturation subtractively
ctl2.subtractiveSaturation = true
var ctl4 = ctl2     // engine 4: Highlights and Shadows go further
ctl4.strongTone = true
var ctl5 = ctl2     // engine 5: Highlights/Shadows re-expose regions, Contrast ×2 about a pivot
ctl5.strongTone = true; ctl5.toneRegions = true; ctl5.highlights = 0.8; ctl5.shadows = 0.6; ctl5.pivot = -1.5
var ctl5b = ctl5    // the opposite extremes (the fold-prone combination) and contrast below 0
ctl5b.highlights = -1; ctl5b.shadows = 1; ctl5b.contrast = -0.6; ctl5b.pivot = 2
var ctl6 = ctl5     // the Film tool on top of engine 5's re-exposure: printer lights, push, flash, silver
(ctl6.printerR, ctl6.printerG, ctl6.printerB) = FilmControls.printerLights(warm: 0.6, magenta: -0.4)
ctl6.push = 1.5; ctl6.flash = 0.03; ctl6.silver = 0.7
var ctl6b = FilmControls()   // ...and alone (the per-axis path), pulled
(ctl6b.printerR, ctl6b.printerG, ctl6b.printerB) = FilmControls.printerLights(warm: -0.5, magenta: 0.8)
ctl6b.push = -1.2; ctl6b.flash = 0.05

var out: [String: Any] = [:]
var timing: [String: [Double]] = [:]
for id in ["print", "phromagraph", "punch", "portrait400", "threestrip", "blockbuster", "night800", "bleachbypass", "bleach", "noir"] {
    let s = FilmStock.named(id)
    var neutral: [[Double]] = [], neutralCtl: [[Double]] = []
    for st in stride(from: -6.0, through: 6.0, by: 0.5) {
        let a = FilmLUT.neutralResponse(stops: st, stock: s)
        let b = FilmLUT.neutralResponse(stops: st, stock: s, controls: ctl)
        neutral.append([a.0, a.1, a.2]); neutralCtl.append([b.0, b.1, b.2])
    }
    // A few saturated colors through the general path (exercises hue protection).
    var colors: [[Double]] = []
    for c in [(0.9, 0.55, 0.3), (1.6, 0.4, 0.2), (0.2, 0.5, 1.2), (0.05, 0.3, 0.06)] {
        let r = FilmLUT.display(negative: FilmLUT.negativeDensity(c, stock: s), stock: s)
        colors.append([r.0, r.1, r.2])
    }
    var colors2: [[Double]] = []
    for c in [(0.9, 0.55, 0.3), (1.6, 0.4, 0.2), (0.2, 0.5, 1.2), (0.05, 0.3, 0.06)] {
        let r = FilmLUT.display(negative: FilmLUT.negativeDensity(c, stock: s), stock: s, controls: ctl2)
        colors2.append([r.0, r.1, r.2])
    }
    let t0 = Date()
    let neg = FilmLUT.negativeCube(stock: s, source: .sceneLinear)
    let t1 = Date()
    let negD = FilmLUT.negativeCube(stock: s, source: .displayReferred)
    let t2 = Date()
    let pc = FilmLUT.printCube(stock: s, controls: FilmControls())
    let t3 = Date()
    let pcCtl = FilmLUT.printCube(stock: s, controls: ctl)
    let t4 = Date()
    let pcCtl2 = FilmLUT.printCube(stock: s, controls: ctl2)
    let pcCtl4 = FilmLUT.printCube(stock: s, controls: ctl4)
    let pcCtl5 = FilmLUT.printCube(stock: s, controls: ctl5)
    let pcCtl5b = FilmLUT.printCube(stock: s, controls: ctl5b)
    let pcCtl6 = FilmLUT.printCube(stock: s, controls: ctl6)
    let pcCtl6b = FilmLUT.printCube(stock: s, controls: ctl6b)
    timing[id] = [t1, t2, t3, t4].enumerated().map { i, t in t.timeIntervalSince([t0, t1, t2, t3][i]) * 1000 }
    let gains = FilmGrain.layerGains(stock: s)
    out[id] = [
        "neutral": neutral, "neutral_ctl": neutralCtl, "colors": colors,
        "neg": sample(neg, FilmLUT.negativeDimension, idxNeg),
        "negD": sample(negD, FilmLUT.negativeDimension, idxNeg),
        "negD_v1": sample(FilmLUT.negativeCube(stock: s, source: .displayReferred, engine: 1), FilmLUT.negativeDimension, idxNeg),
        "negD_ev": sample(FilmLUT.negativeCube(stock: s, source: .displayReferred, exposure: 0.7), FilmLUT.negativeDimension, idxNeg),
        "print": sample(pc, FilmLUT.printDimension, idxPrint),
        "print_ctl": sample(pcCtl, FilmLUT.printDimension, idxPrint),
        "print_ctl2": sample(pcCtl2, FilmLUT.printDimension, idxPrint),
        "print_ctl4": sample(pcCtl4, FilmLUT.printDimension, idxPrint),
        "print_ctl5": sample(pcCtl5, FilmLUT.printDimension, idxPrint),
        "print_ctl5b": sample(pcCtl5b, FilmLUT.printDimension, idxPrint),
        "print_ctl6": sample(pcCtl6, FilmLUT.printDimension, idxPrint),
        "print_ctl6b": sample(pcCtl6b, FilmLUT.printDimension, idxPrint),
        "neutral_ctl6": stride(from: -6.0, through: 6.0, by: 0.5).map { st -> [Double] in
            let v = FilmLUT.neutralResponse(stops: st, stock: s, controls: ctl6); return [v.0, v.1, v.2] },
        "neutral_ctl6b": stride(from: -6.0, through: 6.0, by: 0.5).map { st -> [Double] in
            let v = FilmLUT.neutralResponse(stops: st, stock: s, controls: ctl6b); return [v.0, v.1, v.2] },
        "neutral_ctl5": stride(from: -6.0, through: 6.0, by: 0.5).map { st -> [Double] in
            let v = FilmLUT.neutralResponse(stops: st, stock: s, controls: ctl5); return [v.0, v.1, v.2] },
        "neutral_ctl5b": stride(from: -6.0, through: 6.0, by: 0.5).map { st -> [Double] in
            let v = FilmLUT.neutralResponse(stops: st, stock: s, controls: ctl5b); return [v.0, v.1, v.2] },
        "neutral_ctl4": stride(from: -6.0, through: 6.0, by: 0.5).map { st -> [Double] in
            let v = FilmLUT.neutralResponse(stops: st, stock: s, controls: ctl4); return [v.0, v.1, v.2] },
        "colors_ctl2": colors2,
        // Engine 7's grain (FilmGrain): layer weights and the Jacobian they come from.
        "grain_gains": [gains.0, gains.1, gains.2],
        "grain_jacobian": FilmGrain.jacobian(stock: s),
    ]
}
let grainKernels: [[Double]] = [0.0, 1.0, 1.2, 1.735, 2.5].map { FilmGrain.kernel(cell: $0) }
let grainStrength: [Double] = [0.25, 0.5, 1.0, 2.0, 3.0].map { FilmGrain.strength(size: $0) }
let grainCells: [Double] = [(0.25, 2.88), (1.0, 2.88), (3.0, 2.88), (1.0, 4.032), (3.0, 1.2)].map { FilmGrain.cellPixels(size: $0.0, unit: $0.1) }
out["grain"] = ["kernels": grainKernels, "strength": grainStrength, "cells": grainCells] as [String: Any]
out["timing_ms"] = timing
let data = try! JSONSerialization.data(withJSONObject: out)
_ = FileManager.default.createFile(atPath: CommandLine.arguments[1], contents: data)
for (id, t) in timing.sorted(by: { $0.key < $1.key }) {
    print("\(id): cube build ms (negative, negative display, print, print with all sliders moved):",
          t.map { String(format: "%.1f", $0) }.joined(separator: ", "))
}
