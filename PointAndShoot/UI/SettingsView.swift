import SwiftUI

struct SettingsView: View {
    let camera: CameraController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let s = camera.settings
        NavigationStack {
            Form {
                photoSection(s)
                videoSection(s)
                assistSection(s)
                controlsSection
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

    // MARK: Photo

    @ViewBuilder
    private func photoSection(_ s: CameraSettings) -> some View {
        Section {
            Picker("Processing", selection: camera.binding(\.processing)) {
                ForEach(ProcessingLevel.allCases) { level in
                    Text(level.label).tag(level)
                        .disabled(level == .zero && !camera.supportsBayerRAW)
                }
            }
            .pickerStyle(.segmented)
            Text(s.processing.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if s.processing == .zero {
                Toggle("Keep the DNG too", isOn: camera.binding(\.zeroKeepsDNG))
            } else {
                Picker("RAW", selection: camera.binding(\.rawMode)) {
                    Text("Off").tag(RawMode.off)
                    Text("RAW").tag(RawMode.bayer).disabled(!camera.supportsBayerRAW)
                    Text("ProRAW").tag(RawMode.proRAW).disabled(!camera.supportsProRAW)
                }
                if s.rawMode != .off {
                    Toggle("Also save \(s.photoFormat.label)", isOn: camera.binding(\.keepProcessedWithRAW))
                    if s.rawMode == .bayer && s.keepProcessedWithRAW {
                        Text("Bayer RAW is a single, unfused frame, so its companion \(s.photoFormat.label) uses Natural processing.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }

            Picker("Format", selection: camera.binding(\.photoFormat)) {
                ForEach(PhotoFormat.allCases) { Text($0.label).tag($0) }
            }
            if camera.supportsMaxResolution {
                Picker("Resolution", selection: camera.binding(\.resolution)) {
                    ForEach(PhotoResolution.allCases) { Text($0.label).tag($0) }
                }
            }
            Picker("Flash", selection: camera.binding(\.flash)) {
                ForEach(FlashSetting.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
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
            Toggle("Pro controls (focus, WB, ISO, shutter)", isOn: camera.binding(\.proControls))
            Toggle("Save location (GPS)", isOn: camera.binding(\.saveLocation))
            Toggle("Volume buttons take photo", isOn: camera.binding(\.volumeShutter))
            Toggle("Haptics", isOn: camera.binding(\.haptics))
        } header: {
            Text("Controls")
        } footer: {
            Text("Location uses the GPS chip and compass, so it works in airplane mode — the first fix can take a minute without signal, and works best outdoors. Tap the location icon in the top bar to see accuracy. Tap to focus and meter. Hold to lock AE/AF. Pinch to zoom. Swipe the viewfinder to switch Photo/Video. On iPhone 16, Camera Control adjusts zoom and exposure.")
        }
    }
}
