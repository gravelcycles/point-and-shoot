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
    /// The dropdown open under the bar (Chromagraph's: labelled rows of choices).
    @State private var panel: TopPanel?

    enum TopPanel { case flash, timer }

    var body: some View {
        let s = camera.settings
        let haptics = s.haptics
        HStack(spacing: 8) {
            if s.mode.isStill {
                // Each opens a dropdown of its choices: nothing cycles blindly.
                TopBarButton(symbol: s.flash.symbol, active: s.flash != .off || panel == .flash,
                             enabled: camera.supportsFlash, rotation: rotation, haptics: haptics,
                             label: "Flash \(s.flash.rawValue)") { toggle(.flash) }
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
            } else if s.mode != .print {
                // Print mode has nothing to choose here: it always shoots RAW.
                FormatPill(title: CameraFormat.summary(s),
                           subtitle: s.mode == .video ? camera.recordingTimeLeft.map { CameraFormat.timeLeft($0) + " left" } : nil,
                           highlighted: CameraFormat.isPro(s),
                           haptics: haptics) {
                    showFormat = true
                }
                .accessibilityIdentifier(s.mode == .photo ? "topbar.format" : "topbar.videoformat")
            }

            Spacer(minLength: 4)

            if s.mode.isStill {
                TopBarButton(symbol: "timer", caption: s.selfTimer == .off ? nil : s.selfTimer.label,
                             active: s.selfTimer != .off || panel == .timer, rotation: rotation,
                             haptics: haptics, label: "Self-timer") { toggle(.timer) }
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
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
        .foregroundStyle(.white)
        .overlay(alignment: .top) {
            if let panel, s.mode.isStill, !camera.isRecording {
                ZStack(alignment: .top) {
                    // A tap anywhere else closes it (and doesn't focus the viewfinder).
                    Color.white.opacity(0.001)
                        .frame(height: 1600)
                        .padding(.horizontal, -12)
                        .onTapGesture { close() }
                        .accessibilityHidden(true)
                    dropdown(panel, s)
                        .padding(.top, 50)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
            }
        }
        .onChange(of: camera.settings.mode) { _, _ in panel = nil }
        .onChange(of: camera.isRecording) { _, _ in panel = nil }
    }

    private func toggle(_ p: TopPanel) {
        withAnimation(.snappy(duration: 0.2)) { panel = panel == p ? nil : p }
    }

    private func close() {
        withAnimation(.snappy(duration: 0.2)) { panel = nil }
    }

    @ViewBuilder
    private func dropdown(_ p: TopPanel, _ s: CameraSettings) -> some View {
        switch p {
        case .flash:
            DropdownPanel {
                DropdownRow(title: "Flash", id: "flash", options: FlashSetting.allCases.map { ($0, $0.menuLabel) },
                            selection: s.flash, haptics: s.haptics) { v in
                    camera.update { $0.flash = v }
                    closeSoon()
                }
            }
        case .timer:
            DropdownPanel {
                DropdownRow(title: "Timer", id: "timer", options: SelfTimer.allCases.map { ($0, $0.label) },
                            selection: s.selfTimer, haptics: s.haptics) { v in
                    camera.update { $0.selfTimer = v }
                    closeSoon()
                }
            }
        }
    }

    /// After a pick, long enough to see it land.
    private func closeSoon() {
        let open = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if panel == open { close() }
        }
    }
}

/// The dark rounded card a top-bar dropdown sits in.
struct DropdownPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .environment(\.colorScheme, .dark)
    }
}

/// "TIMER   [Off] [3s] [10s]": a label and pill choices, the current one tan.
struct DropdownRow<Value: Hashable>: View {
    let title: String
    /// For accessibility identifiers: `<id>.<index>`.
    let id: String
    let options: [(Value, String)]
    let selection: Value
    var haptics = true
    let onPick: (Value) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 13, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 64, alignment: .leading)
            ForEach(options.indices, id: \.self) { i in
                let value = options[i].0
                let label = options[i].1
                let on = value == selection
                Button {
                    if haptics { Haptics.selectionChanged() }
                    onPick(value)
                } label: {
                    Text(label)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(on ? Color.black : Color.white)
                        .frame(width: 62, height: 36)
                        .background(Capsule().fill(on ? Color.tan : Color.white.opacity(0.14)))
                }
                .buttonStyle(PressScaleStyle(scale: 0.92))
                .accessibilityIdentifier("\(id).\(i)")
                .accessibilityLabel(label)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
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
        let look = Look.named(s.activeLook)?.name
        return [s.shootsProRAW ? "ProRAW" : "RAW", look].compactMap { $0 }.joined(separator: " · ")
    }

    /// Highlight the pill when you've stepped beyond the defaults (RAW, Zero, Log/HDR, ProRes).
    static func isPro(_ s: CameraSettings) -> Bool {
        if s.mode == .video {
            return s.videoColor != .sdr || s.videoCodec == .proRes422HQ || s.videoCodec == .proRes422
        }
        return s.shootsProRAW
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

            PanelRow(title: "RAW", note: rawNote(s)) {
                Picker("RAW", selection: Binding(get: { s.shootsProRAW ? RawMode.proRAW : .bayer },
                                                 set: { v in camera.update { $0.rawMode = v } })) {
                    ForEach([RawMode.proRAW, .bayer]) { mode in
                        Text(mode.choice).tag(mode)
                            .disabled(mode == .proRAW && !camera.supportsProRAW && !TestHooks.isUITest)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(s.mode == .print)
            }

            PanelRow(title: "Resolution", note: s.shootsProRAW ? "ProRAW at the sensor's full resolution, or 12 MP." : "Bayer RAW is always the sensor's 12 MP frame.") {
                Picker("Resolution", selection: camera.binding(\.resolution)) {
                    ForEach(PhotoResolution.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .disabled(!s.shootsProRAW)
        }
        .padding(20)
        .sensoryFeedback(.selection, trigger: s) { _, _ in s.haptics }
        .preferredColorScheme(.dark)
    }

    private func rawNote(_ s: CameraSettings) -> String {
        s.mode == .print
            ? "Print always shoots ProRAW: cleaner, and what Print was matched on. Zoom works."
            : (s.shootsProRAW ? RawMode.proRAW : .bayer).tradeoff
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
