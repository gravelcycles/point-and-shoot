// Renders the app icon's Dark and Tinted variants (iOS 18+ Home Screen appearances) into
// PointAndShoot/Assets.xcassets/AppIcon.appiconset. The default AppIcon.png is left as is;
// this redraws the same design: a seven-blade aperture in a yellow-ringed lens, plus a dot.
//
//   swift scripts/make-icon-variants.swift
//
// Dark: transparent background (iOS supplies its dark backdrop), same colours.
// Tinted: grayscale on black; iOS colours it with the user's tint.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
                                 : "PointAndShoot/Assets.xcassets/AppIcon.appiconset")

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func gray(_ w: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: w, green: w, blue: w, alpha: a) }

enum Variant { case dark, tinted }

// Design coordinates measured from AppIcon.png (origin top-left).
let center = CGPoint(x: 512, y: 532)
let bladeRadius: CGFloat = 250
let holeRadius: CGFloat = 95
// Blade shades, starting with the blade from the rightmost vertex going clockwise (downwards).
let bladeHex: [UInt32] = [0x2A2A2E, 0x303034, 0x37373B, 0x3F3F43, 0x4A4A4F, 0x2C2C30, 0x36363A]

func circle(_ ctx: CGContext, _ r: CGFloat, at c: CGPoint = center) -> CGRect {
    CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
}

func render(_ v: Variant) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: 1, y: -1)

    if v == .tinted {
        ctx.setFillColor(gray(0))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    }

    // Lens body, yellow ring, dark glass.
    ctx.setFillColor(v == .dark ? rgb(0x2A2A2E) : gray(0.16))
    ctx.fillEllipse(in: circle(ctx, 330))
    ctx.setStrokeColor(v == .dark ? rgb(0xFFCC0F) : gray(1))
    ctx.setLineWidth(11)
    ctx.strokeEllipse(in: circle(ctx, 295))
    ctx.setFillColor(v == .dark ? rgb(0x0A0A0C) : gray(0))
    ctx.fillEllipse(in: circle(ctx, 289))

    // Aperture: a heptagon cut into blades by lines from each vertex to the hole's edge.
    func polar(_ r: CGFloat, _ deg: CGFloat) -> CGPoint {
        let a = deg * .pi / 180
        return CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
    }
    let step: CGFloat = 360 / 7
    for k in 0..<7 {
        let a0 = CGFloat(k) * step, a1 = CGFloat(k + 1) * step
        ctx.beginPath()
        ctx.move(to: polar(bladeRadius, a0))
        ctx.addLine(to: polar(bladeRadius, a1))
        ctx.addLine(to: polar(holeRadius, a1 + 27))
        ctx.addLine(to: polar(holeRadius, a0 + 27))
        ctx.closePath()
        let shade = bladeHex[k]
        let lum = CGFloat((shade >> 16) & 0xFF) / 255
        ctx.setFillColor(v == .dark ? rgb(shade) : gray(min(1, lum * 1.9)))
        ctx.fillPath()
    }
    ctx.setFillColor(v == .dark ? rgb(0x040405) : gray(0))
    ctx.fillEllipse(in: circle(ctx, holeRadius))

    // The "ready" dot.
    ctx.setFillColor(v == .dark ? rgb(0xFFCC0F) : gray(1))
    ctx.fillEllipse(in: circle(ctx, 50, at: CGPoint(x: 825, y: 170)))

    return ctx.makeImage()!
}

func write(_ image: CGImage, _ name: String) {
    let url = out.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    precondition(CGImageDestinationFinalize(dest), "couldn't write \(url.path)")
    print("wrote", url.path)
}

write(render(.dark), "AppIcon-dark.png")
write(render(.tinted), "AppIcon-tinted.png")
