import SwiftUI

struct SettingsView: View {
    let camera: CameraController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let s = camera.settings
        NavigationStack {
            Form {
                photoSection(s)
                librarySection(s)
                videoSection(s)
                assistSection(s)
                controlsSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(.yellow)
    }

    // MARK: Library

    @ViewBuilder
    private func librarySection(_ s: CameraSettings) -> some View {
        Section {
            Toggle("Store New Photos Forever", isOn: camera.binding(\.storeForever))
                .accessibilityIdentifier("settings.storeForever")
            Text("When off, photos move to the Trash 30 days after they were taken unless you tag them Keep (the bookmark in the viewer). The Trash empties after another 30 days.")
                .font(.footnote).foregroundStyle(.secondary)
            Toggle("Auto Export", isOn: camera.binding(\.autoExport))
                .accessibilityIdentifier("settings.autoExport")
            Text("Saves every shot to Photos right after capture, rendered with its look. When off, nothing reaches Photos until you tap Export.")
                .font(.footnote).foregroundStyle(.secondary)
            Picker("Export format", selection: camera.binding(\.exportFormat)) {
                ForEach(ShotRenderer.ExportFormat.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Export size", selection: camera.binding(\.exportMaxSide)) {
                Text("1,920 px").tag(1920)
                Text("2,880 px").tag(2880)
                Text("3,840 px").tag(3840)
                Text("Actual Size").tag(0)
            }
            VStack(alignment: .leading) {
                Text("Export quality \(Int((s.exportQuality * 100).rounded()))%")
                Slider(value: camera.binding(\.exportQuality), in: 0.5...1, step: 0.05)
            }
        } header: {
            Text("Library")
        } footer: {
            Text("Every photo is kept in the app as a RAW with its look, so you can change the look any time. Export renders it into Photos.")
        }
    }

    // MARK: Photo

    @ViewBuilder
    private func photoSection(_ s: CameraSettings) -> some View {
        Section {
            Picker("RAW", selection: Binding(get: { s.shootsProRAW ? RawMode.proRAW : .bayer },
                                             set: { v in camera.update { $0.rawMode = v } })) {
                Text("Bayer RAW").tag(RawMode.bayer)
                Text("ProRAW").tag(RawMode.proRAW).disabled(!camera.supportsProRAW)
            }
            .pickerStyle(.segmented)
            Text(s.shootsProRAW
                 ? "Apple ProRAW: multi-frame, less noise, zoom works. Every look develops from it."
                 : "Bayer RAW: the sensor's own single frame, real grain and contrast. Zoom stays at 1×.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if s.shootsProRAW && camera.supportsMaxResolution {
                Picker("Resolution", selection: camera.binding(\.resolution)) {
                    ForEach(PhotoResolution.allCases) { Text($0.label).tag($0) }
                }
            }
            Picker("Flash", selection: camera.binding(\.flash)) {
                ForEach(FlashSetting.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }

            Picker("Print film look", selection: camera.binding(\.printPlacement)) {
                ForEach(PrintPlacement.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings.printPlacement")
            Text(s.printPlacement == .mode
                 ? "PHOTO · PRINT · VIDEO: Print is its own mode. It always shoots RAW, so it has no format or filter controls."
                 : "Print is one of the filters under FILTER, alongside Warm 400, Cine and the rest.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Picker("Self-timer", selection: camera.binding(\.selfTimer)) {
                ForEach(SelfTimer.allCases) { Text($0.label).tag($0) }
            }
        } header: {
            Text("Photo")
        }
    }

    // MARK: Video

    @ViewBuilder
    private func videoSection(_ s: CameraSettings) -> some View {
        Section {
            Picker("Resolution", selection: camera.binding(\.videoResolution)) {
                ForEach(VideoResolution.allCases) { Text($0.label).tag($0) }
            }
            Picker("Frame rate", selection: camera.binding(\.frameRate)) {
                ForEach(frameRates(s), id: \.self) { Text("\($0) fps").tag($0) }
            }
            Picker("Color", selection: camera.binding(\.videoColor)) {
                ForEach(VideoColor.allCases) { color in
                    Text(colorName(color)).tag(color)
                        .disabled(s.mode == .video && !camera.supportedColors.contains(color))
                }
            }
            Picker("Codec", selection: camera.binding(\.videoCodec)) {
                ForEach(VideoCodec.allCases) { codec in
                    Text(codec.label).tag(codec)
                        .disabled(!camera.supportedCodecs.contains(codec) || (s.videoColor.isTenBit && codec == .h264))
                }
            }
            Picker("Stabilization", selection: camera.binding(\.stabilization)) {
                ForEach(Stabilization.allCases) { mode in
                    Text(mode.label).tag(mode)
                        .disabled(s.mode == .video && !camera.supportedStabilization.contains(mode))
                }
            }
            Toggle("Record audio", isOn: camera.binding(\.recordAudio))
            Toggle("180° shutter", isOn: camera.binding(\.shutterAngleLock))
            if s.videoColor == .appleLog {
                Toggle("Log view assist (Rec.709 preview)", isOn: camera.binding(\.logViewAssist))
            }
        } header: {
            Text("Video")
        } footer: {
            Text("180° shutter locks the shutter at 1/(2 × fps) for natural motion blur and floats ISO to hold exposure. Apple Log needs an iPhone 15 Pro or later; ProRes depends on model and storage.")
        }
    }

    private func frameRates(_ s: CameraSettings) -> [Int] {
        var rates = camera.supportedFrameRates
        if !rates.contains(s.frameRate) { rates.append(s.frameRate) }
        return rates.sorted()
    }

    private func colorName(_ c: VideoColor) -> String {
        switch c {
        case .sdr: "SDR (Rec.709)"
        case .hlg: "HDR (HLG, Dolby Vision)"
        case .appleLog: "Apple Log"
        }
    }

    // MARK: Assists

    @ViewBuilder
    private func assistSection(_ s: CameraSettings) -> some View {
        Section("Assists") {
            Toggle("Grid", isOn: camera.binding(\.showGrid))
            Toggle("Level", isOn: camera.binding(\.showLevel))
            Toggle("Histogram", isOn: camera.binding(\.showHistogram))
            Toggle("Focus peaking", isOn: camera.binding(\.focusPeaking))
            if s.focusPeaking {
                Picker("Peaking color", selection: camera.binding(\.peakingColor)) {
                    ForEach(PeakingColor.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
            }
            Toggle("Zebras", isOn: camera.binding(\.zebras))
            if s.zebras {
                HStack {
                    Text("Threshold")
                    Slider(value: camera.binding(\.zebraThreshold), in: 0.7...1.0, step: 0.01)
                    Text("\(Int(s.zebraThreshold * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            Picker("Frame lines", selection: camera.binding(\.frameLines)) {
                ForEach(FrameLines.allCases) { Text($0.label).tag($0) }
            }
        }
    }

    private var controlsSection: some View {
        Section {
            Toggle("Save location (GPS)", isOn: camera.binding(\.saveLocation))
            Toggle("Volume buttons take photo", isOn: camera.binding(\.volumeShutter))
            Toggle("Haptics", isOn: camera.binding(\.haptics))
            // Where iOS can't mute it, the click always plays: show that honestly.
            let canMute = camera.canSilenceShutter || TestHooks.isUITest
            Toggle("Shutter sound", isOn: canMute ? camera.binding(\.shutterSound) : .constant(true))
                .disabled(!canMute)
        } header: {
            Text("Controls")
        } footer: {
            Text((camera.canSilenceShutter || TestHooks.isUITest
                  ? "The shutter is silent unless you turn Shutter sound on. "
                  : "This iPhone or region doesn't let apps mute the shutter (it needs iOS 18, and some countries require the click); the Ring/Silent switch still mutes it. ") + "Location uses the GPS chip and compass, so it works in airplane mode — the first fix can take a minute without signal, and works best outdoors. Tap the location icon in the top bar to see accuracy. Tap to focus and meter. Hold to lock AE/AF. Pinch to zoom. Swipe the viewfinder to switch Photo/Video. On iPhone 16, Camera Control adjusts zoom and exposure.")
        }
    }

    /// Which build is on the phone, and the development log to share with a bug report.
    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Diag.buildDescription)
            NavigationLink("Diagnostics") { DiagnosticsView() }
                .accessibilityIdentifier("settings.diagnostics")
        } header: {
            Text("About")
        } footer: {
            Text("Diagnostics is a log of what the app did and what went wrong. Share it with a bug report.")
        }
    }
}
