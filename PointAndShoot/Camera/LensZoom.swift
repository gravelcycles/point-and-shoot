import CoreGraphics
import Foundation

/// Lens labels as zoom relative to the main camera, like the built-in Camera app: the
/// ultra wide is 0.5, the main lens 1×, its 2× crop or a 2× telephoto 2, then 2.5, 3, 5.
/// Pure, so the rounding is unit-tested.
enum LensZoom {
    /// The numbers iPhone lenses are known by.
    static let marketing: [CGFloat] = [0.5, 1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10]

    /// A lens's zoom relative to the main lens, from their 35 mm-equivalent focal lengths,
    /// snapped to the nearest marketing value when within 12% (13 / 26 mm → 0.5,
    /// 77 / 26 mm → 3, 120 / 24 mm → 5), otherwise to a tenth.
    static func relative(focalLength: Int, mainFocalLength: Int) -> CGFloat {
        guard focalLength > 0, mainFocalLength > 0 else { return 1 }
        let ratio = CGFloat(focalLength) / CGFloat(mainFocalLength)
        if let near = marketing.min(by: { abs(log($0 / ratio)) < abs(log($1 / ratio)) }),
           abs(near - ratio) / near < 0.12 {
            return near
        }
        return (ratio * 10).rounded() / 10
    }

    /// "0.5", "1", "2.5", "1.4": no trailing zeros, one decimal at most.
    static func label(_ zoom: CGFloat) -> String {
        let tenths = (zoom * 10).rounded() / 10
        if tenths == tenths.rounded() { return String(Int(tenths)) }
        return String(format: "%.1f", Double(tenths))
    }
}
