import AVFoundation
import CoreLocation
import Foundation
import MetricKit
import OSLog
import Photos
import UIKit

/// The development diagnostics log: what the app did and what went wrong, in plain lines
/// the owner can share from Settings → Diagnostics (no Mac needed). Every line also goes to
/// the unified log (subsystem = bundle id, category = area) for Console.app.
///
/// Log events, never per-frame work. Lines are kept in memory (last 3000) and appended to
/// `Application Support/diagnostics.log`, so the run before a crash is still there on the
/// next launch. Uncaught Objective-C exceptions (AVFoundation's instant crashes) are written
/// synchronously before the app dies, and MetricKit's crash reports arrive on a later launch.
enum Diag {
    enum Area: String {
        case app, perms, session, capture, save, bake, roll, viewer, delete, editor, ui, crash
        case importer = "import"
    }

    static let subsystem = Bundle.main.bundleIdentifier ?? "PointAndShoot"

    // MARK: Logging

    static func log(_ area: Area, _ message: String) {
        Logger(subsystem: subsystem, category: area.rawValue).notice("\(message, privacy: .public)")
        record(area, message, isError: false)
    }

    static func error(_ area: Area, _ message: String) {
        Logger(subsystem: subsystem, category: area.rawValue).error("\(message, privacy: .public)")
        record(area, message, isError: true)
    }

    /// `error` with an NSError's domain and code, which is what identifies a Photos/AVFoundation failure.
    static func error(_ area: Area, _ message: String, _ err: Error) {
        let ns = err as NSError
        error(area, "\(message): \(ns.localizedDescription) (\(ns.domain) \(ns.code))")
    }

    // MARK: Store

    private static let queue = DispatchQueue(label: "diagnostics", qos: .utility)
    private static var lines: [String] = []          // queue only
    private static let maxLines = 3000
    private static let maxFileBytes = 1_500_000
    private static var started = false

    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("diagnostics.log")
    }()

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static func record(_ area: Area, _ message: String, isError: Bool) {
        let now = Date()
        queue.async {
            let line = "\(stampFormatter.string(from: now)) [\(area.rawValue)] \(isError ? "⚠︎ " : "")\(message)"
            lines.append(line)
            if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
            appendToFile(line + "\n")
        }
    }

    private static func appendToFile(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            if size > UInt64(maxFileBytes) {
                // Keep it bounded: rewrite with what's in memory (the newest lines).
                try? (lines.joined(separator: "\n") + "\n").data(using: .utf8)?.write(to: fileURL, options: .atomic)
                return
            }
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Everything logged so far (including earlier runs kept in the file), newest last.
    static func text(_ completion: @escaping (String) -> Void) {
        let header = environment()
        queue.async {
            let body = lines.joined(separator: "\n")
            DispatchQueue.main.async { completion(header + "\n\n" + body + "\n") }
        }
    }

    /// The log as a file for the share sheet.
    static func exportFile(_ completion: @escaping (URL?) -> Void) {
        text { text in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("PointAndShoot-diagnostics.txt")
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                completion(url)
            } catch {
                completion(nil)
            }
        }
    }

    static func clear() {
        queue.async {
            lines.removeAll()
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Waits until everything logged so far is stored (tests).
    static func flush() { queue.sync {} }

    // MARK: Start

    /// Once, at launch: reload the previous runs, catch crashes, watch the system.
    static func start() {
        guard !started else { return }
        started = true
        queue.sync {
            if let previous = try? String(contentsOf: fileURL, encoding: .utf8) {
                lines = Array(previous.split(separator: "\n", omittingEmptySubsequences: true).suffix(maxLines).map(String.init))
            }
        }
        log(.app, "— launch — \(buildDescription) · \(deviceModel) · iOS \(UIDevice.current.systemVersion)")
        log(.perms, permissionSummary())

        if !TestHooks.isUnitTestHost {
            NSSetUncaughtExceptionHandler { exception in
                // The app is about to die: write straight to the file, no queues.
                let stack = exception.callStackSymbols.prefix(25).joined(separator: "\n    ")
                let line = "\(Diag.stampFormatter.string(from: Date())) [crash] ⚠︎ uncaught \(exception.name.rawValue): \(exception.reason ?? "") \n    \(stack)\n"
                if let handle = try? FileHandle(forWritingTo: Diag.fileURL), let data = line.data(using: .utf8) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                }
            }
            MXMetricManager.shared.add(metrics)
        }

        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { _ in
            error(.app, "memory warning")
        }
        nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { _ in
            log(.app, "thermal state: \(thermalName(ProcessInfo.processInfo.thermalState))")
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
            log(.app, "background")
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { _ in
            log(.app, "foreground · \(permissionSummary())")
        }
    }

    private static let metrics = DiagnosticPayloads()

    // MARK: Environment

    static var buildDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var built = ""
        if let url = Bundle.main.executableURL,
           let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            built = " · built " + date.formatted(date: .abbreviated, time: .shortened)
        }
        return "\(version) (\(build))\(built)"
    }

    static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static func permissionSummary() -> String {
        func av(_ s: AVAuthorizationStatus) -> String {
            ["not asked", "restricted", "denied", "allowed"][min(max(s.rawValue, 0), 3)]
        }
        func ph(_ s: PHAuthorizationStatus) -> String {
            ["not asked", "restricted", "denied", "full", "limited"][min(max(s.rawValue, 0), 4)]
        }
        let loc: String = switch CLLocationManager().authorizationStatus {
        case .notDetermined: "not asked"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorizedAlways: "always"
        case .authorizedWhenInUse: "when in use"
        @unknown default: "?"
        }
        return "access: camera \(av(AVCaptureDevice.authorizationStatus(for: .video)))"
            + ", mic \(av(AVCaptureDevice.authorizationStatus(for: .audio)))"
            + ", photos \(ph(PHPhotoLibrary.authorizationStatus(for: .readWrite)))"
            + " (add \(ph(PHPhotoLibrary.authorizationStatus(for: .addOnly))))"
            + ", location \(loc)"
    }

    static func thermalName(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "?"
        }
    }

    static func environment() -> String {
        let free = (try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        return """
        Point & Shoot diagnostics
        build: \(buildDescription)
        device: \(deviceModel), iOS \(UIDevice.current.systemVersion)
        \(permissionSummary())
        free storage: \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) · thermal \(thermalName(ProcessInfo.processInfo.thermalState)) · low power \(ProcessInfo.processInfo.isLowPowerModeEnabled)
        """
    }
}

/// MetricKit's crash and hang reports (delivered on a later launch) into the log.
final class DiagnosticPayloads: NSObject, MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                var parts = ["crash report (build \(crash.metaData.applicationBuildVersion))"]
                if let type = crash.exceptionType { parts.append("exception \(type)") }
                if let code = crash.exceptionCode { parts.append("code \(code)") }
                if let signal = crash.signal { parts.append("signal \(signal)") }
                if let reason = crash.terminationReason { parts.append(reason) }
                if let objc = crash.exceptionReason { parts.append("\(objc.exceptionName): \(objc.composedMessage)") }
                Diag.error(.crash, parts.joined(separator: " · "))
                let tree = String(decoding: crash.callStackTree.jsonRepresentation(), as: UTF8.self)
                Diag.error(.crash, "stack: " + String(tree.prefix(6000)))
            }
            for hang in payload.hangDiagnostics ?? [] {
                Diag.error(.crash, "hang of \(hang.hangDuration) (build \(hang.metaData.applicationBuildVersion))")
            }
        }
    }
}
