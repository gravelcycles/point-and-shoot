import AVFoundation
import CoreLocation
import SwiftUI

/// The first-run introduction: five swipeable pages (what the app is, shooting, looks, the
/// library and editor, then permissions), skippable, shown once. Preferences → General →
/// Show Introduction brings it back.
///
/// It's shown before the camera screen is built (`PointAndShootApp`), so the camera and
/// location prompts come on the last page, each after a sentence on why. Skipping it is
/// fine: the camera asks for access when it starts, as it always has, and location when
/// geotagging first starts.
struct IntroView: View {
    /// Set once the intro has been finished or skipped.
    static let seenKey = "intro.v1.seen"

    /// Whether the app opens on the intro: once, never in tests unless `-uitest-intro`.
    static var isNeeded: Bool {
        if TestHooks.showsIntro { return true }
        if TestHooks.isUITest || TestHooks.isUnitTestHost { return false }
        return !UserDefaults.standard.bool(forKey: seenKey)
    }

    /// Preferences → Show Introduction asks the app to put the intro back up.
    static let showRequest = Notification.Name("IntroView.showRequest")
    static func requestShow() { NotificationCenter.default.post(name: showRequest, object: nil) }

    let onFinish: () -> Void

    @State private var page = 0
    @State private var permissions = IntroPermissions()

    private var isLast: Bool { page == IntroPage.allCases.count - 1 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // A soft glow behind the artwork, warming toward the accent page by page.
            RadialGradient(colors: [IntroPage(rawValue: page)?.glow.opacity(0.22) ?? .clear, .clear],
                           center: .init(x: 0.5, y: 0.22), startRadius: 10, endRadius: 360)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.5), value: page)

            TabView(selection: $page) {
                ForEach(IntroPage.allCases) { p in
                    IntroPageView(page: p, current: page == p.rawValue, permissions: permissions)
                        .tag(p.rawValue)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomBar
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .overlay(alignment: .topLeading) { pageProbe }
        .onChange(of: page) { _, _ in Haptics.selectionChanged() }
    }

    private var topBar: some View {
        HStack {
            Spacer()
            Button(action: finish) {
                Text("Skip")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 18)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(PressScaleStyle())
            .opacity(isLast ? 0 : 1)
            .disabled(isLast)
            .accessibilityIdentifier("intro.skip")
        }
        .padding(.horizontal, 6)
        .animation(.easeOut(duration: 0.2), value: isLast)
    }

    private var bottomBar: some View {
        VStack(spacing: 22) {
            HStack(spacing: 7) {
                ForEach(IntroPage.allCases) { p in
                    Capsule()
                        .fill(p.rawValue == page ? Color.yellow : Color.white.opacity(0.25))
                        .frame(width: p.rawValue == page ? 22 : 7, height: 7)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: page)
            .accessibilityHidden(true)

            Button {
                if isLast {
                    finish()
                } else {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { page += 1 }
                }
            } label: {
                Text(isLast ? "Start Shooting" : "Next")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(Capsule().fill(Color.yellow))
                    .contentTransition(.opacity)
            }
            .buttonStyle(PressScaleStyle(scale: 0.96))
            .padding(.horizontal, 24)
            .accessibilityIdentifier(isLast ? "intro.start" : "intro.next")
        }
        .padding(.bottom, 12)
    }

    private func finish() {
        Haptics.impact(.light)
        onFinish()
    }

    /// UI tests: the page on screen (`intro.page`).
    @ViewBuilder private var pageProbe: some View {
        if TestHooks.isUITest {
            Text("\(page)")
                .font(.system(size: 6))
                .foregroundStyle(.white.opacity(0.02))
                .frame(width: 20, height: 8)
                .allowsHitTesting(false)
                .accessibilityIdentifier("intro.page")
                .accessibilityLabel("\(page)")
        }
    }
}

// MARK: - Pages

private enum IntroPage: Int, CaseIterable, Identifiable {
    case welcome, shooting, looks, library, ready
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: "Point & Shoot"
        case .shooting: "Shoot like a camera"
        case .looks: "Looks, from the RAW"
        case .library: "Library and editor"
        case .ready: "Ready when you are"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome: "A RAW camera with film looks. Every photo is a RAW file, and the app develops it with the look you choose."
        case .shooting: "Everything is a gesture away. Yellow means you're in control."
        case .looks: "Film stocks and movie grades, developed from the sensor's data."
        case .library: "Your photos stay in the app until you export them."
        case .ready: "Two permissions, and you're shooting."
        }
    }

    var glow: Color {
        switch self {
        case .welcome: .yellow
        case .shooting: .white
        case .looks: .orange
        case .library: .tan
        case .ready: .yellow
        }
    }

    struct Point: Hashable {
        let symbol: String
        let text: String
        init(_ symbol: String, _ text: String) { self.symbol = symbol; self.text = text }
    }

    var points: [Point] {
        switch self {
        case .welcome:
            [Point("camera.aperture", "Apple ProRAW by default: the cleanest file an iPhone makes."),
             Point("arrow.uturn.backward", "The original is never touched: change the look, or go back to it, any time.")]
        case .shooting:
            [Point("hand.tap", "Tap to focus and expose there."),
             Point("lock", "Hold to lock focus and exposure."),
             Point("arrow.up.and.down", "Drag up or down to brighten or darken."),
             Point("arrow.up.left.and.arrow.down.right", "Pinch to zoom."),
             Point("slider.horizontal.3", "Tap FOCUS, WB, ISO, SHUTTER or EV to dial it in; double-tap one for auto."),
             Point("gearshape", "Double-tap the viewfinder for Preferences.")]
        case .looks:
            [Point("camera.filters", "Tap LOOK to pick one. The viewfinder shows it live."),
             Point("wand.and.rays", "A look is applied to the RAW, not baked in: change it in the editor whenever you like."),
             Point("star", "Set a Default Grade (a look and your sliders) and new shots start from it.")]
        case .library:
            [Point("calendar", "Photos stay 30 days, then move to the Trash, unless you tap Keep."),
             Point("square.and.arrow.down", "Export puts the finished photo in Photos."),
             Point("checkmark.circle", "In the grid, hold a photo to select several."),
             Point("slider.horizontal.below.rectangle", "Edit with Looks, Tone, Color, Texture and Crop. Hold the photo to compare; ⓘ on every tab explains each control.")]
        case .ready:
            []
        }
    }
}

private struct IntroPageView: View {
    let page: IntroPage
    let current: Bool
    let permissions: IntroPermissions

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                hero
                    .frame(height: 230)
                    .padding(.top, 56)
                    .padding(.bottom, 26)
                VStack(alignment: .leading, spacing: 10) {
                    Text(page.title)
                        .font(.system(size: 32, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                    Text(page.subtitle)
                        .font(.system(size: 17))
                        .foregroundStyle(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 24)

                if page == .ready {
                    PermissionRows(permissions: permissions)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(page.points, id: \.self) { point in
                            HStack(alignment: .firstTextBaseline, spacing: 14) {
                                Image(systemName: point.symbol)
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(Color.yellow)
                                    .frame(width: 26)
                                Text(point.text)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 28)
            // Room for the dots and the button.
            .padding(.bottom, 130)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder private var hero: some View {
        switch page {
        case .welcome: ApertureHero(active: current)
        case .shooting: ViewfinderHero(active: current)
        case .looks: LooksHero(active: current)
        case .library: LibraryHero(active: current)
        case .ready: ReadyHero(active: current)
        }
    }
}

// MARK: - Permissions

/// Camera and location access, asked from the intro's last page with a reason for each.
@Observable
private final class IntroPermissions: NSObject, CLLocationManagerDelegate {
    var camera = AVCaptureDevice.authorizationStatus(for: .video)
    var location: CLAuthorizationStatus
    private let manager = CLLocationManager()

    override init() {
        location = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    func requestCamera() {
        switch camera {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { _ in
                DispatchQueue.main.async { self.camera = AVCaptureDevice.authorizationStatus(for: .video) }
            }
        case .denied, .restricted:
            Self.openSettings()
        default:
            break
        }
    }

    func requestLocation() {
        switch location {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: Self.openSettings()
        default: break
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        DispatchQueue.main.async { self.location = status }
    }

    private static func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

private struct PermissionRows: View {
    let permissions: IntroPermissions

    var body: some View {
        VStack(spacing: 12) {
            row(symbol: "camera.fill", title: "Camera",
                why: "To take photos. They stay on this iPhone until you export them.",
                state: state(camera: permissions.camera), id: "intro.allowCamera",
                action: permissions.requestCamera)
            row(symbol: "location.fill", title: "Location",
                why: "To note where each photo was taken. GPS works offline, even in airplane mode. Turn it off any time in Preferences.",
                state: state(location: permissions.location), id: "intro.allowLocation",
                action: permissions.requestLocation)
        }
    }

    enum Access { case ask, allowed, off }

    private func state(camera: AVAuthorizationStatus) -> Access {
        switch camera {
        case .authorized: .allowed
        case .notDetermined: .ask
        default: .off
        }
    }

    private func state(location: CLAuthorizationStatus) -> Access {
        switch location {
        case .authorizedWhenInUse, .authorizedAlways: .allowed
        case .notDetermined: .ask
        default: .off
        }
    }

    private func row(symbol: String, title: String, why: String, state: Access, id: String,
                     action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.yellow)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(why)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button(action: action) {
                Group {
                    switch state {
                    case .allowed:
                        Label("Allowed", systemImage: "checkmark").labelStyle(.iconOnly)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.yellow)
                            .frame(width: 44, height: 34)
                    case .ask:
                        Text("Allow")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(Capsule().fill(Color.yellow))
                    case .off:
                        Text("Settings")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .background(Capsule().fill(Color.white.opacity(0.14)))
                    }
                }
                .frame(minHeight: 44)
            }
            .buttonStyle(PressScaleStyle())
            .disabled(state == .allowed)
            .accessibilityIdentifier(id)
            .accessibilityLabel(state == .allowed ? "\(title) allowed" : state == .ask ? "Allow \(title)" : "Open Settings for \(title)")
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: state)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}

// MARK: - Artwork (SF Symbols and shapes, no image assets)

/// The aperture, slowly turning, with a RAW tag.
private struct ApertureHero: View {
    let active: Bool
    @State private var turn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.yellow.opacity(0.35), lineWidth: 1.5)
                .frame(width: 210, height: 210)
            Circle()
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                .frame(width: 170, height: 170)
            Image(systemName: "camera.aperture")
                .font(.system(size: 120, weight: .ultraLight))
                .foregroundStyle(Color.yellow)
                .rotationEffect(.degrees(turn ? 360 : 0))
                .animation(reduceMotion ? nil : .linear(duration: 30).repeatForever(autoreverses: false), value: turn)
            Text("RAW")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(.black)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color.yellow))
                .offset(x: 82, y: 82)
        }
        .onAppear { turn = true }
        .accessibilityHidden(true)
    }
}

/// A viewfinder with the yellow focus square settling on a subject, and the exposure sun.
private struct ViewfinderHero: View {
    let active: Bool
    @State private var settled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.2), Color(red: 0.12, green: 0.1, blue: 0.08)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    // Rule-of-thirds grid.
                    GeometryReader { geo in
                        Path { p in
                            for i in 1...2 {
                                let x = geo.size.width * CGFloat(i) / 3, y = geo.size.height * CGFloat(i) / 3
                                p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: geo.size.height))
                                p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: geo.size.width, y: y))
                            }
                        }
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    }
                )
                .frame(width: 172, height: 230)
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(Color.yellow, lineWidth: 1.5)
                .frame(width: 58, height: 58)
                .scaleEffect(settled || reduceMotion ? 1 : 1.5)
                .opacity(settled || reduceMotion ? 1 : 0.4)
                .offset(x: -14, y: -16)
            VStack(spacing: 4) {
                Image(systemName: "chevron.up").font(.system(size: 11, weight: .bold))
                Image(systemName: "sun.max.fill").font(.system(size: 20))
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(Color.yellow)
            .offset(x: 30, y: -16)
            .symbolEffect(.bounce, value: active)
        }
        .onAppear { focus() }
        .onChange(of: active) { _, on in if on { settled = false; focus() } }
        .accessibilityHidden(true)
    }

    /// The square drops in and settles, like the camera's reticle.
    private func focus() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.6).delay(0.3)) { settled = true }
    }
}

/// One RAW, fanned out into several looks.
private struct LooksHero: View {
    let active: Bool
    @State private var fanned = false

    private let cards: [[Color]] = [
        [Color(red: 0.95, green: 0.62, blue: 0.32), Color(red: 0.35, green: 0.16, blue: 0.1)],
        [Color(red: 0.45, green: 0.75, blue: 0.6), Color(red: 0.08, green: 0.22, blue: 0.2)],
        [Color(red: 0.4, green: 0.62, blue: 0.9), Color(red: 0.75, green: 0.42, blue: 0.25)],
        [Color(white: 0.85), Color(white: 0.08)],
    ]

    var body: some View {
        ZStack {
            ForEach(cards.indices, id: \.self) { i in
                let spread = Double(i) - Double(cards.count - 1) / 2
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: cards[i], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.18)))
                    .frame(width: 104, height: 140)
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 6)
                    .rotationEffect(.degrees(fanned ? spread * 13 : 0), anchor: .bottom)
                    .offset(x: fanned ? spread * 34 : 0, y: fanned ? abs(spread) * 8 : 0)
            }
            Text("RAW")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(.black)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color.yellow))
                .offset(y: 102)
        }
        .onAppear { fan() }
        .onChange(of: active) { _, on in if on { fanned = false; fan() } }
        .accessibilityHidden(true)
    }

    private func fan() {
        withAnimation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.15)) { fanned = true }
    }
}

/// A slice of the grid: one photo kept, a few being selected.
private struct LibraryHero: View {
    let active: Bool
    @State private var picked = false

    private let hues: [Double] = [0.08, 0.55, 0.12, 0.33, 0.6, 0.02, 0.45, 0.15, 0.7]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<3) { row in
                HStack(spacing: 4) {
                    ForEach(0..<3) { col in
                        let i = row * 3 + col
                        let selected = picked && [4, 5, 7].contains(i)
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(LinearGradient(colors: [Color(hue: hues[i], saturation: 0.45, brightness: 0.8),
                                                          Color(hue: hues[i], saturation: 0.6, brightness: 0.3)],
                                                 startPoint: .top, endPoint: .bottom))
                            .frame(width: 66, height: 66)
                            .overlay { if selected { Color.black.opacity(0.3) } }
                            .overlay(alignment: .bottomTrailing) {
                                if selected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(Color.black, Color.tan)
                                        .font(.system(size: 18, weight: .semibold))
                                        .padding(4)
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }
                            .overlay(alignment: .topTrailing) {
                                if i == 1 {
                                    Image(systemName: "bookmark.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.tan)
                                        .padding(5)
                                }
                            }
                    }
                }
            }
        }
        .onAppear { pick() }
        .onChange(of: active) { _, on in if on { picked = false; pick() } }
        .accessibilityHidden(true)
    }

    private func pick() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7).delay(0.35)) { picked = true }
    }
}

/// The shutter button.
private struct ReadyHero: View {
    let active: Bool

    var body: some View {
        ZStack {
            Circle().strokeBorder(.white, lineWidth: 5).frame(width: 128, height: 128)
            Circle().fill(.white).frame(width: 106, height: 106)
            Image(systemName: "camera.fill")
                .font(.system(size: 32))
                .foregroundStyle(.black)
                .symbolEffect(.bounce, value: active)
        }
        .accessibilityHidden(true)
    }
}
