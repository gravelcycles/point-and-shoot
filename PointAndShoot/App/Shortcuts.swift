import AppIntents
import Foundation

/// Lets the Action button, Siri, Spotlight and Shortcuts open the camera ready to shoot
/// (closing the library if it's open).
enum LaunchRequests {
    static let notification = Notification.Name("PointAndShoot.launchMode")
    static var pending = false

    @MainActor
    static func requestCamera() {
        pending = true
        NotificationCenter.default.post(name: notification, object: nil)
    }
}

struct OpenPhotoModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Take a Photo"
    static let description = IntentDescription("Opens Point & Shoot ready to take a photo.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LaunchRequests.requestCamera()
        return .result()
    }
}

struct PointAndShootShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenPhotoModeIntent(),
                    phrases: ["Take a photo with \(.applicationName)", "Open \(.applicationName)"],
                    shortTitle: "Photo",
                    systemImageName: "camera.fill")
    }
}
