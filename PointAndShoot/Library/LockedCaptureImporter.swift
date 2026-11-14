import Foundation
import LockedCameraCapture

/// Photos shot from the Lock Screen that the capture extension couldn't put straight into
/// the library wait in a system-managed folder; move them in the next time the app opens.
///
/// Runs one import at a time (launch fires both onAppear and scenePhase .active, which used
/// to import every parked shot twice) and remembers what it imported, so a shot that's
/// been imported and then deleted never comes back if its parked file couldn't be removed.
@MainActor
enum LockedCaptureImporter {
    private static var running = false
    private static let importedKey = "lockedCapture.imported"

    static func importPending() async {
        guard #available(iOS 18.0, *), !running else { return }
        running = true
        defer { running = false }

        var imported = Set(UserDefaults.standard.stringArray(forKey: importedKey) ?? [])
        let manager = LockedCameraCaptureManager.shared
        for folder in manager.sessionContentURLs {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
            var everythingImported = true
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard ["heic", "jpg", "jpeg"].contains(file.pathExtension.lowercased()) else { continue }
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let key = "\(file.lastPathComponent)|\(size)"
                if imported.contains(key) {
                    try? FileManager.default.removeItem(at: file)
                    continue
                }
                guard let data = try? Data(contentsOf: file) else { continue }
                do {
                    try await PhotoLibrary.savePhoto(primary: data, rawCompanion: nil)
                    imported.insert(key)
                    UserDefaults.standard.set(Array(imported.suffix(500)), forKey: importedKey)
                    try? FileManager.default.removeItem(at: file)
                } catch {
                    everythingImported = false
                }
            }
            if everythingImported {
                try? await manager.invalidateSessionContent(at: folder)
            }
        }
    }
}
