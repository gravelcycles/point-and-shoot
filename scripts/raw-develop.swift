// Develops DNGs with Core Image's CIRAWFilter the way the app does under a film look
// (EditPipeline.configure: boost 0, no local tone map, no sharpening, chroma NR >= 0.5,
// the camera's own luminance NR floored at 50%), and writes scene-linear sRGB-primaries
// float32 pixels for the Python tools (scripts/phromagraph.py).
//
//   swift scripts/raw-develop.swift OUT_DIR SCALE IMG.dng [...]
//   swift scripts/raw-develop.swift --apple OUT_DIR SCALE IMG.dng [...]
//
// --apple keeps CIRAWFilter's defaults instead (Apple's tone curve, boost and local tone
// map): roughly the processed photo / viewfinder, as display-linear light.
//
// Each IMG.dng becomes OUT_DIR/IMG.f32: an 8-byte header (UInt32 width, UInt32 height,
// little-endian), then width × height × 3 Float32 (RGB, linear, extended range), oriented
// upright. macOS only (Core Image's RAW engine); the simulator can't decode RAW.
import CoreImage
import Foundation

var args = CommandLine.arguments
let appleLook = args.count > 1 && args[1] == "--apple"
if appleLook { args.remove(at: 1) }
guard args.count >= 4, let scale = Float(args[2]) else {
    FileHandle.standardError.write("usage: raw-develop.swift OUT_DIR SCALE IMG.dng [...]\n".data(using: .utf8)!)
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
let ctx = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAf])

for path in args[3...] {
    let url = URL(fileURLWithPath: path)
    guard let raw = CIRAWFilter(imageURL: url) else { print("can't open", path); continue }
    if !appleLook {
        if raw.isLocalToneMapSupported { raw.localToneMapAmount = 0 }
        raw.boostAmount = 0
        if raw.isSharpnessSupported { raw.sharpnessAmount = 0 }
        if raw.isColorNoiseReductionSupported { raw.colorNoiseReductionAmount = max(raw.colorNoiseReductionAmount, 0.5) }
        if raw.isLuminanceNoiseReductionSupported { raw.luminanceNoiseReductionAmount = max(raw.luminanceNoiseReductionAmount, 0.5) }
    }
    raw.extendedDynamicRangeAmount = 0
    raw.scaleFactor = scale
    guard let img = raw.outputImage else { print("no output for", path); continue }
    let ext = img.extent.integral
    let w = Int(ext.width), h = Int(ext.height)
    var rgba = [Float](repeating: 0, count: w * h * 4)
    ctx.render(img, toBitmap: &rgba, rowBytes: w * 16, bounds: ext, format: .RGBAf, colorSpace: linear)
    var data = Data()
    var hdr = [UInt32(w).littleEndian, UInt32(h).littleEndian]
    data.append(Data(bytes: &hdr, count: 8))
    var rgb = [Float](repeating: 0, count: w * h * 3)
    for i in 0..<(w * h) { rgb[3 * i] = rgba[4 * i]; rgb[3 * i + 1] = rgba[4 * i + 1]; rgb[3 * i + 2] = rgba[4 * i + 2] }
    rgb.withUnsafeBytes { data.append(contentsOf: $0) }
    let out = outDir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".f32")
    try data.write(to: out)
    print(String(format: "%@ %dx%d  NR %.2f/%.2f  LTM %.2f  boost %.2f", url.lastPathComponent, w, h,
                 raw.luminanceNoiseReductionAmount, raw.colorNoiseReductionAmount,
                 raw.isLocalToneMapSupported ? raw.localToneMapAmount : 0, raw.boostAmount))
}
