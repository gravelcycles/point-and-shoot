import AVKit
import Photos
import SwiftUI

/// What the camera's thumbnail opens: the shot you just took, full screen. Swipe sideways
/// through the roll, swipe down to get back to shooting, tap Edit to open the editor.
struct PhotoViewer: View {
    let roll: RollStore
    let camera: CameraController

    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var awaitingCapture: Bool
    @State private var chromeHidden = false
    @State private var dragY: CGFloat = 0
    @State private var editing: AssetItem?
    @State private var showGrid = false
    /// The photo was opened from the grid, so swiping down goes back to the grid.
    @State private var cameFromGrid = false
    @State private var infoAsset: AssetItem?
    @State private var shareURL: ShareItem?
    @State private var preparingShare = false
    @State private var assetHasRAW = false
    @State private var savedBanner: String?
    @State private var lastIndex = 0

    private static let pendingID = "__pending__"

    init(roll: RollStore, camera: CameraController) {
        self.roll = roll
        self.camera = camera
        let waiting = camera.capturesInFlight > 0
        _awaitingCapture = State(initialValue: waiting)
        _selectedID = State(initialValue: waiting ? Self.pendingID : (camera.lastSavedAssetID ?? roll.assets.first?.localIdentifier))
    }

    private var showPending: Bool { awaitingCapture && camera.lastThumbnail != nil }
    private var selectedAsset: PHAsset? { selectedID.flatMap { roll.asset(withID: $0) } }

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - min(Double(dragY) / 400, 0.7))
                .ignoresSafeArea()

            Group {
                switch roll.status {
                case .authorized, .limited:
                    if roll.assets.isEmpty && !showPending {
                        ContentUnavailableView("No photos yet", systemImage: "camera",
                                               description: Text("Go take one."))
                    } else {
                        pager
                    }
                case .notDetermined:
                    ProgressView().tint(.white)
                default:
                    accessDenied
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

            if let savedBanner {
                Toast(text: savedBanner)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(chromeHidden)
        .task {
            if roll.status == .notDetermined { await roll.requestAccess() }
            reconcileSelection()
        }
        .onChange(of: roll.assets) { _, _ in
            reconcileSelection()
            // Deleted elsewhere (Photos, another device, the grid) while its info was open.
            if let info = infoAsset, !roll.contains(info.id) { infoAsset = nil }
        }
        .onChange(of: camera.capturesInFlight) { _, _ in reconcileSelection() }
        .onChange(of: camera.lastSavedAssetID) { _, _ in reconcileSelection() }
        .onChange(of: selectedID) { _, id in
            if let id, let i = roll.assets.firstIndex(where: { $0.localIdentifier == id }) { lastIndex = i }
        }
        .task(id: selectedID) {
            if let asset = selectedAsset, asset.mediaType == .image {
                let id = asset.localIdentifier
                let raw = await Task.detached { PhotoLibrary.hasRAW(asset) }.value
                if selectedID == id { assetHasRAW = raw }
            } else {
                assetHasRAW = false
            }
        }
        // One presentation per anchor view: several sheets/covers chained on the same view
        // is unreliable (it's what kept Settings from opening on the camera screen).
        .background {
            Color.clear
                .fullScreenCover(item: $editing) { item in
                    EditorView(asset: item.asset) { message in
                        show(banner: message)
                    }
                }
            Color.clear
                .sheet(item: $infoAsset) { item in
                    PhotoInfoSheet(asset: item.asset)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
            Color.clear
                .sheet(isPresented: $showGrid) {
                    RollGrid(roll: roll) { asset in
                        selectedID = asset.localIdentifier
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
                        .id(Self.pendingID)
                }
                ForEach(roll.assets, id: \.localIdentifier) { asset in
                    AssetPage(asset: asset, manager: roll.imageManager, isCurrent: asset.localIdentifier == selectedID)
                        .containerRelativeFrame([.horizontal, .vertical])
                        .id(asset.localIdentifier)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $selectedID)
        .ignoresSafeArea()
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.2)) { chromeHidden.toggle() }
        }
        .simultaneousGesture(
            // Global space: the pager itself moves with the finger, so local translation
            // would shrink as you drag (jitter, and twice the travel to dismiss).
            DragGesture(minimumDistance: 24, coordinateSpace: .global)
                .onChanged { v in
                    // Only a mostly-vertical, downward pull dismisses; sideways is paging.
                    if v.translation.height > 0, v.translation.height > abs(v.translation.width) * 1.4 {
                        dragY = v.translation.height
                    }
                }
                .onEnded { v in
                    if dragY > 130 || v.predictedEndTranslation.height > 420 && dragY > 40 {
                        // Back to wherever the photo was opened from: the grid or the camera.
                        if cameFromGrid {
                            cameFromGrid = false
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { dragY = 0 }
                            showGrid = true
                        } else {
                            dismiss()
                        }
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { dragY = 0 }
                    }
                }
        )
    }

    /// Keep the viewer pointed at the right photo while a just-taken shot finishes saving.
    private func reconcileSelection() {
        if awaitingCapture, camera.capturesInFlight == 0 {
            if let id = camera.lastSavedAssetID, roll.contains(id) {
                awaitingCapture = false
                if selectedID == Self.pendingID || selectedID == nil { selectedID = id }
            } else if camera.lastSavedAssetID == nil {
                awaitingCapture = false
            }
        }
        if !awaitingCapture, let id = selectedID, id == Self.pendingID || !roll.contains(id) {
            // Deleted (or pending resolved): land on the neighbor, like the Photos app.
            let i = min(lastIndex, roll.assets.count - 1)
            selectedID = i >= 0 ? roll.assets[i].localIdentifier : nil
        }
        if selectedID == nil { selectedID = roll.assets.first?.localIdentifier }
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            Spacer()
            VStack(spacing: 1) {
                if let asset = selectedAsset, let date = asset.creationDate {
                    Text(date, format: .dateTime.month(.abbreviated).day().year())
                        .font(.system(size: 14, weight: .semibold))
                    Text(date, format: .dateTime.hour().minute())
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if selectedID == Self.pendingID {
                    Text("Saving…").font(.system(size: 14, weight: .semibold))
                }
                HStack(spacing: 4) {
                    if assetHasRAW { tag("RAW") }
                    if selectedAsset?.hasAdjustments == true { tag("EDITED") }
                }
                .padding(.top, 2)
            }
            Spacer()
            Button { showGrid = true } label: {
                Image(systemName: "square.grid.3x3")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .background(
            LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        )
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
    }

    private var bottomBar: some View {
        let asset = selectedAsset
        let isPhoto = asset?.mediaType == .image
        return HStack {
            barButton(preparingShare ? "hourglass" : "square.and.arrow.up") { share() }
                .disabled(asset == nil || preparingShare)
            Spacer()
            barButton(asset?.isFavorite == true ? "heart.fill" : "heart",
                      tint: asset?.isFavorite == true ? .red : .white) {
                guard let asset else { return }
                Task {
                    do {
                        try await PhotoLibrary.toggleFavorite(asset)
                    } catch where !PhotoLibrary.isUserCancel(error) {
                        show(banner: "Couldn't change favorite: \(error.localizedDescription)")
                    } catch {}
                }
            }
            .disabled(asset == nil)
            Spacer()
            Button {
                if let asset { editing = AssetItem(asset: asset) }
            } label: {
                Text("Edit")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 26).padding(.vertical, 10)
                    .background(Color.yellow, in: Capsule())
            }
            .buttonStyle(PressScaleStyle(scale: 0.94))
            .disabled(!isPhoto)
            .opacity(isPhoto ? 1 : 0.35)
            Spacer()
            barButton("trash") {
                // iOS's own confirmation is modal, so it can't be double-sent; no busy flag
                // that could get stuck and leave the button dead.
                guard let asset else { return }
                Task {
                    do {
                        try await PhotoLibrary.delete(asset)
                        // The change observer moves the viewer to the neighbor.
                    } catch where PhotoLibrary.isUserCancel(error) {
                        // Tapped Don't Allow on the system confirmation: nothing to do.
                    } catch where PhotoLibrary.isGone(asset) {
                        // Already deleted (in Photos, or a double tap): the roll catches up.
                    } catch {
                        show(banner: "Couldn't delete: \(error.localizedDescription)")
                    }
                }
            }
            .disabled(asset == nil)
            Spacer()
            barButton("info.circle") {
                if let asset { infoAsset = AssetItem(asset: asset) }
            }
            .disabled(asset == nil)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 8)
        .padding(.top, 30)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        )
    }

    private func barButton(_ symbol: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressScaleStyle())
    }

    private var accessDenied: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 44, weight: .thin))
            Text("Photos access is off").font(.title3.weight(.semibold))
            Text("Allow full access to view and edit your shots. Your photos are still being saved.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.borderedProminent)
            .tint(.yellow)
            .foregroundStyle(.black)
        }
        .foregroundStyle(.white)
        .padding(32)
    }

    // MARK: Actions

    private func share() {
        guard let asset = selectedAsset else { return }
        preparingShare = true
        Task {
            let url = await PhotoLibrary.exportForSharing(asset)
            preparingShare = false
            if let url { shareURL = ShareItem(url: url) }
        }
    }

    private func show(banner: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { savedBanner = banner }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeOut(duration: 0.25)) { savedBanner = nil }
        }
    }
}

struct ShareItem: Identifiable {
    let urls: [URL]
    let id = UUID()
    init(url: URL) { urls = [url] }
    init(urls: [URL]) { self.urls = urls }
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

private struct AssetPage: View {
    let asset: PHAsset
    let manager: PHCachingImageManager
    let isCurrent: Bool

    var body: some View {
        if asset.mediaType == .video {
            VideoPage(asset: asset, isCurrent: isCurrent)
        } else {
            PhotoPage(asset: asset, manager: manager)

        }
    }
}

private struct PhotoPage: View {
    let asset: PHAsset
    let manager: PHCachingImageManager

    @State private var image: UIImage?
    @State private var zoom: CGFloat = 1
    @State private var anchor: UnitPoint = .center
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(zoom, anchor: anchor)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            // Pinch to peek at focus; springs back on release.
            .gesture(
                MagnifyGesture()
                    .onChanged { v in
                        anchor = v.startAnchor
                        zoom = max(1, min(v.magnification, 6))
                    }
                    .onEnded { _ in
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { zoom = 1 }
                    }
            )
            // Reload when an edit lands, keeping the current image up meanwhile (favoriting
            // also bumps the revision, and used to flash a spinner).
            .task(id: asset.revisionKey) { load(size: geo.size) }
        }
    }

    private func load(size: CGSize) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.version = .current
        let target = CGSize(width: size.width * displayScale * 1.5, height: size.height * displayScale * 1.5)
        manager.requestImage(for: asset, targetSize: target, contentMode: .aspectFit, options: options) { img, _ in
            if let img { image = img }
        }
    }
}

private struct VideoPage: View {
    let asset: PHAsset
    let isCurrent: Bool
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            if let player {
                // Keep the player's own scrubber and buttons clear of the viewer's top and
                // bottom bars (the pager ignores the safe area), so both stay tappable.
                VideoPlayer(player: player)
                    .padding(.top, 96)
                    .padding(.bottom, 120)
            } else {
                ProgressView().tint(.white)
            }
        }
        .task {
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .automatic
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                guard let item else { return }
                DispatchQueue.main.async { player = AVPlayer(playerItem: item) }
            }
        }
        .onChange(of: isCurrent) { _, current in
            if !current { player?.pause() }
        }
        .onDisappear { player?.pause() }
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
