import AVFoundation
import Foundation

/// What container the processed (non-RAW) image goes into.
enum PhotoFormat: String, Codable, CaseIterable, Identifiable {
    case heif, jpeg
    var id: String { rawValue }
    var label: String { self == .heif ? "HEIF" : "JPEG" }
}

/// RAW capture. Bayer RAW is the honest sensor dump (no Apple pipeline at all);
/// ProRAW is Apple's linear DNG with multi-frame fusion baked in.
enum RawMode: String, Codable, CaseIterable, Identifiable {
    case off, bayer, proRAW
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "Off"
        case .bayer: "RAW"
        case .proRAW: "ProRAW"
        }
    }
    var badge: String {
        switch self {
        case .off: "RAW"
        case .bayer: "RAW"
        case .proRAW: "PRORAW"
        }
    }
    /// The choice as the pickers offer it: the trade-off first.
    var choice: String {
        switch self {
        case .off, .proRAW: "ProRAW · Cleaner"
        case .bayer: "RAW · Faster"
        }
    }
    /// One line on what you get, for the pickers' notes.
    var tradeoff: String {
        switch self {
        case .off, .proRAW:
            "ProRAW, cleaner: Apple merges several frames, so far less noise and more highlight range, and zoom works. Each shot takes a moment longer to finish."
        case .bayer:
            "Bayer RAW, faster: the sensor's single frame, ready in under half a second, with real noise. Zoom stays at 1× (the full sensor is recorded)."
        }
    }
}

/// How much of Apple's computational pipeline (Deep Fusion, Smart HDR, NR, sharpening)
/// is allowed to touch the image.
enum ProcessingLevel: String, Codable, CaseIterable, Identifiable {
    /// Full Apple pipeline: Deep Fusion / Smart HDR / Photonic Engine.
    case apple
    /// Apple's balanced prioritization.
    case balanced
    /// Fastest, lightest touch processing the ISP offers.
    case natural
    /// Zero computational processing. Captures Bayer RAW and develops it ourselves
    /// with a neutral, film-like rendering (no local tone mapping, no smoothing).
    case zero

    var id: String { rawValue }

    var label: String {
        switch self {
        case .apple: "Apple"
        case .balanced: "Balanced"
        case .natural: "Natural"
        case .zero: "Zero"
        }
    }

    var detail: String {
        switch self {
        case .apple: "Deep Fusion, Smart HDR, full noise reduction and sharpening."
        case .balanced: "Apple's middle ground between speed and processing."
        case .natural: "Lightest ISP processing. Less HDR flattening, less smoothing, more texture."
        case .zero: "No computational photography. Bayer RAW developed with a neutral tone curve — grain and real contrast intact."
        }
    }

    var prioritization: AVCapturePhotoOutput.QualityPrioritization {
        switch self {
        case .apple: .quality
        case .balanced: .balanced
        case .natural, .zero: .speed
        }
    }
}

enum FlashSetting: String, Codable, CaseIterable, Identifiable {
    case off, auto, on
    var id: String { rawValue }
    /// In the top bar's dropdown.
    var menuLabel: String { rawValue.capitalized }
    var avMode: AVCaptureDevice.FlashMode {
        switch self {
        case .off: .off
        case .auto: .auto
        case .on: .on
        }
    }
    var symbol: String {
        switch self {
        case .off: "bolt.slash.fill"
        case .auto: "bolt.badge.automatic.fill"
        case .on: "bolt.fill"
        }
    }
}

enum PhotoResolution: String, Codable, CaseIterable, Identifiable {
    case standard, max
    var id: String { rawValue }
    var label: String { self == .standard ? "12 MP" : "Max" }
}

enum SelfTimer: Int, Codable, CaseIterable, Identifiable {
    case off = 0, three = 3, ten = 10
    var id: Int { rawValue }
    var label: String { self == .off ? "Off" : "\(rawValue)s" }
}

// MARK: - Assist overlays

enum FrameLines: String, Codable, CaseIterable, Identifiable {
    case none, square, fourFive, widescreen, flat, scope
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: "Off"
        case .square: "1:1"
        case .fourFive: "4:5"
        case .widescreen: "16:9"
        case .flat: "1.85"
        case .scope: "2.39"
        }
    }
    /// Width / height in landscape terms.
    var ratio: CGFloat? {
        switch self {
        case .none: nil
        case .square: 1
        case .fourFive: 5.0 / 4.0
        case .widescreen: 16.0 / 9.0
        case .flat: 1.85
        case .scope: 2.39
        }
    }
}

enum PeakingColor: String, Codable, CaseIterable, Identifiable {
    case red, green, blue, white
    var id: String { rawValue }
    var rgb: (CGFloat, CGFloat, CGFloat) {
        switch self {
        case .red: (1, 0.15, 0.1)
        case .green: (0.2, 1, 0.3)
        case .blue: (0.2, 0.55, 1)
        case .white: (1, 1, 1)
        }
    }
}

// MARK: - Persisted settings

/// Video and the Print mode were removed (2026-11-24): their saved keys (`mode`,
/// `printPlacement`, `videoResolution`, `frameRate`, …) are ignored when older settings load,
/// and `decodeSaved` moves a camera left in Print mode, or a Print look, to Phromagraph.
struct CameraSettings: Codable, Equatable {
    // Photo
    var photoFormat: PhotoFormat = .heif
    var rawMode: RawMode = .off
    /// The phone can shoot ProRAW (an iPhone Pro, 12 Pro or later). Learned from the main
    /// camera the first time the session runs, and saved so the pickers are right at the
    /// next launch. Without it every photo is Bayer RAW, and ProRAW isn't offered.
    var proRAWAvailable: Bool = true
    /// When shooting RAW, also store Apple's processed HEIF/JPEG alongside it (RAW+HEIF pair).
    var keepProcessedWithRAW: Bool = true
    var processing: ProcessingLevel = .natural
    /// In Zero mode, also keep the DNG next to the developed image.
    var zeroKeepsDNG: Bool = true
    var flash: FlashSetting = .off
    var resolution: PhotoResolution = .standard
    var selfTimer: SelfTimer = .off
    /// Look applied live in the viewfinder and baked onto each shot as an editable edit.
    var captureLook: String?
    /// The named set of looks the LOOK picker shows (`LookSet` id); nil = all looks.
    var lookSet: String?
    /// Ask the camera for a plainer live view (no video HDR, one tone curve for the whole
    /// frame instead of Apple's local brightening), so the viewfinder tracks the photo,
    /// which comes from the RAW alone. Experimental: off until tried on device.
    var plainLiveView: Bool = false
    /// Lens to reopen on next launch.
    var lastLensID: String?

    // Assists
    var showGrid: Bool = true
    var showLevel: Bool = true
    var showHistogram: Bool = false
    var focusPeaking: Bool = true
    var peakingColor: PeakingColor = .red
    var zebras: Bool = false
    var zebraThreshold: Double = 0.95
    var frameLines: FrameLines = .none
    var volumeShutter: Bool = true
    /// Geotag photos (GPS works offline / in airplane mode).
    var saveLocation: Bool = true
    var haptics: Bool = true
    /// Off = silent shutter (iOS 18+, where the region allows it). The phone's silent
    /// switch mutes it too.
    var shutterSound: Bool = false

    // Library (the app keeps every shot as a RAW until exported).
    /// Off = photos not tagged Keep go to the trash 30 days after they were taken.
    var storeForever: Bool = false
    /// Render every shot with its look and save it to Photos right after capture.
    var autoExport: Bool = false
    var exportFormat: ShotRenderer.ExportFormat = .heif
    /// Longest side of exported photos in pixels; 0 = the photo's own size.
    var exportMaxSide: Int = 2880
    /// 0…1.
    var exportQuality: Double = 1.0
    /// The grade new shots start with ("Set as Default Grade" in the editor). Applies while
    /// its look is the one picked in the camera; picking another look starts from that look.
    var defaultGrade: EditRecipe?

    static let storageKey = "camera.settings.v1"

    /// Loads saved settings, filling any options added since they were saved with defaults
    /// (so an app update never wipes your setup).
    static func load() -> CameraSettings {
        if TestHooks.isUITest { return CameraSettings() }
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return CameraSettings() }
        return decodeSaved(data) ?? CameraSettings()
    }

    /// Saved settings from any app version: missing options take their defaults, removed
    /// ones (e.g. `proControls`) are ignored.
    static func decodeSaved(_ data: Data) -> CameraSettings? {
        TolerantJSON.decode(CameraSettings.self, from: data, defaults: CameraSettings()) { saved in
            // The default grade is an EditRecipe: fill keys it lacks (saved by an older
            // version) the same way saved edits are, or the whole settings blob would fail.
            var saved = saved
            if let grade = saved["defaultGrade"] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: grade),
               let decoded = EditRecipe.decodeSaved(data),
               let object = TolerantJSON.object(movingPrintToPhromagraph(decoded)) {
                saved["defaultGrade"] = object
            } else if saved["defaultGrade"] != nil {
                // Unreadable: drop just the grade, never the whole setup.
                saved.removeValue(forKey: "defaultGrade")
            }
            // A camera left in Print mode (removed) keeps shooting that rendering: Photo with
            // Phromagraph, the same film fitted to Chromagraph. A camera left in Video just
            // opens in Photo (there's only Photo now; the `mode` key is ignored).
            if saved["mode"] as? String == "print" { saved["captureLook"] = "phromagraph" }
            // A look that's no longer offered moves to its successor, or to Original, so
            // the camera never applies (or shows) a look the pickers can't select.
            if let id = saved["captureLook"] as? String, Look.named(id) == nil {
                if let next = Look.retired[id]?.successor { saved["captureLook"] = next }
                else { saved.removeValue(forKey: "captureLook") }
            }
            return saved
        }
    }

    /// A default grade on the Print look (no longer offered) moves to Phromagraph, the same
    /// rendering fitted to Chromagraph, keeping its sliders. Photos made with Print keep it.
    static func movingPrintToPhromagraph(_ grade: EditRecipe) -> EditRecipe {
        guard grade.look == Look.printID, let phromagraph = Look.named("phromagraph") else { return grade }
        guard var film = grade.film else { return grade.withLook(phromagraph) }
        var g = grade
        g.look = phromagraph.id
        film.stock = phromagraph.id
        film.tuning = FilmStock.named(phromagraph.id)
        g.film = film
        return g
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

// MARK: - Exposure

/// P / S / M, like a real camera. Shutter-priority holds the shutter and floats ISO
/// against the meter.
enum ExposureMode: String, CaseIterable, Identifiable {
    case auto, shutterPriority, manual
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "P"
        case .shutterPriority: "S"
        case .manual: "M"
        }
    }
}

enum FocusMode: String {
    case auto, locked, manual
}

enum WhiteBalanceMode: Equatable {
    case auto
    case kelvin(Float)
}

/// Standard photographic stops so the dials snap to numbers a photographer recognizes.
enum Stops {
    /// Third-stop ISO values.
    static let iso: [Float] = [
        25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800,
        1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800,
    ]

    /// Third-stop shutter speeds in seconds (fast → slow).
    static let shutter: [Double] = [
        1.0 / 16000, 1.0 / 12800, 1.0 / 10000, 1.0 / 8000, 1.0 / 6400, 1.0 / 5000, 1.0 / 4000,
        1.0 / 3200, 1.0 / 2500, 1.0 / 2000, 1.0 / 1600, 1.0 / 1250, 1.0 / 1000, 1.0 / 800,
        1.0 / 640, 1.0 / 500, 1.0 / 400, 1.0 / 320, 1.0 / 250, 1.0 / 200, 1.0 / 160, 1.0 / 125, 1.0 / 120,
        1.0 / 100, 1.0 / 80, 1.0 / 60, 1.0 / 50, 1.0 / 48, 1.0 / 40, 1.0 / 30, 1.0 / 25, 1.0 / 20,
        1.0 / 15, 1.0 / 13, 1.0 / 10, 1.0 / 8, 1.0 / 6, 1.0 / 5, 1.0 / 4, 1.0 / 3, 0.4, 0.5,
        0.6, 0.8, 1.0,
    ]

    static let ev: [Float] = stride(from: -3.0, through: 3.0, by: 1.0 / 3.0).map { Float(($0 * 3).rounded() / 3) }

    static let kelvin: [Float] = stride(from: 2000, through: 10000, by: 100).map { Float($0) }

    static func shutterLabel(_ seconds: Double) -> String {
        if seconds >= 0.3 {
            let s = (seconds * 10).rounded() / 10
            return s == s.rounded() ? "\(Int(s))\"" : String(format: "%.1f\"", s)
        }
        return "1/\(Int((1 / seconds).rounded()))"
    }

    static func evLabel(_ ev: Float) -> String {
        if abs(ev) < 0.01 { return "±0" }
        let thirds = Int((ev * 3).rounded())
        let whole = abs(thirds) / 3
        let rem = abs(thirds) % 3
        let sign = thirds > 0 ? "+" : "−"
        let frac = rem == 0 ? "" : (rem == 1 ? "⅓" : "⅔")
        if whole == 0 { return sign + frac }
        return sign + "\(whole)" + frac
    }

    static func nearestIndex<T: BinaryFloatingPoint>(_ value: T, in list: [T], logScale: Bool = false) -> Int {
        var best = 0
        var bestDist = T.greatestFiniteMagnitude
        for (i, v) in list.enumerated() {
            let d: T
            if logScale, value > 0, v > 0 {
                d = abs(T(log2(Double(v))) - T(log2(Double(value))))
            } else {
                d = abs(v - value)
            }
            if d < bestDist { bestDist = d; best = i }
        }
        return best
    }
}

extension CameraSettings {
    /// The looks the camera's LOOK picker offers, from the chosen set (`lookSet`) or all of
    /// them.
    var filterLooks: [Look] {
        let set = LookSet.named(lookSet)
        return Look.all.filter { offersInStrip($0) && (set == nil || $0.set == set) }
    }

    /// The LOOK strip's cards: the chosen set's looks, plus the look in use when it's from
    /// another set, first, so it can still be seen and turned off.
    var stripLooks: [Look] {
        var looks = filterLooks
        if let id = captureLook, let look = Look.named(id), offersInStrip(look), !looks.contains(where: { $0.id == id }) {
            looks.insert(look, at: 0)
        }
        return looks
    }

    /// How many cards a set puts in the strip.
    func stripCount(of set: LookSet) -> Int { set.looks.filter(offersInStrip).count }

    private func offersInStrip(_ look: Look) -> Bool { look.id != "none" }

    /// The look applied to new photos: the one picked in the LOOK strip.
    var activeLook: String? { captureLook }

    /// The grade a new shot starts with: the default grade if its look is the active one,
    /// otherwise the active look as designed.
    var startingGrade: EditRecipe? {
        // "none" and nil both mean no look.
        func norm(_ id: String?) -> String? { id == "none" ? nil : id }
        // On today's film engine: a grade saved with older math moves to it with the sliders
        // that match its look (`FilmMigration`), so new shots get today's controls.
        if let g = defaultGrade, norm(g.look) == norm(activeLook) { return FilmMigration.migrate(g, developsFromRAW: true).recipe }
        return Look.named(activeLook)?.recipe
    }

    /// The RAW choice: ProRAW, cleaner, by default; Bayer RAW, the sensor's single frame,
    /// faster, when chosen. `.off` (settings from before RAW-only) = ProRAW.
    var prefersProRAW: Bool { rawMode != .bayer }
    /// Every photo is a RAW (the app's own library develops it): ProRAW when it's chosen
    /// and the phone has it, otherwise Bayer RAW. Where one lens has no ProRAW,
    /// `PhotoPlanner` falls back safely.
    var shootsProRAW: Bool { prefersProRAW && proRAWAvailable }
    /// The active look is a film stock (it develops from scene light).
    var captureLookNeedsRAW: Bool { Look.named(activeLook)?.capturesRAW == true }

    /// The plain live view applies: every photo develops from the RAW alone.
    var wantsPlainLiveView: Bool { plainLiveView }

    /// Bayer RAW is the sensor's full frame, and AVFoundation throws (an instant crash) if
    /// it's captured while digitally zoomed. Bayer RAW locks zoom at 1×; ProRAW zooms.
    var zoomLocked: Bool { !shootsProRAW }

    /// What to call the zoom-locked mode in a toast.
    var zoomLockReason: String { "Bayer RAW" }

    /// Why ProRAW isn't offered on this phone (nil where it is), for the pickers.
    var proRAWUnavailableReason: String? {
        proRAWAvailable ? nil : "ProRAW needs an iPhone Pro (12 Pro or later), so photos are Bayer RAW."
    }
}
