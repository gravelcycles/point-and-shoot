import Foundation

/// Makes the viewfinder predict the saved photo under a film look. The photo comes from
/// the RAW and its saved settings alone (`EditRecipe.filmRAWExposure(bayer:ev100:)`):
/// natural brightness that follows the scene's light the way Apple's rendering does, a
/// touch under it. The viewfinder can only show Apple's processed video; engine 2's
/// un-render undoes Apple's average curve, and this nudges the preview to where the photo
/// will land: −0.2 EV up to bright-interior light, darker on bright days where the photo is
/// capped at Chromagraph's brightness.
///
/// The scene's light comes from the camera's meter: EV100 from aperture, shutter and ISO,
/// corrected by how far the exposure sits off the meter (manual or shutter-priority
/// exposure, EV compensation), so manual controls don't move it; they already change the
/// preview exactly as they change the RAW. What's left per scene (±0.32 EV over 12 shots,
/// docs/film-looks.md §5⅞) is Apple's local tone mapping, which no single number predicts.
///
/// Nothing here feeds the photo: it only changes what's on screen.
enum ViewfinderMatch {
    /// Viewfinder exposure correction (stops) for a scene of this EV100: how far the photo's
    /// develop sits from Apple's rendering, which the viewfinder shows. The photo follows
    /// Apple's per-scene brightness (`EditRecipe.filmRAWExposure(bayer:ev100:)`), so from
    /// EV 3 to ~11.9 this is its `naturalBias` (−0.2); brighter, the develop is capped at
    /// +1.86 while Apple keeps brightening, and the preview comes down with the photo. A Bayer photo develops to
    /// the same brightness as a ProRAW one, so the RAW type doesn't matter.
    static func correction(ev100: Double) -> Double {
        let photo = EditRecipe.filmRAWExposure(bayer: false, ev100: ev100)
        return min(max(photo - EditRecipe.appleMatchedExposure(ev100: ev100), -maxCorrection), maxCorrection)
    }
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
