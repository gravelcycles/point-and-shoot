import CoreLocation
import ImageIO
import Observation

/// GPS + compass for geotagging. Works offline: the GPS receiver and magnetometer stay on
/// in airplane mode (only the first fix is slower, since there's no network assistance).
@Observable
final class LocationTagger: NSObject, CLLocationManagerDelegate {
    enum Fix: Equatable {
        case off          // disabled in settings
        case denied       // user said no / restricted
        case searching    // waiting for a usable fix
        case good(Double) // horizontal accuracy in meters
        case rough(Double)
    }

    private(set) var fix: Fix = .off
    private(set) var authorization: CLAuthorizationStatus

    private let manager = CLLocationManager()
    @ObservationIgnored private var latest: CLLocation?
    @ObservationIgnored private var heading: CLHeading?
    @ObservationIgnored private var running = false

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 3
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = false
        manager.headingFilter = 2
    }

    func start() {
        running = true
        switch manager.authorizationStatus {
        case .notDetermined:
            fix = .searching
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            if case .off = fix { fix = .searching }
            if case .denied = fix { fix = .searching }
            manager.startUpdatingLocation()
            if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
        default:
            fix = .denied
        }
    }

    func stop(disabled: Bool = false) {
        running = false
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        if disabled { fix = .off }
    }

    /// A location good enough to stamp on a photo right now, or nil.
    func snapshot() -> TaggedLocation? {
        guard let loc = latest, loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 1000,
              -loc.timestamp.timeIntervalSinceNow < 10 * 60 else { return nil }
        return TaggedLocation(location: loc, heading: heading)
    }

    var statusText: String {
        switch fix {
        case .off: "Location tagging is off"
        case .denied: "Location access is off — enable it in Settings to geotag"
        case .searching: "Searching for GPS… works in airplane mode, best with open sky"
        case .good(let m): "GPS locked ±\(Int(m.rounded())) m"
        case .rough(let m): "Rough GPS ±\(Int(m.rounded())) m — still improving"
        }
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        switch authorization {
        case .authorizedWhenInUse, .authorizedAlways:
            if running { start() }
        case .denied, .restricted:
            fix = .denied
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, loc.horizontalAccuracy >= 0 else { return }
        // Ignore stale cached fixes iOS sometimes replays on start.
        guard -loc.timestamp.timeIntervalSinceNow < 60 else { return }
        if let current = latest, current.horizontalAccuracy < loc.horizontalAccuracy,
           -current.timestamp.timeIntervalSinceNow < 15 {
            return // keep the sharper recent fix
        }
        latest = loc
        let newFix: Fix = loc.horizontalAccuracy <= 50 ? .good(loc.horizontalAccuracy) : .rough(loc.horizontalAccuracy)
        if newFix != fix { fix = newFix }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        if newHeading.headingAccuracy >= 0 { heading = newHeading }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code == .denied { fix = .denied }
    }
}

/// A position (and which way the camera faced) captured at the moment of the shot.
struct TaggedLocation {
    let location: CLLocation
    let heading: CLHeading?

    /// EXIF GPS dictionary for embedding in the image file itself, so the location travels
    /// with the photo even when the file is shared outside Photos.
    var exifGPS: [String: Any] {
        let c = location.coordinate
        var gps: [String: Any] = [
            kCGImagePropertyGPSLatitude as String: abs(c.latitude),
            kCGImagePropertyGPSLatitudeRef as String: c.latitude >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude as String: abs(c.longitude),
            kCGImagePropertyGPSLongitudeRef as String: c.longitude >= 0 ? "E" : "W",
            kCGImagePropertyGPSHPositioningError as String: location.horizontalAccuracy,
        ]
        if location.verticalAccuracy >= 0 {
            gps[kCGImagePropertyGPSAltitude as String] = abs(location.altitude)
            gps[kCGImagePropertyGPSAltitudeRef as String] = location.altitude < 0 ? 1 : 0
        }
        if location.speed >= 0 {
            gps[kCGImagePropertyGPSSpeed as String] = location.speed * 3.6
            gps[kCGImagePropertyGPSSpeedRef as String] = "K"
        }
        if let heading {
            let trueNorth = heading.trueHeading >= 0
            gps[kCGImagePropertyGPSImgDirection as String] = trueNorth ? heading.trueHeading : heading.magneticHeading
            gps[kCGImagePropertyGPSImgDirectionRef as String] = trueNorth ? "T" : "M"
        }
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd"
        gps[kCGImagePropertyGPSDateStamp as String] = formatter.string(from: location.timestamp)
        formatter.dateFormat = "HH:mm:ss.SS"
        gps[kCGImagePropertyGPSTimeStamp as String] = formatter.string(from: location.timestamp)
        return gps
    }

    /// ISO 6709 string for QuickTime video metadata.
    var iso6709: String {
        let c = location.coordinate
        if location.verticalAccuracy >= 0 {
            return String(format: "%+09.5f%+010.5f%+.3f/", c.latitude, c.longitude, location.altitude)
        }
        return String(format: "%+09.5f%+010.5f/", c.latitude, c.longitude)
    }
}
