import AVFoundation

/// Every capture decision `CameraController.makePhotoSettings` makes, as a pure function of
/// the settings and what the hardware offers, so each combination can be unit-tested
/// without a camera. AVFoundation throws an uncatchable exception (an instant crash) on an
/// invalid `AVCapturePhotoSettings` combination, so these rules are load-bearing:
/// - Bayer RAW is never requested while zoomed (crashed on device, #18).
/// - Bayer RAW always uses `.speed` and 12 MP dimensions.
/// - Bursts never use RAW or flash.
struct PhotoDecision: Equatable {
    enum RAW: Equatable { case none, bayer, proRAW }

    var raw: RAW = .none
    /// A processed HEIF/JPEG is requested (alongside the RAW, or on its own).
    var withProcessed = true
    /// We develop the Bayer DNG ourselves (Zero, film looks).
    var zeroDevelop = false
    /// Keep the DNG in the library.
    var storeRAW = true
    var heif = true
    var prioritization: AVCapturePhotoOutput.QualityPrioritization = .balanced
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
        // Bursts trade RAW and heavy processing for speed.
        // Zero processing and film looks develop the Bayer RAW themselves.
        let wantsZero = s.developsBayerRAW && !burst
        let rawMode: RawMode = burst ? .off : (wantsZero ? .bayer : s.rawMode)
        switch rawMode {
        case .off: d.raw = .none
        case .bayer: d.raw = (caps.zoomed || !caps.bayerRAW) ? .none : .bayer
        case .proRAW: d.raw = caps.proRAW ? .proRAW : .none
        }
        d.heif = s.photoFormat == .heif && caps.hevc

        if d.raw != .none {
            d.zeroDevelop = wantsZero
            // A film look's edit re-develops from the DNG, so it's always kept.
            d.storeRAW = wantsZero ? (s.zeroKeepsDNG || s.captureLookNeedsRAW) : true
            d.withProcessed = !(wantsZero || !s.keepProcessedWithRAW)
        } else {
            d.withProcessed = true
            d.zeroDevelop = false
            if wantsZero {
                if caps.zoomed {
                    d.fallbackNote = s.processing == .zero
                        ? "Zoomed in: RAW needs 1×, so this shot used Natural"
                        : "Zoomed in: RAW needs 1×, so the look went on the processed photo"
                } else {
                    d.fallbackNote = s.processing == .zero
                        ? "Zero needs Bayer RAW — this lens used Natural"
                        : "No Bayer RAW on this lens — Print look applied to the processed photo"
                }
            } else if rawMode == .bayer && caps.zoomed {
                d.fallbackNote = "Zoomed in: RAW needs 1×, so this shot is HEIF/JPEG only"
            }
        }

        // Bayer RAW can't go through multi-frame fusion; ask for the honest single frame.
        let isBayer = d.raw == .bayer
        d.prioritization = (isBayer || burst) ? .speed : s.processing.prioritization
        d.flash = !burst && caps.flash && s.flash != .off
        d.standardDimensions = isBayer || burst || s.resolution == .standard
        return d
    }
}
