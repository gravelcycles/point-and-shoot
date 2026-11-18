import SwiftUI

/// The editor's tools, Chromagraph-style: each has sub-tabs, each sub-tab one to three
/// labelled sliders (or toggles) under the photo.
enum EditorTool: String, CaseIterable, Identifiable {
    case looks, tone, color, texture, crop
    var id: String { rawValue }
    var label: String {
        switch self {
        case .looks: "Looks"
        case .tone: "Tone"
        case .color: "Color"
        case .texture: "Texture"
        case .crop: "Crop"
        }
    }
    var symbol: String {
        switch self {
        case .looks: "camera.filters"
        case .tone: "chart.line.uptrend.xyaxis"
        case .color: "paintpalette"
        case .texture: "circle.dotted"
        case .crop: "crop.rotate"
        }
    }
}

/// One control in a sub-tab.
enum EditorControl: Identifiable {
    case slider(Adjustment)
    case toggle(id: String, name: String, keyPath: WritableKeyPath<EditRecipe, Bool>)
    /// The color mixer's band picker.
    case bands

    var id: String {
        switch self {
        case .slider(let a): a.id
        case .toggle(let id, _, _): id
        case .bands: "bands"
        }
    }
}

struct EditorSubTab: Identifiable {
    let id: String
    let name: String
    let controls: [EditorControl]
}

/// Chromagraph-style editor: pick a tool, a sub-tab, then drag its sliders. Pinch and
/// two-finger pan zoom the photo; double-tap a slider to reset it.
struct EditorView: View {
    @State private var session: EditSession
    @Environment(\.dismiss) private var dismiss

    @State private var tool: EditorTool = .looks
    @State private var subTab: [EditorTool: String] = [:]
    @State private var showOriginal = false
    @State private var cropAspect: CropAspect = .free
    @State private var undoStack: [EditRecipe] = []
    @State private var selectionTick = 0
    @State private var confirmDiscard = false
    @State private var colorBand: ColorBand = .red
    @State private var showFilterGuide = false
    /// The named set of looks the Looks tool shows (`LookSet` id, "all" = every look).
    @AppStorage("editor.lookSet") private var lookSet = "all"

    /// Called with a short message ("Saved") after a successful save.
    private let onSaved: (String) -> Void
    /// The grade new shots start with ("Reset This Image" goes back to it).
    private let defaultGrade: EditRecipe?
    private let onSetDefault: (EditRecipe) -> Void

    init(shot: Shot, store: ShotStore, defaultGrade: EditRecipe? = nil,
         onSetDefault: @escaping (EditRecipe) -> Void = { _ in },
         onSaved: @escaping (String) -> Void = { _ in }) {
        _session = State(initialValue: EditSession(shot: shot, store: store))
        self.defaultGrade = defaultGrade
        self.onSetDefault = onSetDefault
        self.onSaved = onSaved
    }

    // MARK: Sub-tabs

    private var isFilm: Bool { session.recipe.film != nil }

    private func adj(_ id: String) -> Adjustment {
        Adjustment.catalog[id]!
    }

    private func subTabs(_ tool: EditorTool) -> [EditorSubTab] {
        switch tool {
        case .looks, .crop:
            return []
        case .tone:
            var tabs = [
                EditorSubTab(id: "exposure", name: "Exposure", controls: [.slider(adj("exposure"))]),
                EditorSubTab(id: "contrast", name: "Contrast", controls: [.slider(adj("contrast")), .slider(adj("fade"))]),
                EditorSubTab(id: "shadowHighlight", name: "Shadow/Highlight",
                             controls: [.slider(adj("highlights")), .slider(adj("shadows"))]),
                EditorSubTab(id: "whitesBlacks", name: "Whites/Blacks",
                             controls: [.slider(adj("whites")), .slider(adj("blacks"))]),
            ]
            if session.hasRAW {
                tabs.append(EditorSubTab(id: "raw", name: "RAW", controls: [
                    .slider(adj("rawLTM")), .slider(adj("rawBoost")),
                ]))
            }
            return tabs
        case .color:
            var tabs = [
                EditorSubTab(id: "balance", name: "Balance", controls: [.slider(adj("warmth")), .slider(adj("tint"))]),
                EditorSubTab(id: "saturation", name: "Saturation", controls: [
                    .slider(adj("saturation")), .slider(adj("vibrance")),
                    .toggle(id: "mono", name: "B&W", keyPath: \.mono),
                ]),
            ]
            if isFilm {
                tabs.append(EditorSubTab(id: "crossover", name: "Crossover", controls: [.slider(adj("crossover"))]))
            }
            tabs.append(EditorSubTab(id: "mixer", name: "Mixer",
                                     controls: [.bands] + Adjustment.mixer(colorBand).map { .slider($0) }))
            return tabs
        case .texture:
            var tabs = [EditorSubTab(id: "grain", name: "Grain", controls: [.slider(adj("grain"))])]
            if isFilm {
                tabs.append(EditorSubTab(id: "halation", name: "Halation", controls: [.slider(adj("halation"))]))
            }
            tabs.append(EditorSubTab(id: "detail", name: "Detail", controls: [.slider(adj("structure")), .slider(adj("sharpen"))]))
            tabs.append(EditorSubTab(id: "vignette", name: "Vignette", controls: [.slider(adj("vignette"))]))
            if session.hasRAW {
                tabs.append(EditorSubTab(id: "noise", name: "Noise", controls: [.slider(adj("rawNR"))]))
            }
            return tabs
        }
    }

    private var currentSubTab: EditorSubTab? {
        let tabs = subTabs(tool)
        return tabs.first { $0.id == subTab[tool] } ?? tabs.first
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            header
            infoRow
            canvas
            toolPanel
                .frame(height: 170)
            toolTabs
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .task { await session.load(maxPixels: 2400) }
        .sensoryFeedback(.selection, trigger: selectionTick)
        .interactiveDismissDisabled(session.hasChanges)
        .confirmationDialog("Discard your changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Save") { Task { await saveAndClose() } }
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { session.errorMessage != nil },
            set: { if !$0 { session.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.errorMessage ?? "")
        }
        // Own anchor: one presentation per view.
        .background {
            Color.clear
                .alert("This photo was moved to the Trash", isPresented: Binding(
                    get: { session.assetDeleted },
                    set: { if !$0 { session.assetDeleted = false } })) {
                    Button("Discard Changes", role: .cancel) { dismiss() }
                } message: {
                    Text("Restore it from the Trash in the grid to keep editing.")
                }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Button {
                Task { await saveAndClose() }
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 38, height: 38)
                    .background(Color.tan, in: Circle())
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(PressScaleStyle(scale: 0.94))
            .disabled(session.isLoading || session.isSaving)
            .accessibilityIdentifier("editor.save")

            Button(action: undo) {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 17, weight: .semibold))
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(undoStack.isEmpty)
            .opacity(undoStack.isEmpty ? 0.35 : 1)
            .accessibilityIdentifier("editor.undo")

            Spacer()

            Image(systemName: showOriginal ? "square.split.2x1.fill" : "square.split.2x1")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(showOriginal ? Color.tan : Color.white)
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0, maximumDistance: 60, pressing: { pressing in
                    showOriginal = pressing
                }, perform: {})
                .accessibilityLabel("Hold to compare")

            Menu {
                Button {
                    EditClipboard.recipe = session.recipe
                } label: { Label("Copy Grade", systemImage: "doc.on.doc") }
                Button {
                    guard let copied = EditClipboard.recipe else { return }
                    pushUndo()
                    withAnimation(.snappy) { session.paste(copied) }
                } label: { Label("Paste Grade", systemImage: "doc.on.clipboard") }
                .disabled(EditClipboard.recipe == nil)
                Button {
                    onSetDefault(session.recipe.asDefaultGrade)
                    Haptics.success()
                } label: { Label("Set as Default Grade", systemImage: "star") }
                // A retired look can't start new shots: pick a current one first.
                .disabled(session.recipe.look != nil && Look.named(session.recipe.look) == nil)
                Divider()
                Button(role: .destructive) {
                    pushUndo()
                    withAnimation(.snappy) { session.resetToGrade(defaultGrade) }
                } label: { Label("Reset This Image", systemImage: "arrow.counterclockwise") }
                Button(role: .destructive) {
                    pushUndo()
                    withAnimation(.snappy) { session.resetToGrade(nil) }
                } label: { Label("Reset to Original", systemImage: "arrow.uturn.backward.circle") }
                Divider()
                Button(role: .destructive) {
                    if session.hasChanges { confirmDiscard = true } else { dismiss() }
                } label: { Label("Discard Changes", systemImage: "xmark") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.12), in: Circle())
                    .frame(width: 44, height: 44)
            }
            .disabled(session.isLoading || session.isSaving)
            .accessibilityIdentifier("editor.more")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 52)
    }

    private var infoRow: some View {
        HStack(spacing: 8) {
            Text(session.shot.kind == .proRAW ? "PRORAW" : session.shot.isRAW ? "RAW" : "HEIF")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
            if let name = Look.displayName(session.recipe.look) {   // retired looks keep their name
                Text(name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.tan)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(session.shot.captured, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                    .font(.system(size: 10, weight: .semibold))
                if !session.shot.exposureLine.isEmpty {
                    Text(session.shot.exposureLine).font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    /// Saves the grade in the app's library (the RAW is untouched; reset any time).
    private func saveAndClose() async {
        guard session.hasChanges else { dismiss(); return }
        if await session.save() { finish("Saved") }
    }

    private func finish(_ message: String) {
        Haptics.success()
        onSaved(message)
        dismiss()
    }

    // MARK: Canvas

    private var displayImage: CIImage? {
        showOriginal ? session.originalPreview
            : (tool == .crop ? session.uncroppedPreview() : session.editedPreview())
    }

    private var canvas: some View {
        GeometryReader { geo in
            let image = displayImage
            ZStack {
                MetalImageView(image: image,
                               contentKey: session.recipeRevision &* 8 + (showOriginal ? 1 : 0) + (tool == .crop ? 2 : 0) + (session.isLoading ? 4 : 0),
                               zoomable: tool != .crop && !session.isLoading,
                               oneFingerPan: true,
                               pixelSize: session.pixelSize,
                               onZoom: zoomChanged)

                if tool == .crop, !showOriginal, let image {
                    CropOverlay(crop: $session.recipe.crop,
                                imageRect: aspectFitRect(image.extent.size, in: geo.size),
                                aspect: cropAspect.ratio(imageAspect: session.orientedAspect),
                                onBegin: pushUndo)
                }

                if session.isLoading || session.isSaving {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                        .padding(24)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }

    /// Zoomed in: render from the sharper source (loaded the first time).
    private func zoomChanged(_ scale: CGFloat) {
        let zoomed = scale > 1.01
        if session.zoomedIn != zoomed { session.zoomedIn = zoomed }
        if zoomed && !session.detailReady { Task { await session.loadDetail() } }
    }

    // MARK: Panels

    @ViewBuilder
    private var toolPanel: some View {
        switch tool {
        case .looks:
            looksPanel
        case .tone, .color, .texture:
            gradePanel
        case .crop:
            cropPanel
        }
    }

    private var gradePanel: some View {
        let tabs = subTabs(tool)
        let current = currentSubTab
        return VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tabs) { tab in
                        let selected = tab.id == current?.id
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { subTab[tool] = tab.id }
                            selectionTick += 1
                        } label: {
                            Text(tab.name)
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.8))
                                .background(selected ? Color.white : Color.white.opacity(0.1), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("editor.sub.\(tab.id)")
                    }
                }
                .padding(.horizontal, 16)
            }
            if let current {
                VStack(spacing: 10) {
                    ForEach(current.controls) { control in
                        controlView(control)
                    }
                }
                .padding(.horizontal, 20)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 10)
    }

    @ViewBuilder
    private func controlView(_ control: EditorControl) -> some View {
        switch control {
        case .slider(let a):
            let rawOnly = ["rawLTM", "rawBoost", "rawNR"].contains(a.id)
            GradeSlider(adjustment: a,
                        value: Binding(get: { session.recipe[keyPath: a.keyPath] },
                                       set: { session.recipe[keyPath: a.keyPath] = $0 }),
                        defaultValue: defaultValue(a),
                        onBegin: pushUndo)
                .disabled(rawOnly && !session.developsFromRAW)
                .opacity(rawOnly && !session.developsFromRAW ? 0.35 : 1)
        case .toggle(let id, let name, let keyPath):
            Toggle(isOn: Binding(get: { session.recipe[keyPath: keyPath] },
                                 set: { v in pushUndo(); withAnimation(.snappy) { session.recipe[keyPath: keyPath] = v } })) {
                Text(name).font(.system(size: 13, weight: .semibold))
            }
            .tint(.tan)
            .accessibilityIdentifier("editor.toggle.\(id)")
        case .bands:
            colorBandPicker
        }
    }

    /// Original plus the chosen set's looks (or every look), and the photo's own look when
    /// it's from another set, so the one in use always shows.
    private var shownLooks: [Look] {
        guard let set = LookSet.named(lookSet) else { return Look.all }
        var looks = [Look.all[0]] + set.looks
        if let id = session.recipe.look, let look = Look.named(id), !looks.contains(where: { $0.id == id }) {
            looks.insert(look, at: 1)
        }
        return looks
    }

    private var lookSetMenu: some View {
        let current = LookSet.named(lookSet)
        return Menu {
            Picker("Look set", selection: Binding(get: { LookSet.named(lookSet)?.rawValue ?? "all" },   // unknown id = all
                                                  set: { lookSet = $0 })) {
                Text("All looks").tag("all")
                ForEach(LookSet.allCases) { set in
                    Text("\(set.name) (\(set.looks.count))").tag(set.rawValue)
                }
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(current == nil ? Color.white : Color.tan)
                    .frame(width: 68, height: 68)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(current?.name ?? "All looks")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(current == nil ? Color.white.opacity(0.8) : Color.tan)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("editor.lookSet")
        .accessibilityLabel("Look set: \(current?.name ?? "All looks")")
    }

    private var looksPanel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                lookSetMenu
                ForEach(shownLooks) { look in
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
                                .stroke(selected ? Color.tan : Color.clear, lineWidth: 2))
                            Text(look.name)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(selected ? Color.tan : Color.white.opacity(0.8))
                        }
                    }
                    .buttonStyle(PressScaleStyle(scale: 0.94))
                }
                Button { showFilterGuide = true } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 22, weight: .medium))
                            .frame(width: 68, height: 68)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Text("About").font(.system(size: 11, weight: .semibold))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle(scale: 0.94))
                .accessibilityLabel("About looks")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        .sheet(isPresented: $showFilterGuide) {
            FilterGuide(thumbnails: session.lookThumbnails, selectedID: session.recipe.look, looks: shownLooks) { id in
                pushUndo()
                let look = Look.all.first { $0.id == (id ?? "none") } ?? Look.all[0]
                withAnimation(.snappy) { session.apply(look: look) }
            }
            .presentationDetents([.medium, .large])
        }
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
                            .fill(edited ? Color.tan : Color.clear)
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
                                .background(cropAspect == a ? Color.white : Color.white.opacity(0.1), in: Capsule())
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
        HStack(spacing: 0) {
            ForEach(EditorTool.allCases) { t in
                Button {
                    withAnimation(.snappy(duration: 0.25)) { tool = t }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: t.symbol).font(.system(size: 18, weight: .medium))
                        Text(t.label).font(.system(size: 10, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(tool == t ? Color.white : Color.white.opacity(0.4))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("editor.tool.\(t.rawValue)")
            }
            Button {
                Task { if await session.saveCopy() { finish("Saved to Photos") } }
            } label: {
                ZStack {
                    Circle().fill(Color.tan)
                    if session.isSaving {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.black)
                    }
                }
                .frame(width: 42, height: 42)
                .padding(.horizontal, 10)
            }
            .buttonStyle(PressScaleStyle(scale: 0.94))
            .disabled(session.isLoading || session.isSaving)
            .accessibilityIdentifier("editor.export")
        }
        .padding(.top, 8)
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
        // A film look's grain is part of the look; reset to that, not to none.
        if adj.id == "grain" && session.recipe.film != nil { return FilmRecipe.defaultGrain }
        switch adj.id {
        case "rawNR", "rawLTM", "rawBoost": return session.rawDefault(adj.id) ?? EditRecipe()[keyPath: adj.keyPath]
        default: return EditRecipe()[keyPath: adj.keyPath]
        }
    }
}

/// A labelled slider: name and value above the track, a mark at the default, the fill
/// running from the default to the value. Double-tap resets; a tick when it crosses the
/// default.
struct GradeSlider: View {
    let adjustment: Adjustment
    @Binding var value: Double
    let defaultValue: Double
    var onBegin: () -> Void = {}

    @State private var dragStart: Double?
    /// True while a drag is in progress; SwiftUI resets it even when the drag is cancelled
    /// (which `onEnded` never hears about), so a stale start never leaks into the next drag.
    @GestureState private var dragging = false
    /// The drag has changed the value (and pushed its undo step).
    @State private var dragMoved = false
    @State private var crossTick = 0

    private var range: ClosedRange<Double> { adjustment.range }

    private var label: String {
        if adjustment.id == "exposure" {
            // Exposure is ±2 stops across the slider.
            return String(format: "%+.1f", value / 50)
        }
        let i = Int(value.rounded())
        return adjustment.isBipolar && i > 0 ? "+\(i)" : "\(i)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(adjustment.name).font(.system(size: 12, weight: .semibold))
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(value == defaultValue ? Color.white.opacity(0.45) : Color.tan)
                    .contentTransition(.numericText())
            }
            GeometryReader { geo in
                let w = geo.size.width
                let span = range.upperBound - range.lowerBound
                let x = CGFloat((value - range.lowerBound) / span) * w
                let d = CGFloat((defaultValue - range.lowerBound) / span) * w
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18)).frame(height: 3)
                    Capsule().fill(Color.tan)
                        .frame(width: max(0, abs(x - d)), height: 3)
                        .offset(x: min(x, d))
                    Circle().fill(Color.white.opacity(0.6)).frame(width: 5, height: 5)
                        .offset(x: d - 2.5)
                    Circle().fill(Color.white)
                        .frame(width: 24, height: 24)
                        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                        .offset(x: x - 12)
                }
                .frame(height: 28)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .updating($dragging) { _, state, _ in state = true }
                        .onChanged { g in
                            if dragStart == nil { dragStart = value }
                            // Relative drag (the thumb doesn't jump to the finger), full
                            // range across the track.
                            let start = dragStart ?? value
                            let delta = Double(g.translation.width / max(w, 1)) * span
                            var v = min(max(start + delta, range.lowerBound), range.upperBound)
                            // A little detent at the default.
                            if abs(v - defaultValue) < span * 0.012 { v = defaultValue }
                            v = v.rounded()
                            if v != value {
                                // One undo step per drag, and only once it changes something.
                                if !dragMoved { dragMoved = true; onBegin() }
                                if (value - defaultValue).sign != (v - defaultValue).sign || v == defaultValue { crossTick += 1 }
                                value = v
                            }
                        }
                        .onEnded { _ in
                            dragStart = nil
                            dragMoved = false
                        }
                )
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    guard value != defaultValue else { return }
                    onBegin()
                    withAnimation(.snappy) { value = defaultValue }
                })
            }
            .frame(height: 28)
        }
        .onChange(of: dragging) { _, active in
            if !active {
                dragStart = nil
                dragMoved = false
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: crossTick)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(adjustment.name)
        .accessibilityValue(label)
        .accessibilityIdentifier("editor.slider.\(adjustment.id)")
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 50
            onBegin()
            value = min(max(value + (direction == .increment ? step : -step), range.lowerBound), range.upperBound)
        }
    }
}
