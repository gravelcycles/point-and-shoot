import Foundation
import LockedCameraCapture

/// Photos shot from the Lock Screen that the capture extension couldn't put straight into
/// the library wait in a system-managed folder; move them in the next time the app opens.
enum LockedCaptureImporter {
    static func importPending() async {
        guard #available(iOS 18.0, *) else { return }
        let manager = LockedCameraCaptureManager.shared
        for folder in manager.sessionContentURLs {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
            var everythingImported = true
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard ["heic", "jpg", "jpeg"].contains(file.pathExtension.lowercased()),
                      let data = try? Data(contentsOf: file) else { continue }
                do {
                    try await PhotoLibrary.savePhoto(primary: data, rawCompanion: nil)
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
