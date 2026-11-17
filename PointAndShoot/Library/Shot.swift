import CoreGraphics
import Foundation
import ImageIO

/// One photo in the app's own library: the original file the camera produced (a DNG, or a
/// processed photo only where the lens has no RAW), its grade (`recipe.json`, an
/// `EditRecipe`), and renders of that grade (`preview.jpg`, `thumb.jpg`).
///
/// Nothing reaches the iOS photo library until the photo is exported (Chromagraph's model).
/// Each shot lives in its own folder, `Application Support/Shots/<id>/`:
///   shot.json      this struct
///   original.dng   (or original.heic / original.jpg)
///   recipe.json    the grade
///   capture.jpg    the camera's quick preview: shown instantly, and the stand-in for the
///                  RAW where it can't be decoded (the simulator)
///   preview.jpg    the graded render the viewer shows (long side `ShotRenderer.previewSide`)
///   thumb.jpg      the graded render the grid and filmstrip show
struct Shot: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        /// Single-frame sensor data.
        case bayerRAW
        /// Apple ProRAW (multi-frame, linear DNG).
        case proRAW
        /// A HEIF/JPEG, where the lens offered no RAW (some front cameras).
        case processed
        /// A RAW brought in from the photo library.
        case imported
    }

    var id: UUID
    var captured: Date
    var kind: Kind
    /// File name of the original inside the shot's folder.
    var original: String
    /// Tagged to keep: never moved to the trash automatically.
    var keep = false
    var trashedAt: Date?
    var exportedAt: Date?
    /// When it entered this library (an import of an older RAW is new here).
    var added: Date?
    /// When it was last put back from the Trash.
    var restoredAt: Date?
    /// Bumped whenever the grade changes, so image caches refresh.
    var revision = 0

    // Shown in the viewer's info line.
    var pixelWidth: Int?
    var pixelHeight: Int?
    var lens: String?
    var focalLength35: Int?
    var exposureTime: Double?
    var fNumber: Double?
    var iso: Int?
    var kelvin: Int?
    var latitude: Double?
    var longitude: Double?

    init(id: UUID = UUID(), captured: Date = Date(), kind: Kind, original: String) {
        self.id = id
        self.captured = captured
        self.kind = kind
        self.original = original
    }

    var isRAW: Bool { kind != .processed }

    /// When its 30 days started: taken, added to the library (imports of older RAWs) or put
    /// back from the Trash, whichever is latest.
    var retentionStart: Date {
        max(captured, added ?? captured, restoredAt ?? .distantPast)
    }

    /// "1/121 s · f/1.6 · ISO 40 · 6080 K", whatever is known.
    var exposureLine: String {
        var parts: [String] = []
        if let t = exposureTime, t > 0 {
            parts.append(t >= 1 ? String(format: "%.1f s", t) : "1/\(Int((1 / t).rounded())) s")
        }
        if let f = fNumber { parts.append(String(format: "f/%.1f", f)) }
        if let iso { parts.append("ISO \(iso)") }
        if let kelvin { parts.append("\(kelvin) K") }
        return parts.joined(separator: " · ")
    }

    // Tolerant decoding: a shot.json written by any version of the app loads.
    private enum CodingKeys: String, CodingKey {
        case id, captured, kind, original, keep, trashedAt, exportedAt, revision, added, restoredAt
        case pixelWidth, pixelHeight, lens, focalLength35, exposureTime, fNumber, iso, kelvin, latitude, longitude
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        captured = try c.decodeIfPresent(Date.self, forKey: .captured) ?? Date()
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .bayerRAW
        original = try c.decodeIfPresent(String.self, forKey: .original) ?? "original.dng"
        keep = try c.decodeIfPresent(Bool.self, forKey: .keep) ?? false
        trashedAt = try c.decodeIfPresent(Date.self, forKey: .trashedAt)
        exportedAt = try c.decodeIfPresent(Date.self, forKey: .exportedAt)
        added = try c.decodeIfPresent(Date.self, forKey: .added)
        restoredAt = try c.decodeIfPresent(Date.self, forKey: .restoredAt)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        pixelWidth = try c.decodeIfPresent(Int.self, forKey: .pixelWidth)
        pixelHeight = try c.decodeIfPresent(Int.self, forKey: .pixelHeight)
        lens = try c.decodeIfPresent(String.self, forKey: .lens)
        focalLength35 = try c.decodeIfPresent(Int.self, forKey: .focalLength35)
        exposureTime = try c.decodeIfPresent(Double.self, forKey: .exposureTime)
        fNumber = try c.decodeIfPresent(Double.self, forKey: .fNumber)
        iso = try c.decodeIfPresent(Int.self, forKey: .iso)
        kelvin = try c.decodeIfPresent(Int.self, forKey: .kelvin)
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
    }

    /// Fills the info fields from the original file's metadata.
    mutating func readMetadata(from data: Data) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return }
        if let w = props[kCGImagePropertyPixelWidth as String] as? Int,
           let h = props[kCGImagePropertyPixelHeight as String] as? Int {
            // Report upright dimensions.
            let o = props[kCGImagePropertyOrientation as String] as? Int ?? 1
            (pixelWidth, pixelHeight) = (5...8).contains(o) ? (h, w) : (w, h)
        }
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        exposureTime = exif[kCGImagePropertyExifExposureTime as String] as? Double
        fNumber = exif[kCGImagePropertyExifFNumber as String] as? Double
        iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first
        focalLength35 = exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? Int
        lens = exif[kCGImagePropertyExifLensModel as String] as? String
        if let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any],
           var lat = gps[kCGImagePropertyGPSLatitude as String] as? Double,
           var lon = gps[kCGImagePropertyGPSLongitude as String] as? Double {
            if (gps[kCGImagePropertyGPSLatitudeRef as String] as? String) == "S" { lat = -lat }
            if (gps[kCGImagePropertyGPSLongitudeRef as String] as? String) == "W" { lon = -lon }
            latitude = lat
            longitude = lon
        }
    }
}

/// Retention rules (pure, unit-tested): what the 30-day sweep trashes and purges.
enum ShotRetention {
    static let keepDays = 30
    static let trashDays = 30

    /// Shots to move to the trash now: older than 30 days, not tagged Keep, unless the
    /// user stores everything forever.
    static func dueForTrash(_ shots: [Shot], now: Date, storeForever: Bool) -> [UUID] {
        guard !storeForever else { return [] }
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 86_400)
        return shots.filter { $0.trashedAt == nil && !$0.keep && $0.retentionStart < cutoff }.map(\.id)
    }

    /// Trashed shots to delete for good: in the trash for 30 days.
    static func dueForPurge(_ shots: [Shot], now: Date) -> [UUID] {
        let cutoff = now.addingTimeInterval(-Double(trashDays) * 86_400)
        return shots.filter { ($0.trashedAt ?? .distantFuture) < cutoff }.map(\.id)
    }

    /// Days left before an unkept shot goes to the trash (nil when it never will).
    static func daysLeft(_ shot: Shot, now: Date, storeForever: Bool) -> Int? {
        guard !storeForever, !shot.keep, shot.trashedAt == nil else { return nil }
        let due = shot.retentionStart.addingTimeInterval(Double(keepDays) * 86_400)
        return max(0, Int(ceil(due.timeIntervalSince(now) / 86_400)))
    }
}
