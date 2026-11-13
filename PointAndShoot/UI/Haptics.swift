import UIKit

/// Cached, pre-warmed feedback generators. Allocating a generator per tap adds latency to
/// the first tick (the Taptic Engine has to spin up) and churns objects on every scrub.
enum Haptics {
    private static var impacts: [UIImpactFeedbackGenerator.FeedbackStyle: UIImpactFeedbackGenerator] = [:]
    private static let selection = UISelectionFeedbackGenerator()
    private static let notification = UINotificationFeedbackGenerator()

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard Thread.isMainThread else { return DispatchQueue.main.async { impact(style) } }
        let generator = impacts[style] ?? {
            let g = UIImpactFeedbackGenerator(style: style)
            impacts[style] = g
            return g
        }()
        generator.impactOccurred()
        generator.prepare()   // keep the engine warm for the next one
    }

    static func selectionChanged() {
        guard Thread.isMainThread else { return DispatchQueue.main.async { selectionChanged() } }
        selection.selectionChanged()
        selection.prepare()
    }

    static func success() {
        guard Thread.isMainThread else { return DispatchQueue.main.async { success() } }
        notification.notificationOccurred(.success)
    }
}
