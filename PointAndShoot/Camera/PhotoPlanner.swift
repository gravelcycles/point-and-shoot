import AVFoundation

/// Every capture decision `CameraController.makePhotoSettings` makes, as a pure function of
/// the settings and what the hardware offers, so each combination can be unit-tested
/// without a camera. AVFoundation throws an uncatchable exception (an instant crash) on an
/// invalid `AVCapturePhotoSettings` combination, so these rules are load-bearing:
/// - Every photo is a RAW (Bayer by default, ProRAW when chosen); a processed photo only
///   where the lens offers no RAW at all.
/// - Bayer RAW is never requested while zoomed (crashed on device, #18): ProRAW stands in.
/// - Bayer RAW always uses `.speed` and 12 MP dimensions.
/// - Bursts never use RAW or flash.
struct PhotoDecision: Equatable {
    enum RAW: Equatable { case none, bayer, proRAW }

    var raw: RAW = .bayer
    /// Format of a processed-only photo (no RAW available).
    var heif = true
    var prioritization: AVCapturePhotoOutput.QualityPrioritization = .speed
    var flash = false
    /// 12 MP-class dimensions instead of the sensor's maximum.
    var standardDimensions = true
    var fallbackNote: String?
}

enum PhotoPlanner {
    /// What the current lens and photo output can do.
    struct Capabilities: Equatable {
        var bayerRAW = true
        var proRAW = true
        var hevc = true
        var flash = true
        /// The device's videoZoomFactor is above 1 (pinch zoom or a cropped lens).
        var zoomed = false
    }

    static func decide(_ s: CameraSettings, burst: Bool, caps: Capabilities) -> PhotoDecision {
        var d = PhotoDecision()
        d.heif = caps.hevc
        if burst {
            d.raw = .none
        } else if s.shootsProRAW && caps.proRAW {
            d.raw = .proRAW
        } else if caps.bayerRAW && !caps.zoomed {
            d.raw = .bayer
        } else if caps.proRAW {
            d.raw = .proRAW
            d.fallbackNote = caps.zoomed ? "Zoomed in: Bayer RAW needs 1×, so this shot is ProRAW"
                                         : "No Bayer RAW on this lens, so this shot is ProRAW"
        } else {
            d.raw = .none
            d.fallbackNote = "No RAW on this lens, so this shot is \(caps.hevc ? "HEIF" : "JPEG")"
        }

        switch d.raw {
        case .bayer:
            // Bayer RAW can't go through multi-frame fusion; ask for the honest single frame.
            d.prioritization = .speed
            d.standardDimensions = true
        case .proRAW:
            d.prioritization = .quality
            d.standardDimensions = s.resolution == .standard
        case .none:
            d.prioritization = burst ? .speed : .balanced
            d.standardDimensions = burst || s.resolution == .standard
        }
        d.flash = !burst && caps.flash && s.flash != .off
        return d
    }
}
