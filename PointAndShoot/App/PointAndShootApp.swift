import SwiftUI

@main
struct PointAndShootApp: App {
    @State private var camera = CameraController()
    @State private var store = ShotStore.shared
    /// UI tests: the library is ready (`roll.seeded` appears).
    @State private var seeded = false
    @AppStorage(IntroView.seenKey) private var introSeen = false
    /// The intro is up: on first launch, or again from Preferences → Show Introduction.
    @State private var showIntro = IntroView.isNeeded
    /// The camera screen is built only once the first intro is done, so the camera's
    /// permission prompt never appears underneath the intro that explains it.
    @State private var cameraBuilt = !IntroView.isNeeded

    init() {
        Diag.start()
    }

    var body: some Scene {
        WindowGroup {
            if TestHooks.isUnitTestHost {
                // Hosting PointAndShootTests: no camera, no roll, nothing in the way.
                Color.black.ignoresSafeArea()
            } else {
                ZStack {
                    Color.black.ignoresSafeArea()
                    if cameraBuilt {
                        CameraView(camera: camera, store: store)
                    }
                    if showIntro {
                        IntroView(onFinish: finishIntro)
                            .transition(.opacity)
                            .zIndex(1)
                    }
                }
                .onAppear {
                    FilmPipeline.prewarm()
                    Task {
                        if TestHooks.isUITest {
                            await TestHooks.prepareLibrary(store)
                            await TestHooks.seedPhotosIfRequested()
                            seeded = true
                        } else {
                            await store.load()
                            store.applyRetention(storeForever: camera.settings.storeForever)
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: IntroView.showRequest)) { _ in
                    // Preferences → Show Introduction: over the camera, which pauses
                    // meanwhile (so the volume buttons can't take a photo behind it).
                    guard !showIntro else { return }
                    camera.stop()
                    withAnimation(.easeInOut(duration: 0.35)) { showIntro = true }
                }
                .overlay(alignment: .topTrailing) {
                    if seeded {
                        Text("seeded").font(.system(size: 6)).foregroundStyle(.white.opacity(0.02))
                            .allowsHitTesting(false).accessibilityIdentifier("roll.seeded")
                    }
                }
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
            }
        }
    }

    private func finishIntro() {
        introSeen = true
        if cameraBuilt {
            camera.start()
        } else {
            cameraBuilt = true   // its onAppear starts the camera
        }
        withAnimation(.easeInOut(duration: 0.4)) { showIntro = false }
    }
}
