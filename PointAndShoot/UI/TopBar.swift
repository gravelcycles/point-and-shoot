import SwiftUI

/// The top bar: a few big, obviously-tappable buttons and one format pill.
///
/// Every control has a visible background, a 44 pt tap target and a haptic click, and the
/// cryptic format badges are gone. Instead the pill states what you'll capture
/// ("HEIF · Natural") and opens a panel with labelled choices, so nothing changes blindly.
struct TopBar: View {
    let camera: CameraController
    let rotation: Angle
    @Binding var showSettings: Bool
    @Binding var showFormat: Bool

    var body: some View {
        let s = camera.settings
        let haptics = s.haptics
        HStack(spacing: 8) {
            if s.mode == .photo {
                TopBarButton(symbol: s.flash.symbol, active: s.flash != .off, enabled: camera.supportsFlash,
                             rotation: rotation, haptics: haptics, label: "Flash \(s.flash.rawValue)") {
                    camera.update { $0.flash = cycled(s.flash, in: FlashSetting.allCases) }
                }
                .accessibilityIdentifier("topbar.flash")
            } else {
                Color.clear.frame(width: 44, height: 44)
            }

            Spacer(minLength: 4)

            if camera.isRecording, let start = camera.recordingStart {
                VStack(spacing: 2) {
                    RecordingClock(start: start)
                    if let left = camera.recordingTimeLeft {
                        Text(CameraFormat.timeLeft(left) + " left")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(left < 300 ? Color.red : Color.white.opacity(0.6))
                    }
                }
            } else {
                FormatPill(title: CameraFormat.summary(s),
                           subtitle: s.mode == .video ? camera.recordingTimeLeft.map { CameraFormat.timeLeft($0) + " left" } : nil,
                           highlighted: CameraFormat.isPro(s),
                           haptics: haptics) {
                    showFormat = true
                }
                .accessibilityIdentifier(s.mode == .photo ? "topbar.format" : "topbar.videoformat")
            }

            Spacer(minLength: 4)

            if s.mode == .photo {
                TopBarButton(symbol: "timer", caption: s.selfTimer == .off ? nil : s.selfTimer.label,
                             active: s.selfTimer != .off, rotation: rotation, haptics: haptics, label: "Self-timer") {
                    camera.update { $0.selfTimer = cycled(s.selfTimer, in: SelfTimer.allCases) }
                }
                .accessibilityIdentifier("topbar.timer")
            }
            GPSIndicator(tagger: camera.location, rotation: rotation) {
                camera.haptic(.light)
                camera.toast = camera.location.statusText
            }
            TopBarButton(symbol: "gearshape.fill", enabled: !camera.isRecording, rotation: rotation,
                         haptics: haptics, label: "Settings") {
                showSettings = true
            }
            .accessibilityIdentifier("topbar.settings")
            // Each presentation hangs off its own view: stacking a sheet and the photo
            // viewer's full-screen cover on one view kept Settings from ever appearing.
            .sheet(isPresented: $showSettings) {
                SettingsView(camera: camera)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .foregroundStyle(.white)
    }
}

/// Round button with a visible fill, so it reads as tappable; the whole 44 pt square responds.
struct TopBarButton: View {
    let symbol: String
    var caption: String? = nil
    var active = false
    var enabled = true
    let rotation: Angle
    var haptics = true
    let label: String
    let action: () -> Void

    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                if let caption {
                    Text(caption).font(.system(size: 12, weight: .bold, design: .rounded))
                }
            }
            .foregroundStyle(active ? Color.black : Color.white)
            .padding(.horizontal, caption == nil ? 0 : 10)
            .frame(minWidth: 38, minHeight: 38)
            .background(Capsule().fill(active ? Color.yellow : Color.white.opacity(0.16)))
            .rotationEffect(rotation)
            .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .sensoryFeedback(.impact(weight: .light), trigger: taps) { _, _ in haptics }
        .accessibilityLabel(label)
    }
}

/// "HEIF · Natural ▾": says what you'll capture; tap to change it.
struct FormatPill: View {
    let title: String
    var subtitle: String?
    let highlighted: Bool
    var haptics = true
    let action: () -> Void

    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            VStack(spacing: 1) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 9.5, weight: .semibold))
                        .opacity(0.65)
                }
            }
            .foregroundStyle(highlighted ? Color.black : Color.white)
            .padding(.horizontal, 14)
            .frame(minHeight: 38)
            .background(Capsule().fill(highlighted ? Color.yellow : Color.white.opacity(0.16)))
            .frame(minHeight: 44)
        }
        .buttonStyle(PressScaleStyle(scale: 0.95))
        .sensoryFeedback(.impact(weight: .light), trigger: taps) { _, _ in haptics }
        .accessibilityLabel(title)
        .accessibilityHint("Change format")
    }
}

enum CameraFormat {
    static func summary(_ s: CameraSettings) -> String {
        if s.mode == .video {
            return "\(s.videoResolution.label) · \(s.frameRate) · \(s.videoColor.label) · \(s.videoCodec.label)"
        }
        if s.developsBayerRAW {
            return s.processing == .zero ? "Zero · RAW" : "\(Look.named(s.captureLook)?.name ?? "Film") · RAW"
        }
        let file: String
        switch s.rawMode {
        case .off: file = s.photoFormat.label
        case .bayer: file = s.keepProcessedWithRAW ? "RAW+\(s.photoFormat.label)" : "RAW"
        case .proRAW: file = s.keepProcessedWithRAW ? "ProRAW+\(s.photoFormat.label)" : "ProRAW"
        }
        return "\(file) · \(s.processing.label)"
    }

    /// Highlight the pill when you've stepped beyond the defaults (RAW, Zero, Log/HDR, ProRes).
    static func isPro(_ s: CameraSettings) -> Bool {
        if s.mode == .video {
            return s.videoColor != .sdr || s.videoCodec == .proRes422HQ || s.videoCodec == .proRes422
        }
        return s.rawMode != .off || s.developsBayerRAW
    }

    static func timeLeft(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60)
        if m >= 60 { return "\(m / 60)h \(m % 60)m" }
        return m < 1 ? "<1 min" : "\(m) min"
    }
}

// MARK: - Format panels

/// Labelled choices for what a photo is saved as. Replaces tap-to-cycle badges.
struct CaptureFormatPanel: View {
    let camera: CameraController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let s = camera.settings
        VStack(alignment: .leading, spacing: 18) {
            PanelHeader(title: "Photo format") { dismiss() }

            PanelRow(title: "File type",
                     note: s.photoFormat == .heif ? "Smaller files, same quality." : "Most compatible.") {
                Picker("File type", selection: camera.binding(\.photoFormat)) {
                    ForEach(PhotoFormat.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .disabled(s.developsBayerRAW || (s.rawMode != .off && !s.keepProcessedWithRAW))

            PanelRow(title: "RAW", note: rawNote(s)) {
                Picker("RAW", selection: camera.binding(\.rawMode)) {
                    ForEach(rawOptions) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .disabled(s.developsBayerRAW || rawOptions.count < 2)

            if s.rawMode != .off && !s.developsBayerRAW {
                Toggle("Also save \(s.photoFormat.label)", isOn: camera.binding(\.keepProcessedWithRAW))
                    .font(.system(size: 14, weight: .semibold))
                    .tint(.yellow)
            }

            PanelRow(title: "Processing", note: s.processing.detail) {
                Picker("Processing", selection: camera.binding(\.processing)) {
                    ForEach(processingOptions) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(20)
        .sensoryFeedback(.selection, trigger: s) { _, _ in s.haptics }
        .preferredColorScheme(.dark)
    }

    private var rawOptions: [RawMode] {
        var options: [RawMode] = [.off]
        if camera.supportsBayerRAW { options.append(.bayer) }
        if camera.supportsProRAW { options.append(.proRAW) }
        return options
    }

    private var processingOptions: [ProcessingLevel] {
        var options: [ProcessingLevel] = [.apple, .balanced, .natural]
        if camera.supportsBayerRAW { options.append(.zero) }
        return options
    }

    private func rawNote(_ s: CameraSettings) -> String {
        if s.processing == .zero { return "Zero always shoots RAW." }
        if s.developsBayerRAW { return "The \(Look.named(s.captureLook)?.name ?? "film") filter develops from RAW, so it always shoots RAW." }
        if rawOptions.count < 2 { return "This lens doesn't offer RAW." }
        switch s.rawMode {
        case .off: return "Off: just the processed photo."
        case .bayer: return "The sensor's own data — maximum editing latitude."
        case .proRAW: return "Apple's RAW with its multi-frame processing."
        }
    }
}

struct VideoFormatPanel: View {
    let camera: CameraController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let s = camera.settings
        VStack(alignment: .leading, spacing: 18) {
            PanelHeader(title: "Video format") { dismiss() }

            PanelRow(title: "Resolution", note: nil) {
                Picker("Resolution", selection: camera.binding(\.videoResolution)) {
                    ForEach(VideoResolution.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            PanelRow(title: "Frame rate", note: s.shutterAngleLock ? "Shutter locks to 1/\(s.frameRate * 2) (180°)." : nil) {
                Picker("Frame rate", selection: camera.binding(\.frameRate)) {
                    ForEach(frameRates(s), id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
            }
            PanelRow(title: "Color", note: colorNote(s.videoColor)) {
                Picker("Color", selection: camera.binding(\.videoColor)) {
                    ForEach(camera.supportedColors) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            PanelRow(title: "Codec", note: nil) {
                Picker("Codec", selection: camera.binding(\.videoCodec)) {
                    ForEach(codecs(s)) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(20)
        .sensoryFeedback(.selection, trigger: s) { _, _ in s.haptics }
        .preferredColorScheme(.dark)
    }

    private func frameRates(_ s: CameraSettings) -> [Int] {
        var rates = camera.supportedFrameRates
        if !rates.contains(s.frameRate) { rates.append(s.frameRate) }
        return rates.sorted()
    }

    private func codecs(_ s: CameraSettings) -> [VideoCodec] {
        let available = camera.supportedCodecs.isEmpty ? [VideoCodec.hevc, .h264] : camera.supportedCodecs
        return available.filter { !(s.videoColor.isTenBit && $0 == .h264) }
    }

    private func colorNote(_ c: VideoColor) -> String {
        switch c {
        case .sdr: "Standard color. Plays everywhere."
        case .hlg: "HDR (HLG): bright highlights on HDR screens."
        case .appleLog: "Apple Log: flat, for color grading. Preview shows a 709 view."
        }
    }
}

struct PanelHeader: View {
    let title: String
    let done: () -> Void

    var body: some View {
        HStack {
            Text(title).font(.system(size: 17, weight: .bold))
            Spacer()
            Button("Done", action: done)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.yellow)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("format.done")
        }
    }
}

struct PanelRow<Content: View>: View {
    let title: String
    let note: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.55))
            content()
            if let note {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
