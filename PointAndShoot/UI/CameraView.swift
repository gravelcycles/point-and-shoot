import AVFoundation
import SwiftUI

struct CameraView: View {
    let camera: CameraController
    let store: ShotStore

    @State private var motion = MotionManager()
    @State private var activeDial: DialKind?
    @State private var showSettings = false
    @State private var showFormat = false
    @State private var showLibrary = false
    @State private var reticle: CGPoint?
    @State private var reticleLocked = false
    @State private var reticleID = 0
    @State private var pinchStart: CGFloat = 1
    @State private var blink = false
    @State private var panAxis: PanAxis?
    @State private var panStartEV: Float = 0
    @State private var evIndicator: Float?
    @State private var evHideTask: Task<Void, Never>?
    /// The library's newest shot, rendered (the thumbnail button once the capture's own
    /// preview hands over).
    @State private var newestThumb: (id: UUID, image: UIImage)?

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
            camera.heldOrientation = motion.bucket
            consumeLaunchRequest()
            Task { await LockedCaptureImporter.importPending() }
        }
        .onReceive(NotificationCenter.default.publisher(for: LaunchRequests.notification)) { _ in
            consumeLaunchRequest()
        }
        .onChange(of: motion.bucket) { _, held in camera.heldOrientation = held }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active where showLibrary:
                // Back to the app with the library open: the camera waits for it to close, but
                // orientation restarts now. It used to stay stopped for good, so rotation died
                // after leaving the app from the library (the owner: "sometimes dies after
                // closing screen or switching to another app").
                motion.start()
            case .active:
                camera.start()
                motion.start()
                store.applyRetention(storeForever: camera.settings.storeForever)
                store.redevelopMissing()
                Task { await LockedCaptureImporter.importPending() }
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
            if open {
                camera.suspendForBrowsing()
            } else {
                camera.resumeAfterBrowsing()
                motion.start()
            }
        }
        .onChange(of: camera.toast) { _, toast in
            if let toast { Diag.log(.ui, "toast: \(toast)") }
        }
        .task(id: newestKey) { await loadNewestThumb() }
        .onChange(of: camera.capturesInFlight) { _, _ in handOffThumbnail() }
        .onChange(of: camera.lastSavedShotID) { _, _ in handOffThumbnail() }
        .onChange(of: store.developing) { _, _ in handOffThumbnail() }
        .fullScreenCover(isPresented: $showLibrary) {
            PhotoViewer(store: store, camera: camera)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Layout

    private var cameraUI: some View {
        VStack(spacing: 0) {
            TopBar(camera: camera, rotation: motion.iconRotation, showSettings: $showSettings, showFormat: $showFormat)
                .padding(.horizontal, 12)
                .frame(height: 50)
                // Above the viewfinder, so its dropdowns can hang over it.
                .zIndex(1)
                .sheet(isPresented: $showFormat) {
                    CaptureFormatPanel(camera: camera)
                        .presentationDetents([.height(CaptureFormatPanel.height(camera))])
                        .presentationDragIndicator(.visible)
                }
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
                onDoubleTap: {
                    camera.haptic(.light)
                    showSettings = true
                },
                onLongPress: { p, size in handleTap(p, size: size, lock: true) },
                onPinch: { scale, state in
                    if camera.settings.zoomLocked {
                        // RAW is the full sensor frame: say why nothing zooms, once per pinch.
                        if state == .began {
                            camera.haptic(.light)
                            camera.toast = "No zoom in \(camera.settings.zoomLockReason): RAW is the full frame"
                        }
                        return
                    }
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
                    if s.showHistogram { LiveHistogram(camera: camera) }
                    Spacer()
                }
                .padding(10)
                if let toast = camera.toast {
                    Toast(text: toast)
                        .padding(.horizontal, 24)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Spacer()
                if camera.exposureMode == .manual {
                    LiveExposureMeter(camera: camera)
                        .padding(.bottom, 10)
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
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipped()
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
            .frame(height: activeDial == .look ? 78 : 48)
            .animation(.snappy(duration: 0.25), value: activeDial)

            ControlStrip(camera: camera, active: $activeDial)

            HStack {
                ThumbnailButton(image: rollThumbnail, rotation: motion.iconRotation) {
                    showLibrary = true
                }
                .accessibilityIdentifier("camera.thumbnail")
                .overlay(alignment: .top) { RollCountProbe(store: store).offset(y: -12) }
                .overlay(alignment: .bottom) { ViewerEventProbeView().offset(y: 12) }
                Spacer()
                ShutterButton(countingDown: camera.countdown != nil,
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
                .accessibilityLabel("Switch camera")
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 6)
        }
        .foregroundStyle(.white)
        // Taps in the gaps between controls belong to the controls, not to tap-to-focus on
        // the viewfinder underneath.
        .background(Color.black.opacity(0.001))
        .padding(.top, 26)
        .background(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(0.7), location: 0.25),
                .init(color: .black, location: 0.6),
            ], startPoint: .top, endPoint: .bottom)
            .opacity(controlsNeedScrim ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: controlsNeedScrim)
            .allowsHitTesting(false)
        )
    }

    /// The dark fade behind the controls is only for an open dial panel, whose labels sit on
    /// the picture. Otherwise the 3:4 picture ends above the strip, and the fade only
    /// darkened its bottom ~70 pt behind the lens buttons (the owner: "the bottom part where
    /// the zoom sizes are is darker than the rest"); the lens buttons carry their own discs.
    private var controlsNeedScrim: Bool {
        activeDial != nil
    }

    /// A just-taken shot shows instantly from the capture; once the library has developed
    /// it the library takes over, so deletes and edits are reflected.
    private var rollThumbnail: UIImage? {
        camera.lastThumbnail ?? (newestThumb?.id == store.newest?.id ? newestThumb?.image : nil)
    }

    private var newestKey: String {
        store.newest.map { "\($0.id)-\($0.revision)" } ?? "none"
    }

    private func loadNewestThumb() async {
        guard let newest = store.newest else {
            newestThumb = nil
            handOffThumbnail()
            return
        }
        if let image = await store.image(newest, .thumb) { newestThumb = (newest.id, image) }
        handOffThumbnail()
    }

    private func handOffThumbnail() {
        let release = ThumbnailHandoff.shouldRelease(
            hasCaptureThumbnail: camera.lastThumbnail != nil,
            capturesInFlight: camera.capturesInFlight,
            lastSavedID: camera.lastSavedShotID,
            developing: store.developing,
            libraryContains: { store.shot($0)?.trashedAt == nil && store.shot($0) != nil },
            shownID: newestThumb?.id,
            newestID: store.newest?.id)
        if release { camera.releaseCaptureThumbnail() }
    }

    // MARK: - Actions

    /// One finger on the viewfinder: vertical drag = exposure compensation (like the
    /// built-in camera, but in ⅓-stop clicks). A sideways drag does nothing (there's one mode).
    private func handlePan(_ t: CGPoint, _ velocity: CGPoint, _ state: UIGestureRecognizer.State) {
        switch state {
        case .began, .changed:
            if panAxis == nil {
                guard abs(t.x) > 8 || abs(t.y) > 8 else { return }
                panAxis = abs(t.y) > abs(t.x) ? .vertical : .horizontal
                panStartEV = camera.exposureBias
                // Once per drag, not on every touch event (that re-rendered the screen).
                if panAxis == .vertical && camera.exposureMode == .manual {
                    camera.toast = "Manual exposure — use the ISO / shutter dials"
                }
            }
            guard panAxis == .vertical, camera.exposureMode != .manual else { return }
            let raw = panStartEV - Float(t.y) / 170
            let snapped = (max(-3, min(3, raw)) * 3).rounded() / 3
            if snapped != camera.exposureBias {
                camera.setExposureBias(snapped)
                Haptics.selectionChanged()
            }
            evHideTask?.cancel()
            withAnimation(.easeOut(duration: 0.12)) { evIndicator = snapped }
        case .cancelled, .failed:
            // e.g. a second finger turned it into a pinch: no EV change.
            panAxis = nil
            withAnimation(.easeOut(duration: 0.3)) { evIndicator = nil }
        default:
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

    /// Action button / Siri / Shortcuts asked for the camera: close the library.
    private func consumeLaunchRequest() {
        guard LaunchRequests.pending else { return }
        LaunchRequests.pending = false
        showLibrary = false
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
                .frame(width: 30, height: 44)
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

// MARK: - Bottom controls

struct LensPicker: View {
    let camera: CameraController
    let rotation: Angle

    var body: some View {
        let position = camera.currentLens?.position ?? .back
        HStack(spacing: 10) {
            // Cropped "lenses" (zoom ≠ 1) are digital zoom: hidden while zoom is locked for RAW.
            ForEach(camera.lenses.filter { $0.position == position && (!camera.settings.zoomLocked || $0.zoom == 1) }) { lens in
                let selected = lens == camera.currentLens
                // Relative to the main lens, like the Camera app: 0.5, 1×, 2, 3. The chosen
                // lens follows a pinch (1.4×).
                let zoom = selected ? lens.relativeZoom / lens.zoom * camera.zoomFactor : lens.relativeZoom
                let label = LensZoom.label(zoom)
                Button {
                    camera.select(lens: lens)
                } label: {
                    Text(selected ? label + "×" : label)
                        .font(.system(size: selected ? 14 : 12, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: selected ? 44 : 38, height: selected ? 44 : 38)
                        .background(Circle().fill(Color.black.opacity(0.5)))
                        .overlay(Circle().stroke(selected ? Color.yellow : Color.white.opacity(0.15), lineWidth: 1.2))
                        .foregroundStyle(selected ? Color.yellow : Color.white)
                        .rotationEffect(rotation)
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("\(LensZoom.label(lens.relativeZoom))× lens")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .animation(.snappy(duration: 0.25), value: camera.currentLens?.id)
    }
}

struct ShutterButton: View {
    let countingDown: Bool
    var burstCount: Int = 0
    let onTap: () -> Void
    var onBurstStart: () -> Void = {}
    var onBurstEnd: () -> Void = {}

    @State private var pressed = false
    @State private var bursting = false
    @State private var holdTask: Task<Void, Never>?
    /// Resets itself when the touch is cancelled (Control Center, a call, an alert), where
    /// DragGesture.onEnded never fires — otherwise a burst would run away.
    @GestureState private var touching = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(bursting ? Color.yellow : Color.white, lineWidth: 4)
                .frame(width: 78, height: 78)
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
        }
        .scaleEffect(pressed ? 0.9 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.6), value: pressed)
        .animation(.snappy(duration: 0.12), value: burstCount)
        .contentShape(Circle())
        // Tap = shoot. Hold = burst until you let go (off while every photo is a RAW:
        // `CameraController.burstEnabled`).
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($touching) { _, state, _ in state = true }
                .onChanged { _ in
                    guard !pressed else { return }
                    pressed = true
                    guard !countingDown else { return }
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
        .onChange(of: touching) { _, isTouching in
            guard !isTouching else { return }
            // Safety net for a *cancelled* touch. Deferred one tick so a normal release is
            // handled by onEnded first (otherwise ending a burst could also fire a tap).
            DispatchQueue.main.async {
                holdTask?.cancel()
                holdTask = nil
                pressed = false
                if bursting {
                    bursting = false
                    onBurstEnd()
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Take photo")
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
            // The whole frame is tappable, not just the glyphs: transparent padding is
            // otherwise ignored by hit testing and taps fall through to the viewfinder.
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
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
