import Photos
import SwiftUI

enum EditorTool: String, CaseIterable, Identifiable {
    case looks, tune, details, color, crop, raw
    var id: String { rawValue }
    var label: String {
        switch self {
        case .looks: "Filters"
        case .tune: "Tune"
        case .details: "Details"
        case .color: "Color"
        case .crop: "Crop"
        case .raw: "RAW"
        }
    }
    var symbol: String {
        switch self {
        case .looks: "camera.filters"
        case .tune: "slider.horizontal.3"
        case .details: "triangle.lefthalf.filled"
        case .color: "paintpalette"
        case .crop: "crop.rotate"
        case .raw: "r.square"
        }
    }
    var adjustments: [Adjustment] {
        switch self {
        case .tune: Adjustment.tune
        case .details: Adjustment.details
        case .raw: Adjustment.raw
        default: []
        }
    }
}

/// Snapseed-style editor: swipe ↕ on the photo to pick a parameter, ↔ to dial it in.
struct EditorView: View {
    @State private var session: EditSession
    @Environment(\.dismiss) private var dismiss

    @State private var tool: EditorTool = .looks
    @State private var selection: [EditorTool: Int] = [:]
    @State private var showOriginal = false
    @State private var dragMode: DragMode?
    @State private var dragStartValue: Double = 0
    @State private var dragStartIndex = 0
    @State private var cropAspect: CropAspect = .free
    @State private var undoStack: [EditRecipe] = []
    @State private var selectionTick = 0
    @State private var zeroTick = 0
    @State private var confirmDiscard = false

    /// Called with a short message ("Saved to Photos") after a successful save.
    private let onSaved: (String) -> Void

    private enum DragMode { case choose, adjust }

    init(asset: PHAsset, onSaved: @escaping (String) -> Void = { _ in }) {
        _session = State(initialValue: EditSession(asset: asset))
        self.onSaved = onSaved
    }

    @State private var colorBand: ColorBand = .red

    private var adjustments: [Adjustment] {
        tool == .color ? Adjustment.mixer(colorBand) : tool.adjustments
    }
    private var selectedIndex: Int { min(selection[tool] ?? 0, max(adjustments.count - 1, 0)) }
    private var current: Adjustment? { adjustments.isEmpty ? nil : adjustments[selectedIndex] }

    var body: some View {
        VStack(spacing: 0) {
            header
            canvas
            toolPanel
                .frame(height: 132)
            toolTabs
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .task { await session.load(maxPixels: 2400) }
        .sensoryFeedback(.selection, trigger: selectionTick)
        .sensoryFeedback(.impact(weight: .light), trigger: zeroTick)
        .interactiveDismissDisabled(session.hasChanges)
        .confirmationDialog("Discard your edits?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Save to Photos") { Task { await saveAndClose() } }
            Button("Discard Edits", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { session.errorMessage != nil },
            set: { if !$0 { session.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.errorMessage ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 18) {
            Button {
                if session.hasChanges { confirmDiscard = true } else { dismiss() }
            } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            Button(action: undo) {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(undoStack.isEmpty)
            .opacity(undoStack.isEmpty ? 0.35 : 1)

            Spacer()

            Image(systemName: showOriginal ? "square.split.2x1.fill" : "square.split.2x1")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(showOriginal ? Color.yellow : Color.white)
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0, maximumDistance: 60, pressing: { pressing in
                    showOriginal = pressing
                }, perform: {})

            Menu {
                Button {
                    Task {
                        if await session.saveCopy() { finish("Saved as a new photo") }
                    }
                } label: { Label("Save as New Photo", systemImage: "plus.square.on.square") }

                Divider()
                Button {
                    EditClipboard.recipe = session.recipe
                } label: { Label("Copy Edits", systemImage: "doc.on.doc") }
                Button {
                    guard let copied = EditClipboard.recipe else { return }
                    pushUndo()
                    withAnimation(.snappy) { session.recipe = copied.look(appliedTo: session.recipe) }
                } label: { Label("Paste Edits", systemImage: "doc.on.clipboard") }
                .disabled(EditClipboard.recipe == nil)

                if session.canRevert {
                    Divider()
                    Button(role: .destructive) {
                        Task {
                            if await session.revertToOriginal() { finish("Reverted to original") }
                        }
                    } label: { Label("Revert to Original", systemImage: "arrow.counterclockwise") }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 19, weight: .semibold))
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(session.isLoading || session.isSaving)

            Button {
                Task { await saveAndClose() }
            } label: {
                Text("Save")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(Color.yellow, in: Capsule())
            }
            .buttonStyle(PressScaleStyle(scale: 0.94))
            .disabled(session.isLoading || session.isSaving || !session.hasChanges)
            .opacity(session.hasChanges ? 1 : 0.45)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    /// One tap: writes the edit to the photo in your camera roll (non-destructively —
    /// Photos keeps the original and you can revert there or here).
    private func saveAndClose() async {
        if await session.save() { finish("Saved to Photos") }
    }

    private func finish(_ message: String) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onSaved(message)
        dismiss()
    }

    // MARK: Canvas

    private var displayImage: CIImage? {
        if showOriginal { return session.originalPreview }
        if tool == .crop { return session.uncroppedPreview() }
        return session.editedPreview()
    }

    private var canvas: some View {
        GeometryReader { geo in
            let image = displayImage
            ZStack {
                MetalImageView(image: image)

                if tool == .crop, !showOriginal, let image {
                    CropOverlay(crop: $session.recipe.crop,
                                imageRect: aspectFitRect(image.extent.size, in: geo.size),
                                aspect: cropAspect.ratio(imageAspect: session.orientedAspect),
                                onBegin: pushUndo)
                }

                if let current, !adjustments.isEmpty, !showOriginal {
                    VStack {
                        ValuePill(name: current.name, value: session.recipe[keyPath: current.keyPath], range: current.range)
                            .padding(.top, 10)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }

                if dragMode == .choose {
                    ParameterMenu(adjustments: adjustments, selected: selectedIndex, recipe: session.recipe)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }

                if session.isLoading || session.isSaving {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                        .padding(24)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .contentShape(Rectangle())
            .gesture(adjustGesture, including: adjustments.isEmpty ? .subviews : .all)
        }
    }

    private var adjustGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { v in
                guard let _ = current else { return }
                if dragMode == nil {
                    let vertical = abs(v.translation.height) > abs(v.translation.width)
                    withAnimation(.easeOut(duration: 0.15)) { dragMode = vertical ? .choose : .adjust }
                    dragStartIndex = selectedIndex
                    if let adj = current { dragStartValue = session.recipe[keyPath: adj.keyPath] }
                    if !vertical { pushUndo() }
                }
                switch dragMode {
                case .choose:
                    let idx = min(max(dragStartIndex + Int((v.translation.height / 34).rounded()), 0), adjustments.count - 1)
                    if idx != selectedIndex {
                        selection[tool] = idx
                        selectionTick += 1
                    }
                case .adjust:
                    guard let adj = current else { return }
                    let span = adj.range.upperBound - adj.range.lowerBound
                    // Full range across ~2.2 screen widths: fine control, Snapseed feel.
                    let delta = Double(v.translation.width) / 860 * span
                    let newValue = min(max((dragStartValue + delta).rounded(), adj.range.lowerBound), adj.range.upperBound)
                    let old = session.recipe[keyPath: adj.keyPath]
                    if newValue != old {
                        if adj.isBipolar && (old < 0 && newValue >= 0 || old > 0 && newValue <= 0) { zeroTick += 1 }
                        session.recipe[keyPath: adj.keyPath] = newValue
                    }
                case .none:
                    break
                }
            }
            .onEnded { _ in
                withAnimation(.easeOut(duration: 0.2)) { dragMode = nil }
            }
    }

    // MARK: Panels

    @ViewBuilder
    private var toolPanel: some View {
        switch tool {
        case .looks:
            looksPanel
        case .tune, .details, .color, .raw:
            adjustmentPanel
        case .crop:
            cropPanel
        }
    }

    private var looksPanel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Look.all) { look in
                    let selected = (session.recipe.look ?? "none") == look.id
                    Button {
                        pushUndo()
                        withAnimation(.snappy) { session.apply(look: look) }
                    } label: {
                        VStack(spacing: 6) {
                            Group {
                                if let thumb = session.lookThumbnails[look.id] {
                                    Image(uiImage: thumb).resizable().scaledToFill()
                                } else {
                                    Color.white.opacity(0.08)
                                }
                            }
                            .frame(width: 68, height: 68)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(selected ? Color.yellow : Color.clear, lineWidth: 2))
                            Text(look.name)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(selected ? Color.yellow : Color.white.opacity(0.8))
                        }
                    }
                    .buttonStyle(PressScaleStyle(scale: 0.94))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
    }

    private var adjustmentPanel: some View {
        VStack(spacing: 10) {
            if tool == .color {
                colorBandPicker
            }
            if tool == .raw {
                if session.hasRAW {
                    Toggle(isOn: Binding(get: { session.recipe.useRAW },
                                         set: { v in pushUndo(); session.recipe.useRAW = v })) {
                        Text("Develop from RAW").font(.system(size: 13, weight: .semibold))
                    }
                    .tint(.yellow)
                    .padding(.horizontal, 20)
                } else {
                    Text("No RAW data in this photo. Shoot with RAW, ProRAW or Zero to develop from the sensor.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(adjustments.enumerated()), id: \.element.id) { i, adj in
                            let value = session.recipe[keyPath: adj.keyPath]
                            let selected = i == selectedIndex
                            Button {
                                selection[tool] = i
                                selectionTick += 1
                            } label: {
                                VStack(spacing: 3) {
                                    Text(adj.name)
                                        .font(.system(size: 12, weight: .semibold))
                                    Text(format(value, bipolar: adj.isBipolar))
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                        .monospacedDigit()
                                        .opacity(isDefault(adj, value) ? 0.4 : 1)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .foregroundStyle(selected ? Color.black : Color.white)
                                .background(selected ? Color.yellow : Color.white.opacity(0.1),
                                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .id(i)
                            .simultaneousGesture(TapGesture(count: 2).onEnded {
                                pushUndo()
                                session.recipe[keyPath: adj.keyPath] = defaultValue(adj)
                            })
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .onChange(of: selectedIndex) { _, i in
                    withAnimation(.snappy) { proxy.scrollTo(i, anchor: .center) }
                }
            }
            .disabled(tool == .raw && !session.developsFromRAW)
            .opacity(tool == .raw && !session.developsFromRAW ? 0.35 : 1)

            Text("Swipe ↕ on the photo to choose · ↔ to adjust · double-tap to reset")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.top, 10)
    }

    /// Eight swatches; a dot marks bands you've changed.
    private var colorBandPicker: some View {
        HStack(spacing: 0) {
            ForEach(ColorBand.allCases) { band in
                let selected = band == colorBand
                let values = session.recipe.mixerValues
                let edited = (0..<3).contains { values[band.rawValue * 3 + $0] != 0 }
                Button {
                    withAnimation(.snappy(duration: 0.2)) { colorBand = band }
                    selectionTick += 1
                } label: {
                    VStack(spacing: 4) {
                        Circle()
                            .fill(Color(hue: band.hue / 360, saturation: 0.85, brightness: 0.95))
                            .frame(width: selected ? 28 : 22, height: selected ? 28 : 22)
                            .overlay(Circle().stroke(Color.white, lineWidth: selected ? 2.5 : 0))
                        Circle()
                            .fill(edited ? Color.yellow : Color.clear)
                            .frame(width: 4, height: 4)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(band.name)
            }
        }
        .padding(.horizontal, 12)
    }

    private var cropPanel: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CropAspect.allCases) { a in
                        Button {
                            pushUndo()
                            cropAspect = a
                            withAnimation(.snappy) {
                                session.recipe.crop = CropOverlay.centered(aspect: a.ratio(imageAspect: session.orientedAspect),
                                                                           imageAspect: session.orientedAspect)
                            }
                        } label: {
                            Text(a.label)
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 11).padding(.vertical, 6)
                                .foregroundStyle(cropAspect == a ? Color.black : Color.white)
                                .background(cropAspect == a ? Color.yellow : Color.white.opacity(0.1), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Divider().frame(height: 20).overlay(Color.white.opacity(0.3))
                    iconChip("rotate.right") {
                        pushUndo()
                        session.recipe.quarterTurns += 1
                        session.recipe.crop = CropOverlay.centered(aspect: cropAspect.ratio(imageAspect: session.orientedAspect),
                                                                   imageAspect: session.orientedAspect)
                    }
                    iconChip("arrow.left.and.right.righttriangle.left.righttriangle.right") {
                        pushUndo()
                        session.recipe.flipped.toggle()
                    }
                    iconChip("arrow.counterclockwise") {
                        pushUndo()
                        cropAspect = .free
                        withAnimation(.snappy) {
                            session.recipe.crop = CGRect(x: 0, y: 0, width: 1, height: 1)
                            session.recipe.straighten = 0
                            session.recipe.quarterTurns = 0
                            session.recipe.flipped = false
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            let angles = Array(stride(from: -45.0, through: 45.0, by: 0.5))
            HStack(spacing: 8) {
                Text(String(format: "%+.1f°", session.recipe.straighten))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 54)
                ScrubDial(count: angles.count,
                          index: Stops.nearestIndex(session.recipe.straighten, in: angles),
                          label: { i in Int(angles[i] * 2) % 20 == 0 ? "\(Int(angles[i]))" : nil },
                          onChange: { session.recipe.straighten = angles[$0] })
            }
            .padding(.horizontal, 12)
        }
        .padding(.top, 12)
    }

    private func iconChip(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 34, height: 30)
                .background(Color.white.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var toolTabs: some View {
        HStack {
            ForEach(EditorTool.allCases) { t in
                Button {
                    withAnimation(.snappy(duration: 0.25)) { tool = t }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: t.symbol).font(.system(size: 18, weight: .medium))
                        Text(t.label).font(.system(size: 10, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(tool == t ? Color.yellow : Color.white.opacity(0.75))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(Color.black)
    }

    // MARK: Helpers

    private func pushUndo() {
        undoStack.append(session.recipe)
        if undoStack.count > 50 { undoStack.removeFirst() }
    }

    private func undo() {
        guard let last = undoStack.popLast() else { return }
        withAnimation(.snappy) { session.recipe = last }
    }

    private func defaultValue(_ adj: Adjustment) -> Double {
        EditRecipe()[keyPath: adj.keyPath]
    }

    private func isDefault(_ adj: Adjustment, _ value: Double) -> Bool {
        switch adj.id {
        case "rawNR", "rawLTM", "rawBoost": false
        default: value == defaultValue(adj)
        }
    }

    private func format(_ v: Double, bipolar: Bool) -> String {
        let i = Int(v.rounded())
        return bipolar && i > 0 ? "+\(i)" : "\(i)"
    }
}

struct ValuePill: View {
    let name: String
    let value: Double
    let range: ClosedRange<Double>

    var body: some View {
        let bipolar = range.lowerBound < 0
        let i = Int(value.rounded())
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Text(name)
                Text(bipolar && i > 0 ? "+\(i)" : "\(i)")
                    .monospacedDigit()
                    .foregroundStyle(Color.yellow)
                    .contentTransition(.numericText())
            }
            .font(.system(size: 14, weight: .semibold))
            GeometryReader { geo in
                let w = geo.size.width
                let span = range.upperBound - range.lowerBound
                let zeroX = bipolar ? w / 2 : 0
                let x = CGFloat((value - range.lowerBound) / span) * w
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.25))
                    Capsule().fill(Color.yellow)
                        .frame(width: max(2, abs(x - zeroX)))
                        .offset(x: min(x, zeroX))
                }
            }
            .frame(width: 150, height: 3)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.black.opacity(0.55), in: Capsule())
    }
}

struct ParameterMenu: View {
    let adjustments: [Adjustment]
    let selected: Int
    let recipe: EditRecipe

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(adjustments.enumerated()), id: \.element.id) { i, adj in
                let v = Int(recipe[keyPath: adj.keyPath].rounded())
                HStack {
                    Text(adj.name)
                    Spacer()
                    Text(adj.isBipolar && v > 0 ? "+\(v)" : "\(v)").monospacedDigit()
                }
                .font(.system(size: 15, weight: i == selected ? .bold : .medium))
                .foregroundStyle(i == selected ? Color.black : Color.white)
                .padding(.horizontal, 16)
                .frame(width: 220, height: 34)
                .background(i == selected ? Color.yellow : Color.clear)
            }
        }
        .background(.black.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.snappy(duration: 0.15), value: selected)
    }
}
