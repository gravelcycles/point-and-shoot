import AppIntents
import Foundation

/// Data the app and its Lock Screen capture extension can hand each other.
struct LockedCaptureContext: Codable, Sendable {
    var mode: String = "photo"
}

/// The one intent the Lock Screen, Control Center and the Action button use to open the
/// camera. Compiled into the app, the Control widget and the capture extension.
/// Locked: the system runs the capture extension (no unlock needed).
/// Unlocked: the system opens the app.
@available(iOS 18.0, *)
struct PointAndShootCaptureIntent: CameraCaptureIntent {
    typealias AppContext = LockedCaptureContext

    static let title: LocalizedStringResource = "Point & Shoot"
    static let description = IntentDescription("Open the camera straight from the Lock Screen, Control Center or the Action button.")

    @MainActor
    func perform() async throws -> some IntentResult {
        .result()
    }
}
