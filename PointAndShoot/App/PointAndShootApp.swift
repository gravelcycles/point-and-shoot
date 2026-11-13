import SwiftUI

@main
struct PointAndShootApp: App {
    @State private var camera = CameraController()
    @State private var roll = RollStore()

    var body: some Scene {
        WindowGroup {
            CameraView(camera: camera, roll: roll)
                .onAppear {
                    roll.activateIfAuthorized()
                    FilmPipeline.prewarm()
                }
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
    }
}
