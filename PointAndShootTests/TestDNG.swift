import Foundation

/// Builds a tiny, valid DNG in memory (sRGB primaries, D65), so the RAW save/develop paths
/// can be tested in the simulator without shipping sample files. `bayer: true` makes an
/// RGGB sensor mosaic like the camera's Bayer RAW (what Zero and Print develop); otherwise
/// a linear (demosaiced) 16-bit RGB DNG like ProRAW.
enum TestDNG {
    static func make(width: Int = 64, height: Int = 48, orientation: UInt16 = 1, bayer: Bool = false) -> Data {
        var out = Data()
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }

        enum Kind: UInt16 { case byte = 1, ascii = 2, short = 3, long = 4, rational = 5, srational = 10 }
        struct Entry { let tag: UInt16; let kind: Kind; let count: UInt32; let bytes: [UInt8] }
        func le16(_ v: [UInt16]) -> [UInt8] { v.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] } }
        func le32(_ v: [UInt32]) -> [UInt8] { v.flatMap { x in (0..<4).map { UInt8((x >> (8 * $0)) & 0xff) } } }
        func ascii(_ s: String) -> [UInt8] { Array(s.utf8) + [0] }
        func srational(_ v: [Double]) -> [UInt8] {
            v.flatMap { d -> [UInt8] in
                let n = Int32((d * 10_000).rounded())
                return le32([UInt32(bitPattern: n), 10_000])
            }
        }
        func rational(_ v: [Double]) -> [UInt8] { v.flatMap { le32([UInt32((($0) * 10_000).rounded()), 10_000]) } }

        let samples = bayer ? 1 : 3
        let pixelBytes = width * height * samples * 2
        // XYZ (D65) → linear sRGB: the "camera" is sRGB.
        let colorMatrix = [3.2406, -1.5372, -0.4986, -0.9689, 1.8758, 0.0415, 0.0557, -0.2040, 1.0570]

        var entries: [Entry] = [
            Entry(tag: 254, kind: .long, count: 1, bytes: le32([0])),
            Entry(tag: 256, kind: .long, count: 1, bytes: le32([UInt32(width)])),
            Entry(tag: 257, kind: .long, count: 1, bytes: le32([UInt32(height)])),
            Entry(tag: 258, kind: .short, count: UInt32(samples), bytes: le16(Array(repeating: 16, count: samples))),
            Entry(tag: 259, kind: .short, count: 1, bytes: le16([1])),
            Entry(tag: 262, kind: .short, count: 1, bytes: le16([bayer ? 32803 : 34892])),   // CFA / LinearRaw
            Entry(tag: 271, kind: .ascii, count: 0, bytes: ascii("PointAndShoot")),
            Entry(tag: 272, kind: .ascii, count: 0, bytes: ascii("Test DNG")),
            Entry(tag: 273, kind: .long, count: 1, bytes: le32([0])),        // patched below
            Entry(tag: 274, kind: .short, count: 1, bytes: le16([orientation])),
            Entry(tag: 277, kind: .short, count: 1, bytes: le16([UInt16(samples)])),
            Entry(tag: 278, kind: .long, count: 1, bytes: le32([UInt32(height)])),
            Entry(tag: 279, kind: .long, count: 1, bytes: le32([UInt32(pixelBytes)])),
            Entry(tag: 284, kind: .short, count: 1, bytes: le16([1])),
        ]
        if bayer {
            entries += [
                Entry(tag: 33421, kind: .short, count: 2, bytes: le16([2, 2])),   // CFARepeatPatternDim
                Entry(tag: 33422, kind: .byte, count: 4, bytes: [0, 1, 1, 2]),    // CFAPattern RGGB
            ]
        }
        entries += [
            Entry(tag: 50706, kind: .byte, count: 4, bytes: [1, 4, 0, 0]),   // DNGVersion
            Entry(tag: 50707, kind: .byte, count: 4, bytes: [1, 1, 0, 0]),   // DNGBackwardVersion
            Entry(tag: 50708, kind: .ascii, count: 0, bytes: ascii("PointAndShoot Test")),
        ]
        if bayer {
            entries += [
                Entry(tag: 50710, kind: .byte, count: 3, bytes: [0, 1, 2]),       // CFAPlaneColor
                Entry(tag: 50711, kind: .short, count: 1, bytes: le16([1])),      // CFALayout
            ]
        }
        entries += [
            Entry(tag: 50717, kind: .long, count: UInt32(samples), bytes: le32(Array(repeating: 65535, count: samples))),
            Entry(tag: 50721, kind: .srational, count: 9, bytes: srational(colorMatrix)),  // ColorMatrix1
            Entry(tag: 50728, kind: .rational, count: 3, bytes: rational([1, 1, 1])),      // AsShotNeutral
            Entry(tag: 50778, kind: .short, count: 1, bytes: le16([21])),                  // D65
        ]
        entries = entries.map { e in
            e.kind == .ascii ? Entry(tag: e.tag, kind: e.kind, count: UInt32(e.bytes.count), bytes: e.bytes) : e
        }

        // Layout: header (8) | IFD | out-of-line values | pixels.
        let ifdSize = 2 + entries.count * 12 + 4
        var extraOffset = 8 + ifdSize
        var extra: [UInt8] = []
        var valueFields: [[UInt8]] = []
        for e in entries {
            if e.bytes.count <= 4 {
                valueFields.append(e.bytes + Array(repeating: 0, count: 4 - e.bytes.count))
            } else {
                if extra.count % 2 == 1 { extra.append(0) }   // word-align
                let offset = UInt32(8 + ifdSize + extra.count)
                extra.append(contentsOf: e.bytes)
                valueFields.append(le32([offset]))
            }
        }
        extraOffset += extra.count
        if extraOffset % 2 == 1 { extra.append(0); extraOffset += 1 }
        let pixelOffset = UInt32(extraOffset)
        if let i = entries.firstIndex(where: { $0.tag == 273 }) { valueFields[i] = le32([pixelOffset]) }

        out.append(contentsOf: [0x49, 0x49])   // "II"
        u16(42)
        u32(8)
        u16(UInt16(entries.count))
        for (e, value) in zip(entries, valueFields) {
            u16(e.tag)
            u16(e.kind.rawValue)
            u32(e.count)
            out.append(contentsOf: value)
        }
        u32(0)   // no next IFD
        out.append(contentsOf: extra)

        // A colourful gradient so a develop has something to show.
        for y in 0..<height {
            for x in 0..<width {
                let r = UInt16(2000 + 50_000 * x / max(width - 1, 1))
                let g = UInt16(2000 + 50_000 * y / max(height - 1, 1))
                let b: UInt16 = 20_000
                if bayer {
                    // RGGB: R at (even, even), B at (odd, odd), G elsewhere.
                    u16(y % 2 == 0 ? (x % 2 == 0 ? r : g) : (x % 2 == 0 ? g : b))
                } else {
                    u16(r); u16(g); u16(b)
                }
            }
        }
        return out
    }
}
