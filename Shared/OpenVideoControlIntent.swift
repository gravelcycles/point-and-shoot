import AppIntents
import Foundation

/// Behind the "Record Video" control (Control Center, Lock Screen buttons, Action button).
/// Opens the app straight into Video mode. Compiled into the app and both extensions; with
/// `openAppWhenRun` the system performs it in the app, so the extensions only need the type.
/// (Unlike the photo control, this needs Face ID: video recording isn't part of the Lock
/// Screen capture extension.)
@available(iOS 18.0, *)
struct OpenVideoControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Record Video"
    static let description = IntentDescription("Opens Point & Shoot ready to record video.")
    static let openAppWhenRun: Bool = true
    // "Record a Video" (Shortcuts.swift) already covers this in the Shortcuts app.
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !APP_EXTENSION
        LaunchRequests.request(.video)
        #endif
        return .result()
    }
}
