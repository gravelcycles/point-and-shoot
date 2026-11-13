// Dumps FilmModel numbers for scripts/print-look.py parity (compiled with swiftc on any
// platform: FilmModel.swift is Foundation-only).
import Foundation
let s = FilmStock.printLook
var out: [String: Any] = [:]
var neutral: [[Double]] = []
for st in stride(from: -6.0, through: 6.0, by: 0.5) {
    let r = FilmLUT.neutralResponse(stops: st, stock: s)
    neutral.append([r.0, r.1, r.2])
}
out["neutral"] = neutral
var ctl = FilmControls(); ctl.contrast = 0.4; ctl.saturation = 0.5; ctl.crossover = -0.5; ctl.highlights = 0.3; ctl.shadows = -0.4
var neutralCtl: [[Double]] = []
for st in stride(from: -6.0, through: 6.0, by: 0.5) {
    let r = FilmLUT.neutralResponse(stops: st, stock: s, controls: ctl)
    neutralCtl.append([r.0, r.1, r.2])
}
out["neutral_ctl"] = neutralCtl
let t0 = Date()
let neg = FilmLUT.negativeCube(stock: s, source: .sceneLinear)
let t1 = Date()
let negD = FilmLUT.negativeCube(stock: s, source: .displayReferred)
let t2 = Date()
let pc = FilmLUT.printCube(stock: s, controls: FilmControls())
let t3 = Date()
let pcCtl = FilmLUT.printCube(stock: s, controls: ctl)
let t4 = Date()
out["timing_ms"] = [t1.timeIntervalSince(t0) * 1000, t2.timeIntervalSince(t1) * 1000, t3.timeIntervalSince(t2) * 1000,
                    t4.timeIntervalSince(t3) * 1000]
func sample(_ cube: [Float], _ n: Int, _ idx: [(Int, Int, Int)]) -> [[Double]] {
    idx.map { (r, g, b) in let o = ((b * n + g) * n + r) * 4; return [Double(cube[o]), Double(cube[o + 1]), Double(cube[o + 2])] }
}
let idxNeg = [(0, 0, 0), (10, 20, 30), (40, 40, 40), (47, 47, 47), (44, 12, 33), (21, 22, 23), (5, 46, 31)]
let idx48 = [(0, 0, 0), (10, 20, 30), (24, 24, 24), (47, 47, 47), (40, 9, 25), (16, 17, 18), (3, 45, 23)]
out["neg"] = sample(neg, FilmLUT.negativeDimension, idxNeg)
out["negD"] = sample(negD, FilmLUT.negativeDimension, idxNeg)
out["print"] = sample(pc, FilmLUT.printDimension, idx48)
out["print_ctl"] = sample(pcCtl, FilmLUT.printDimension, idx48)
let data = try! JSONSerialization.data(withJSONObject: out)
_ = FileManager.default.createFile(atPath: CommandLine.arguments[1], contents: data)
print("cube build ms (negative, negative display, print, print with all sliders moved):", out["timing_ms"]!)
