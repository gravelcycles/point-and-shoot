import SwiftUI

struct GridOverlay: View {
    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            for i in 1...2 {
                let x = size.width * CGFloat(i) / 3
                let y = size.height * CGFloat(i) / 3
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
            }
            ctx.stroke(path, with: .color(.white.opacity(0.28)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

/// Cinema frame lines. `landscape` flips the guide when the phone is held sideways.
struct FrameLinesOverlay: View {
    let ratio: CGFloat
    let landscape: Bool

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            // Ratio is width/height in the held orientation.
            let target = landscape ? 1 / ratio : ratio
            let frame: CGSize = {
                if size.width / size.height > target {
                    return CGSize(width: size.height * target, height: size.height)
                }
                return CGSize(width: size.width, height: size.width / target)
            }()
            let rect = CGRect(x: (size.width - frame.width) / 2, y: (size.height - frame.height) / 2,
                              width: frame.width, height: frame.height)
            ZStack {
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: size))
                    p.addRect(rect)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                Path { p in p.addRect(rect) }
                    .stroke(Color.white.opacity(0.7), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

struct LevelOverlay: View {
    let motion: MotionManager

    var body: some View {
        let tilt = motion.tiltDegrees
        let level = abs(tilt) < 0.8
        ZStack {
            // Fixed reference (the camera)
            HStack(spacing: 80) {
                Rectangle().frame(width: 22, height: 1.5)
                Rectangle().frame(width: 22, height: 1.5)
            }
            .foregroundStyle(level ? Color.yellow : Color.white.opacity(0.75))
            .rotationEffect(.degrees(motion.bucket))
            // World horizon
            Rectangle()
                .frame(width: level ? 124 : 72, height: 1.5)
                .foregroundStyle(level ? Color.yellow : Color.white.opacity(0.75))
                .rotationEffect(.radians(motion.angle))
        }
        .animation(.easeOut(duration: 0.15), value: level)
        .opacity(motion.isFlat ? 0 : 1)
        .allowsHitTesting(false)
    }
}

/// These wrappers read the fast-changing values inside their own bodies, so a histogram
/// update (≈6×/s) or meter tick (15×/s) redraws just the readout — not the whole camera
/// screen, which kept the main thread busy and made the controls feel sticky.
struct LiveHistogram: View {
    let camera: CameraController
    var body: some View { HistogramView(histogram: camera.histogram) }
}

struct LiveAudioMeter: View {
    let camera: CameraController
    var body: some View { AudioMeter(level: camera.audioLevel) }
}

struct LiveExposureMeter: View {
    let camera: CameraController
    var body: some View { ExposureMeter(offset: camera.meterOffset) }
}

struct HistogramView: View {
    let histogram: Histogram

    var body: some View {
        Canvas { ctx, size in
            guard histogram.luma.count > 1 else { return }
            let peak = max(
                histogram.red.dropFirst().dropLast().max() ?? 0,
                histogram.green.dropFirst().dropLast().max() ?? 0,
                histogram.blue.dropFirst().dropLast().max() ?? 0,
                0.0001)
            func path(_ values: [Float], filled: Bool) -> Path {
                var p = Path()
                let n = values.count
                p.move(to: CGPoint(x: 0, y: size.height))
                for (i, v) in values.enumerated() {
                    let x = size.width * CGFloat(i) / CGFloat(n - 1)
                    let y = size.height - min(1, CGFloat(v / peak)) * size.height
                    p.addLine(to: CGPoint(x: x, y: y))
                }
                p.addLine(to: CGPoint(x: size.width, y: size.height))
                if filled { p.closeSubpath() }
                return p
            }
            ctx.fill(path(histogram.luma, filled: true), with: .color(.white.opacity(0.35)))
            ctx.blendMode = .plusLighter
            ctx.stroke(path(histogram.red, filled: false), with: .color(.red.opacity(0.9)), lineWidth: 1)
            ctx.stroke(path(histogram.green, filled: false), with: .color(.green.opacity(0.9)), lineWidth: 1)
            ctx.stroke(path(histogram.blue, filled: false), with: .color(.blue.opacity(0.9)), lineWidth: 1)
        }
        .frame(width: 112, height: 48)
        .padding(6)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .allowsHitTesting(false)
    }
}

/// Light meter for manual exposure: how far the dialed exposure is from the meter.
struct ExposureMeter: View {
    let offset: Float

    var body: some View {
        let clamped = CGFloat(max(-3, min(3, offset)))
        VStack(spacing: 3) {
            ZStack {
                HStack(spacing: 0) {
                    ForEach(-3...3, id: \.self) { i in
                        Rectangle()
                            .frame(width: 1, height: i == 0 ? 9 : 5)
                            .frame(maxWidth: .infinity)
                    }
                }
                .foregroundStyle(.white.opacity(0.7))
                GeometryReader { geo in
                    let x = geo.size.width / 2 + clamped / 3 * (geo.size.width / 2 - geo.size.width / 14)
                    Triangle()
                        .fill(abs(offset) < 0.34 ? Color.yellow : Color.white)
                        .frame(width: 7, height: 5)
                        .position(x: x, y: -3)
                }
            }
            .frame(width: 120, height: 10)
            Text(Stops.evLabel(offset))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
        }
        .animation(.easeOut(duration: 0.12), value: offset)
        .allowsHitTesting(false)
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// Sun-on-a-track readout while dragging exposure on the viewfinder.
struct ExposureDragIndicator: View {
    let ev: Float

    var body: some View {
        let fraction = CGFloat((ev + 3) / 6)
        VStack(spacing: 6) {
            ZStack {
                Capsule().fill(Color.yellow.opacity(0.5)).frame(width: 1.5, height: 120)
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.yellow)
                    .offset(y: 60 - fraction * 120)
            }
            .frame(height: 130)
            Text(Stops.evLabel(ev))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.yellow)
                .shadow(radius: 3)
        }
        .animation(.interactiveSpring(response: 0.2), value: ev)
    }
}

struct FocusReticle: View {
    let locked: Bool
    @State private var appeared = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.yellow, lineWidth: 1.2)
                .frame(width: 72, height: 72)
            if locked {
                Text("AE/AF LOCK")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.yellow, in: Capsule())
                    .offset(y: -52)
            }
        }
        .scaleEffect(appeared ? 1 : 1.5)
        .opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { appeared = true } }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("focus.reticle")
    }
}

struct AudioMeter: View {
    let level: Float // dBFS

    var body: some View {
        let normalized = CGFloat(max(0, min(1, (level + 50) / 50)))
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.white.opacity(0.2))
                Capsule()
                    .fill(LinearGradient(colors: [.green, .yellow, .red], startPoint: .bottom, endPoint: .top))
                    .frame(height: geo.size.height * normalized)
            }
        }
        .frame(width: 4, height: 54)
        .animation(.linear(duration: 0.07), value: normalized)
        .allowsHitTesting(false)
    }
}

struct Toast: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)
    }
}
