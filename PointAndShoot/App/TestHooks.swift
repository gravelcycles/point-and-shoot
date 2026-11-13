import Foundation

/// UI-test mode (`-uitest` launch argument). The simulator has no camera, so the tests run
/// the real UI without the camera session, permission prompts or the first-launch tour.
enum TestHooks {
    static let isUITest = ProcessInfo.processInfo.arguments.contains("-uitest")
}
