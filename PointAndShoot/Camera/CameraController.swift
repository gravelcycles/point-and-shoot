import AVFoundation
import AVKit
import Observation
import SwiftUI
import UIKit

struct Lens: Identifiable, Equatable {
    let device: AVCaptureDevice
    /// Zoom factor applied on this physical camera (2 = the 48 mm sensor crop on the main lens).
    let zoom: CGFloat
    /// 35 mm-equivalent focal length.
    let focalLength: Int

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
/// Threading: all session/device configuration happens on `sessionQueue`; frames arrive on
/// `dataQueue`; observable UI state is only ever mutated on the main thread.
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
    private(set) var isRecording = false
    private(set) var recordingStart: Date?
    private(set) var shutterBlink = 0
    private(set) var capturesInFlight = 0
    private(set) var lastThumbnail: UIImage?
    private(set) var lastThumbnailDate = Date.distantPast
    /// Library ID of the most recent photo/video this app saved — the viewer opens on it.
    private(set) var lastSavedAssetID: String?
    private(set) var countdown: Int?
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
    private(set) var audioLevel: Float = -160

    // Capabilities of the current lens / format
    private(set) var supportsBayerRAW = false
    private(set) var supportsProRAW = false
    private(set) var supportsFlash = false
    private(set) var supportsManualFocus = false
    private(set) var supportsCustomWB = false
    private(set) var supportsCustomExposure = false
    private(set) var supportedFrameRates: [Int] = [24, 25, 30]
    private(set) var supportedColors: [VideoColor] = [.sdr]
    private(set) var supportedCodecs: [VideoCodec] = [.hevc, .h264]
    private(set) var supportedStabilization: [Stabilization] = [.off, .standard]
    private(set) var supportsMaxResolution = false
    private(set) var histogram = Histogram()

    // MARK: - Hardware

    let session = AVCaptureSession()
    let renderer = PreviewRenderer()
    private let sessionQueue = DispatchQueue(label: "camera.session", qos: .userInitiated)
    private let dataQueue = DispatchQueue(label: "camera.data", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let audioDataOutput = AVCaptureAudioDataOutput()
    private let recorder = VideoRecorder()
    @ObservationIgnored private var videoInput: AVCaptureDeviceInput?
    @ObservationIgnored private var audioInput: AVCaptureDeviceInput?
    @ObservationIgnored private var device: AVCaptureDevice?
    @ObservationIgnored private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var inFlight: [Int64: PhotoCaptureProcessor] = [:]
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private var subjectAreaObserver: NSObjectProtocol?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var isConfigured = false
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var lastISOAdjust = Date.distantPast
    @ObservationIgnored private var suspendWhenIdle = false

    override init() {
        super.init()
        renderer.onHistogram = { [weak self] h in
            DispatchQueue.main.async { self?.histogram = h }
        }
        pushRendererConfig()
    }

    // MARK: - Lifecycle

    func start() {
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
        meterTimer?.invalidate()
        meterTimer = nil
        if isRecording { stopRecording() }
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isSessionRunning = false }
        }
    }

    /// Opening the roll: free the camera, but never while a shot is still being processed
    /// and saved — stopping the session then could drop the photo.
    func suspendForBrowsing() {
        if isRecording { stopRecording() }
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

    private func captureFinished() {
        capturesInFlight = max(0, capturesInFlight - 1)
        if capturesInFlight == 0 && suspendWhenIdle {
            suspendWhenIdle = false
            stop()
        }
    }

    private func startSession() {
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
            if error?.code == .mediaServicesWereReset {
                self.sessionQueue.async { if !self.session.isRunning { self.session.startRunning() } }
            }
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.sessionQueue.async { if !self.session.isRunning { self.session.startRunning() } }
        })
    }

    // MARK: - Settings

    func update(_ change: (inout CameraSettings) -> Void) {
        var s = settings
        change(&s)
        s = sanitize(s)
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

    private func sanitize(_ input: CameraSettings) -> CameraSettings {
        var s = input
        // H.264 is 8-bit only; Log/HDR in 8 bits bands. Force HEVC.
        if s.videoColor.isTenBit && s.videoCodec == .h264 { s.videoCodec = .hevc }
        return s
    }

    private func apply(old: CameraSettings, new s: CameraSettings) {
        pushRendererConfig()

        let videoFormatChanged = old.videoResolution != s.videoResolution || old.frameRate != s.frameRate
            || old.videoColor != s.videoColor || old.recordAudio != s.recordAudio || old.stabilization != s.stabilization
        let photoPipelineChanged = old.rawMode != s.rawMode || old.processing != s.processing

        if old.mode != s.mode {
            // Entering video with a 180° shutter: classic cinematographer default.
            if s.mode == .video && s.shutterAngleLock && supportsCustomExposure {
                setExposureMode(.shutterPriority, shutter: 1.0 / Double(2 * s.frameRate))
            } else if s.mode == .photo && exposureMode == .shutterPriority && old.shutterAngleLock {
                setExposureMode(.auto)
            }
            reconfigure(s, lens: currentLens)
        } else if s.mode == .video && videoFormatChanged {
            if s.shutterAngleLock && exposureMode == .shutterPriority {
                shutter = 1.0 / Double(2 * s.frameRate)
            }
            reconfigure(s, lens: currentLens)
        } else if s.mode == .photo && photoPipelineChanged {
            reconfigure(s, lens: currentLens)
        } else if old.shutterAngleLock != s.shutterAngleLock && s.mode == .video && s.shutterAngleLock {
            setExposureMode(.shutterPriority, shutter: 1.0 / Double(2 * s.frameRate))
        }
    }

    private func pushRendererConfig() {
        let s = settings
        let manualFocus = focusMode == .manual
        let front = currentLens?.position == .front
        renderer.update { c in
            c.peaking = s.focusPeaking && (manualFocus || s.mode == .video)
            c.peakingColor = s.peakingColor.rgb
            c.zebras = s.zebras
            c.zebraThreshold = s.zebraThreshold
            c.logAssist = s.mode == .video && s.videoColor == .appleLog && s.logViewAssist
            c.mirrored = front
            c.computeHistogram = s.showHistogram
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
        DispatchQueue.main.async { self.lenses = result }
        lensesCache = result
    }

    @ObservationIgnored private var lensesCache: [Lens] = []

    private func initialLens(for s: CameraSettings) -> Lens? {
        lensesCache.first { $0.position == .back && $0.device.deviceType == .builtInWideAngleCamera && $0.zoom == 1 }
            ?? lensesCache.first
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
            guard let lens = lens ?? self.initialLens(for: s) else { return }
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
                return
            }

            // Audio
            let wantsAudio = s.mode == .video && s.recordAudio
            if wantsAudio && self.audioInput == nil, let mic = AVCaptureDevice.default(for: .audio),
               let input = try? AVCaptureDeviceInput(device: mic), self.session.canAddInput(input) {
                self.session.addInput(input)
                self.audioInput = input
            } else if !wantsAudio, let input = self.audioInput {
                self.session.removeInput(input)
                self.audioInput = nil
            }

            // Outputs
            if !self.session.outputs.contains(self.videoDataOutput), self.session.canAddOutput(self.videoDataOutput) {
                self.session.addOutput(self.videoDataOutput)
                self.videoDataOutput.setSampleBufferDelegate(self, queue: self.dataQueue)
            }
            if wantsAudio {
                if !self.session.outputs.contains(self.audioDataOutput), self.session.canAddOutput(self.audioDataOutput) {
                    self.session.addOutput(self.audioDataOutput)
                    self.audioDataOutput.setSampleBufferDelegate(self, queue: self.dataQueue)
                }
            } else if self.session.outputs.contains(self.audioDataOutput) {
                self.session.removeOutput(self.audioDataOutput)
            }

            var fallbackMessage: String?
            if s.mode == .photo {
                if !self.session.outputs.contains(self.photoOutput), self.session.canAddOutput(self.photoOutput) {
                    self.session.addOutput(self.photoOutput)
                }
                if self.session.canSetSessionPreset(.photo) { self.session.sessionPreset = .photo }
                self.configureDeviceForPhoto(device)
                self.configurePhotoOutput(device: device, settings: s)
            } else {
                if self.session.outputs.contains(self.photoOutput) { self.session.removeOutput(self.photoOutput) }
                fallbackMessage = self.configureDeviceForVideo(device, settings: s)
            }

            // Data output pixel format & connection
            self.configureVideoDataOutput(settings: s)

            self.session.commitConfiguration()

            // Restore the photographer's exposure/focus/WB choices on the new lens.
            self.withLockedDevice { d in
                d.videoZoomFactor = max(d.minAvailableVideoZoomFactor, min(lens.zoom, d.maxAvailableVideoZoomFactor))
                d.isSubjectAreaChangeMonitoringEnabled = true
                if d.isSmoothAutoFocusSupported { d.isSmoothAutoFocusEnabled = s.mode == .video }
                if d.isLowLightBoostSupported { d.automaticallyEnablesLowLightBoostWhenAvailable = false }
            }
            self.applyExposure(mode: exposureState.0, iso: exposureState.1, shutter: exposureState.2, bias: exposureState.3)
            self.applyWhiteBalance(wb)
            self.applyFocus(mode: focus.0, lensPosition: focus.1)
            self.installCameraControls(device: device)

            let caps = self.readCapabilities(device: device, settings: s)
            DispatchQueue.main.async {
                self.currentLens = lens
                self.zoomFactor = lens.zoom
                self.apply(capabilities: caps)
                self.pushRendererConfig()
                if let fallbackMessage { self.toast = fallbackMessage }
            }
            // Let a frame or two of the new configuration through before un-blurring.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                self.renderer.update { $0.transitionBlur = false }
                self.isSwitchingLens = false
            }
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
            photoOutput.isAppleProRAWEnabled = s.rawMode == .proRAW && s.processing != .zero
        }
        if photoOutput.isZeroShutterLagSupported { photoOutput.isZeroShutterLagEnabled = true }
        if photoOutput.isResponsiveCaptureSupported { photoOutput.isResponsiveCaptureEnabled = true }
        if photoOutput.isFastCapturePrioritizationSupported { photoOutput.isFastCapturePrioritizationEnabled = true }
    }

    /// Returns a message if we had to fall back from what was asked.
    private func configureDeviceForVideo(_ device: AVCaptureDevice, settings s: CameraSettings) -> String? {
        var message: String?
        var color = s.videoColor
        var fps = s.frameRate
        var resolution = s.videoResolution

        var format = Self.videoFormat(device: device, resolution: resolution, fps: fps, color: color, stabilization: s.stabilization)
        if format == nil, color != .sdr {
            color = .sdr
            format = Self.videoFormat(device: device, resolution: resolution, fps: fps, color: color, stabilization: s.stabilization)
            if format != nil { message = "\(s.videoColor.label) isn't available here — using SDR" }
        }
        if format == nil {
            for candidate in [30, 25, 24] where candidate != fps {
                if let f = Self.videoFormat(device: device, resolution: resolution, fps: candidate, color: color, stabilization: s.stabilization) {
                    format = f
                    message = "\(resolution.label) \(fps) isn't available here — using \(candidate) fps"
                    fps = candidate
                    break
                }
            }
        }
        if format == nil, resolution == .uhd4K {
            resolution = .hd1080
            format = Self.videoFormat(device: device, resolution: resolution, fps: fps, color: color, stabilization: s.stabilization)
            message = "4K isn't available on this lens — using HD"
        }
        guard let format else { return "No compatible video format on this lens" }

        withLockedDevice { d in
            d.activeFormat = format
            if format.supportedColorSpaces.contains(color.colorSpace) { d.activeColorSpace = color.colorSpace }
            let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
            d.activeVideoMinFrameDuration = duration
            d.activeVideoMaxFrameDuration = duration
        }

        if color != s.videoColor || fps != s.frameRate || resolution != s.videoResolution {
            DispatchQueue.main.async {
                var fixed = self.settings
                fixed.videoColor = color
                fixed.frameRate = fps
                fixed.videoResolution = resolution
                self.settings = fixed
                fixed.save()
                self.pushRendererConfig()
            }
        }
        return message
    }

    static func videoFormat(device: AVCaptureDevice, resolution: VideoResolution, fps: Int, color: VideoColor,
                            stabilization: Stabilization) -> AVCaptureDevice.Format? {
        let want = resolution.dimensions
        let rate = Double(fps)
        let candidates = device.formats.filter { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            guard d.width == want.width, d.height == want.height else { return false }
            guard f.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= rate && rate <= $0.maxFrameRate }) else { return false }
            guard f.supportedColorSpaces.contains(color.colorSpace) else { return false }
            let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            if color.isTenBit {
                return sub == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            } else {
                return sub == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            }
        }
        func score(_ f: AVCaptureDevice.Format) -> Int {
            var s = 0
            if f.isVideoStabilizationModeSupported(stabilization.avMode) { s += 4 }
            if !f.isVideoBinned { s += 2 }
            if CMFormatDescriptionGetMediaSubType(f.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange { s += 1 }
            return s
        }
        return candidates.max { score($0) < score($1) }
    }

    private func configureVideoDataOutput(settings s: CameraSettings) {
        let available = videoDataOutput.availableVideoPixelFormatTypes
        let preferred: [OSType]
        if s.mode == .video {
            preferred = s.videoColor.isTenBit
                ? [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange]
                : [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        } else {
            preferred = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        }
        if let format = preferred.first(where: available.contains) {
            videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: format]
        }
        // Recording must never drop frames; photo preview should never lag.
        videoDataOutput.alwaysDiscardsLateVideoFrames = s.mode == .photo
        if let connection = videoDataOutput.connection(with: .video), connection.isVideoStabilizationSupported {
            let mode = s.mode == .video ? s.stabilization.avMode : .off
            connection.preferredVideoStabilizationMode = mode
        }
    }

    private struct Capabilities {
        var bayer = false, proRAW = false, flash = false, manualFocus = false, customWB = false, customExposure = false
        var frameRates: [Int] = []
        var colors: [VideoColor] = []
        var codecs: [VideoCodec] = []
        var stabilization: [Stabilization] = []
        var maxRes = false
        var isoRange: ClosedRange<Float> = 25...3200
        var shutterRange: ClosedRange<Double> = (1.0 / 8000)...1
    }

    private func readCapabilities(device: AVCaptureDevice, settings s: CameraSettings) -> Capabilities {
        var c = Capabilities()
        if s.mode == .photo {
            c.bayer = photoOutput.availableRawPhotoPixelFormatTypes.contains { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
            c.proRAW = photoOutput.isAppleProRAWSupported
            c.maxRes = Self.hasHighResSensor(device)
        } else {
            c.bayer = supportsBayerRAW
            c.proRAW = supportsProRAW
        }
        c.flash = device.hasFlash
        c.manualFocus = device.isLockingFocusWithCustomLensPositionSupported
        c.customWB = device.isLockingWhiteBalanceWithCustomDeviceGainsSupported
        c.customExposure = device.isExposureModeSupported(.custom)
        c.frameRates = [24, 25, 30, 48, 50, 60, 100, 120].filter {
            Self.videoFormat(device: device, resolution: s.videoResolution, fps: $0, color: s.videoColor, stabilization: .off) != nil
        }
        c.colors = VideoColor.allCases.filter { color in
            [24, 25, 30].contains { Self.videoFormat(device: device, resolution: s.videoResolution, fps: $0, color: color, stabilization: .off) != nil }
        }
        let writerCodecs = videoDataOutput.availableVideoCodecTypesForAssetWriter(writingTo: .mov)
        c.codecs = VideoCodec.allCases.filter { writerCodecs.contains($0.avCodec) }
        c.stabilization = Stabilization.allCases.filter { $0 == .off || device.activeFormat.isVideoStabilizationModeSupported($0.avMode) }
        let f = device.activeFormat
        c.isoRange = f.minISO...f.maxISO
        c.shutterRange = f.minExposureDuration.seconds...min(f.maxExposureDuration.seconds, 1.0)
        return c
    }

    private func apply(capabilities c: Capabilities) {
        supportsBayerRAW = c.bayer
        supportsProRAW = c.proRAW
        supportsFlash = c.flash
        supportsManualFocus = c.manualFocus
        supportsCustomWB = c.customWB
        supportsCustomExposure = c.customExposure
        supportedFrameRates = c.frameRates.isEmpty ? [30] : c.frameRates
        supportedColors = c.colors.isEmpty ? [.sdr] : c.colors
        supportedCodecs = c.codecs
        supportedStabilization = c.stabilization
        supportsMaxResolution = c.maxRes
        isoRange = c.isoRange
        shutterRange = c.shutterRange
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
        DispatchQueue.main.async { self.toast = message }
    }

    // MARK: - Camera Control button (iPhone 16+)

    private func installCameraControls(device: AVCaptureDevice) {
        guard #available(iOS 18.0, *), session.supportsControls else { return }
        session.beginConfiguration()
        for control in session.controls { session.removeControl(control) }
        let zoom = AVCaptureSystemZoomSlider(device: device)
        let ev = AVCaptureSystemExposureBiasSlider(device: device)
        for control in [zoom, ev] as [AVCaptureControl] where session.canAddControl(control) {
            session.addControl(control)
        }
        session.setControlsDelegate(self, queue: sessionQueue)
        session.commitConfiguration()
    }

    // MARK: - Lens & zoom

    func select(lens: Lens) {
        guard !isRecording, lens != currentLens else { return }
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
        reconfigure(settings, lens: lens)
    }

    func flipCamera() {
        guard !isRecording else { return }
        let wantFront = currentLens?.position != .front
        let target = wantFront
            ? lenses.first { $0.position == .front }
            : lenses.first { $0.position == .back && $0.device.deviceType == .builtInWideAngleCamera && $0.zoom == 1 }
        if let target { select(lens: target) }
    }

    /// Continuous pinch zoom on the current physical lens.
    func setZoom(_ factor: CGFloat) {
        zoomFactor = factor
        sessionQueue.async {
            self.withLockedDevice { d in
                d.videoZoomFactor = max(d.minAvailableVideoZoomFactor, min(factor, min(d.maxAvailableVideoZoomFactor, 15)))
            }
        }
    }

    var zoomRange: ClosedRange<CGFloat> { 1...10 }

    // MARK: - Exposure

    func setExposureMode(_ mode: ExposureMode, shutter forcedShutter: Double? = nil) {
        exposureMode = mode
        if let forcedShutter { shutter = forcedShutter }
        if mode == .shutterPriority && forcedShutter == nil && settings.mode == .video && settings.shutterAngleLock {
            shutter = 1.0 / Double(2 * settings.frameRate)
        }
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
                let seconds = max(f.minExposureDuration.seconds, min(shutter, f.maxExposureDuration.seconds))
                let duration = CMTime(seconds: seconds, preferredTimescale: 1_000_000)
                let clampedISO = max(f.minISO, min(iso, f.maxISO))
                d.setExposureModeCustom(duration: duration, iso: clampedISO, completionHandler: nil)
            }
        }
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
                let duration = CMTime(seconds: s, preferredTimescale: 1_000_000)
                d.setExposureModeCustom(duration: duration, iso: clamped, completionHandler: nil)
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

    private func meterTick() {
        guard let d = device else { return }
        let offset = d.exposureTargetOffset
        if abs(offset - meterOffset) > 0.03 { meterOffset = offset }

        switch exposureMode {
        case .auto:
            let newISO = d.iso
            let newShutter = d.exposureDuration.seconds
            if abs(newISO - iso) > 0.5 { iso = newISO }
            if newShutter.isFinite, abs(newShutter - shutter) / max(shutter, 1e-6) > 0.01 { shutter = newShutter }
        case .shutterPriority:
            shutterPriorityStep(offset: offset)
        case .manual:
            break
        }

        if focusMode != .manual {
            let lp = d.lensPosition
            if abs(lp - lensPosition) > 0.005 { lensPosition = lp }
        }
        if whiteBalance == .auto, d.whiteBalanceMode != .locked {
            let gains = d.deviceWhiteBalanceGains
            let maxGain = d.maxWhiteBalanceGain
            if gains.redGain >= 1, gains.greenGain >= 1, gains.blueGain >= 1,
               gains.redGain <= maxGain, gains.greenGain <= maxGain, gains.blueGain <= maxGain {
                let k = d.temperatureAndTintValues(for: gains).temperature
                if abs(k - measuredKelvin) > 25 { measuredKelvin = k }
            }
        }
        if settings.mode == .video && settings.recordAudio,
           let channel = audioDataOutput.connection(with: .audio)?.audioChannels.first {
            audioLevel = channel.averagePowerLevel
        }
        if !isSwitchingLens {
            let z = d.videoZoomFactor
            if abs(z - zoomFactor) > 0.01 { zoomFactor = z }
        }
    }

    // MARK: - Photo capture

    func shutterPressed() {
        if settings.mode == .video {
            toggleRecording()
            return
        }
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

    private func capturePhoto() {
        let s = settings
        capturesInFlight += 1
        haptic(.medium)
        let rotation = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
        sessionQueue.async {
            guard let device = self.device, self.session.outputs.contains(self.photoOutput) else {
                DispatchQueue.main.async { self.captureFinished() }
                return
            }
            if let connection = self.photoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(rotation) {
                connection.videoRotationAngle = rotation
            }
            let (avSettings, plan) = self.makePhotoSettings(s, device: device)
            let id = avSettings.uniqueID
            let processor = PhotoCaptureProcessor(
                plan: plan,
                willCapture: { [weak self] in self?.shutterBlink += 1 },
                thumbnail: { [weak self] image in
                    self?.lastThumbnail = image
                    self?.lastThumbnailDate = Date()
                },
                completion: { [weak self] message, assetID in
                    guard let self else { return }
                    self.sessionQueue.async { self.inFlight[id] = nil }
                    DispatchQueue.main.async {
                        if let assetID { self.lastSavedAssetID = assetID }
                        self.captureFinished()
                        if let message { self.toast = message }
                    }
                })
            self.inFlight[id] = processor
            self.photoOutput.capturePhoto(with: avSettings, delegate: processor)
        }
    }

    private func makePhotoSettings(_ s: CameraSettings, device: AVCaptureDevice) -> (AVCapturePhotoSettings, PhotoPlan) {
        let wantsZero = s.processing == .zero
        let rawMode: RawMode = wantsZero ? .bayer : s.rawMode
        let rawTypes = photoOutput.availableRawPhotoPixelFormatTypes
        var rawType: OSType?
        switch rawMode {
        case .off: rawType = nil
        case .bayer: rawType = rawTypes.first { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
        case .proRAW: rawType = rawTypes.first { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }
        }

        let codec: AVVideoCodecType = (s.photoFormat == .heif && photoOutput.availablePhotoCodecTypes.contains(.hevc)) ? .hevc : .jpeg
        let processedFormat: [String: Any] = [AVVideoCodecKey: codec]

        var plan = PhotoPlan()
        let photoSettings: AVCapturePhotoSettings
        if let rawType {
            plan.expectsRAW = true
            plan.zeroDevelop = wantsZero
            plan.storeRAW = wantsZero ? s.zeroKeepsDNG : true
            plan.zeroAsHEIF = codec == .hevc
            if wantsZero || !s.keepProcessedWithRAW {
                photoSettings = AVCapturePhotoSettings(rawPixelFormatType: rawType)
            } else {
                photoSettings = AVCapturePhotoSettings(rawPixelFormatType: rawType, processedFormat: processedFormat)
                plan.expectsProcessed = true
            }
        } else {
            photoSettings = AVCapturePhotoSettings(format: processedFormat)
            plan.expectsProcessed = true
            if wantsZero { plan.fallbackNote = "Zero needs Bayer RAW — this lens used Natural" }
        }

        // Bayer RAW can't go through multi-frame fusion; ask for the honest single frame.
        let isBayer = rawType.map { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) } ?? false
        let wanted: AVCapturePhotoOutput.QualityPrioritization = isBayer ? .speed : s.processing.prioritization
        photoSettings.photoQualityPrioritization =
            wanted.rawValue <= photoOutput.maxPhotoQualityPrioritization.rawValue ? wanted : photoOutput.maxPhotoQualityPrioritization

        if device.hasFlash, photoOutput.supportedFlashModes.contains(s.flash.avMode) {
            photoSettings.flashMode = s.flash.avMode
        }

        let all = device.activeFormat.supportedMaxPhotoDimensions.sorted { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }
        let standard = all.last { Int($0.width) * Int($0.height) <= 13_000_000 } ?? all.first
        let maxDims = photoOutput.maxPhotoDimensions
        if isBayer || s.resolution == .standard, let standard {
            photoSettings.maxPhotoDimensions = standard
        } else {
            photoSettings.maxPhotoDimensions = maxDims
        }

        if let previewType = photoSettings.availablePreviewPhotoPixelFormatTypes.first {
            photoSettings.previewPhotoFormat = [
                kCVPixelBufferPixelFormatTypeKey as String: previewType,
                kCVPixelBufferWidthKey as String: 240,
                kCVPixelBufferHeightKey as String: 240,
            ]
        }
        return (photoSettings, plan)
    }

    // MARK: - Video recording

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        let s = settings
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
        haptic(.medium)
        dataQueue.async {
            // These come back as untyped dictionaries on some SDKs; normalize.
            let forCodec = self.videoDataOutput.recommendedVideoSettings(
                forVideoCodecType: s.videoCodec.avCodec, assetWriterOutputFileType: .mov) as? [String: Any]
            let generic = self.videoDataOutput.recommendedVideoSettingsForAssetWriter(writingTo: .mov) as? [String: Any]
            var videoSettings: [String: Any] = forCodec ?? generic ?? [:]
            if videoSettings.isEmpty {
                self.post("Recording isn't available with these settings")
                return
            }
            if s.videoCodec == .hevc || s.videoCodec == .h264 {
                // Give the encoder headroom: ~cinema bitrates rather than phone defaults.
                var props = videoSettings[AVVideoCompressionPropertiesKey] as? [String: Any] ?? [:]
                let pixels = Double(s.videoResolution.dimensions.width) * Double(s.videoResolution.dimensions.height)
                let bitsPerPixel = s.videoColor.isTenBit ? 0.22 : 0.16
                props[AVVideoAverageBitRateKey] = Int(pixels * Double(s.frameRate) * bitsPerPixel)
                props[AVVideoExpectedSourceFrameRateKey] = s.frameRate
                props[AVVideoMaxKeyFrameIntervalKey] = s.frameRate
                videoSettings[AVVideoCompressionPropertiesKey] = props
            }
            let audioSettings: [String: Any]? = s.recordAudio
                ? (self.audioDataOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: Any])
                : nil
            let transform = CGAffineTransform(rotationAngle: angle * .pi / 180)
            do {
                try self.recorder.start(videoSettings: videoSettings, audioSettings: audioSettings, transform: transform)
                DispatchQueue.main.async {
                    self.isRecording = true
                    self.recordingStart = Date()
                    UIApplication.shared.isIdleTimerDisabled = true
                }
            } catch {
                self.post("Couldn't start recording: \(error.localizedDescription)")
            }
        }
    }

    func stopRecording() {
        haptic(.medium)
        isRecording = false
        recordingStart = nil
        UIApplication.shared.isIdleTimerDisabled = false
        dataQueue.async {
            self.recorder.stop { url, error in
                guard let url else {
                    if let error { self.post("Recording failed: \(error.localizedDescription)") }
                    return
                }
                Task {
                    do {
                        let thumb = await Self.videoThumbnail(url: url)
                        let assetID = try await PhotoLibrary.saveVideo(at: url)
                        await MainActor.run {
                            if let thumb {
                                self.lastThumbnail = thumb
                                self.lastThumbnailDate = Date()
                            }
                            if let assetID { self.lastSavedAssetID = assetID }
                        }
                    } catch {
                        self.post("Couldn't save video: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private static func videoThumbnail(url: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        guard let cg = try? await generator.image(at: .zero).image else { return nil }
        return UIImage(cgImage: cg)
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
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}

// MARK: - Frames

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioDataOutput {
            recorder.append(audio: sampleBuffer)
            return
        }
        recorder.append(video: sampleBuffer)
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
