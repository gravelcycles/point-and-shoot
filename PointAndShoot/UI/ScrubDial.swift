import SwiftUI

/// A horizontal "jog wheel" of tick marks — the feel of a real camera's command dial.
/// Drag to scrub, fling to coast, with a selection haptic on every detent.
struct ScrubDial: View {
    let count: Int
    let index: Int
    /// Label for a tick, or nil for an unlabeled minor tick.
    let label: (Int) -> String?
    let onChange: (Int) -> Void
    var accent: Color = .yellow

    @State private var position: CGFloat?
    @State private var startIndex = 0

    private let spacing: CGFloat = 13

    var body: some View {
        GeometryReader { geo in
            let current = position ?? CGFloat(index)
            HStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { i in
                    tick(i)
                }
            }
            .offset(x: geo.size.width / 2 - spacing / 2 - current * spacing)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
        }
        .overlay(alignment: .top) {
            Capsule().fill(accent).frame(width: 2.5, height: 24).offset(y: -3)
        }
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.18),
                .init(color: .black, location: 0.82),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        )
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if position == nil { startIndex = index }
                    let p = clamp(CGFloat(startIndex) - value.translation.width / spacing)
                    position = p
                    let i = Int(p.rounded())
                    if i != index { onChange(i) }
                }
                .onEnded { value in
                    let coast = CGFloat(startIndex) - value.predictedEndTranslation.width / spacing
                    let i = Int(clamp(coast).rounded())
                    if i != index { onChange(i) }
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { position = nil }
                }
        )
        // Detent clicks only while your finger is on it — not when auto values drift.
        .sensoryFeedback(.selection, trigger: index) { _, _ in position != nil }
        .frame(height: 44)
    }

    private func clamp(_ v: CGFloat) -> CGFloat { min(max(v, 0), CGFloat(count - 1)) }

    @ViewBuilder
    private func tick(_ i: Int) -> some View {
        let text = label(i)
        let selected = i == index
        VStack(spacing: 5) {
            Rectangle()
                .frame(width: text == nil ? 1 : 1.5, height: text == nil ? 9 : 16)
            Text(text ?? " ")
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .fixedSize()
        }
        .frame(width: spacing, height: 44, alignment: .top)
        .foregroundStyle(selected ? accent : Color.white.opacity(text == nil ? 0.38 : 0.85))
    }
}
