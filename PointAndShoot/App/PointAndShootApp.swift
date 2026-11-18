import SwiftUI

@main
struct PointAndShootApp: App {
    @State private var camera = CameraController()
    @State private var store = ShotStore.shared
    /// UI tests: the library is ready (`roll.seeded` appears).
    @State private var seeded = false

    init() {
        Diag.start()
    }

    var body: some Scene {
        WindowGroup {
            if TestHooks.isUnitTestHost {
                // Hosting PointAndShootTests: no camera, no roll, nothing in the way.
                Color.black.ignoresSafeArea()
            } else {
                CameraView(camera: camera, store: store)
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
}
