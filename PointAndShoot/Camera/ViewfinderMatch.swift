import Foundation

/// Makes the viewfinder predict the saved photo under a film look. The photo comes from
/// the RAW alone, developed at a fixed exposure (`EditRecipe.filmRAWExposure`), so its
/// brightness follows the camera's exposure and nothing else. The viewfinder can only
/// show Apple's processed video, which renders dim scenes darker and bright scenes
/// brighter on purpose; engine 2's un-render undoes Apple's *average* curve, not that
/// per-scene choice.
///
/// The per-scene choice follows how much light the scene has, which the camera's meter
/// knows: EV100 from aperture, shutter and ISO, corrected by how far the exposure sits off
/// the meter (manual or shutter-priority exposure, EV compensation). Measured on 12
/// Chromagraph shots (docs/film-looks.md §5⅞), the viewfinder ran 0.96 EV darker than the
/// photo at night (EV 4.7) and up to 0.6 EV brighter on bright days; against EV100 the gap
/// correlates 0.81, and this correction cuts it from ±0.53 to ±0.32 EV. What's left is
/// Apple's local tone mapping, which no single number predicts.
///
/// Nothing here feeds the photo: it only changes what's on screen.
enum ViewfinderMatch {
    /// Viewfinder exposure correction (stops) for a scene of this EV100, for the RAW type the
    /// shot will be. The fit is against ProRAW at +1.86. A Bayer RAW develops at +0.54
    /// (`EditRecipe.filmBayerRAWExposure`), and relative to Apple's rendering a Bayer RAW
    /// sits ~0.65 EV brighter than a ProRAW (3 scenes, 2026-11-18): net, its photo lands
    /// ~0.67 EV darker than a ProRAW one, and so must the preview.
    static func correction(ev100: Double, bayer: Bool = false) -> Double {
        min(max(0.03 - 0.122 * (ev100 - 10), -maxCorrection), maxCorrection) + (bayer ? bayerOffset : 0)
    }
    static let bayerOffset = -0.67
    /// The fit covers EV 4.7–15.2; don't extrapolate far beyond it.
    static let maxCorrection = 0.75
    /// The correction moves in these steps, so the viewfinder's table (one per exposure)
    /// changes rarely and is built before it's shown.
    static let step = 1.0 / 6

    /// The scene's light as the meter reads it, at ISO 100: what the exposure *would* be
    /// with the meter centred and no EV compensation.
    /// - `targetOffset`: `AVCaptureDevice.exposureTargetOffset`, how far the current
    ///   exposure is from the meter's target (+ = brighter), in auto and custom modes.
    /// - `targetBias`: `AVCaptureDevice.exposureTargetBias`, the target's own offset (the
    ///   EV compensation), which the offset is measured against.
    /// A manual exposure 1 EV under reads offset −1, so the scene's EV is unchanged: the
    /// correction doesn't move when you change ISO, shutter or EV — the viewfinder already
    /// shows those, exactly as the RAW records them.
    static func meteredEV100(aperture: Double, seconds: Double, iso: Double,
                             targetOffset: Double, targetBias: Double) -> Double? {
        guard aperture > 0, seconds > 0, iso > 0, seconds.isFinite, targetOffset.isFinite, targetBias.isFinite
        else { return nil }
        let settings = log2(aperture * aperture / seconds) - log2(iso / 100)
        return settings + targetOffset + targetBias
    }

    /// The stepped correction to show, given the one showing now: it changes only once the
    /// target is three quarters of a step away, so it doesn't flicker at a step's edge.
    static func stepped(_ target: Double, current: Double) -> Double {
        if abs(target - current) < step * 0.75 { return current }
        return (target / step).rounded() * step
    }
}
