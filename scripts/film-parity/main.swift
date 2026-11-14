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

var out: [String: Any] = [:]
var timing: [String: [Double]] = [:]
for id in ["print", "chrome", "warm400", "noir"] {
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
    let t0 = Date()
    let neg = FilmLUT.negativeCube(stock: s, source: .sceneLinear)
    let t1 = Date()
    let negD = FilmLUT.negativeCube(stock: s, source: .displayReferred)
    let t2 = Date()
    let pc = FilmLUT.printCube(stock: s, controls: FilmControls())
    let t3 = Date()
    let pcCtl = FilmLUT.printCube(stock: s, controls: ctl)
    let t4 = Date()
    timing[id] = [t1, t2, t3, t4].enumerated().map { i, t in t.timeIntervalSince([t0, t1, t2, t3][i]) * 1000 }
    out[id] = [
        "neutral": neutral, "neutral_ctl": neutralCtl, "colors": colors,
        "neg": sample(neg, FilmLUT.negativeDimension, idxNeg),
        "negD": sample(negD, FilmLUT.negativeDimension, idxNeg),
        "print": sample(pc, FilmLUT.printDimension, idxPrint),
        "print_ctl": sample(pcCtl, FilmLUT.printDimension, idxPrint),
    ]
}
out["timing_ms"] = timing
let data = try! JSONSerialization.data(withJSONObject: out)
_ = FileManager.default.createFile(atPath: CommandLine.arguments[1], contents: data)
for (id, t) in timing.sorted(by: { $0.key < $1.key }) {
    print("\(id): cube build ms (negative, negative display, print, print with all sliders moved):",
          t.map { String(format: "%.1f", $0) }.joined(separator: ", "))
}
