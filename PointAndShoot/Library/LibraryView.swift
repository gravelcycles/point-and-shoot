import Photos
import SwiftUI

struct AssetItem: Identifiable, Hashable {
    let asset: PHAsset
    var id: String { asset.localIdentifier }
}

/// Grid of the whole roll, opened from the viewer. Tap a photo to jump the viewer to it,
/// or tap Select to pick several and share or delete them together.
struct RollGrid: View {
    let roll: RollStore
    let onSelect: (PHAsset) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var share: ShareItem?
    @State private var working = false
    @State private var errorMessage: String?
    @State private var ticks = 0

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 4)

    private var selectedAssets: [PHAsset] {
        roll.assets.filter { selected.contains($0.localIdentifier) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(roll.assets, id: \.localIdentifier) { asset in
                        let isSelected = selected.contains(asset.localIdentifier)
                        AssetThumbnail(asset: asset, manager: roll.imageManager)
                            .id(asset.revisionKey)
                            .aspectRatio(1, contentMode: .fill)
                            .clipped()
                            .overlay {
                                if selecting {
                                    ZStack(alignment: .bottomTrailing) {
                                        Color.black.opacity(isSelected ? 0.3 : 0)
                                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 22, weight: .semibold))
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(isSelected ? Color.black : Color.white, isSelected ? Color.yellow : Color.black.opacity(0.3))
                                            .padding(5)
                                    }
                                    .allowsHitTesting(false)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { tap(asset) }
                            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                    }
                }
            }
            .navigationTitle(selecting ? (selected.isEmpty ? "Select Items" : "\(selected.count) Selected") : "Roll")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(selecting ? "Cancel" : "Select") {
                        withAnimation(.snappy(duration: 0.2)) {
                            selecting.toggle()
                            selected.removeAll()
                        }
                    }
                    .accessibilityIdentifier("grid.select")
                }
            }
            .overlay {
                if roll.isLoaded && roll.assets.isEmpty {
                    ContentUnavailableView("No photos", systemImage: "photo.on.rectangle",
                                           description: Text("Everything here has been deleted."))
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selecting { selectionBar }
            }
            // Items deleted elsewhere (Photos, another device) drop out of the selection.
            .onChange(of: roll.assets) { _, assets in
                let live = Set(assets.map(\.localIdentifier))
                if !selected.isSubset(of: live) { selected.formIntersection(live) }
                if assets.isEmpty, selecting { selecting = false }
            }
            .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil },
                                                                set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .sheet(item: $share) { item in
            ActivityView(items: item.urls)
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
        .sensoryFeedback(.selection, trigger: ticks)
        .preferredColorScheme(.dark)
        .tint(.yellow)
        .presentationDragIndicator(.visible)
    }

    private var selectionBar: some View {
        HStack {
            Button {
                shareSelected()
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
                    .frame(minWidth: 88, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("grid.share")
            Spacer()
            if working { ProgressView().tint(.white) }
            Spacer()
            Button(role: .destructive) {
                deleteSelected()
            } label: {
                Label("Delete", systemImage: "trash")
                    .frame(minWidth: 88, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("grid.delete")
        }
        .font(.system(size: 15, weight: .semibold))
        .disabled(selected.isEmpty || working)
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func tap(_ asset: PHAsset) {
        guard selecting else {
            onSelect(asset)
            return
        }
        let id = asset.localIdentifier
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        ticks += 1
    }

    private func shareSelected() {
        let assets = selectedAssets
        working = true
        Task {
            let urls = await PhotoLibrary.exportForSharing(assets)
            working = false
            if urls.isEmpty {
                errorMessage = "Couldn't prepare those items for sharing."
            } else {
                share = ShareItem(urls: urls)
            }
        }
    }

    private func deleteSelected() {
        let assets = selectedAssets
        guard !assets.isEmpty, !working else { return }
        working = true
        Task {
            defer { working = false }
            do {
                try await PhotoLibrary.delete(assets)
                withAnimation(.snappy(duration: 0.2)) {
                    selected.removeAll()
                    selecting = false
                }
            } catch where PhotoLibrary.isUserCancel(error) {
                // Kept them: stay in Select with the same items picked.
            } catch {
                errorMessage = "Couldn't delete: \(error.localizedDescription)"
            }
        }
    }
}

struct AssetThumbnail: View {
    let asset: PHAsset
    let manager: PHCachingImageManager
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                Color.white.opacity(0.06)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .transition(.opacity)
                }
                HStack(spacing: 3) {
                    if asset.mediaType == .video {
                        Image(systemName: "video.fill")
                        Text(Self.duration(asset.duration))
                    }
                    if asset.isFavorite { Image(systemName: "heart.fill") }
                    if asset.hasAdjustments { Image(systemName: "slider.horizontal.3") }
                }
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .shadow(radius: 2)
                .padding(4)
            }
            .onAppear { request(size: geo.size) }
            .onDisappear {
                if let requestID { manager.cancelImageRequest(requestID) }
            }
        }
    }

    private static func duration(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func request(size: CGSize) {
        guard image == nil else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        let target = CGSize(width: max(size.width, 100) * displayScale, height: max(size.height, 100) * displayScale)
        requestID = manager.requestImage(for: asset, targetSize: target, contentMode: .aspectFill, options: options) { img, _ in
            if let img { withAnimation(.easeOut(duration: 0.15)) { image = img } }
        }
    }
}
