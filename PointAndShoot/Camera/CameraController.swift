import AVFoundation
import Observation
import SwiftUI
import UIKit

struct Lens: Identifiable, Equatable {
    let device: AVCaptureDevice
    /// Zoom factor applied on this physical camera (2 = the 2× sensor crop on the main lens).
    let zoom: CGFloat
    /// 35 mm-equivalent focal length.
    let focalLength: Int
    /// Zoom relative to the main (wide) lens, as the lens picker labels it: 0.5, 1, 2, 3, 5.
    var relativeZoom: CGFloat = 1

    var id: String { "\(device.uniqueID)-\(zoom)" }
    var position: AVCaptureDevice.Position { device.position }

    static func == (a: Lens, b: Lens) -> Bool { a.id == b.id }
}

struct Histogram: Equatable {
    var red: [Float] = []
    var green: [Float] = []
    var blue: [Float] = []
    var luma: [Float] = []
}

/// Owns the AVCaptureSession and everything that touches the hardware.
///
/// Threading: all session/device configuration happens on `sessionQueue`; viewfinder
/// frames arrive on `dataQueue`; observable UI state is only ever mutated on the main thread.
@Observable
final class CameraController: NSObject {

    // MARK: - UI state

    private(set) var settings: CameraSettings = .load()
    private(set) var authorization: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    private(set) var isSessionRunning = false
    private(set) var lenses: [Lens] = []
    private(set) var currentLens: Lens?
    private(set) var zoomFactor: CGFloat = 1
    private(set) var isSwitchingLens = false
    private(set) var shutterBlink = 0
    private(set) var capturesInFlight = 0
    private(set) var lastThumbnail: UIImage?
    private(set) var lastThumbnailDate = Date.distantPast
    /// The most recent photo stored in the app's library — the viewer opens on it.
    private(set) var lastSavedShotID: UUID?
    private(set) var countdown: Int?
    private(set) var burstCount = 0
    /// Thermal state is serious or worse: heavy assists are paused.
    private(set) var isHot = false
    var toast: String?

    // Exposure / focus / white balance
    private(set) var exposureMode: ExposureMode = .auto
    private(set) var iso: Float = 100
    private(set) var shutter: Double = 1.0 / 60
    private(set) var exposureBias: Float = 0
    private(set) var meterOffset: Float = 0
    private(set) var isoRange: ClosedRange<Float> = 25...3200
    private(set) var shutterRange: ClosedRange<Double> = (1.0 / 16000)...1
    private(set) var focusMode: FocusMode = .auto
    private(set) var lensPosition: Float = 1
    private(set) var whiteBalance: WhiteBalanceMode = .auto
    private(set) var measuredKelvin: Float = 5500
    private(set) var aeafLocked = false

    // Capabilities of the current lens / format
    private(set) var supportsBayerRAW = false
    private(set) var supportsProRAW = false
    private(set) var supportsFlash = false
    private(set) var supportsManualFocus = false
    private(set) var supportsCustomWB = false
    private(set) var supportsCustomExposure = false
    /// iOS 18+ lets the app mute the shutter click, except where the law requires it.
    private(set) var canSilenceShutter = false
    private(set) var supportsMaxResolution = false
    private(set) var histogram = Histogram()

    // MARK: - Hardware

    let session = AVCaptureSession()
    let renderer = PreviewRenderer()
    let location = LocationTagger()
    private let sessionQueue = DispatchQueue(label: "camera.session", qos: .userInitiated)
    private let dataQueue = DispatchQueue(label: "camera.data", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    @ObservationIgnored private var videoInput: AVCaptureDeviceInput?
    @ObservationIgnored private var device: AVCaptureDevice?
    @ObservationIgnored private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    /// How the phone is held, from gravity (`MotionManager.bucket`: 0 portrait, ±90
    /// landscape), set by the camera screen. It works with Rotation Lock on, where iOS's own
    /// device orientation (and so the rotation coordinator) can stay portrait.
    @ObservationIgnored var heldOrientation: Double = 0
    @ObservationIgnored private var inFlight: [Int64: PhotoCaptureProcessor] = [:]
    @ObservationIgnored private var meterTimer: Timer?
    /// The viewfinder's exposure correction under a film look (`ViewfinderMatch`), stops.
    @ObservationIgnored private var viewfinderExposure: Double = 0
    /// The look id + correction whose table has been built off the render queue; until it
    /// matches, the viewfinder shows the look uncorrected rather than stall on a build.
    @ObservationIgnored private var viewfinderReady: String?
    @ObservationIgnored private var viewfinderWarming: String?
    @ObservationIgnored private var subjectAreaObserver: NSObjectProtocol?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var isConfigured = false
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var lastISOAdjust = Date.distantPast
    @ObservationIgnored private var suspendWhenIdle = false
    @ObservationIgnored private var burstTimer: Timer?
    @ObservationIgnored private var meterSampling = false

    override init() {
        super.init()
        renderer.onHistogram = { [weak self] h in
            DispatchQueue.main.async { self?.histogram = h }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.thermalChanged() })
        pushRendererConfig()
    }

    // MARK: - Lifecycle

    func start() {
        if TestHooks.isUITest {
            authorization = .authorized
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorization = .authorized
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.authorization = granted ? .authorized : .denied
                    if granted { self.startSession() }
                }
            }
        default:
            authorization = AVCaptureDevice.authorizationStatus(for: .video)
        }
    }

    func stop() {
        location.stop()
        meterTimer?.invalidate()
        meterTimer = nil
        burstTimer?.invalidate()
        burstTimer = nil
        burstCount = 0
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isSessionRunning = false }
        }
    }

    /// Opening the roll: free the camera, but never while a shot is still being processed
    /// and saved — stopping the session then could drop the photo.
    func suspendForBrowsing() {
        if capturesInFlight == 0 {
            stop()
        } else {
            suspendWhenIdle = true
        }
    }

    func resumeAfterBrowsing() {
        suspendWhenIdle = false
        start()
    }

    /// The capture's own thumbnail only bridges the gap until the library has rendered the
    /// shot. After that the library is the source of truth, so deleting it updates the
    /// camera's thumbnail button.
    func releaseCaptureThumbnail() {
        lastThumbnail = nil
    }

    private func captureFinished() {
        capturesInFlight = max(0, capturesInFlight - 1)
        if capturesInFlight == 0 && suspendWhenIdle {
            suspendWhenIdle = false
            stop()
        }
    }

    private func startSession() {
        if settings.saveLocation { location.start() }
        if !isConfigured {
            isConfigured = true
            // Serial queue: discovery → configuration → startRunning, in that order.
            sessionQueue.async {
                self.discoverLenses()
                self.installObservers()
            }
            reconfigure(settings, lens: nil)
        }
        sessionQueue.async {
            if !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async {
                self.isSessionRunning = self.session.isRunning
                self.startMetering()
            }
        }
    }

    private func installObservers() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
            guard let self else { return }
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
            Diag.error(.session, "runtime error: \(error?.localizedDescription ?? "?") (code \(error?.code.rawValue ?? 0))")
            if error?.code == .mediaServicesWereReset {
                self.sessionQueue.async { if !self.session.isRunning { self.session.startRunning() } }
            }
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { note in
            let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int) ?? -1
            Diag.log(.session, "interrupted (reason \(reason))")
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            Diag.log(.session, "interruption ended")
            self.sessionQueue.async { if !self.session.isRunning { self.session.startRunning() } }
        })
    }

    // MARK: - Settings

    func update(_ change: (inout CameraSettings) -> Void) {
        var s = settings
        change(&s)
        guard s != settings else { return }
        let old = settings
        settings = s
        s.save()
        apply(old: old, new: s)
    }

    func binding<T>(_ keyPath: WritableKeyPath<CameraSettings, T>) -> Binding<T> {
        Binding(get: { self.settings[keyPath: keyPath] },
                set: { value in self.update { $0[keyPath: keyPath] = value } })
    }

    private func apply(old: CameraSettings, new s: CameraSettings) {
        pushRendererConfig()
        if s.zoomLocked != old.zoomLocked {
            if s.zoomLocked { enforceZoomLock() }
            let zoomAllowed = !s.zoomLocked
            sessionQueue.async {
                guard let device = self.device else { return }
                self.installCameraControls(device: device, zoom: zoomAllowed)
            }
        }
        if s.wantsPlainLiveView != old.wantsPlainLiveView {
            sessionQueue.async { self.applyPlainLiveView(s) }
        }
        if old.saveLocation != s.saveLocation {
            if s.saveLocation { location.start() } else { location.stop(disabled: true) }
        }
        // ProRAW on or off in the photo output needs a reconfigure; looks don't.
        if old.shootsProRAW != s.shootsProRAW || Self.proRAWActive(old) != Self.proRAWActive(s) {
            reconfigure(s, lens: currentLens)
        }
    }

    private func pushRendererConfig() {
        let s = settings
        let manualFocus = focusMode == .manual
        let front = currentLens?.position == .front
        let hot = isHot
        renderer.update { c in
            c.peaking = !hot && s.focusPeaking && manualFocus
            c.peakingColor = s.peakingColor.rgb
            c.zebras = !hot && s.zebras
            c.zebraThreshold = s.zebraThreshold
            c.mirrored = front
            c.computeHistogram = !hot && s.showHistogram
            c.look = viewfinderLook(s)
        }
    }

    /// The look the viewfinder renders: the capture look, plus the exposure correction that
    /// makes it predict the RAW-developed photo (`ViewfinderMatch`). The corrected table is
    /// built on a background queue first; meanwhile the look shows uncorrected.
    private func viewfinderLook(_ s: CameraSettings) -> EditRecipe? {
        // What new shots start with (the default grade, or the picked look).
        guard let look = s.startingGrade else { return nil }
        guard look.film != nil, viewfinderExposure != 0 else { return look }
        let grade = (try? JSONEncoder().encode(look)).map { String($0.hashValue) } ?? ""
        let key = "\(s.activeLook ?? "")@\(viewfinderExposure)@\(grade)"
        var corrected = look
        corrected.exposure += viewfinderExposure * 50     // recipe exposure: 50 = 1 stop
        if viewfinderReady == key { return corrected }
        if viewfinderWarming != key {
            viewfinderWarming = key
            DispatchQueue.global(qos: .userInitiated).async {
                FilmPipeline.prewarmViewfinder(corrected)
                DispatchQueue.main.async {
                    guard self.viewfinderWarming == key else { return }
                    self.viewfinderWarming = nil
                    self.viewfinderReady = key
                    self.pushRendererConfig()
                }
            }
        }
        return look
    }

    /// Moves the viewfinder's correction to the scene's light, in steps (from the meter).
    private func updateViewfinderMatch(_ m: MeterSample) {
        guard let ev = ViewfinderMatch.meteredEV100(aperture: Double(m.aperture), seconds: m.duration,
                                                    iso: Double(m.iso), targetOffset: Double(m.offset),
                                                    targetBias: Double(m.bias)) else { return }
        let next = ViewfinderMatch.stepped(ViewfinderMatch.correction(ev100: ev), current: viewfinderExposure)
        guard next != viewfinderExposure else { return }
        viewfinderExposure = next
        if settings.startingGrade?.film != nil {
            Diag.log(.capture, String(format: "viewfinder match %+.2f EV (scene EV100 %.1f)", next, ev))
            pushRendererConfig()
        }
    }

    // MARK: - Lens discovery

    private func discoverLenses() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video, position: .unspecified)
        var result: [Lens] = []
        let back = discovery.devices.filter { $0.position == .back }
        for device in back.sorted(by: { Self.focalLength(for: $0) < Self.focalLength(for: $1) }) {
            let f = Self.focalLength(for: device)
            result.append(Lens(device: device, zoom: 1, focalLength: f))
            // The 48 MP main sensor gives a near-optical 2× crop.
            if device.deviceType == .builtInWideAngleCamera && Self.hasHighResSensor(device) {
                result.append(Lens(device: device, zoom: 2, focalLength: f * 2))
            }
        }
        if let front = discovery.devices.first(where: { $0.position == .front }) {
            result.append(Lens(device: front, zoom: 1, focalLength: Self.focalLength(for: front)))
        }
        result = Self.withRelativeZoom(result)
        DispatchQueue.main.async { self.lenses = result }
        lensesCache = result
    }

    @ObservationIgnored private var lensesCache: [Lens] = []

    private func initialLens(for s: CameraSettings) -> Lens? {
        if let id = s.lastLensID, let remembered = lensesCache.first(where: { $0.id == id }) {
            // A cropped "lens" (e.g. 48 mm = main at 2×) is a zoom: not while zoom is locked.
            if s.zoomLocked, remembered.zoom != 1, let base = baseLens(of: remembered) { return base }
            return remembered
        }
        return lensesCache.first { $0.position == .back && $0.device.deviceType == .builtInWideAngleCamera && $0.zoom == 1 }
            ?? lensesCache.first
    }

    /// The 1× entry for the same physical camera as `lens`.
    private func baseLens(of lens: Lens) -> Lens? {
        lensesCache.first { $0.device == lens.device && $0.zoom == 1 }
    }

    /// Labels each lens by its zoom relative to the main (wide) camera on its side.
    static func withRelativeZoom(_ lenses: [Lens]) -> [Lens] {
        lenses.map { lens in
            let main = lenses.first { $0.position == lens.position && $0.zoom == 1
                && $0.device.deviceType == .builtInWideAngleCamera }
            var labelled = lens
            labelled.relativeZoom = LensZoom.relative(focalLength: lens.focalLength,
                                                      mainFocalLength: main?.focalLength ?? lens.focalLength)
            return labelled
        }
    }

    static func focalLength(for device: AVCaptureDevice) -> Int {
        let fov = device.formats.map(\.videoFieldOfView).max() ?? device.activeFormat.videoFieldOfView
        let half = Double(fov) * .pi / 360
        guard half > 0 else { return 26 }
        // 35 mm diagonal / 2 = 21.63; 4:3 sensor diagonal is 1.25 × its width.
        let eq = 21.633 / (tan(half) * 1.25)
        let marketing = [13, 24, 26, 28, 48, 52, 65, 77, 100, 120]
        if let k = marketing.min(by: { abs(Double($0) - eq) < abs(Double($1) - eq) }),
           abs(Double(k) - eq) / eq < 0.12 {
            return k
        }
        return Int(eq.rounded())
    }

    static func hasHighResSensor(_ device: AVCaptureDevice) -> Bool {
        device.formats.contains { f in f.supportedMaxPhotoDimensions.contains { $0.width >= 8000 } }
    }

    // MARK: - Session configuration (sessionQueue)

    private func reconfigure(_ s: CameraSettings, lens: Lens?) {
        DispatchQueue.main.async { self.isSwitchingLens = true }
        renderer.update { $0.transitionBlur = true }
        let exposureState = (exposureMode, iso, shutter, exposureBias)
        let wb = whiteBalance
        let focus = (focusMode, lensPosition)

        sessionQueue.async {
            guard let lens = lens ?? self.initialLens(for: s) else {
                self.endTransition()
                return
            }
            self.session.beginConfiguration()
            self.session.automaticallyConfiguresCaptureDeviceForWideColor = false

            // Input
            if self.device != lens.device || self.videoInput == nil {
                if let input = self.videoInput { self.session.removeInput(input) }
                do {
                    let input = try AVCaptureDeviceInput(device: lens.device)
                    if self.session.canAddInput(input) {
                        self.session.addInput(input)
                        self.videoInput = input
                        self.device = lens.device
                    }
                } catch {
                    self.post("Couldn't open camera: \(error.localizedDescription)")
                }
                if let observer = self.subjectAreaObserver { NotificationCenter.default.removeObserver(observer) }
                self.subjectAreaObserver = NotificationCenter.default.addObserver(
                    forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: lens.device, queue: nil
                ) { [weak self] _ in self?.subjectAreaChanged() }
                self.rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: lens.device, previewLayer: nil)
            }
            guard let device = self.device else {
                self.session.commitConfiguration()
                self.endTransition()
                return
            }

            // Outputs
            if !self.session.outputs.contains(self.videoDataOutput), self.session.canAddOutput(self.videoDataOutput) {
                self.session.addOutput(self.videoDataOutput)
                self.videoDataOutput.setSampleBufferDelegate(self, queue: self.dataQueue)
            }
            if !self.session.outputs.contains(self.photoOutput), self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
            }
            if self.session.canSetSessionPreset(.photo) { self.session.sessionPreset = .photo }
            self.configureDeviceForPhoto(device)
            self.configurePhotoOutput(device: device, settings: s)

            // Data output pixel format & connection (the viewfinder's frames)
            self.configureVideoDataOutput()

            self.session.commitConfiguration()

            // Restore the photographer's exposure/focus/WB choices on the new lens.
            self.withLockedDevice { d in
                d.videoZoomFactor = max(d.minAvailableVideoZoomFactor, min(lens.zoom, d.maxAvailableVideoZoomFactor))
                d.isSubjectAreaChangeMonitoringEnabled = true
                if d.isSmoothAutoFocusSupported { d.isSmoothAutoFocusEnabled = false }
                if d.isLowLightBoostSupported { d.automaticallyEnablesLowLightBoostWhenAvailable = false }
            }
            // A new format resets global tone mapping, so set it again.
            self.applyPlainLiveView(s)
            self.applyExposure(mode: exposureState.0, iso: exposureState.1, shutter: exposureState.2, bias: exposureState.3)
            self.applyWhiteBalance(wb)
            self.applyFocus(mode: focus.0, lensPosition: focus.1)
            self.installCameraControls(device: device, zoom: !s.zoomLocked)

            let caps = self.readCapabilities(device: device)
            // The main camera says whether this phone has ProRAW at all (an iPhone Pro).
            let isMainCamera = lens.position == .back && lens.device.deviceType == .builtInWideAngleCamera
            DispatchQueue.main.async {
                self.currentLens = lens
                if self.settings.lastLensID != lens.id {
                    self.settings.lastLensID = lens.id
                    self.settings.save()
                }
                self.zoomFactor = lens.zoom
                self.apply(capabilities: caps)
                self.pushRendererConfig()
                if isMainCamera { self.learnProRAWSupport(caps.proRAW) }
            }
            // Let a frame or two of the new configuration through before un-blurring.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                self.renderer.update { $0.transitionBlur = false }
                self.isSwitchingLens = false
            }
        }
    }

    /// Un-blur the viewfinder even when a reconfigure bails out early.
    private func endTransition() {
        DispatchQueue.main.async {
            self.renderer.update { $0.transitionBlur = false }
            self.isSwitchingLens = false
        }
    }

    private func configureDeviceForPhoto(_ device: AVCaptureDevice) {
        withLockedDevice { d in
            if d.activeFormat.supportedColorSpaces.contains(.P3_D65) {
                d.activeColorSpace = .P3_D65
            } else {
                d.activeColorSpace = .sRGB
            }
        }
    }

    private func configurePhotoOutput(device: AVCaptureDevice, settings s: CameraSettings) {
        photoOutput.maxPhotoQualityPrioritization = .quality
        let dims = device.activeFormat.supportedMaxPhotoDimensions
        if let largest = dims.max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
            photoOutput.maxPhotoDimensions = largest
        }
        // Only turn ProRAW on when it's wanted — it changes how the output allocates buffers.
        if photoOutput.isAppleProRAWSupported {
            photoOutput.isAppleProRAWEnabled = Self.proRAWActive(s)
        }
        if photoOutput.isZeroShutterLagSupported { photoOutput.isZeroShutterLagEnabled = true }
        if photoOutput.isResponsiveCaptureSupported { photoOutput.isResponsiveCaptureEnabled = true }
        if photoOutput.isFastCapturePrioritizationSupported { photoOutput.isFastCapturePrioritizationEnabled = true }
    }

    /// The viewfinder's frames: full-range 8-bit, never queued (a late frame is dropped, so
    /// the preview never lags), no stabilization (it would crop and delay the live view).
    private func configureVideoDataOutput() {
        let available = videoDataOutput.availableVideoPixelFormatTypes
        let preferred: [OSType] = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        if let format = preferred.first(where: available.contains) {
            videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: format]
        }
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        if let connection = videoDataOutput.connection(with: .video), connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .off
        }
    }

    private struct Capabilities {
        var bayer = false, proRAW = false, flash = false, manualFocus = false, customWB = false, customExposure = false
        var silentShutter = false
        var maxRes = false
        var isoRange: ClosedRange<Float> = 25...3200
        var shutterRange: ClosedRange<Double> = (1.0 / 8000)...1
    }

    private func readCapabilities(device: AVCaptureDevice) -> Capabilities {
        var c = Capabilities()
        c.bayer = photoOutput.availableRawPhotoPixelFormatTypes.contains { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
        c.proRAW = photoOutput.isAppleProRAWSupported
        c.maxRes = Self.hasHighResSensor(device)
        if #available(iOS 18.0, *) { c.silentShutter = photoOutput.isShutterSoundSuppressionSupported }
        c.flash = device.hasFlash
        c.manualFocus = device.isLockingFocusWithCustomLensPositionSupported
        c.customWB = device.isLockingWhiteBalanceWithCustomDeviceGainsSupported
        c.customExposure = device.isExposureModeSupported(.custom)
        let f = device.activeFormat
        c.isoRange = f.minISO...f.maxISO
        c.shutterRange = f.minExposureDuration.seconds...min(f.maxExposureDuration.seconds, 1.0)
        return c
    }

    /// Saves whether the phone has ProRAW, from the main camera's photo output. Without it,
    /// photos are Bayer RAW and the pickers say why, instead of every shot falling back
    /// with a toast. Changing it reconfigures the session (ProRAW off in the output).
    private func learnProRAWSupport(_ supported: Bool) {
        guard settings.proRAWAvailable != supported else { return }
        Diag.log(.session, "ProRAW \(supported ? "available" : "not available on this iPhone: photos are Bayer RAW")")
        update { $0.proRAWAvailable = supported }
    }

    private func apply(capabilities c: Capabilities) {
        supportsBayerRAW = c.bayer
        supportsProRAW = c.proRAW
        supportsFlash = c.flash
        supportsManualFocus = c.manualFocus
        supportsCustomWB = c.customWB
        supportsCustomExposure = c.customExposure
        canSilenceShutter = c.silentShutter
        supportsMaxResolution = c.maxRes
        isoRange = c.isoRange
        shutterRange = c.shutterRange
    }

    /// The live view is Apple's processed video, never the RAW. Where the photo comes from
    /// the RAW alone, a plainer feed (video HDR off, global instead of local tone mapping)
    /// lets the film's un-render track it more closely. Elsewhere Apple's defaults return.
    /// sessionQueue only.
    private func applyPlainLiveView(_ s: CameraSettings) {
        let plain = s.wantsPlainLiveView
        withLockedDevice { d in
            let format = d.activeFormat
            if d.automaticallyAdjustsVideoHDREnabled == plain { d.automaticallyAdjustsVideoHDREnabled = !plain }
            if plain, format.isVideoHDRSupported, d.isVideoHDREnabled { d.isVideoHDREnabled = false }
            let global = plain && format.isGlobalToneMappingSupported
            if d.isGlobalToneMappingEnabled != global { d.isGlobalToneMappingEnabled = global }
            if plain {
                Diag.log(.session, "plain live view: video HDR \(format.isVideoHDRSupported ? "off" : "unsupported"), "
                         + "global tone mapping \(format.isGlobalToneMappingSupported ? "on" : "unsupported")")
            }
        }
    }

    private func withLockedDevice(_ body: (AVCaptureDevice) -> Void) {
        guard let device else { return }
        do {
            try device.lockForConfiguration()
            body(device)
            device.unlockForConfiguration()
        } catch {
            post("Camera busy: \(error.localizedDescription)")
        }
    }

    private func post(_ message: String) {
        Diag.log(.session, message)
        DispatchQueue.main.async { self.toast = message }
    }

    // MARK: - Camera Control button (iPhone 16+)

    /// `zoom: false` leaves out the zoom slider (zoom is locked while shooting Bayer RAW).
    private func installCameraControls(device: AVCaptureDevice, zoom: Bool) {
        guard #available(iOS 18.0, *), session.supportsControls else { return }
        session.beginConfiguration()
        for control in session.controls { session.removeControl(control) }
        var controls: [AVCaptureControl] = [AVCaptureSystemExposureBiasSlider(device: device)]
        if zoom { controls.insert(AVCaptureSystemZoomSlider(device: device), at: 0) }
        for control in controls where session.canAddControl(control) {
            session.addControl(control)
        }
        session.setControlsDelegate(self, queue: sessionQueue)
        session.commitConfiguration()
    }

    // MARK: - Reset

    /// Puts one control back on automatic (the dial's "A", or double-tapping its cell).
    func resetToAuto(_ kind: DialKind) {
        switch kind {
        case .focus: setFocusAuto()
        case .wb: setWhiteBalance(.auto)
        case .iso: if exposureMode == .manual { setExposureMode(.shutterPriority) }
        case .shutter: setExposureMode(.auto)
        case .ev: setExposureBias(0)
        case .look: setCaptureLook(nil)
        }
    }

    // MARK: - Capture look

    /// ProRAW is switched on in the photo output only while it's what we'll capture.
    static func proRAWActive(_ s: CameraSettings) -> Bool {
        s.shootsProRAW
    }

    /// The look new shots start with. Every shot keeps its RAW, so the look stays editable.
    func setCaptureLook(_ id: String?) {
        update { $0.captureLook = (id == nil || id == "none") ? nil : id }
    }

    // MARK: - Lens & zoom

    func select(lens: Lens) {
        guard lens != currentLens else { return }
        haptic(.light)
        if let current = currentLens, current.device == lens.device {
            // Same glass, different crop — ramp the zoom so it glides.
            currentLens = lens
            zoomFactor = lens.zoom
            sessionQueue.async {
                self.withLockedDevice { d in
                    d.ramp(toVideoZoomFactor: max(d.minAvailableVideoZoomFactor, min(lens.zoom, d.maxAvailableVideoZoomFactor)), withRate: 12)
                }
            }
            return
        }
        // Manual focus position doesn't translate across lenses.
        if focusMode != .auto { focusMode = .auto }
        aeafLocked = false
        reconfigure(settings, lens: lens)
    }

    func flipCamera() {
        let wantFront = currentLens?.position != .front
        let target = wantFront
            ? lenses.first { $0.position == .front }
            : lenses.first { $0.position == .back && $0.device.deviceType == .builtInWideAngleCamera && $0.zoom == 1 }
        if let target { select(lens: target) }
    }

    /// Continuous pinch zoom on the current physical lens.
    func setZoom(_ factor: CGFloat) {
        guard !settings.zoomLocked else { return }
        zoomFactor = factor
        sessionQueue.async {
            self.withLockedDevice { d in
                d.videoZoomFactor = max(d.minAvailableVideoZoomFactor, min(factor, min(d.maxAvailableVideoZoomFactor, 15)))
            }
        }
    }

    var zoomRange: ClosedRange<CGFloat> { 1...10 }

    /// Back to 1× when Bayer RAW turns on.
    private func enforceZoomLock() {
        if let lens = currentLens, lens.zoom != 1, let base = baseLens(of: lens) {
            select(lens: base)   // same glass: ramps the crop back to 1×
            return
        }
        guard abs(zoomFactor - 1) > 0.001 else { return }
        zoomFactor = 1
        sessionQueue.async {
            self.withLockedDevice { d in d.ramp(toVideoZoomFactor: max(d.minAvailableVideoZoomFactor, 1), withRate: 16) }
        }
    }

    // MARK: - Exposure

    func setExposureMode(_ mode: ExposureMode, shutter forcedShutter: Double? = nil) {
        exposureMode = mode
        if let forcedShutter { shutter = forcedShutter }
        let (i, s, b) = (iso, shutter, exposureBias)
        sessionQueue.async { self.applyExposure(mode: mode, iso: i, shutter: s, bias: b) }
        pushRendererConfig()
    }

    func setISO(_ value: Float) {
        iso = value
        if exposureMode == .auto { exposureMode = .manual }
        if exposureMode == .shutterPriority { exposureMode = .manual }
        let (m, s, b) = (exposureMode, shutter, exposureBias)
        sessionQueue.async { self.applyExposure(mode: m, iso: value, shutter: s, bias: b) }
    }

    func setShutter(_ seconds: Double) {
        shutter = seconds
        if exposureMode == .auto { exposureMode = .shutterPriority }
        let (m, i, b) = (exposureMode, iso, exposureBias)
        sessionQueue.async { self.applyExposure(mode: m, iso: i, shutter: seconds, bias: b) }
    }

    func setExposureBias(_ ev: Float) {
        exposureBias = ev
        let (m, i, s) = (exposureMode, iso, shutter)
        sessionQueue.async { self.applyExposure(mode: m, iso: i, shutter: s, bias: ev) }
    }

    private func applyExposure(mode: ExposureMode, iso: Float, shutter: Double, bias: Float) {
        withLockedDevice { d in
            let f = d.activeFormat
            switch mode {
            case .auto:
                if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
                d.setExposureTargetBias(max(d.minExposureTargetBias, min(bias, d.maxExposureTargetBias)), completionHandler: nil)
            case .shutterPriority, .manual:
                guard d.isExposureModeSupported(.custom) else { return }
                _ = f
                let (duration, clampedISO) = Self.safeExposure(d, seconds: shutter, iso: iso)
                d.setExposureModeCustom(duration: duration, iso: clampedISO, completionHandler: nil)
            }
        }
    }

    /// Clamps to the *current* format's limits, comparing in CMTime. AVFoundation raises
    /// (crashes) for out-of-range values, and both the UI's cached ranges and a rounded
    /// CMTime can land just outside them right after a lens or format change.
    static func safeExposure(_ d: AVCaptureDevice, seconds: Double, iso: Float) -> (CMTime, Float) {
        let f = d.activeFormat
        var duration = CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
        duration = CMTimeMaximum(duration, f.minExposureDuration)
        duration = CMTimeMinimum(duration, f.maxExposureDuration)
        let clampedISO = max(f.minISO, min(iso, f.maxISO))
        return (duration, clampedISO)
    }

    /// Shutter priority: hold the shutter, float ISO against the meter.
    private func shutterPriorityStep(offset: Float) {
        let error = offset - exposureBias
        guard abs(error) > 0.08, Date().timeIntervalSince(lastISOAdjust) > 0.09 else { return }
        lastISOAdjust = Date()
        let target = iso * powf(2, -error * 0.6)
        let clamped = max(isoRange.lowerBound, min(target, isoRange.upperBound))
        guard abs(clamped - iso) / iso > 0.02 else { return }
        iso = clamped
        let s = shutter
        sessionQueue.async {
            self.withLockedDevice { d in
                guard d.exposureMode == .custom else { return }
                let (duration, safeISO) = Self.safeExposure(d, seconds: s, iso: clamped)
                d.setExposureModeCustom(duration: duration, iso: safeISO, completionHandler: nil)
            }
        }
    }

    // MARK: - Focus

    func setFocusAuto() {
        focusMode = .auto
        aeafLocked = false
        sessionQueue.async { self.applyFocus(mode: .auto, lensPosition: 0) }
        pushRendererConfig()
    }

    func setManualFocus(_ position: Float) {
        focusMode = .manual
        lensPosition = position
        sessionQueue.async { self.applyFocus(mode: .manual, lensPosition: position) }
        pushRendererConfig()
    }

    private func applyFocus(mode: FocusMode, lensPosition: Float) {
        withLockedDevice { d in
            switch mode {
            case .auto:
                if d.isFocusModeSupported(.continuousAutoFocus) {
                    if d.isFocusPointOfInterestSupported { d.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5) }
                    d.focusMode = .continuousAutoFocus
                }
                if d.isExposurePointOfInterestSupported { d.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5) }
            case .manual:
                if d.isLockingFocusWithCustomLensPositionSupported {
                    d.setFocusModeLocked(lensPosition: max(0, min(lensPosition, 1)), completionHandler: nil)
                }
            case .locked:
                if d.isFocusModeSupported(.locked) { d.focusMode = .locked }
            }
        }
    }

    /// Tap: focus + meter at a point. `devicePoint` is in sensor coordinates (0–1, landscape).
    func focus(at devicePoint: CGPoint, lock: Bool) {
        if focusMode == .manual && !lock { return }
        focusMode = lock ? .locked : .auto
        aeafLocked = lock
        haptic(lock ? .medium : .light)
        let mode = exposureMode
        sessionQueue.async {
            self.withLockedDevice { d in
                if d.isFocusPointOfInterestSupported, d.isFocusModeSupported(.autoFocus) {
                    d.focusPointOfInterest = devicePoint
                    d.focusMode = .autoFocus
                }
                if mode == .auto, d.isExposurePointOfInterestSupported, d.isExposureModeSupported(.autoExpose) {
                    d.exposurePointOfInterest = devicePoint
                    d.exposureMode = lock ? .autoExpose : .continuousAutoExposure
                }
                d.isSubjectAreaChangeMonitoringEnabled = !lock
            }
        }
    }

    private func subjectAreaChanged() {
        DispatchQueue.main.async {
            guard !self.aeafLocked, self.focusMode == .auto else { return }
            self.sessionQueue.async { self.applyFocus(mode: .auto, lensPosition: 0) }
        }
    }

    // MARK: - White balance

    func setWhiteBalance(_ mode: WhiteBalanceMode) {
        whiteBalance = mode
        sessionQueue.async { self.applyWhiteBalance(mode) }
    }

    private func applyWhiteBalance(_ mode: WhiteBalanceMode) {
        withLockedDevice { d in
            switch mode {
            case .auto:
                if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
            case .kelvin(let k):
                guard d.isLockingWhiteBalanceWithCustomDeviceGainsSupported else { return }
                let tt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: k, tint: 0)
                var g = d.deviceWhiteBalanceGains(for: tt)
                let maxGain = d.maxWhiteBalanceGain
                g.redGain = max(1, min(g.redGain, maxGain))
                g.greenGain = max(1, min(g.greenGain, maxGain))
                g.blueGain = max(1, min(g.blueGain, maxGain))
                d.setWhiteBalanceModeLocked(with: g, completionHandler: nil)
            }
        }
    }

    // MARK: - Metering readouts

    private func startMetering() {
        meterTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in self?.meterTick() }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private struct MeterSample {
        var offset: Float
        var iso: Float
        var duration: Double
        var lensPosition: Float
        var kelvin: Float?
        var zoom: CGFloat
        var aperture: Float
        var bias: Float
    }

    /// 15×/s readouts. The device is sampled on `sessionQueue`: AVCaptureDevice getters take
    /// locks that `commitConfiguration()` holds, so reading them on main froze touches for
    /// as long as a reconfigure took.
    private func meterTick() {
        guard !meterSampling else { return }   // previous sample still waiting on a busy queue
        meterSampling = true
        let wantsKelvin = whiteBalance == .auto
        sessionQueue.async {
            guard let d = self.device else {
                DispatchQueue.main.async { self.meterSampling = false }
                return
            }
            var kelvin: Float?
            if wantsKelvin, d.whiteBalanceMode != .locked {
                let gains = d.deviceWhiteBalanceGains
                let maxGain = d.maxWhiteBalanceGain
                if gains.redGain >= 1, gains.greenGain >= 1, gains.blueGain >= 1,
                   gains.redGain <= maxGain, gains.greenGain <= maxGain, gains.blueGain <= maxGain {
                    kelvin = d.temperatureAndTintValues(for: gains).temperature
                }
            }
            let sample = MeterSample(
                offset: d.exposureTargetOffset,
                iso: d.iso,
                duration: d.exposureDuration.seconds,
                lensPosition: d.lensPosition,
                kelvin: kelvin,
                zoom: d.videoZoomFactor,
                aperture: d.lensAperture,
                bias: d.exposureTargetBias)
            DispatchQueue.main.async {
                self.meterSampling = false
                self.apply(meter: sample)
            }
        }
    }

    private func apply(meter m: MeterSample) {
        if abs(m.offset - meterOffset) > 0.03 { meterOffset = m.offset }
        switch exposureMode {
        case .auto:
            if abs(m.iso - iso) > 0.5 { iso = m.iso }
            if m.duration.isFinite, abs(m.duration - shutter) / max(shutter, 1e-6) > 0.01 { shutter = m.duration }
        case .shutterPriority:
            shutterPriorityStep(offset: m.offset)
        case .manual:
            break
        }
        if focusMode != .manual, abs(m.lensPosition - lensPosition) > 0.005 { lensPosition = m.lensPosition }
        if whiteBalance == .auto, let k = m.kelvin, abs(k - measuredKelvin) > 25 { measuredKelvin = k }
        if !isSwitchingLens, abs(m.zoom - zoomFactor) > 0.01 { zoomFactor = m.zoom }
        if !isSwitchingLens { updateViewfinderMatch(m) }
    }

    // MARK: - Heat

    private func thermalChanged() {
        let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        guard hot != isHot else { return }
        isHot = hot
        pushRendererConfig()
        toast = hot ? "Phone is hot — peaking, zebras & histogram paused" : "Cooled down — assists back on"
    }

    // MARK: - Photo capture

    func shutterPressed() {
        if countdown != nil {
            countdownTask?.cancel()
            countdown = nil
            return
        }
        if settings.selfTimer != .off {
            let seconds = settings.selfTimer.rawValue
            countdownTask = Task { @MainActor in
                for remaining in stride(from: seconds, to: 0, by: -1) {
                    self.countdown = remaining
                    self.haptic(.light)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { return }
                }
                self.countdown = nil
                self.capturePhoto()
            }
        } else {
            capturePhoto()
        }
    }

    // MARK: - Burst

    /// Hold the shutter: fires processed (non-RAW), fast-prioritized frames as quickly as
    /// the pipeline keeps up, without ever queueing a backlog.
    func startBurst() {
        // Every photo is a RAW now; RAW can't burst. Holding the shutter does nothing.
        guard Self.burstEnabled else { return }
        guard countdown == nil else { return }
        burstTimer?.invalidate()
        burstCount = 0
        fireBurstShot()
        let timer = Timer(timeInterval: 0.11, repeats: true) { [weak self] _ in self?.fireBurstShot() }
        RunLoop.main.add(timer, forMode: .common)
        burstTimer = timer
    }

    func stopBurst() {
        burstTimer?.invalidate()
        burstTimer = nil
        if burstCount > 1 { toast = "Burst: \(burstCount) shots" }
        burstCount = 0
    }

    static let burstEnabled = false

    private func fireBurstShot() {
        guard burstCount < 60 else { stopBurst(); return }
        guard capturesInFlight < 4 else { return }
        burstCount += 1
        capturePhoto(burst: true)
    }

    /// The photo's rotation angle. The rotation coordinator follows iOS's device orientation,
    /// which stays portrait with Rotation Lock on (the owner: "horizontal/vertical switching
    /// still doesn't work"), so a landscape shot came out portrait while the icons, which
    /// read gravity, showed landscape. When the two disagree, gravity wins: on the back camera
    /// rotated counter-clockwise (+90, top to the left) the sensor is upright at 0°, clockwise
    /// at 180°; the front camera's sensor faces the other way, so those swap.
    static func captureRotation(coordinator: CGFloat?, held: Double, front: Bool) -> CGFloat {
        let fromGravity: CGFloat
        switch held {
        case 90: fromGravity = front ? 180 : 0
        case -90: fromGravity = front ? 0 : 180
        default: fromGravity = 90
        }
        guard let coordinator else { return fromGravity }
        let coordinatorLandscape = abs(coordinator - 90) > 45 && abs(coordinator - 270) > 45
        let heldLandscape = held != 0
        return coordinatorLandscape == heldLandscape ? coordinator : fromGravity
    }

    private func capturePhoto(burst: Bool = false) {
        let s = settings
        capturesInFlight += 1
        haptic(burst ? .soft : .medium)
        let coordinator = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture
        let rotation = Self.captureRotation(coordinator: coordinator, held: heldOrientation,
                                            front: currentLens?.position == .front)
        Diag.log(.capture, "orientation at the shutter: capture rotation \(Int(rotation))° (90 = portrait, 0/180 = landscape); "
                 + "coordinator \(coordinator.map { "\(Int($0))°" } ?? "none"), held \(MotionManager.name(heldOrientation))")
        let place = s.saveLocation ? location.snapshot() : nil
        let look = s.startingGrade
        sessionQueue.async {
            guard let device = self.device, self.session.outputs.contains(self.photoOutput) else {
                DispatchQueue.main.async { self.captureFinished() }
                return
            }
            if let connection = self.photoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(rotation) {
                connection.videoRotationAngle = rotation
            }
            let (avSettings, basePlan) = self.makePhotoSettings(s, device: device, burst: burst)
            var plan = basePlan
            plan.location = place
            plan.look = look
            let id = avSettings.uniqueID
            let processor = PhotoCaptureProcessor(
                plan: plan,
                willCapture: { [weak self] in self?.shutterBlink += 1 },
                thumbnail: { [weak self] image in
                    self?.lastThumbnail = image
                    self?.lastThumbnailDate = Date()
                },
                completion: { [weak self] message, shotID in
                    if let shotID {
                        Diag.log(.save, "saved \(shotID.uuidString.prefix(8))\(message.map { " · " + $0 } ?? "")")
                    } else {
                        Diag.error(.save, "not saved: \(message ?? "no reason")")
                    }
                    guard let self else { return }
                    self.sessionQueue.async { self.inFlight[id] = nil }
                    DispatchQueue.main.async {
                        if let shotID {
                            self.lastSavedShotID = shotID
                            if s.autoExport {
                                Task { @MainActor in
                                    await ShotExporter.autoExport(shotID, store: ShotStore.shared, options: .init(s))
                                }
                            }
                        } else {
                            // Nothing was saved: don't keep showing a thumbnail of it, and
                            // let a viewer waiting on "Saving…" stop waiting.
                            self.lastThumbnail = nil
                            self.lastSavedShotID = nil
                        }
                        self.captureFinished()
                        if let message { self.toast = message }
                    }
                })
            self.inFlight[id] = processor
            self.photoOutput.capturePhoto(with: avSettings, delegate: processor)
        }
    }

    /// The camera's exposure at the shutter, for brightness reports: what it was set to,
    /// how far from its own meter (offset) and the EV compensation (bias), the scene light
    /// that adds up to, and the two settings Plain live view changes (they move how iOS
    /// exposes, so they move the RAW).
    static func exposureReport(_ d: AVCaptureDevice) -> String {
        let t = d.exposureDuration.seconds
        let ev = ViewfinderMatch.meteredEV100(aperture: Double(d.lensAperture), seconds: t, iso: Double(d.iso),
                                              targetOffset: Double(d.exposureTargetOffset),
                                              targetBias: Double(d.exposureTargetBias))
        let format = d.activeFormat
        return String(format: "exposure: ISO %.0f, 1/%.0f s, f/%.1f, offset %+.2f, bias %+.2f, scene EV100 %@, ",
                      d.iso, t > 0 ? 1 / t : 0, d.lensAperture, d.exposureTargetOffset, d.exposureTargetBias,
                      ev.map { String(format: "%.1f", $0) } ?? "?")
            + "video HDR \(format.isVideoHDRSupported ? (d.isVideoHDREnabled ? "on" : "off") : "unsupported"), "
            + "global tone mapping \(format.isGlobalToneMappingSupported ? (d.isGlobalToneMappingEnabled ? "on" : "off") : "unsupported")"
    }

    private func makePhotoSettings(_ s: CameraSettings, device: AVCaptureDevice,
                                   burst: Bool = false) -> (AVCapturePhotoSettings, PhotoPlan) {
        // The decisions live in PhotoPlanner (pure, unit-tested); this applies them.
        let rawTypes = photoOutput.availableRawPhotoPixelFormatTypes
        let bayerType = rawTypes.first { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
        let proRAWType = rawTypes.first { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }
        let caps = PhotoPlanner.Capabilities(
            bayerRAW: bayerType != nil,
            proRAW: proRAWType != nil,
            hevc: photoOutput.availablePhotoCodecTypes.contains(.hevc),
            flash: device.hasFlash && photoOutput.supportedFlashModes.contains(s.flash.avMode),
            zoomed: device.videoZoomFactor > 1.001)
        let d = PhotoPlanner.decide(s, burst: burst, caps: caps)
        Diag.log(.capture, Self.exposureReport(device))
        Diag.log(.capture, "shot: look \(s.activeLook ?? "-") raw \(d.raw) burst \(burst) zoomed \(caps.zoomed) lens \(device.localizedName)\(d.fallbackNote.map { " · " + $0 } ?? "")")

        let processedFormat: [String: Any] = [AVVideoCodecKey: d.heif ? AVVideoCodecType.hevc : .jpeg]
        let rawType: OSType? = switch d.raw {
        case .none: nil
        case .bayer: bayerType
        case .proRAW: proRAWType
        }

        var plan = PhotoPlan()
        plan.fallbackNote = d.fallbackNote
        plan.heif = d.heif
        let photoSettings: AVCapturePhotoSettings
        if let rawType {
            // RAW only: the app develops it (`ShotStore`), nothing processed is kept.
            plan.rawKind = d.raw == .proRAW ? .proRAW : .bayerRAW
            photoSettings = AVCapturePhotoSettings(rawPixelFormatType: rawType)
        } else {
            plan.rawKind = nil
            photoSettings = AVCapturePhotoSettings(format: processedFormat)
        }

        let wanted = d.prioritization
        photoSettings.photoQualityPrioritization =
            wanted.rawValue <= photoOutput.maxPhotoQualityPrioritization.rawValue ? wanted : photoOutput.maxPhotoQualityPrioritization

        // Silent unless the user turned the shutter sound on (where iOS allows muting it).
        if #available(iOS 18.0, *), photoOutput.isShutterSoundSuppressionSupported {
            photoSettings.isShutterSoundSuppressionEnabled = !s.shutterSound
        }

        if d.flash {
            photoSettings.flashMode = s.flash.avMode
        }

        let all = device.activeFormat.supportedMaxPhotoDimensions.sorted { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }
        let standard = all.last { Int($0.width) * Int($0.height) <= 13_000_000 } ?? all.first
        let maxDims = photoOutput.maxPhotoDimensions
        if d.standardDimensions, let standard {
            photoSettings.maxPhotoDimensions = standard
        } else {
            photoSettings.maxPhotoDimensions = maxDims
        }

        if let previewType = photoSettings.availablePreviewPhotoPixelFormatTypes.first {
            photoSettings.previewPhotoFormat = [
                kCVPixelBufferPixelFormatTypeKey as String: previewType,
                // Shown instantly, and the stand-in for the RAW until it's developed.
                kCVPixelBufferWidthKey as String: 1440,
                kCVPixelBufferHeightKey as String: 1440,
            ]
        }
        return (photoSettings, plan)
    }

    // MARK: - Tap conversion

    /// Converts a point in the preview view into sensor coordinates for focus/exposure POI.
    func devicePoint(fromViewPoint p: CGPoint, viewSize: CGSize) -> CGPoint {
        let img = renderer.orientedImageSize
        guard img.width > 0, img.height > 0, viewSize.width > 0 else {
            return CGPoint(x: p.y / max(viewSize.height, 1), y: 1 - p.x / max(viewSize.width, 1))
        }
        let scale = max(viewSize.width / img.width, viewSize.height / img.height)
        let shown = CGSize(width: img.width * scale, height: img.height * scale)
        let origin = CGPoint(x: (viewSize.width - shown.width) / 2, y: (viewSize.height - shown.height) / 2)
        let u = min(max((p.x - origin.x) / shown.width, 0), 1)
        let v = min(max((p.y - origin.y) / shown.height, 0), 1)
        return currentLens?.position == .front ? CGPoint(x: v, y: u) : CGPoint(x: v, y: 1 - u)
    }

    // MARK: - Haptics

    func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard settings.haptics else { return }
        Haptics.impact(style)
    }
}

// MARK: - Frames

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            renderer.enqueue(pixelBuffer)
        }
    }
}

// MARK: - Camera Control delegate

@available(iOS 18.0, *)
extension CameraController: AVCaptureSessionControlsDelegate {
    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {}
    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {}
    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {}
    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {}
}
