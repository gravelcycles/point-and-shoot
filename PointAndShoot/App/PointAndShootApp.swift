import SwiftUI

@main
struct PointAndShootApp: App {
    @State private var camera = CameraController()
    @State private var roll = RollStore()
    /// UI tests: seeded photos are all saved (`roll.seeded` appears).
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
                CameraView(camera: camera, roll: roll)
                    .onAppear {
                        roll.activateIfAuthorized()
                        FilmPipeline.prewarm()
                        if TestHooks.seedCount > 0 {
                            Task {
                                await TestHooks.seedPhotosIfRequested()
                                roll.activateIfAuthorized()
                                seeded = true
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
