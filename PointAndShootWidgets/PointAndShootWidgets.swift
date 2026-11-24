import AppIntents
import SwiftUI
import WidgetKit

@main
struct PointAndShootWidgets: WidgetBundle {
    var body: some Widget {
        CameraControl()
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
