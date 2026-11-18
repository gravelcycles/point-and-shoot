import CoreImage
import XCTest
@testable import PointAndShoot

/// The editor's zoom bitmap lives in a Metal texture (`MetalImageView.Coordinator.renderToTexture`):
/// it must come back upright, in the same place, with the same colors.
final class CanvasBitmapTests: XCTestCase {
    private func pixel(_ image: CIImage, _ x: CGFloat, _ y: CGFloat) -> [Float] {
        var px = [Float](repeating: 0, count: 4)
        EditPipeline.context.render(image, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                                    format: .RGBAf, colorSpace: EditPipeline.displayColorSpace)
        return px
    }

    func testTheBitmapIsUprightAndFaithful() throws {
        // Bright red at the top, dark blue at the bottom, offset from the origin like a crop.
        let extent = CGRect(x: 40, y: 20, width: 64, height: 48)
        let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 40, y: 20), "inputPoint1": CIVector(x: 40, y: 68),
            "inputColor0": CIColor(red: 0.05, green: 0.1, blue: 0.6),
            "inputColor1": CIColor(red: 0.9, green: 0.2, blue: 0.1),
        ])!.outputImage!.cropped(to: extent)
        let bitmap = try XCTUnwrap(MetalImageView.Coordinator.renderToTexture(gradient, extent: extent))
        XCTAssertEqual(bitmap.extent, extent, "same place")
        for (x, y) in [(45.0, 24.0), (70.0, 44.0), (100.0, 64.0)] {
            let a = pixel(gradient, x, y), b = pixel(bitmap, x, y)
            for c in 0..<3 { XCTAssertEqual(a[c], b[c], accuracy: 0.02, "channel \(c) at (\(x), \(y))") }
        }
        XCTAssertGreaterThan(pixel(bitmap, 70, 64)[0], pixel(bitmap, 70, 24)[0], "upright: red stays at the top")
    }
}
