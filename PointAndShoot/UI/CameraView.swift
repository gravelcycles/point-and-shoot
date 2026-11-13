import AVFoundation
import SwiftUI

struct CameraView: View {
    let camera: CameraController
    let roll: RollStore

    @State private var motion = MotionManager()
    @State private var activeDial: DialKind?
    @State private var showSettings = false
    @State private var showLibrary = false
    @State private var reticle: CGPoint?
    @State private var reticleLocked = false
    @State private var reticleID = 0
    @State private var pinchStart: CGFloat = 1
    @State private var blink = false
    @AppStorage("hints.v1.seen") private var hintsSeen = false
    @State private var panAxis: PanAxis?
    @State private var panStartEV: Float = 0
    @State private var evIndicator: Float?
    @State private var evHideTask: Task<Void, Never>?

    private enum PanAxis { case vertical, horizontal }
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch camera.authorization {
            case .authorized:
                cameraUI
            case .notDetermined:
                ProgressView().tint(.white)
            default:
                PermissionView()
            }
        }
        .onAppear {
            camera.start()
            motion.start()
            consumeLaunchRequest()
        }
        .onReceive(NotificationCenter.default.publisher(for: LaunchRequests.notification)) { _ in
            consumeLaunchRequest()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active where !showLibrary:
                camera.start()
                motion.start()
                roll.activateIfAuthorized()
            case .background:
                camera.stop()
                motion.stop()
            default:
                break
            }
        }
        .onChange(of: showLibrary) { _, open in
            // Hand the camera back while browsing/editing — but only once any shot still
            // developing has been saved.
            if open { camera.suspendForBrowsing() } else { camera.resumeAfterBrowsing() }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(camera: camera)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showLibrary) {
            PhotoViewer(roll: roll, camera: camera)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Layout

    private var cameraUI: some View {
        VStack(spacing: 0) {
            TopBar(camera: camera, rotation: motion.iconRotation, showSettings: $showSettings)
                .padding(.horizontal, 14)
                .frame(height: 46)
            ZStack(alignment: .bottom) {
                previewArea
                    .frame(maxHeight: .infinity, alignment: .top)
                bottomControls
            }
        }
        .background(CaptureEventView(enabled: camera.settings.volumeShutter) { camera.shutterPressed() })
        .onChange(of: camera.shutterBlink) { _, _ in
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { blink = true }
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.28)) { blink = false }
            }
        }
        .task(id: camera.toast) {
            guard camera.toast != nil else { return }
            try? await Task.sleep(for: .seconds(2.6))
            withAnimation { camera.toast = nil }
        }
    }

    private var previewArea: some View {
        let s = camera.settings
        return ZStack {
            PreviewView(
                renderer: camera.renderer,
                onTap: { p, size in handleTap(p, size: size, lock: false) },
                onLongPress: { p, size in handleTap(p, size: size, lock: true) },
                onPinch: { scale, state in
                    if state == .began { pinchStart = camera.zoomFactor }
                    camera.setZoom(min(max(pinchStart * scale, 1), 10))
                },
                onPan: handlePan)

            if s.showGrid { GridOverlay() }
            if let ratio = s.frameLines.ratio { FrameLinesOverlay(ratio: ratio, landscape: motion.isLandscape) }
            if s.showLevel { LevelOverlay(motion: motion) }

            if let reticle {
                FocusReticle(locked: reticleLocked)
                    .id(reticleID)
                    .position(reticle)
            }

            if let ev = evIndicator {
                GeometryReader { geo in
                    let anchor = reticle ?? CGPoint(x: geo.size.width - 40, y: geo.size.height / 2)
                    ExposureDragIndicator(ev: ev)
                        .position(x: min(anchor.x + 56, geo.size.width - 22), y: anchor.y)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            VStack {
                HStack(alignment: .top) {
                    if s.showHistogram { HistogramView(histogram: camera.histogram) }
                    Spacer()
                    if s.mode == .video && s.recordAudio { AudioMeter(level: camera.audioLevel) }
                }
                .padding(10)
                if let toast = camera.toast {
                    Toast(text: toast)
                        .padding(.horizontal, 24)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Spacer()
                if camera.exposureMode == .manual {
                    ExposureMeter(offset: camera.meterOffset)
                        .padding(.bottom, s.mode == .photo ? 10 : 260)
                }
            }
            .allowsHitTesting(false)

            if let count = camera.countdown {
                Text("\(count)")
                    .font(.system(size: 120, weight: .thin, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(radius: 12)
                    .contentTransition(.numericText(countsDown: true))
                    .rotationEffect(motion.iconRotation)
                    .allowsHitTesting(false)
            }

            Color.black.opacity(blink ? 0.85 : 0).allowsHitTesting(false)

            if !hintsSeen {
                GestureHints { withAnimation(.easeOut(duration: 0.25)) { hintsSeen = true } }
                    .transition(.opacity)
            }
        }
        .aspectRatio(s.mode == .photo ? 3.0 / 4.0 : 9.0 / 16.0, contentMode: .fit)
        .clipped()
        .animation(.smooth(duration: 0.35), value: s.mode)
    }

    private var bottomControls: some View {
        VStack(spacing: 10) {
            ZStack {
                if let dial = activeDial {
                    DialPanel(kind: dial, camera: camera)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                } else {
                    LensPicker(camera: camera, rotation: motion.iconRotation)
                        .transition(.opacity)
                }
            }
            .frame(height: 48)

            ControlStrip(camera: camera, active: $activeDial)

            ModePicker(mode: camera.settings.mode, disabled: camera.isRecording) { mode in
                withAnimation(.smooth) { activeDial = nil }
                camera.update { $0.mode = mode }
            }

            HStack {
                ThumbnailButton(image: rollThumbnail, rotation: motion.iconRotation) {
                    showLibrary = true
                }
                .disabled(camera.isRecording)
                Spacer()
                ShutterButton(mode: camera.settings.mode, isRecording: camera.isRecording,
                              countingDown: camera.countdown != nil,
                              burstCount: camera.burstCount,
                              onTap: { camera.shutterPressed() },
                              onBurstStart: { camera.startBurst() },
                              onBurstEnd: { camera.stopBurst() })
                Spacer()
                Button {
                    camera.flipCamera()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                        .rotationEffect(motion.iconRotation)
                }
                .buttonStyle(PressScaleStyle())
                .disabled(camera.isRecording)
                .opacity(camera.isRecording ? 0.3 : 1)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 6)
        }
        .foregroundStyle(.white)
        .padding(.top, 26)
        .background(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(0.7), location: 0.25),
                .init(color: .black, location: 0.6),
            ], startPoint: .top, endPoint: .bottom)
            .allowsHitTesting(false)
        )
    }

    /// Whichever is fresher: the instant preview from the shutter, or the roll's newest
    /// (which reflects edits and anything shot in other apps).
    private var rollThumbnail: UIImage? {
        if let shot = camera.lastThumbnail, camera.lastThumbnailDate > roll.latestThumbnailDate { return shot }
        return roll.latestThumbnail ?? camera.lastThumbnail
    }

    // MARK: - Actions

    /// One finger on the viewfinder: vertical drag = exposure compensation (like the
    /// built-in camera, but in ⅓-stop clicks); horizontal swipe = Photo/Video.
    private func handlePan(_ t: CGPoint, _ velocity: CGPoint, _ state: UIGestureRecognizer.State) {
        switch state {
        case .began, .changed:
            if panAxis == nil {
                guard abs(t.x) > 8 || abs(t.y) > 8 else { return }
                panAxis = abs(t.y) > abs(t.x) ? .vertical : .horizontal
                panStartEV = camera.exposureBias
            }
            guard panAxis == .vertical else { return }
            guard camera.exposureMode != .manual else {
                if evIndicator == nil { camera.toast = "Manual exposure — use the ISO / shutter dials" }
                return
            }
            let raw = panStartEV - Float(t.y) / 170
            let snapped = (max(-3, min(3, raw)) * 3).rounded() / 3
            if snapped != camera.exposureBias {
                camera.setExposureBias(snapped)
                UISelectionFeedbackGenerator().selectionChanged()
            }
            evHideTask?.cancel()
            withAnimation(.easeOut(duration: 0.12)) { evIndicator = snapped }
        default:
            if panAxis == .horizontal, !camera.isRecording,
               abs(t.x) > 50 || abs(velocity.x) > 500 {
                let target: CaptureMode = t.x < 0 ? .video : .photo
                if target != camera.settings.mode {
                    camera.haptic(.light)
                    withAnimation(.smooth) { activeDial = nil }
                    camera.update { $0.mode = target }
                }
            }
            if panAxis == .vertical {
                evHideTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.2))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.3)) { evIndicator = nil }
                }
            }
            panAxis = nil
        }
    }

    /// Action button / Siri / Shortcuts asked for a specific mode.
    private func consumeLaunchRequest() {
        guard let mode = LaunchRequests.pendingMode else { return }
        LaunchRequests.pendingMode = nil
        showLibrary = false
        guard !camera.isRecording, camera.settings.mode != mode else { return }
        withAnimation(.smooth) { activeDial = nil }
        camera.update { $0.mode = mode }
    }

    private func handleTap(_ p: CGPoint, size: CGSize, lock: Bool) {
        if activeDial != nil && !lock {
            withAnimation(.snappy) { activeDial = nil }
        }
        guard camera.focusMode != .manual || lock else { return }
        let devicePoint = camera.devicePoint(fromViewPoint: p, viewSize: size)
        camera.focus(at: devicePoint, lock: lock)
        reticle = p
        reticleLocked = lock
        reticleID += 1
        let id = reticleID
        if !lock {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                if reticleID == id { withAnimation(.easeOut(duration: 0.3)) { reticle = nil } }
            }
        }
    }
}

// MARK: - Top bar

struct TopBar: View {
    let camera: CameraController
    let rotation: Angle
    @Binding var showSettings: Bool

    var body: some View {
        let s = camera.settings
        HStack(spacing: 8) {
            if s.mode == .photo {
                iconButton(s.flash.symbol, active: s.flash != .off) {
                    camera.update { $0.flash = cycled(s.flash, in: FlashSetting.allCases) }
                }
                .opacity(camera.supportsFlash ? 1 : 0.25)
                .disabled(!camera.supportsFlash)
                Spacer(minLength: 4)
                Badge(text: rawLabel, active: rawActive, rotation: rotation) { cycleRAW() }
                if !(rawActive && (!s.keepProcessedWithRAW || s.processing == .zero)) {
                    Badge(text: s.photoFormat.label, active: false, rotation: rotation) {
                        camera.update { $0.photoFormat = s.photoFormat == .heif ? .jpeg : .heif }
                    }
                }
                Badge(text: s.processing.label.uppercased(), active: s.processing == .zero || s.processing == .natural,
                      rotation: rotation) { cycleProcessing() }
                Spacer(minLength: 4)
                iconButton("timer", active: s.selfTimer != .off,
                           caption: s.selfTimer == .off ? nil : s.selfTimer.label) {
                    camera.update { $0.selfTimer = cycled(s.selfTimer, in: SelfTimer.allCases) }
                }
            } else if camera.isRecording, let start = camera.recordingStart {
                Spacer()
                RecordingClock(start: start)
                if let left = camera.recordingTimeLeft {
                    Text(Self.timeLeft(left) + " left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(left < 300 ? Color.red : Color.white.opacity(0.6))
                }
                Spacer()
            } else {
                Spacer(minLength: 0)
                Badge(text: s.videoResolution.label, active: false, rotation: rotation) {
                    camera.update { $0.videoResolution = s.videoResolution == .uhd4K ? .hd1080 : .uhd4K }
                }
                Badge(text: "\(s.frameRate)", active: false, rotation: rotation) {
                    camera.update { $0.frameRate = cycled(s.frameRate, in: camera.supportedFrameRates) }
                }
                Badge(text: s.videoColor.label, active: s.videoColor != .sdr, rotation: rotation) {
                    camera.update { $0.videoColor = cycled(s.videoColor, in: camera.supportedColors) }
                }
                Badge(text: s.videoCodec.label.uppercased(), active: s.videoCodec == .proRes422HQ || s.videoCodec == .proRes422,
                      rotation: rotation) {
                    let options = camera.supportedCodecs.filter { !(s.videoColor.isTenBit && $0 == .h264) }
                    camera.update { $0.videoCodec = cycled(s.videoCodec, in: options) }
                }
                if let left = camera.recordingTimeLeft {
                    Text(Self.timeLeft(left))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(left < 300 ? Color.red : Color.white.opacity(0.55))
                        .lineLimit(1)
                        .fixedSize()
                }
                Spacer(minLength: 0)
            }
            GPSIndicator(tagger: camera.location, rotation: rotation) {
                camera.toast = camera.location.statusText
            }
            iconButton("slider.horizontal.3", active: false) { showSettings = true }
                .disabled(camera.isRecording)
        }
        .foregroundStyle(.white)
    }

    static func timeLeft(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60)
        if m >= 60 { return "\(m / 60)h \(m % 60)m" }
        return m < 1 ? "<1 min" : "\(m) min"
    }

    private var rawActive: Bool { camera.settings.rawMode != .off || camera.settings.processing == .zero }
    private var rawLabel: String {
        if camera.settings.processing == .zero { return "RAW" }
        return camera.settings.rawMode.badge
    }

    private func cycleRAW() {
        var options: [RawMode] = [.off]
        if camera.supportsBayerRAW { options.append(.bayer) }
        if camera.supportsProRAW { options.append(.proRAW) }
        guard options.count > 1 else {
            camera.toast = "RAW isn't available on this lens"
            return
        }
        camera.update {
            $0.rawMode = cycled($0.rawMode, in: options)
            if $0.processing == .zero && $0.rawMode != .bayer { $0.processing = .natural }
        }
    }

    private func cycleProcessing() {
        var options: [ProcessingLevel] = [.apple, .balanced, .natural]
        if camera.supportsBayerRAW { options.append(.zero) }
        camera.update { $0.processing = cycled($0.processing, in: options) }
        camera.toast = camera.settings.processing.detail
    }

    private func iconButton(_ symbol: String, active: Bool, caption: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                if let caption {
                    Text(caption).font(.system(size: 11, weight: .bold, design: .rounded))
                }
            }
            .foregroundStyle(active ? Color.yellow : Color.white)
            .frame(minWidth: 36, minHeight: 36)
            .rotationEffect(rotation)
        }
        .buttonStyle(PressScaleStyle())
    }
}

func cycled<T: Equatable>(_ value: T, in options: [T]) -> T {
    guard !options.isEmpty else { return value }
    guard let i = options.firstIndex(of: value) else { return options[0] }
    return options[(i + 1) % options.count]
}

/// Green = locked, pulsing yellow = searching, slashed = off/denied. Tap for details.
struct GPSIndicator: View {
    let tagger: LocationTagger
    let rotation: Angle
    let action: () -> Void
    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .opacity(isSearching && pulse ? 0.35 : 1)
                .frame(width: 26, height: 36)
                .rotationEffect(rotation)
        }
        .buttonStyle(PressScaleStyle())
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private var isSearching: Bool {
        if case .searching = tagger.fix { return true }
        return false
    }

    private var symbol: String {
        switch tagger.fix {
        case .off, .denied: "location.slash"
        case .searching: "location"
        case .good, .rough: "location.fill"
        }
    }

    private var color: Color {
        switch tagger.fix {
        case .off: .white.opacity(0.4)
        case .denied: .red.opacity(0.8)
        case .searching: .yellow
        case .rough: .yellow
        case .good: .green
        }
    }
}

struct Badge: View {
    let text: String
    let active: Bool
    let rotation: Angle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(0.4)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .foregroundStyle(active ? Color.black : Color.white)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(active ? Color.yellow : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(active ? Color.clear : Color.white.opacity(0.6), lineWidth: 1)
                )
                .rotationEffect(rotation)
                .contentTransition(.interpolate)
        }
        .buttonStyle(PressScaleStyle())
        .animation(.snappy(duration: 0.2), value: text)
        .animation(.snappy(duration: 0.2), value: active)
    }
}

struct RecordingClock: View {
    let start: Date

    var body: some View {
        TimelineView(.periodic(from: start, by: 0.5)) { context in
            let t = max(0, Int(context.date.timeIntervalSince(start)))
            HStack(spacing: 6) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text(String(format: "%02d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60))
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color.red.opacity(0.25), in: Capsule())
        }
    }
}

// MARK: - Bottom controls

struct LensPicker: View {
    let camera: CameraController
    let rotation: Angle

    var body: some View {
        let position = camera.currentLens?.position ?? .back
        HStack(spacing: 10) {
            ForEach(camera.lenses.filter { $0.position == position }) { lens in
                let selected = lens == camera.currentLens
                let base = CGFloat(lens.focalLength) / lens.zoom
                let focal = selected ? Int((base * camera.zoomFactor).rounded()) : lens.focalLength
                Button {
                    camera.select(lens: lens)
                } label: {
                    VStack(spacing: -2) {
                        Text("\(focal)")
                            .font(.system(size: selected ? 14 : 12, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("mm").font(.system(size: 7, weight: .semibold))
                    }
                    .frame(width: selected ? 44 : 38, height: selected ? 44 : 38)
                    .background(Circle().fill(Color.black.opacity(0.5)))
                    .overlay(Circle().stroke(selected ? Color.yellow : Color.white.opacity(0.15), lineWidth: 1.2))
                    .foregroundStyle(selected ? Color.yellow : Color.white)
                    .rotationEffect(rotation)
                }
                .buttonStyle(PressScaleStyle())
                .disabled(camera.isRecording && lens.device != camera.currentLens?.device)
            }
        }
        .animation(.snappy(duration: 0.25), value: camera.currentLens?.id)
    }
}

struct ModePicker: View {
    let mode: CaptureMode
    let disabled: Bool
    let select: (CaptureMode) -> Void

    var body: some View {
        HStack(spacing: 22) {
            ForEach(CaptureMode.allCases) { m in
                Button { select(m) } label: {
                    Text(m.label)
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(m == mode ? Color.yellow : Color.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }
}

struct ShutterButton: View {
    let mode: CaptureMode
    let isRecording: Bool
    let countingDown: Bool
    var burstCount: Int = 0
    let onTap: () -> Void
    var onBurstStart: () -> Void = {}
    var onBurstEnd: () -> Void = {}

    @State private var pressed = false
    @State private var bursting = false
    @State private var holdTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Circle()
                .stroke(bursting ? Color.yellow : Color.white, lineWidth: 4)
                .frame(width: 78, height: 78)
            if mode == .photo {
                Circle()
                    .fill(countingDown ? Color.yellow : Color.white)
                    .frame(width: 64, height: 64)
                    .scaleEffect(bursting ? 0.82 : 1)
                if bursting && burstCount > 0 {
                    Text("\(burstCount)")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.black)
                        .contentTransition(.numericText())
                }
            } else {
                RoundedRectangle(cornerRadius: isRecording ? 7 : 32, style: .continuous)
                    .fill(Color.red)
                    .frame(width: isRecording ? 30 : 64, height: isRecording ? 30 : 64)
            }
        }
        .scaleEffect(pressed ? 0.9 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.6), value: pressed)
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: isRecording)
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: mode)
        .animation(.snappy(duration: 0.12), value: burstCount)
        .contentShape(Circle())
        // Tap = shoot. Hold (photo) = burst until you let go.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed else { return }
                    pressed = true
                    guard mode == .photo, !countingDown else { return }
                    holdTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(380))
                        guard !Task.isCancelled, pressed else { return }
                        bursting = true
                        onBurstStart()
                    }
                }
                .onEnded { _ in
                    pressed = false
                    holdTask?.cancel()
                    holdTask = nil
                    if bursting {
                        bursting = false
                        onBurstEnd()
                    } else {
                        onTap()
                    }
                }
        )
        .accessibilityElement()
        .accessibilityLabel(mode == .photo ? "Take photo" : (isRecording ? "Stop recording" : "Start recording"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onTap() }
    }
}

struct ThumbnailButton: View {
    let image: UIImage?
    let rotation: Angle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.scale.combined(with: .opacity))
                        .id(ObjectIdentifier(image))
                } else {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(width: 52, height: 52)
            .background(Color.white.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.3), lineWidth: 1))
            .rotationEffect(rotation)
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: image.map { ObjectIdentifier($0) })
        }
        .buttonStyle(PressScaleStyle())
    }
}

struct PressScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.88

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// One-time cheat sheet for the gestures, shown on first launch.
struct GestureHints: View {
    let dismiss: () -> Void

    private let hints: [(String, String)] = [
        ("hand.tap", "Tap to focus · hold to lock"),
        ("arrow.up.and.down", "Drag up/down for exposure"),
        ("arrow.left.and.right", "Swipe for Photo / Video"),
        ("arrow.up.left.and.arrow.down.right", "Pinch to zoom"),
        ("circle.inset.filled", "Hold the shutter for burst"),
        ("slider.horizontal.3", "Tap ISO, shutter, WB, focus or LOOK to dial them in"),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.72)
            VStack(alignment: .leading, spacing: 16) {
                Text("Quick tour")
                    .font(.system(size: 22, weight: .bold))
                ForEach(hints, id: \.1) { hint in
                    HStack(spacing: 14) {
                        Image(systemName: hint.0)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.yellow)
                            .frame(width: 28)
                        Text(hint.1).font(.system(size: 15, weight: .medium))
                    }
                }
                Text("Tap anywhere to start shooting")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, 6)
            }
            .foregroundStyle(.white)
            .padding(28)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: dismiss)
    }
}

struct PermissionView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 48, weight: .thin))
            Text("Camera access is off")
                .font(.title3.weight(.semibold))
            Text("Point & Shoot needs the camera to, well, shoot.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.borderedProminent)
            .tint(.yellow)
            .foregroundStyle(.black)
        }
        .foregroundStyle(.white)
        .padding()
    }
}
