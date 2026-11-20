// Renders a DNG through the app's own film pipeline (FilmPipeline.swift, on macOS's Core
// Image), the way EditPipeline does under a film look, and writes a 16-bit sRGB PNG. For
// measuring the app's grain against a reference app's exports (scripts/phromagraph.py grain).
//
//   swiftc -O -o film-render scripts/film-render/main.swift PointAndShoot/Editor/FilmModel.swift \
//     PointAndShoot/Editor/FilmStock+Stocks.swift PointAndShoot/Editor/FilmPipeline.swift
//   film-render IMG.dng OUT.png --long 2880 --ev 1.86 --stock phromagraph --grain 1 --size 1 \
//     [--engine N] [--pixel] [--color C] [--seed-shift N]
//
// --grain is FilmPipeline.Settings.grain (EditRecipe.grain / 50), --size is grainSize
// (EditRecipe.grainSize / 100). The develop is CIRAWFilter as scripts/raw-develop.swift does
// it (boost 0, no local tone map, no sharpening, NR floored), at the scale that gives --long.
import CoreImage
import Foundation

var a = Array(CommandLine.arguments.dropFirst())
func opt(_ k: String, _ d: String) -> String {
    if let i = a.firstIndex(of: k), i + 1 < a.count { let v = a[i + 1]; a.removeSubrange(i...(i + 1)); return v }
    return d
}
func flag(_ k: String) -> Bool { if let i = a.firstIndex(of: k) { a.remove(at: i); return true }; return false }
let long = Double(opt("--long", "2880"))!
let ev = Double(opt("--ev", "1.86"))!
let stockID = opt("--stock", "phromagraph")
var s = FilmPipeline.Settings()
s.stockID = stockID
s.halation = Double(opt("--halation", "1"))!
s.grain = Double(opt("--grain", "0"))!
s.grainSize = Double(opt("--size", "1"))!
s.grainColor = Double(opt("--color", "0"))!
s.engine = Int(opt("--engine", String(FilmLUT.currentEngine)))!
s.pixelGrain = flag("--pixel")
guard a.count == 2 else { print("usage: film-render IMG.dng OUT.png [options]"); exit(2) }

let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
let ctx = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAf])
guard let raw = CIRAWFilter(imageURL: URL(fileURLWithPath: a[0])) else { print("can't open", a[0]); exit(1) }
if raw.isLocalToneMapSupported { raw.localToneMapAmount = 0 }
raw.boostAmount = 0
if raw.isSharpnessSupported { raw.sharpnessAmount = 0 }
if raw.isColorNoiseReductionSupported { raw.colorNoiseReductionAmount = max(raw.colorNoiseReductionAmount, 0.5) }
if raw.isLuminanceNoiseReductionSupported { raw.luminanceNoiseReductionAmount = max(raw.luminanceNoiseReductionAmount, 0.5) }
raw.extendedDynamicRangeAmount = 0
raw.exposure = Float(ev)
let native = raw.nativeSize
raw.scaleFactor = Float(long / Double(max(native.width, native.height)))
guard let img = raw.outputImage else { print("no output"); exit(1) }
let ext = img.extent.integral
let moved = img.transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
    .cropped(to: CGRect(origin: .zero, size: ext.size))
let unit = max(ext.width, ext.height) / 1000
let out = FilmPipeline.apply(moved, settings: s, unit: unit)
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
try ctx.writePNGRepresentation(of: out, to: URL(fileURLWithPath: a[1]), format: .RGBA16, colorSpace: srgb)
print(String(format: "%@ %dx%d  ev %+.2f  grain %.2f size %.2f engine %d", a[1], Int(ext.width), Int(ext.height),
             ev, s.grain, s.grainSize, s.engine))

// Stubs for the app types FilmPipeline's prewarm helpers mention (never called here).
struct Look { var capturesRAW = false; var recipe = EditRecipe(); static let all: [Look] = [] }
struct EditRecipe { struct Film { var stock: String?; var renderEngine = FilmLUT.currentEngine }; var film: Film?; var exposure = 0.0; var filmControls = FilmControls() }
extension FilmStock { static func resolved(for r: EditRecipe) -> FilmStock? { nil } }
