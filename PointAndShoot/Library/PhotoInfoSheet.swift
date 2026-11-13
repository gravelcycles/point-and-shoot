import CoreLocation
import ImageIO
import MapKit
import Photos
import SwiftUI
import UniformTypeIdentifiers

/// What a photographer wants to know about a frame.
struct AssetDetails {
    var cameraModel: String?
    var lensModel: String?
    var focal35: Int?
    var aperture: Double?
    var shutter: Double?
    var iso: Int?
    var exposureBias: Double?
    var width = 0
    var height = 0
    var fileType: String?
    var fileBytes: Int?
    var hasRAW = false
    var heading: Double?

    static func load(for asset: PHAsset) async -> AssetDetails {
        var d = AssetDetails()
        d.width = asset.pixelWidth
        d.height = asset.pixelHeight
        guard asset.mediaType == .image else { return d }

        let result: (Data, String?)? = await withCheckedContinuation { cont in
            let options = PHImageRequestOptions()
            options.version = .original
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, _ in
                cont.resume(returning: data.map { ($0, uti) })
            }
        }
        d.hasRAW = PhotoLibrary.hasRAW(asset)
        guard let result else { return d }
        let (data, uti) = result
        d.fileBytes = data.count
        if let uti, let type = UTType(uti) {
            d.fileType = type.preferredFilenameExtension?.uppercased()
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return d }

        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
        d.cameraModel = tiff[kCGImagePropertyTIFFModel as String] as? String
        d.lensModel = exif[kCGImagePropertyExifLensModel as String] as? String
        d.focal35 = (exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? NSNumber)?.intValue
        d.aperture = (exif[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue
        d.shutter = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue
        d.iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.intValue
        d.exposureBias = (exif[kCGImagePropertyExifExposureBiasValue as String] as? NSNumber)?.doubleValue
        d.heading = (gps[kCGImagePropertyGPSImgDirection as String] as? NSNumber)?.doubleValue
        return d
    }
}

struct PhotoInfoSheet: View {
    let asset: PHAsset
    @State private var details: AssetDetails?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if asset.mediaType == .image { exposure }
                    fileInfo
                    if let location = asset.location { mapSection(location) }
                }
                .padding(20)
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .tint(.yellow)
        .task { details = await AssetDetails.load(for: asset) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let date = asset.creationDate {
                Text(date, format: .dateTime.weekday(.wide).month(.wide).day().year())
                    .font(.system(size: 17, weight: .semibold))
                Text(date, format: .dateTime.hour().minute().second())
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            if asset.hasAdjustments {
                Label("Edited — original kept", systemImage: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.yellow)
                    .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private var exposure: some View {
        if let d = details {
            VStack(alignment: .leading, spacing: 10) {
                if let lens = d.lensModel ?? d.cameraModel {
                    Text(lens)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    if let f = d.focal35 { chip("\(f) mm") }
                    if let a = d.aperture { chip(String(format: "ƒ%.1f", a)) }
                    if let s = d.shutter { chip(Stops.shutterLabel(s)) }
                    if let iso = d.iso { chip("ISO \(iso)") }
                    if let ev = d.exposureBias, abs(ev) > 0.01 { chip(Stops.evLabel(Float(ev)) + " EV") }
                }
            }
        } else {
            ProgressView().tint(.white)
        }
    }

    private var fileInfo: some View {
        let mp = Double(asset.pixelWidth * asset.pixelHeight) / 1_000_000
        var parts = ["\(Int(mp.rounded())) MP", "\(asset.pixelWidth) × \(asset.pixelHeight)"]
        if asset.mediaType == .video {
            let t = Int(asset.duration.rounded())
            parts.append(String(format: "%d:%02d", t / 60, t % 60))
        }
        if let type = details?.fileType { parts.append(type) }
        if let bytes = details?.fileBytes {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        return HStack(spacing: 8) {
            Text(parts.joined(separator: " · "))
                .font(.system(size: 13, weight: .medium))
            if details?.hasRAW == true { chip("RAW") }
        }
    }

    private func mapSection(_ location: CLLocation) -> some View {
        let c = location.coordinate
        return VStack(alignment: .leading, spacing: 8) {
            Map(initialPosition: .region(MKCoordinateRegion(center: c, latitudinalMeters: 900, longitudinalMeters: 900))) {
                Marker("Photo", systemImage: "camera.fill", coordinate: c)
                    .tint(.yellow)
            }
            .frame(height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "%.5f, %.5f", c.latitude, c.longitude))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                    HStack(spacing: 10) {
                        if location.verticalAccuracy >= 0 {
                            Text("\(Int(location.altitude.rounded())) m altitude")
                        }
                        if let heading = details?.heading {
                            Label("\(Int(heading.rounded()))° \(compass(heading))", systemImage: "location.north.line")
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open in Maps") {
                    if let url = URL(string: "maps://?ll=\(c.latitude),\(c.longitude)&q=Photo") {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.system(size: 13, weight: .semibold))
            }
        }
    }

    private func compass(_ degrees: Double) -> String {
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return names[Int((degrees / 45).rounded()) % 8]
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.white.opacity(0.12), in: Capsule())
    }
}
