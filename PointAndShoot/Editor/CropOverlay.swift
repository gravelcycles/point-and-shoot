import SwiftUI

/// Draggable crop rectangle. Works in normalized image coordinates (top-left origin).
struct CropOverlay: View {
    @Binding var crop: CGRect
    /// Where the (uncropped) image is drawn, in this view's coordinates.
    let imageRect: CGRect
    /// Desired pixel aspect (w/h), or nil for free.
    let aspect: CGFloat?
    var onBegin: () -> Void = {}

    @State private var start: CGRect?

    private enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    var body: some View {
        let r = viewRect(crop)
        ZStack {
            Path { p in
                p.addRect(imageRect)
                p.addRect(r)
            }
            .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Path { p in
                for i in 1...2 {
                    let x = r.minX + r.width * CGFloat(i) / 3
                    let y = r.minY + r.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                    p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(start == nil ? 0.25 : 0.55), lineWidth: 0.5)
            .allowsHitTesting(false)

            Rectangle()
                .path(in: r)
                .stroke(Color.white, lineWidth: 1.2)
                .allowsHitTesting(false)

            // Body: drag to move.
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width: max(r.width - 60, 1), height: max(r.height - 60, 1))
                .position(x: r.midX, y: r.midY)
                .gesture(moveGesture)

            ForEach(Corner.allCases, id: \.self) { corner in
                handle(corner)
                    .position(point(for: corner, in: r))
                    .gesture(cornerGesture(corner))
            }
        }
    }

    private func handle(_ corner: Corner) -> some View {
        let flipX: CGFloat = (corner == .topRight || corner == .bottomRight) ? -1 : 1
        let flipY: CGFloat = (corner == .bottomLeft || corner == .bottomRight) ? -1 : 1
        return Path { p in
            p.move(to: CGPoint(x: 0, y: 18))
            p.addLine(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: 18, y: 0))
        }
        .stroke(Color.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
        .frame(width: 18, height: 18)
        .scaleEffect(x: flipX, y: flipY)
        .offset(x: 7 * flipX, y: 7 * flipY)
        .frame(width: 48, height: 48)
        .contentShape(Rectangle())
    }

    private func point(for corner: Corner, in r: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: CGPoint(x: r.minX, y: r.minY)
        case .topRight: CGPoint(x: r.maxX, y: r.minY)
        case .bottomLeft: CGPoint(x: r.minX, y: r.maxY)
        case .bottomRight: CGPoint(x: r.maxX, y: r.maxY)
        }
    }

    private func viewRect(_ n: CGRect) -> CGRect {
        CGRect(x: imageRect.minX + n.minX * imageRect.width,
               y: imageRect.minY + n.minY * imageRect.height,
               width: n.width * imageRect.width,
               height: n.height * imageRect.height)
    }

    /// Aspect in normalized units (normalized w / normalized h).
    private var normalizedAspect: CGFloat? {
        guard let aspect, imageRect.width > 0 else { return nil }
        return aspect * imageRect.height / imageRect.width
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if start == nil { start = crop; onBegin() }
                guard let s = start else { return }
                var r = s
                r.origin.x = min(max(0, s.minX + v.translation.width / imageRect.width), 1 - s.width)
                r.origin.y = min(max(0, s.minY + v.translation.height / imageRect.height), 1 - s.height)
                crop = r
            }
            .onEnded { _ in withAnimation(.snappy) { start = nil } }
    }

    private func cornerGesture(_ corner: Corner) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if start == nil { start = crop; onBegin() }
                guard let s = start else { return }
                let dx = v.translation.width / imageRect.width
                let dy = v.translation.height / imageRect.height
                let minSize: CGFloat = 0.08

                // Opposite corner stays put.
                let anchor: CGPoint
                var moving: CGPoint
                switch corner {
                case .topLeft: anchor = CGPoint(x: s.maxX, y: s.maxY); moving = CGPoint(x: s.minX + dx, y: s.minY + dy)
                case .topRight: anchor = CGPoint(x: s.minX, y: s.maxY); moving = CGPoint(x: s.maxX + dx, y: s.minY + dy)
                case .bottomLeft: anchor = CGPoint(x: s.maxX, y: s.minY); moving = CGPoint(x: s.minX + dx, y: s.maxY + dy)
                case .bottomRight: anchor = CGPoint(x: s.minX, y: s.minY); moving = CGPoint(x: s.maxX + dx, y: s.maxY + dy)
                }
                moving.x = min(max(moving.x, 0), 1)
                moving.y = min(max(moving.y, 0), 1)

                var w = max(abs(moving.x - anchor.x), minSize)
                var h = max(abs(moving.y - anchor.y), minSize)
                let signX: CGFloat = moving.x < anchor.x ? -1 : 1
                let signY: CGFloat = moving.y < anchor.y ? -1 : 1

                if let na = normalizedAspect {
                    // Lock aspect: follow whichever axis the finger moved more.
                    if w / h > na { h = w / na } else { w = h * na }
                    let maxW = signX < 0 ? anchor.x : 1 - anchor.x
                    let maxH = signY < 0 ? anchor.y : 1 - anchor.y
                    if w > maxW { w = maxW; h = w / na }
                    if h > maxH { h = maxH; w = h * na }
                }
                let x = signX < 0 ? anchor.x - w : anchor.x
                let y = signY < 0 ? anchor.y - h : anchor.y
                crop = CGRect(x: max(0, x), y: max(0, y), width: min(w, 1), height: min(h, 1))
            }
            .onEnded { _ in withAnimation(.snappy) { start = nil } }
    }

    /// Largest centered rect of the given pixel aspect inside the image.
    static func centered(aspect: CGFloat?, imageAspect: CGFloat) -> CGRect {
        guard let aspect else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let na = aspect / imageAspect
        var w: CGFloat = 1, h: CGFloat = 1
        if na > 1 { h = 1 / na } else { w = na }
        return CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }
}
