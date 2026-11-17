import Photos
import UIKit

/// Test modes. The simulator has no camera, so tests run the real UI without the camera
/// session, permission prompts or the first-launch tour.
enum TestHooks {
    private static let args = ProcessInfo.processInfo.arguments

    /// UI tests (`-uitest` launch argument).
    static let isUITest = args.contains("-uitest")

    /// The app is hosting the unit-test bundle (`PointAndShootTests`): show nothing, start
    /// nothing, so the tests own the process.
    static let isUnitTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        && !isUITest

    static func intArg(_ name: String) -> Int {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return 0 }
        return Int(args[i + 1]) ?? 0
    }

    /// `-uitest-seed N`: N generated shots in the app's library at launch (UI tests of the
    /// viewer, grid, trash). The library starts empty in every UI test.
    static var seedCount: Int { intArg("-uitest-seed") }
    /// `-uitest-photos N`: N generated photos saved to the iOS photo library, asking for
    /// full access first (the UI test taps "Allow Full Access"). That grant holds for the
    /// rest of the run, including the Photos integration unit tests.
    static var photosSeedCount: Int { intArg("-uitest-photos") }

    /// UI tests: an empty library, then the seeded shots, newest first in capture order.
    @MainActor
    static func prepareLibrary(_ store: ShotStore) async {
        guard isUITest else { return }
        let existing = (try? FileManager.default.contentsOfDirectory(at: store.root, includingPropertiesForKeys: nil)) ?? []
        for url in existing { try? FileManager.default.removeItem(at: url) }
        await store.load()
        let n = seedCount
        for i in 0..<n {
            guard let data = solidJPEG(i, of: n) else { continue }
            _ = try? await store.add(original: data, fileExtension: "jpg", kind: .processed, capturePreview: nil,
                                     recipe: EditRecipe(), captured: Date().addingTimeInterval(Double(i - n)))
        }
    }

    static func solidJPEG(_ i: Int, of n: Int) -> Data? {
        let hue = CGFloat(i) / CGFloat(max(n, 1))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).image { ctx in
            UIColor(hue: hue, saturation: 0.7, brightness: 0.9, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        return image.jpegData(compressionQuality: 0.8)
    }

    /// Saves `photosSeedCount` solid-colour JPEGs to the iOS photo library.
    @discardableResult
    static func seedPhotosIfRequested() async -> Int {
        let n = photosSeedCount
        guard isUITest, n > 0 else { return 0 }
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        var saved = 0
        for i in 0..<n {
            guard let data = solidJPEG(i, of: n) else { continue }
            if (try? await PhotoLibrary.savePhoto(primary: data, rawCompanion: nil)) != nil { saved += 1 }
        }
        return saved
    }
}

import SwiftUI

/// UI-test-only readout of how many shots the library holds (`roll.count`), so tests can
/// check that a delete really removed one. Invisible; absent outside `-uitest`.
struct RollCountProbe: View {
    let store: ShotStore
    var body: some View {
        if TestHooks.isUITest {
            Text("\(store.shots.count)")
                .font(.system(size: 6))
                .foregroundStyle(.white.opacity(0.02))
                .frame(width: 20, height: 8)
                .allowsHitTesting(false)
                .accessibilityIdentifier("roll.count")
                .accessibilityLabel("\(store.shots.count)")
        }
    }
}

/// UI tests: a short trail of the viewer's gesture decisions (touches, drag, dismiss), shown
/// on the camera screen (`viewer.events`) so it can still be read after the viewer closed.
@Observable
final class ViewerEventProbe {
    static let shared = ViewerEventProbe()
    var text = ""

    func add(_ event: String) {
        guard TestHooks.isUITest else { return }
        text = String((text + " " + event).suffix(240))
    }
}

struct ViewerEventProbeView: View {
    var body: some View {
        if TestHooks.isUITest {
            let text = ViewerEventProbe.shared.text
            Text(text)
                .font(.system(size: 6))
                .foregroundStyle(.white.opacity(0.02))
                .frame(width: 20, height: 8)
                .allowsHitTesting(false)
                .accessibilityIdentifier("viewer.events")
                .accessibilityLabel(text.isEmpty ? "none" : text)
        }
    }
}
