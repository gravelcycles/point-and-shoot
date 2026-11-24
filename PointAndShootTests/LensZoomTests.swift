import XCTest
@testable import PointAndShoot

/// The lens picker labels lenses by zoom relative to the main lens (0.5, 1×, 2, 3), not mm.
final class LensZoomTests: XCTestCase {
    func testIPhoneLensesGetTheirFamiliarNumbers() {
        // (lens mm, main mm, label): 12 Pro, 12 Pro Max, 13–15 Pro, 15 Pro Max / 16 Pro.
        let cases: [(Int, Int, CGFloat)] = [
            (13, 26, 0.5), (26, 26, 1), (52, 26, 2), (65, 26, 2.5), (77, 26, 3),
            (13, 24, 0.5), (24, 24, 1), (48, 24, 2), (120, 24, 5),
            (14, 28, 0.5), (28, 28, 1),
        ]
        for (lens, main, expected) in cases {
            XCTAssertEqual(LensZoom.relative(focalLength: lens, mainFocalLength: main), expected,
                           "\(lens) mm on a \(main) mm main")
        }
    }

    func testOddFocalLengthsRoundToATenth() {
        XCTAssertEqual(LensZoom.relative(focalLength: 35, mainFocalLength: 24), 1.5)   // 1.46: within 12%
        XCTAssertEqual(LensZoom.relative(focalLength: 31, mainFocalLength: 24), 1.3)   // 1.29: not near 1 or 1.5
        XCTAssertEqual(LensZoom.relative(focalLength: 26, mainFocalLength: 0), 1, "no main lens: 1")
    }

    func testLabels() {
        XCTAssertEqual(LensZoom.label(0.5), "0.5")
        XCTAssertEqual(LensZoom.label(1), "1")
        XCTAssertEqual(LensZoom.label(2), "2")
        XCTAssertEqual(LensZoom.label(2.5), "2.5")
        XCTAssertEqual(LensZoom.label(1.43), "1.4")
        XCTAssertEqual(LensZoom.label(2.98), "3")
    }
}
