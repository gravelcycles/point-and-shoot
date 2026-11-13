import Photos
import SwiftUI

struct AssetItem: Identifiable, Hashable {
    let asset: PHAsset
    var id: String { asset.localIdentifier }
}

/// Grid of the whole roll, opened from the viewer. Picking a photo jumps the viewer to it.
struct RollGrid: View {
    let roll: RollStore
    let onSelect: (PHAsset) -> Void
    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 4)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(roll.assets, id: \.localIdentifier) { asset in
                        AssetThumbnail(asset: asset, manager: roll.imageManager)
                            .id(asset.revisionKey)
                            .aspectRatio(1, contentMode: .fill)
                            .clipped()
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect(asset) }
                    }
                }
            }
            .navigationTitle("Roll")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(.yellow)
        .presentationDragIndicator(.visible)
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
