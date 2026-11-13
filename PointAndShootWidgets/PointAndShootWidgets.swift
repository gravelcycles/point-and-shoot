import AppIntents
import SwiftUI
import WidgetKit

@main
struct PointAndShootWidgets: WidgetBundle {
    var body: some Widget {
        CameraControl()
        VideoControl()
    }
}

/// Opens the full app in Video mode (asks for Face ID when locked).
struct VideoControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.pointandshoot.camera.video") {
            ControlWidgetButton(action: OpenVideoControlIntent()) {
                Label("Record Video", systemImage: "video.fill")
            }
        }
        .displayName("Record Video")
        .description("Open Point & Shoot ready to record video.")
    }
}

/// A Control for Control Center, the Lock Screen's bottom buttons and the Action button.
struct CameraControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.pointandshoot.camera.capture") {
            ControlWidgetButton(action: PointAndShootCaptureIntent()) {
                Label("Point & Shoot", systemImage: "camera.aperture")
            }
        }
        .displayName("Point & Shoot")
        .description("Open the camera — even from the Lock Screen.")
    }
}
