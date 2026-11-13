import AVFoundation
import Foundation

// MARK: - Modes

enum CaptureMode: String, Codable, CaseIterable, Identifiable {
    case photo, video
    var id: String { rawValue }
    var label: String { self == .photo ? "PHOTO" : "VIDEO" }
}

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

// MARK: - Video

enum VideoResolution: String, Codable, CaseIterable, Identifiable {
    case hd1080, uhd4K
    var id: String { rawValue }
    var label: String { self == .hd1080 ? "HD" : "4K" }
    var dimensions: CMVideoDimensions {
        self == .hd1080 ? CMVideoDimensions(width: 1920, height: 1080) : CMVideoDimensions(width: 3840, height: 2160)
    }
}

enum VideoCodec: String, Codable, CaseIterable, Identifiable {
    case hevc, h264, proRes422HQ, proRes422
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hevc: "HEVC"
        case .h264: "H.264"
        case .proRes422HQ: "ProRes HQ"
        case .proRes422: "ProRes 422"
        }
    }
    var avCodec: AVVideoCodecType {
        switch self {
        case .hevc: .hevc
        case .h264: .h264
        case .proRes422HQ: .proRes422HQ
        case .proRes422: .proRes422
        }
    }
}

enum VideoColor: String, Codable, CaseIterable, Identifiable {
    case sdr, hlg, appleLog
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sdr: "SDR"
        case .hlg: "HDR"
        case .appleLog: "LOG"
        }
    }
    var colorSpace: AVCaptureColorSpace {
        switch self {
        case .sdr: .sRGB
        case .hlg: .HLG_BT2020
        case .appleLog: .appleLog
        }
    }
    var isTenBit: Bool { self != .sdr }
}

enum Stabilization: String, Codable, CaseIterable, Identifiable {
    case off, standard, cinematic, cinematicExtended
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "Off"
        case .standard: "Standard"
        case .cinematic: "Cinematic"
        case .cinematicExtended: "Extended"
        }
    }
    var avMode: AVCaptureVideoStabilizationMode {
        switch self {
        case .off: .off
        case .standard: .standard
        case .cinematic: .cinematic
        case .cinematicExtended: .cinematicExtended
        }
    }
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

struct CameraSettings: Codable, Equatable {
    var mode: CaptureMode = .photo

    // Photo
    var photoFormat: PhotoFormat = .heif
    var rawMode: RawMode = .off
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
    /// Lens to reopen on next launch.
    var lastLensID: String?

    // Video
    var videoResolution: VideoResolution = .uhd4K
    var frameRate: Int = 24
    var videoCodec: VideoCodec = .hevc
    var videoColor: VideoColor = .sdr
    var stabilization: Stabilization = .standard
    var recordAudio: Bool = true
    /// Lock the shutter to a 180° angle (1 / 2×fps) and let ISO float.
    var shutterAngleLock: Bool = true
    /// Preview Apple Log through a Rec.709 display transform (recorded file stays Log).
    var logViewAssist: Bool = true

    // Assists
    var showGrid: Bool = true
    var showLevel: Bool = true
    var showHistogram: Bool = true
    var focusPeaking: Bool = true
    var peakingColor: PeakingColor = .red
    var zebras: Bool = false
    var zebraThreshold: Double = 0.95
    var frameLines: FrameLines = .none
    var volumeShutter: Bool = true
    /// Geotag photos and videos (GPS works offline / in airplane mode).
    var saveLocation: Bool = true
    var haptics: Bool = true

    static let storageKey = "camera.settings.v1"

    /// Loads saved settings, filling any options added since they were saved with defaults
    /// (so an app update never wipes your setup).
    static func load() -> CameraSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaultsData = try? JSONEncoder().encode(CameraSettings()),
              var merged = try? JSONSerialization.jsonObject(with: defaultsData) as? [String: Any] else {
            return CameraSettings()
        }
        merged.merge(saved) { _, stored in stored }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let s = try? JSONDecoder().decode(CameraSettings.self, from: mergedData) else {
            return CameraSettings()
        }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

// MARK: - Exposure

/// P / S / M, like a real camera. Shutter-priority holds the shutter and floats ISO
/// against the meter — perfect for locking a 180° shutter for video.
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
