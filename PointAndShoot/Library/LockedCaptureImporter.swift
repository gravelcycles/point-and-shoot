import Foundation
import LockedCameraCapture

/// Photos shot from the Lock Screen wait in a system-managed folder; they're moved into the
/// app's own library (`ShotStore`) the next time the app opens.
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
                let ext = file.pathExtension.lowercased()
                guard ["heic", "jpg", "jpeg", "dng"].contains(ext) else { continue }
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let key = "\(file.lastPathComponent)|\(size)"
                if imported.contains(key) {
                    try? FileManager.default.removeItem(at: file)
                    continue
                }
                guard let data = try? Data(contentsOf: file) else { continue }
                do {
                    let date = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                    try await ShotStore.shared.add(original: data, fileExtension: ext == "jpeg" ? "jpg" : ext,
                                                   kind: ext == "dng" ? .bayerRAW : .processed,
                                                   capturePreview: nil,
                                                   recipe: Look.named(CameraSettings.load().captureLook)?.recipe ?? EditRecipe(),
                                                   captured: date)
                    imported.insert(key)
                    UserDefaults.standard.set(Array(imported.suffix(500)), forKey: importedKey)
                    try? FileManager.default.removeItem(at: file)
                    Diag.log(.importer, "imported Lock Screen shot \(file.lastPathComponent)")
                } catch {
                    Diag.error(.importer, "couldn't import Lock Screen shot \(file.lastPathComponent)", error)
                    everythingImported = false
                }
            }
            if everythingImported {
                try? await manager.invalidateSessionContent(at: folder)
            }
        }
    }
}
