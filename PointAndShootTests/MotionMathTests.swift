import XCTest
@testable import PointAndShoot

/// The held orientation from gravity (`MotionManager.step`).
final class MotionMathTests: XCTestCase {
    private func settle(_ s: MotionManager.State, at degrees: Double, samples: Int = 40) -> MotionManager.State {
        // Gravity in the screen plane for the phone rotated `degrees` (counter-clockwise).
        let a = degrees * .pi / 180
        var out = s
        for _ in 0..<samples { out = MotionManager.step(out, gravity: (x: sin(a), y: -cos(a), z: 0)) }
        return out
    }

    func testRotatingThroughTheOrientations() {
        var s = MotionManager.State(angle: 0, bucket: 0, isFlat: false)
        s = settle(s, at: 90); XCTAssertEqual(s.bucket, 90)
        s = settle(s, at: 0); XCTAssertEqual(s.bucket, 0)
        s = settle(s, at: -90); XCTAssertEqual(s.bucket, -90)
        s = settle(s, at: 0); XCTAssertEqual(s.bucket, 0)
    }

    /// On device the orientation got stuck: after the phone went upside down, the smoothed
    /// angle ran past ±180° and upright read as 360°, matching no orientation.
    func testUpsideDownAndBackNeverGetsStuck() {
        var s = MotionManager.State(angle: 0, bucket: 0, isFlat: false)
        for path in [[90.0, 179, -179, -90, 0], [-90.0, -179, 179, 90, 0], [170.0, -170, 170, -170, 0]] {
            for d in path { s = settle(s, at: d) }
            XCTAssertEqual(s.bucket, 0, "stuck after \(path)")
            XCTAssertLessThan(abs(s.angle), 0.05, "angle unwrapped after \(path): \(s.angle)")
        }
        // Many full turns: the angle stays in (−π, π].
        for _ in 0..<5 { for d in stride(from: 0.0, through: 360, by: 30) { s = settle(s, at: d, samples: 8) } }
        XCTAssertLessThanOrEqual(abs(s.angle), .pi)
        s = settle(s, at: 90)
        XCTAssertEqual(s.bucket, 90)
    }

    func testFlatKeepsTheOrientation() {
        var s = settle(MotionManager.State(angle: 0, bucket: 0, isFlat: false), at: 90)
        s = MotionManager.step(s, gravity: (x: 0.1, y: 0, z: -0.99))
        XCTAssertTrue(s.isFlat)
        XCTAssertEqual(s.bucket, 90, "lying flat keeps the last orientation")
    }

    func testWrap() {
        XCTAssertEqual(MotionManager.wrap(3 * .pi), .pi, accuracy: 1e-12)
        XCTAssertEqual(MotionManager.wrap(-3 * .pi), .pi, accuracy: 1e-12)
        XCTAssertEqual(MotionManager.wrap(2 * .pi + 0.1), 0.1, accuracy: 1e-12)
    }

    /// The photo's rotation (the owner: "horizontal/vertical switching still doesn't work").
    /// The rotation coordinator stays portrait with Rotation Lock on, so when it disagrees with
    /// gravity, gravity decides; when they agree, the coordinator's exact angle is kept.
    func testCaptureRotationFollowsGravityWhenTheCoordinatorDisagrees() {
        typealias C = CameraController
        // Rotation Lock: the coordinator says portrait, the phone is held landscape.
        XCTAssertEqual(C.captureRotation(coordinator: 90, held: 90, front: false), 0)
        XCTAssertEqual(C.captureRotation(coordinator: 90, held: -90, front: false), 180)
        XCTAssertEqual(C.captureRotation(coordinator: 90, held: 90, front: true), 180)
        XCTAssertEqual(C.captureRotation(coordinator: 90, held: -90, front: true), 0)
        // They agree: keep the coordinator's angle.
        XCTAssertEqual(C.captureRotation(coordinator: 180, held: -90, front: false), 180)
        XCTAssertEqual(C.captureRotation(coordinator: 0, held: 90, front: false), 0)
        XCTAssertEqual(C.captureRotation(coordinator: 90, held: 0, front: false), 90)
        // The coordinator stuck in landscape after the phone came back upright.
        XCTAssertEqual(C.captureRotation(coordinator: 0, held: 0, front: false), 90)
        // No coordinator at all.
        XCTAssertEqual(C.captureRotation(coordinator: nil, held: 0, front: false), 90)
        XCTAssertEqual(C.captureRotation(coordinator: nil, held: 90, front: false), 0)
    }
}
