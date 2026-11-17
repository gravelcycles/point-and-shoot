import SwiftUI

/// What the camera's thumbnail opens: the shot you just took, full screen, with every shot
/// in a filmstrip below it (Chromagraph's reel). Swipe sideways or tap the filmstrip to move
/// through the library, swipe down to get back to shooting. Shots live in the app's own
/// library (`ShotStore`); Export puts the rendered photo into Photos.
struct PhotoViewer: View {
    let store: ShotStore
    let camera: CameraController

    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var awaitingCapture: Bool
    @State private var chromeHidden = false
    @State private var dragY: CGFloat = 0
    @State private var editing: Shot?
    @State private var showGrid = false
    /// The photo was opened from the grid, so swiping down goes back to the grid.
    @State private var cameFromGrid = false
    @State private var shareURL: ShareItem?
    @State private var working = false
    @State private var banner: Banner?
    @State private var lastIndex = 0
    /// The photo on screen is zoomed in: drags pan it instead of dismissing the viewer.
    @State private var pageZoomed = false
    @GestureState private var dismissDragActive = false
    @State private var dismissing = false
    /// Two fingers pinched since the current drag began.
    @State private var pinchedDuringDrag = false
    /// When a second finger last touched the photo. Never cleared: a drag ending within
    /// moments of a pinch is that pinch's fingers lifting, whatever order SwiftUI and UIKit
    /// deliver the lift in.
    @State private var lastMultiTouch = Date.distantPast
    private var recentlyPinched: Bool { Date().timeIntervalSince(lastMultiTouch) < 0.6 }
    /// UI tests: the last zoom report (scale @ whether it was for the selected page).
    @State private var zoomProbe = "none"

    private static let pendingID = ViewerSelection.pendingID

    struct Banner: Equatable {
        var text: String
        /// Shots that "Undo" brings back from the trash.
        var undoTrash: [UUID] = []
        let id = UUID()
    }

    init(store: ShotStore, camera: CameraController) {
        self.store = store
        self.camera = camera
        let waiting = camera.capturesInFlight > 0
        _awaitingCapture = State(initialValue: waiting)
        _selectedID = State(initialValue: waiting ? Self.pendingID
                            : (camera.lastSavedShotID?.uuidString ?? store.shots.first?.id.uuidString))
    }

    private var showPending: Bool { awaitingCapture && camera.lastThumbnail != nil }
    private var selectedShot: Shot? {
        guard let selectedID, let id = UUID(uuidString: selectedID) else { return nil }
        return store.shots.first { $0.id == id }
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - min(Double(dragY) / 400, 0.7))
                .ignoresSafeArea()

            Group {
                if store.shots.isEmpty && !showPending {
                    ContentUnavailableView("No photos yet", systemImage: "camera",
                                           description: Text("Go take one."))
                } else {
                    pager
                }
            }
            .offset(y: dragY)
            .scaleEffect(1 - min(dragY / 2400, 0.12))

            if !chromeHidden && dragY == 0 {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    bottomBar
                }
                .transition(.opacity)
            }

            if let banner {
                bannerView(banner)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(chromeHidden)
        .overlay(alignment: .topLeading) { RollCountProbe(store: store).padding(.top, 2) }
        .overlay(alignment: .topTrailing) {
            if TestHooks.isUITest {
                let state = "zoomed=\(pageZoomed ? 1 : 0) pinched=\(pinchedDuringDrag ? 1 : 0) dragY=\(Int(dragY)) last=\(zoomProbe)"
                Text(state)
                    .font(.system(size: 6))
                    .foregroundStyle(.white.opacity(0.02))
                    .frame(width: 20, height: 8)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("viewer.zoomProbe")
                    .accessibilityLabel(state)
            }
        }
        .task { reconcileSelection() }
        .onChange(of: store.shots.map(\.id)) { _, _ in reconcileSelection() }
        .onChange(of: camera.capturesInFlight) { _, _ in reconcileSelection() }
        .onChange(of: camera.lastSavedShotID) { _, _ in reconcileSelection() }
        .onChange(of: pageZoomed) { _, zoomed in
            if zoomed, dragY != 0 { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { dragY = 0 } }
        }
        .onChange(of: dismissDragActive) { _, active in
            guard !active else { return }
            ViewerEventProbe.shared.add("g-")
            // Not the place to clear `pinchedDuringDrag`: SwiftUI can end and restart its
            // drag mid-pinch (when a finger joins or lifts). A new touch sequence clears it.
            if !dismissing, dragY != 0 {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { dragY = 0 }
            }
        }
        .onChange(of: selectedID) { _, id in
            pageZoomed = false
            pinchedDuringDrag = false
            if let id, let i = store.shots.firstIndex(where: { $0.id.uuidString == id }) { lastIndex = i }
        }
        // One presentation per anchor view.
        .background {
            Color.clear
                .fullScreenCover(item: $editing) { shot in
                    EditorView(shot: shot, store: store, defaultGrade: camera.settings.defaultGrade,
                               onSetDefault: { grade in
                                   camera.update {
                                       $0.defaultGrade = grade
                                       $0.captureLook = grade.look
                                   }
                               }) { message in
                        show(Banner(text: message))
                    }
                }
            Color.clear
                .sheet(isPresented: $showGrid) {
                    RollGrid(store: store, camera: camera) { shot in
                        selectedID = shot.id.uuidString
                        cameFromGrid = true
                        showGrid = false
                    }
                }
            Color.clear
                .sheet(item: $shareURL) { item in
                    ActivityView(items: item.urls)
                        .presentationDetents([.medium, .large])
                        .ignoresSafeArea()
                }
        }
    }

    // MARK: Pager

    private var pager: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                if showPending, let thumb = camera.lastThumbnail {
                    PendingPage(image: thumb)
                        .containerRelativeFrame([.horizontal, .vertical])
                        .contentShape(Rectangle())
                        .onTapGesture(perform: toggleChrome)
                        .id(Self.pendingID)
                }
                ForEach(store.shots) { shot in
                    let id = shot.id.uuidString
                    ShotPage(shot: shot, store: store, isCurrent: id == selectedID,
                             developing: store.developing.contains(shot.id),
                             onTap: toggleChrome,
                             onZoom: { scale in
                                 if TestHooks.isUITest { zoomProbe = String(format: "%.2f@%d", scale, id == selectedID ? 1 : 0) }
                                 guard id == selectedID else { return }
                                 let zoomed = scale > 1.01
                                 if zoomed != pageZoomed { pageZoomed = zoomed }
                                 if zoomed { pinchedDuringDrag = true }
                             },
                             onTouches: { multiTouch in
                                 // Two fingers anywhere in this touch sequence make it a
                                 // pinch: when they lift it must never count as a swipe-down.
                                 ViewerEventProbe.shared.add(multiTouch ? "t2" : "t1")
                                 if multiTouch {
                                     lastMultiTouch = Date()
                                     pinchedDuringDrag = true
                                     if dragY != 0 { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { dragY = 0 } }
                                 } else {
                                     // A new touch sequence (first finger down).
                                     pinchedDuringDrag = false
                                 }
                             })
                        .containerRelativeFrame([.horizontal, .vertical])
                        .id(id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $selectedID)
        .ignoresSafeArea()
        .simultaneousGesture(
            DragGesture(minimumDistance: 24, coordinateSpace: .global)
                .updating($dismissDragActive) { _, active, _ in active = true }
                .onChanged { v in
                    // Zoomed in (or pinching), a drag pans the photo; it never dismisses.
                    guard !pageZoomed, !pinchedDuringDrag, !recentlyPinched else { return }
                    if v.translation.height > 0, v.translation.height > abs(v.translation.width) * 1.4 {
                        if dragY == 0 { ViewerEventProbe.shared.add("d") }
                        dragY = v.translation.height
                    }
                }
                .onEnded { v in
                    ViewerEventProbe.shared.add("e\(pinchedDuringDrag ? 1 : 0)\(pageZoomed ? 1 : 0)y\(Int(dragY))")
                    if pageZoomed || pinchedDuringDrag || recentlyPinched {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { dragY = 0 }
                        return
                    }
                    if dragY > 130 || v.predictedEndTranslation.height > 420 && dragY > 40 {
                        if cameFromGrid {
                            cameFromGrid = false
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { dragY = 0 }
                            showGrid = true
                        } else {
                            dismissing = true
                            ViewerEventProbe.shared.add("X")
                            dismiss()
                        }
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { dragY = 0 }
                    }
                }
        )
    }

    private func toggleChrome() {
        withAnimation(.easeOut(duration: 0.2)) { chromeHidden.toggle() }
    }

    /// Keep the viewer pointed at the right photo while a just-taken shot finishes saving,
    /// and on the neighbour after one is trashed.
    private func reconcileSelection() {
        let next = ViewerSelection.reconcile(
            .init(awaitingCapture: awaitingCapture, selectedID: selectedID),
            capturesInFlight: camera.capturesInFlight,
            lastSavedAssetID: camera.lastSavedShotID?.uuidString,
            assetIDs: store.shots.map(\.id.uuidString),
            lastIndex: lastIndex)
        if next.awaitingCapture != awaitingCapture { awaitingCapture = next.awaitingCapture }
        if next.selectedID != selectedID { selectedID = next.selectedID }
    }

    // MARK: Chrome

    private var topBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                circleButton("square.grid.2x2", id: "viewer.grid") { showGrid = true }
                circleButton("camera", id: "viewer.close") {
                    ViewerEventProbe.shared.add("C")
                    dismiss()
                }
                circleButton(working ? "hourglass" : "square.and.arrow.up", id: "viewer.share") { share() }
                    .disabled(selectedShot == nil || working)
                Spacer()
                circleButton(selectedShot?.keep == true ? "bookmark.fill" : "bookmark", id: "viewer.keep",
                             tint: selectedShot?.keep == true ? .tan : .white) {
                    guard let shot = selectedShot else { return }
                    Haptics.impact(.light)
                    store.setKeep(!shot.keep, for: [shot.id])
                    show(Banner(text: shot.keep ? "No longer kept" : "Kept — never moved to the Trash"))
                }
                .disabled(selectedShot == nil)
                circleButton("trash", id: "viewer.delete") { trash() }
                    .disabled(selectedShot == nil)
            }
            if let shot = selectedShot {
                infoLine(shot)
            } else if selectedID == Self.pendingID {
                Text("Saving…").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .background(
            LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        )
    }

    private func infoLine(_ shot: Shot) -> some View {
        HStack(spacing: 8) {
            Text(shot.kind == .proRAW ? "PRORAW" : shot.isRAW ? "RAW" : "HEIF")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 1) {
                Text(shot.captured, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                    .font(.system(size: 11, weight: .semibold))
                if !shot.exposureLine.isEmpty {
                    Text(shot.exposureLine).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if shot.keep {
                Label("Kept", systemImage: "bookmark.fill")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.tan)
            } else if let days = ShotRetention.daysLeft(shot, now: Date(), storeForever: camera.settings.storeForever) {
                Text(days == 1 ? "1 day left" : "\(days) days left")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("viewer.info")
    }

    private var bottomBar: some View {
        let shot = selectedShot
        return VStack(spacing: 10) {
            HStack {
                Color.clear.frame(width: 44, height: 44)
                Spacer()
                Button {
                    if let shot { editing = shot }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 52, height: 44)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(PressScaleStyle(scale: 0.94))
                .disabled(shot == nil)
                .accessibilityIdentifier("viewer.edit")
                Spacer()
                Button { export() } label: {
                    ZStack {
                        Circle().fill(Color.tan)
                        if working {
                            ProgressView().tint(.black)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.black)
                        }
                    }
                    .frame(width: 44, height: 44)
                }
                .buttonStyle(PressScaleStyle(scale: 0.94))
                .disabled(shot == nil || working)
                .accessibilityIdentifier("viewer.export")
            }
            .padding(.horizontal, 20)
            Filmstrip(store: store, selectedID: $selectedID)
                .frame(height: 50)
        }
        .padding(.bottom, 6)
        .padding(.top, 30)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        )
    }

    private func circleButton(_ symbol: String, id: String, tint: Color = .white,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityIdentifier(id)
    }

    private func bannerView(_ b: Banner) -> some View {
        HStack(spacing: 12) {
            Text(b.text)
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
            if !b.undoTrash.isEmpty {
                Button("Undo") {
                    store.restore(b.undoTrash)
                    if let first = b.undoTrash.first { selectedID = first.uuidString }
                    withAnimation { banner = nil }
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.tan)
                .accessibilityIdentifier("viewer.undo")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 110)
    }

    // MARK: Actions

    private func trash() {
        Haptics.impact(.light)
        guard let shot = selectedShot else { return }
        store.moveToTrash([shot.id])
        show(Banner(text: "Moved to Trash", undoTrash: [shot.id]), seconds: 4)
    }

    private func export() {
        guard let shot = selectedShot else { return }
        working = true
        Task {
            do {
                try await ShotExporter.exportToPhotos([shot], store: store, options: .init(camera.settings))
                Haptics.success()
                show(Banner(text: "Saved to Photos"))
            } catch {
                show(Banner(text: "Couldn't save to Photos: \(error.localizedDescription)"), seconds: 5)
            }
            working = false
        }
    }

    private func share() {
        guard let shot = selectedShot else { return }
        working = true
        Task {
            let urls = await ShotExporter.shareFiles([shot], store: store, options: .init(camera.settings))
            working = false
            if !urls.isEmpty { shareURL = ShareItem(urls: urls) }
        }
    }

    private func show(_ b: Banner, seconds: Double = 1.8) {
        Diag.log(.viewer, "banner: \(b.text)")
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { banner = b }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if banner?.id == b.id { withAnimation(.easeOut(duration: 0.25)) { banner = nil } }
        }
    }
}

extension Color {
    /// Chromagraph-style accent for library actions (export, keep).
    static let tan = Color(red: 0.80, green: 0.70, blue: 0.53)
}

struct ShareItem: Identifiable {
    let urls: [URL]
    let id = UUID()
    init(url: URL) { urls = [url] }
    init(urls: [URL]) { self.urls = urls }
}

// MARK: - Filmstrip

/// Every shot in a strip under the photo; the current one outlined. Tap to jump.
struct Filmstrip: View {
    let store: ShotStore
    @Binding var selectedID: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 3) {
                    ForEach(store.shots) { shot in
                        let id = shot.id.uuidString
                        ShotThumbnail(shot: shot, store: store)
                            .frame(width: id == selectedID ? 50 : 36, height: 46)
                            .clipped()
                            .overlay(RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.white, lineWidth: id == selectedID ? 2 : 0))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Haptics.selectionChanged()
                                selectedID = id
                            }
                            .id(id)
                            .accessibilityIdentifier("viewer.filmstrip.cell")
                    }
                }
                .padding(.horizontal, 16)
                .animation(.snappy(duration: 0.2), value: selectedID)
            }
            .onAppear { if let selectedID { proxy.scrollTo(selectedID, anchor: .center) } }
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

/// A shot's graded thumbnail (the camera's preview until it's developed).
struct ShotThumbnail: View {
    let shot: Shot
    let store: ShotStore
    @State private var image: UIImage?

    var body: some View {
        Color(white: 0.12)
            .overlay {
                if let image = image ?? store.cachedImage(shot, .thumb) {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .task(id: "\(shot.id)-\(shot.revision)") {
                image = await store.image(shot, .thumb)
            }
    }
}

// MARK: - Pages

private struct PendingPage: View {
    let image: UIImage

    var body: some View {
        ZStack {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .blur(radius: 6)
                .opacity(0.8)
            VStack(spacing: 10) {
                ProgressView().tint(.white).controlSize(.large)
                Text("Developing…").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            }
        }
    }
}

private struct ShotPage: View {
    let shot: Shot
    let store: ShotStore
    var isCurrent = true
    /// Its look is still being developed: show the camera's preview blurred under
    /// "Developing…" rather than as if it were the finished shot.
    var developing = false
    var onTap: () -> Void = {}
    var onZoom: (CGFloat) -> Void = { _ in }
    var onTouches: (Bool) -> Void = { _ in }

    @State private var image: UIImage?
    /// A full-resolution render from the RAW for zooming in, made the first time the page is
    /// zoomed.
    @State private var detail: UIImage?
    @State private var detailKey: Int?
    @State private var detailTask: Task<Void, Never>?

    static let detailMaxPixels: CGFloat = 4096

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image = image ?? store.cachedImage(shot, .preview) {
                    if developing {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .blur(radius: 6)
                            .opacity(0.8)
                            .contentShape(Rectangle())
                            .onTapGesture(perform: onTap)
                        VStack(spacing: 10) {
                            ProgressView().tint(.white).controlSize(.large)
                            Text("Developing…").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        }
                        .allowsHitTesting(false)
                        .transition(.opacity)
                    } else {
                        ZoomableImageView(
                            image: detailKey == shot.revision ? (detail ?? image) : image,
                            pixelSize: CGSize(width: shot.pixelWidth ?? 4032, height: shot.pixelHeight ?? 3024),
                            isCurrent: isCurrent,
                            onTap: onTap,
                            onZoom: { scale in
                                onZoom(scale)
                                if scale > 1.3 { loadDetail() }
                            },
                            onTouches: onTouches)
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                } else {
                    ProgressView().tint(.white)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onTap)
                }
            }
            .animation(.easeOut(duration: 0.25), value: developing)
            .frame(width: geo.size.width, height: geo.size.height)
            .task(id: "\(shot.id)-\(shot.revision)") {
                if let loaded = await store.image(shot, .preview) { image = loaded }
            }
            .onChange(of: isCurrent) { _, current in
                if !current { dropDetail() }
            }
            .onDisappear { dropDetail() }
        }
    }

    /// Zoomed in: render the grade from the RAW at (up to) full size so it stays sharp.
    private func loadDetail() {
        let revision = shot.revision
        guard detailKey != revision, detailTask == nil, isCurrent, !developing else { return }
        let shot = self.shot
        let dir = store.dir(shot.id)
        let recipe = store.recipe(for: shot.id)
        let maxPixels = Self.detailMaxPixels
        detailTask = Task {
            let start = Date()
            let rendered = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let image = ShotRenderer.render(shot, in: dir, recipe: recipe, maxSide: maxPixels),
                      let cg = EditPipeline.context.createCGImage(image, from: image.extent, format: .RGBA8,
                                                                  colorSpace: EditPipeline.displayColorSpace)
                else { return nil }
                return UIImage(cgImage: cg)
            }.value
            detailTask = nil
            guard !Task.isCancelled, let rendered, self.shot.revision == revision else { return }
            detail = rendered
            detailKey = revision
            Diag.log(.viewer, "zoom render \(Int(rendered.size.width))×\(Int(rendered.size.height)) in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        }
    }

    private func dropDetail() {
        detailTask?.cancel()
        detailTask = nil
        detail = nil
        detailKey = nil
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
