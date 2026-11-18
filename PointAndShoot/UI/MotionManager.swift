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
        Diag.log(.ui, "orientation: motion started (\(Self.name(bucket)))")
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        Diag.log(.ui, "orientation: motion stopped (\(Self.name(bucket)))")
    }

    private func process(_ g: CMAcceleration) {
        let s = Self.step(State(angle: angle, bucket: bucket, isFlat: isFlat), gravity: (g.x, g.y, g.z))
        if s.isFlat != isFlat { isFlat = s.isFlat }
        angle = s.angle
        if s.bucket != bucket {
            Diag.log(.ui, String(format: "orientation: %@ → %@ (%.0f°)", Self.name(bucket), Self.name(s.bucket), s.angle * 180 / .pi))
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { bucket = s.bucket }
        }
    }

    // MARK: The math (pure, unit-tested)

    struct State: Equatable {
        var angle: Double
        var bucket: Double
        var isFlat: Bool
    }

    /// One gravity sample: the smoothed angle in the screen plane and the held orientation.
    /// The angle is kept in (−π, π]: unwrapped, it ran past ±180° whenever the phone went
    /// upside down, and upright then read as 360°, matching no orientation, so icons and
    /// frame lines stayed stuck in the last one ("the horizontal vertical orientation gets
    /// stuck a lot", on device).
    static func step(_ s: State, gravity g: (x: Double, y: Double, z: Double)) -> State {
        var out = s
        out.isFlat = abs(g.z) > 0.88
        guard !out.isFlat else { return out }
        let raw = atan2(g.x, -g.y)
        // Low-pass, handling wrap-around.
        out.angle = wrap(s.angle + wrap(raw - s.angle) * 0.25)
        let degrees = out.angle * 180 / .pi
        // Hysteresis so icons don't flicker at 45°. Upside down (beyond ±135°) keeps the
        // current orientation: the UI has no upside-down layout.
        if abs(degrees) < 35 { out.bucket = 0 }
        else if degrees > 55 && degrees < 135 { out.bucket = 90 }
        else if degrees < -55 && degrees > -135 { out.bucket = -90 }
        return out
    }

    /// An angle in (−π, π].
    static func wrap(_ a: Double) -> Double {
        var x = a.truncatingRemainder(dividingBy: 2 * .pi)
        if x > .pi { x -= 2 * .pi }
        if x <= -.pi { x += 2 * .pi }
        return x
    }

    static func name(_ bucket: Double) -> String {
        switch bucket {
        case 90: "landscape (left)"
        case -90: "landscape (right)"
        default: "portrait"
        }
    }
}
