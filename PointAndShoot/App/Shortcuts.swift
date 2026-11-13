import AppIntents
import Foundation

/// Lets the Action button, Siri, Spotlight and Shortcuts open the camera straight into
/// Photo or Video mode.
enum LaunchRequests {
    static let notification = Notification.Name("PointAndShoot.launchMode")
    static var pendingMode: CaptureMode?

    @MainActor
    static func request(_ mode: CaptureMode) {
        pendingMode = mode
        NotificationCenter.default.post(name: notification, object: nil)
    }
}

struct OpenPhotoModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Take a Photo"
    static let description = IntentDescription("Opens Point & Shoot ready to take a photo.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LaunchRequests.request(.photo)
        return .result()
    }
}

struct OpenVideoModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Record a Video"
    static let description = IntentDescription("Opens Point & Shoot ready to record video.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LaunchRequests.request(.video)
        return .result()
    }
}

struct PointAndShootShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenPhotoModeIntent(),
                    phrases: ["Take a photo with \(.applicationName)", "Open \(.applicationName)"],
                    shortTitle: "Photo",
                    systemImageName: "camera.fill")
        AppShortcut(intent: OpenVideoModeIntent(),
                    phrases: ["Record video with \(.applicationName)"],
                    shortTitle: "Video",
                    systemImageName: "video.fill")
    }
}
