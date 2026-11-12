import Photos
import SwiftUI

struct AssetItem: Identifiable, Hashable {
    let asset: PHAsset
    var id: String { asset.localIdentifier }
}

/// A fast camera-roll grid. Tap a photo to open it in the editor.
struct LibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var items: [AssetItem] = []
    @State private var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var editing: AssetItem?
    @State private var manager = PHCachingImageManager()

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        NavigationStack {
            Group {
                switch status {
                case .authorized, .limited:
                    grid
                case .notDetermined:
                    ProgressView()
                default:
                    ContentUnavailableView("Photos access is off",
                                           systemImage: "photo.on.rectangle.angled",
                                           description: Text("Allow full access in Settings to browse and edit."))
                }
            }
            .navigationTitle("Roll")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "camera.fill") }
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(.yellow)
        .task {
            status = await PhotoLibrary.requestReadWrite()
            if status == .authorized || status == .limited { reload() }
        }
        .fullScreenCover(item: $editing, onDismiss: reload) { item in
            EditorView(asset: item.asset)
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(items) { item in
                    AssetThumbnail(asset: item.asset, manager: manager)
                        .aspectRatio(1, contentMode: .fill)
                        .clipped()
                        .contentShape(Rectangle())
                        .onTapGesture { editing = item }
                }
            }
        }
    }

    private func reload() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 600
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var list: [AssetItem] = []
        list.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in list.append(AssetItem(asset: asset)) }
        items = list
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
            ZStack {
                Color.white.opacity(0.06)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .transition(.opacity)
                }
            }
            .onAppear { request(size: geo.size) }
            .onDisappear {
                if let requestID { manager.cancelImageRequest(requestID) }
            }
        }
    }

    private func request(size: CGSize) {
        guard image == nil else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        let target = CGSize(width: max(size.width, 120) * displayScale, height: max(size.height, 120) * displayScale)
        requestID = manager.requestImage(for: asset, targetSize: target, contentMode: .aspectFill, options: options) { img, _ in
            if let img { withAnimation(.easeOut(duration: 0.15)) { image = img } }
        }
    }
}
