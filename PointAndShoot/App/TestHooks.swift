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

    /// `-uitest-seed N`: save N generated photos to the library at launch (UI tests of the
    /// viewer, grid and deletes). Needs Photos access, which CI grants with `simctl privacy`.
    static var seedCount: Int {
        guard let i = args.firstIndex(of: "-uitest-seed"), i + 1 < args.count else { return 0 }
        return Int(args[i + 1]) ?? 0
    }

    /// Saves `seedCount` solid-colour JPEGs, newest last. Returns how many were saved.
    @discardableResult
    static func seedPhotosIfRequested() async -> Int {
        let n = seedCount
        guard isUITest, n > 0 else { return 0 }
        // Ask for full access ourselves: the UI test taps "Allow Full Access" (CI's
        // `simctl privacy` grant doesn't reliably reach the app). Once granted it holds for
        // the rest of the run, including the Photos integration unit tests.
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        var saved = 0
        for i in 0..<n {
            let hue = CGFloat(i) / CGFloat(max(n, 1))
            let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).image { ctx in
                UIColor(hue: hue, saturation: 0.7, brightness: 0.9, alpha: 1).setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            }
            guard let data = image.jpegData(compressionQuality: 0.8) else { continue }
            if (try? await PhotoLibrary.savePhoto(primary: data, rawCompanion: nil)) != nil { saved += 1 }
        }
        return saved
    }
}

import SwiftUI

/// UI-test-only readout of how many items the roll holds (`roll.count`), so tests can check
/// that a delete really removed a photo. Invisible; absent outside `-uitest`.
struct RollCountProbe: View {
    let roll: RollStore
    var body: some View {
        if TestHooks.isUITest {
            Text("\(roll.assets.count)")
                .font(.system(size: 6))
                .foregroundStyle(.white.opacity(0.02))
                .frame(width: 20, height: 8)
                .allowsHitTesting(false)
                .accessibilityIdentifier("roll.count")
                .accessibilityLabel("\(roll.assets.count)")
        }
    }
}
