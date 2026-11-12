import SwiftUI

@main
struct PointAndShootApp: App {
    @State private var camera = CameraController()

    var body: some Scene {
        WindowGroup {
            CameraView(camera: camera)
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
    }
}
