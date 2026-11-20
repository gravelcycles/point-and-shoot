import CoreImage
import XCTest
@testable import PointAndShoot

/// Film engine 7's grain (`FilmGrain`, `FilmPipeline.addMeasuredGrain`), measured on a flat
/// grey the way `scripts/phromagraph.py grain` measures Chromagraph's exports: per-pixel std
/// of encoded output, lag-1 autocorrelation and how alike the three channels are.
final class GrainTests: XCTestCase {
    private let side = 256

    private struct Measure {
        var std: [Double]        // per channel, encoded P3
        var luma: Double         // encoded luminance
        var lag1: Double         // along rows, luminance
        var corr: Double         // red–green correlation
    }

    /// Phromagraph on 18% scene grey, rendered as part of a frame whose long side is
    /// `unit` × 1000 px.
    private func render(engine: Int, amount: Double, size: Double = 1, pixel: Bool = false,
                        unit: CGFloat = 2.88) -> [Float] {
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        let grey = CIImage(color: CIColor(red: 0.18, green: 0.18, blue: 0.18, alpha: 1, colorSpace: linear)!)
            .cropped(to: rect)
        var s = FilmPipeline.Settings()
        s.stockID = "phromagraph"
        s.engine = engine
        s.halation = 0
        s.grain = amount
        s.grainSize = size
        s.pixelGrain = pixel
        let out = FilmPipeline.apply(grey, settings: s, unit: unit)
        var buf = [Float](repeating: 0, count: side * side * 4)
        EditPipeline.context.render(out.cropped(to: rect), toBitmap: &buf, rowBytes: side * 16, bounds: rect,
                                    format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!)
        return buf
    }

    private func measure(_ img: [Float], base: [Float]) -> Measure {
        let n = side * side
        var ch = [[Double]](repeating: [Double](repeating: 0, count: n), count: 3)
        for i in 0..<n { for c in 0..<3 { ch[c][i] = Double(img[i * 4 + c] - base[i * 4 + c]) } }
        let l = FilmMath.lumP3
        let y = (0..<n).map { l.0 * ch[0][$0] + l.1 * ch[1][$0] + l.2 * ch[2][$0] }
        func mean(_ v: [Double]) -> Double { v.reduce(0, +) / Double(v.count) }
        func sd(_ v: [Double]) -> Double { let m = mean(v); return (v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count)).squareRoot() }
        let my = mean(y), vy = sd(y) * sd(y)
        var a = 0.0, k = 0
        for row in 0..<side { for x in 0..<(side - 1) { a += (y[row * side + x] - my) * (y[row * side + x + 1] - my); k += 1 } }
        let m0 = mean(ch[0]), m1 = mean(ch[1])
        var cov = 0.0
        for i in 0..<n { cov += (ch[0][i] - m0) * (ch[1][i] - m1) }
        return Measure(std: ch.map(sd), luma: vy.squareRoot(), lag1: a / Double(k) / vy,
                       corr: cov / Double(n) / (sd(ch[0]) * sd(ch[1])))
    }

    /// Engine 7 adds only grain: with grain off it renders exactly like engine 6 (and 5).
    func testEngineSevenChangesOnlyGrain() {
        XCTAssertEqual(FilmLUT.currentEngine, 7)
        let seven = render(engine: 7, amount: 0), six = render(engine: 6, amount: 0), five = render(engine: 5, amount: 0)
        XCTAssertEqual(seven, six, "engine 7 must render like engine 6 without grain")
        XCTAssertEqual(seven, five)
    }

    /// Strength, size and colour follow the mapping measured on Chromagraph's exports: at a
    /// 2880 px frame, Phromagraph at slider 50 (label 1.25, Size 1) is grainDensity × 1.07 of
    /// encoded std per channel on grey, linear in the amount, ×0.52 at Size 0.25 and ×1.42 at
    /// Size 3, the same in every channel, and as fine as Chromagraph's (lag-1 0.245 at Size 1,
    /// 0.609 at Size max).
    func testGrainFollowsTheMeasuredMapping() {
        XCTAssertEqual(FilmGrain.strength(size: 1), 1, accuracy: 1e-12)
        XCTAssertEqual(FilmGrain.strength(size: 0.25), 0.52, accuracy: 0.005)
        XCTAssertEqual(FilmGrain.strength(size: 3), 1.42, accuracy: 0.005)
        XCTAssertEqual(FilmGrain.cellPixels(size: 1, unit: 2.88), 1.2, accuracy: 0.01)
        XCTAssertEqual(FilmGrain.cellPixels(size: 3, unit: 2.88), 1.735, accuracy: 0.01)
        XCTAssertEqual(FilmGrain.cellPixels(size: 0.25, unit: 2.88), FilmGrain.minimumCellPixels, "nothing finer than the floor")
        XCTAssertEqual(FilmGrain.kernel(cell: 1.7).reduce(0, +), 1, accuracy: 1e-12)

        let stock = FilmStock.named("phromagraph")
        let base = render(engine: 7, amount: 0)
        let cases: [(amount: Double, size: Double, lag1: Double)] = [(1, 1, 0.245), (4, 1, 0.245), (1, 0.25, 0.245), (1, 3, 0.609)]
        var size1 = 0.0
        for c in cases {
            let m = measure(render(engine: 7, amount: c.amount, size: c.size), base: base)
            let expected = stock.grainDensity * FilmGrain.outputGain * c.amount * FilmGrain.strength(size: c.size)
            for (i, s) in m.std.enumerated() {
                XCTAssertEqual(s, expected, accuracy: expected * 0.08, "amount \(c.amount) size \(c.size) channel \(i)")
            }
            XCTAssertGreaterThan(m.corr, 0.9, "mostly monochrome")
            let kernel = FilmGrain.kernel(cell: FilmGrain.cellPixels(size: c.size, unit: 2.88))
            XCTAssertEqual(m.lag1, FilmGrain.lag1(kernel), accuracy: 0.03, "amount \(c.amount) size \(c.size)")
            XCTAssertEqual(m.lag1, c.lag1, accuracy: 0.04, "Chromagraph's fineness at size \(c.size)")
            if c.amount == 1 && c.size == 1 { size1 = m.luma }
            if c.amount == 4 { XCTAssertEqual(m.luma / size1, 4, accuracy: 0.2, "linear in the amount") }
        }
        // Pixel Size Grain: one pixel, uncorrelated, at the amount's strength whatever the Size.
        let px = measure(render(engine: 7, amount: 1, size: 3, pixel: true), base: base)
        XCTAssertEqual(px.lag1, 0, accuracy: 0.03)
        XCTAssertEqual(px.std[1], stock.grainDensity * FilmGrain.outputGain, accuracy: 0.08 * stock.grainDensity)
        // The cell is a share of the frame: a bigger frame, bigger (more correlated) grain.
        let big = measure(render(engine: 7, amount: 1, unit: 6), base: render(engine: 7, amount: 0, unit: 6))
        XCTAssertGreaterThan(big.lag1, 0.5)
    }

    /// Migration to engine 7 keeps an older photo's grain as strong (luminance on grey) and,
    /// within the sliders' reach, as fine at a 4032 px export.
    func testMigrationKeepsGrainStrengthAndFineness() {
        let unit: CGFloat = 4.032
        let base = render(engine: 7, amount: 0, unit: unit)
        var r = Look.named("phromagraph")!.recipe
        r.grain = 50
        for engine in [5, 6] {
            r.film?.engine = engine
            let m = FilmMigration.migrate(r, developsFromRAW: true, force: true).recipe
            XCTAssertEqual(m.film?.engine, FilmLUT.currentEngine)
            let old = measure(render(engine: engine, amount: 1, unit: unit), base: base)
            let new = measure(render(engine: 7, amount: m.grain / 50, size: m.grainSizeValue / 100, unit: unit), base: base)
            XCTAssertEqual(new.luma, old.luma, accuracy: old.luma * 0.1, "engine \(engine) → grain \(m.grain) size \(m.grainSizeValue)")
            if engine == 5 {
                XCTAssertEqual(new.lag1, old.lag1, accuracy: 0.05, "engine 5's fine grain is within reach")
                XCTAssertLessThan(m.grainSizeValue, 100)
            } else {
                XCTAssertEqual(m.grainSizeValue, 300, "engine 6's coarse grain gets the largest size")
            }
        }
    }
}
