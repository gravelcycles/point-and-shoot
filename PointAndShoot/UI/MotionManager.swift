import CoreMotion
import Observation
import SwiftUI

/// Gravity-driven level and UI orientation. The UI is locked to portrait (so the preview
/// never jumps), and icons rotate in place like a real camera body.
@Observable
final class MotionManager {
    /// Smoothed angle of the device in the screen plane, radians. 0 = upright portrait,
    /// +π/2 = rotated counter-clockwise into landscape.
    private(set) var angle: Double = 0
    /// The nearest upright orientation, in degrees (0, 90, -90).
    private(set) var bucket: Double = 0
    private(set) var isFlat = false

    var isLandscape: Bool { bucket != 0 }
    var iconRotation: Angle { .degrees(bucket) }
    /// How far off level we are relative to the held orientation, degrees.
    var tiltDegrees: Double { angle * 180 / .pi - bucket }

    private let manager = CMMotionManager()

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let g = motion?.gravity else { return }
            self.process(g)
        }
    }

    func stop() { manager.stopDeviceMotionUpdates() }

    private func process(_ g: CMAcceleration) {
        let flat = abs(g.z) > 0.88
        if flat != isFlat { isFlat = flat }
        guard !flat else { return }

        let raw = atan2(g.x, -g.y)
        // Low-pass, handling wrap-around.
        var delta = raw - angle
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        angle += delta * 0.25

        let degrees = angle * 180 / .pi
        var newBucket = bucket
        // Hysteresis so icons don't flicker at 45°.
        if abs(degrees) < 35 { newBucket = 0 }
        else if degrees > 55 && degrees < 135 { newBucket = 90 }
        else if degrees < -55 && degrees > -135 { newBucket = -90 }
        if newBucket != bucket {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { bucket = newBucket }
        }
    }
}
