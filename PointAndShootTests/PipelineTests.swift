import CoreImage
import XCTest
@testable import PointAndShoot

/// Every filter through the real edit pipeline on the simulator's GPU: catches crashes,
/// NaNs and blank output in the film model before a photo ever does.
final class PipelineTests: XCTestCase {
    /// A small colourful test image: horizontal hue ramp, vertical brightness ramp.
    private func testImage() -> CIImage {
        let hue = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 96, y: 0),
            "inputColor0": CIColor(red: 0.9, green: 0.2, blue: 0.1),
            "inputColor1": CIColor(red: 0.1, green: 0.4, blue: 0.9),
        ])!.outputImage!
        let shade = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0, y: 72),
            "inputColor0": CIColor(red: 0.05, green: 0.05, blue: 0.05),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1),
        ])!.outputImage!
        return hue.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: shade])
            .cropped(to: CGRect(x: 0, y: 0, width: 96, height: 72))
    }

    private func pixels(of image: CIImage) throws -> [Float] {
        let rect = CGRect(x: 0, y: 0, width: 96, height: 72)
        var buffer = [Float](repeating: 0, count: 96 * 72 * 4)
        EditPipeline.context.render(image.cropped(to: rect), toBitmap: &buffer, rowBytes: 96 * 16,
                                    bounds: rect, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return buffer
    }

    func testEveryLookRendersFiniteVariedPixels() throws {
        let base = testImage()
        for look in Look.all {
            let out = EditPipeline.apply(look.recipe, to: base, developedFromRAW: false)
            XCTAssertFalse(out.extent.isInfinite, "\(look.id): infinite extent")
            let px = try pixels(of: out)
            XCTAssertTrue(px.allSatisfy { $0.isFinite }, "\(look.id): NaN/inf pixels")
            var lo = Float.greatestFiniteMagnitude
            var hi = -Float.greatestFiniteMagnitude
            var i = 0
            while i + 2 < px.count {
                let sum: Float = px[i] + px[i + 1] + px[i + 2]
                lo = min(lo, sum)
                hi = max(hi, sum)
                i += 4
            }
            XCTAssertGreaterThan(hi - lo, 0.05, "\(look.id): flat output")
        }
    }

    func testSceneKeyIsPositiveAndFinite() throws {
        let key = try XCTUnwrap(FilmPipeline.sceneKey(of: testImage(), context: EditPipeline.context, source: .displayReferred))
        XCTAssertTrue(key.isFinite && key > 0)
    }

    func testBakeQueueRunsInOrder() async {
        // Each later bake is shorter, so if bakes overlapped they'd finish out of order.
        let log = OrderLog()
        var tasks: [Task<Void, Never>] = []
        for i in 0..<4 {
            tasks.append(Task {
                await BakeQueue.shared.run {
                    try? await Task.sleep(nanoseconds: UInt64(4 - i) * 40_000_000)
                    await log.add(i)
                }
            })
            try? await Task.sleep(nanoseconds: 20_000_000)   // enqueue in a known order
        }
        for t in tasks { await t.value }
        let items = await log.items
        XCTAssertEqual(items, [0, 1, 2, 3], "Bakes must not overlap or reorder")
    }
}

private actor OrderLog {
    var items: [Int] = []
    func add(_ i: Int) { items.append(i) }
}
