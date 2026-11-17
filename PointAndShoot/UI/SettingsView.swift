import SwiftUI
import UniformTypeIdentifiers

/// Preferences, Chromagraph-style: General · Camera · Processing, each option explained in
/// a line or two (including what it doesn't affect). Opens from the gear or a double-tap on
/// the viewfinder.
struct SettingsView: View {
    let camera: CameraController
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .general
    @AppStorage("hints.v1.seen") private var hintsSeen = false
    @State private var showLockScreenHelp = false
    @State private var showRAWPicker = false
    @State private var showArchivePicker = false
    @State private var importing = false
    @State private var importMessage: String?
    @State private var confirmReset: ResetKind?

    enum Tab: String, CaseIterable, Identifiable {
        case general, camera, processing
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    enum ResetKind: Identifiable {
        case general, camera, export, grade
        var id: Self { self }
    }

    var body: some View {
        let s = camera.settings
        NavigationStack {
            Form {
                Section {
                    Picker("Section", selection: $tab) {
                        ForEach(Tab.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("settings.tabs")
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))

                switch tab {
                case .general: general(s)
                case .camera: cameraTab(s)
                case .processing: processing(s)
                }

                Section {} footer: {
                    Text("Point & Shoot \(Diag.buildDescription)")
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Preferences")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
            .background {
                Color.clear.sheet(isPresented: $showLockScreenHelp) { LockScreenHelp() }
                Color.clear.sheet(isPresented: $showRAWPicker) {
                    RAWPicker { results in
                        showRAWPicker = false
                        guard !results.isEmpty else { return }
                        importing = true
                        Task {
                            let grade = camera.settings.defaultGrade ?? EditRecipe()
                            let r = await ShotArchive.importPicked(results, store: ShotStore.shared, grade: grade)
                            importing = false
                            importMessage = r.summary
                        }
                    }
                    .ignoresSafeArea()
                }
                Color.clear.fileImporter(isPresented: $showArchivePicker, allowedContentTypes: [.zip]) { result in
                    guard case .success(let url) = result else { return }
                    importing = true
                    Task {
                        do {
                            let r = try await ShotArchive.importZip(at: url, store: ShotStore.shared)
                            importMessage = r.summary
                        } catch {
                            importMessage = error.localizedDescription
                        }
                        importing = false
                    }
                }
                Color.clear.alert("Import", isPresented: Binding(get: { importMessage != nil },
                                                                 set: { if !$0 { importMessage = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(importMessage ?? "")
                }
            }
            .confirmationDialog(resetTitle, isPresented: Binding(get: { confirmReset != nil },
                                                                  set: { if !$0 { confirmReset = nil } }),
                                titleVisibility: .visible) {
                Button("Reset", role: .destructive) { if let kind = confirmReset { reset(kind) } }
            }
        }
        .tint(.tan)
        .preferredColorScheme(.dark)
    }

    // MARK: General

    @ViewBuilder
    private func general(_ s: CameraSettings) -> some View {
        Section {
            Toggle("Store New Photos Forever", isOn: camera.binding(\.storeForever))
                .accessibilityIdentifier("settings.storeForever")
        } header: {
            Text("RAW File Storage")
        } footer: {
            Text("When off, photos move to the Trash 30 days after they were taken unless you tag them Keep (the bookmark in the viewer). The Trash empties itself after another 30 days. Photos you exported stay in Photos either way.")
        }
        Section {
            Toggle("Auto Export", isOn: camera.binding(\.autoExport))
                .accessibilityIdentifier("settings.autoExport")
        } header: {
            Text("Auto Export to Photo Library")
        } footer: {
            Text("Renders every shot right after capture with its look and saves it to your Photo Library. When off, nothing reaches Photos until you tap Export.")
        }
        Section {
            Toggle("Geotag Photos", isOn: camera.binding(\.saveLocation))
        } header: {
            Text("Location")
        } footer: {
            Text("Records where a photo was taken into its RAW file and carries it through to anything you export or share. Uses the GPS chip and compass, so it works in airplane mode; the first fix can take a minute without signal.")
        }
        Section {
            Button {
                showRAWPicker = true
            } label: {
                HStack {
                    Text("Import RAW Photos…")
                    Spacer()
                    if importing { ProgressView() } else { Image(systemName: "square.and.arrow.down") }
                }
            }
            .disabled(importing)
            .accessibilityIdentifier("settings.importRAW")
        } header: {
            Text("Import from Photos")
        } footer: {
            Text("Choose RAW files from your Photo Library to copy into Point & Shoot's library, with your default grade. The originals stay where they are.")
        }
        Section {
            Button {
                showArchivePicker = true
            } label: {
                HStack {
                    Text("Import Archive…")
                    Spacer()
                    Image(systemName: "archivebox")
                }
            }
            .disabled(importing)
            .accessibilityIdentifier("settings.importArchive")
        } header: {
            Text("Import Archive")
        } footer: {
            Text("Brings back a zip made with Archive RAW… in the grid, with each photo's grade. Photos already in your library are skipped.")
        }
        Section {
            Button("Lock Screen Camera Setup…") { showLockScreenHelp = true }
        } header: {
            Text("Lock Screen")
        } footer: {
            Text("Open Point & Shoot from the Lock Screen, the Action button or Control Center. Lock Screen shots move into the library the next time you open the app.")
        }
        Section {
            Button("Show Introduction") {
                hintsSeen = false
                dismiss()
            }
            LabeledContent("Version", value: Diag.buildDescription)
            NavigationLink("Diagnostics") { DiagnosticsView() }
                .accessibilityIdentifier("settings.diagnostics")
        } header: {
            Text("Help")
        } footer: {
            Text("Diagnostics is a log of what the app did and what went wrong. Share it with a bug report.")
        }
        Section {
            Button("Reset General Settings", role: .destructive) { confirmReset = .general }
        } footer: {
            Text("Factory settings for RAW storage, auto export and geotagging.")
        }
    }

    // MARK: Camera

    @ViewBuilder
    private func cameraTab(_ s: CameraSettings) -> some View {
        Section {
            Picker("RAW", selection: Binding(get: { s.shootsProRAW ? RawMode.proRAW : .bayer },
                                             set: { v in camera.update { $0.rawMode = v } })) {
                Text("Bayer RAW").tag(RawMode.bayer)
                Text("ProRAW").tag(RawMode.proRAW).disabled(!camera.supportsProRAW)
            }
            .pickerStyle(.segmented)
            if s.shootsProRAW && camera.supportsMaxResolution {
                Picker("Resolution", selection: camera.binding(\.resolution)) {
                    ForEach(PhotoResolution.allCases) { Text($0.label).tag($0) }
                }
            }
        } header: {
            Text("RAW Format")
        } footer: {
            Text(s.shootsProRAW
                 ? "Apple ProRAW: several frames merged, less noise, and zoom works. Every look develops from it."
                 : "Bayer RAW: the sensor's own single frame, with real grain and contrast. Zoom stays at 1× (the full sensor is recorded).")
        }
        Section {
            Picker("Print film look", selection: camera.binding(\.printPlacement)) {
                ForEach(PrintPlacement.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings.printPlacement")
            Picker("Self-timer", selection: camera.binding(\.selfTimer)) {
                ForEach(SelfTimer.allCases) { Text($0.label).tag($0) }
            }
            Picker("Flash", selection: camera.binding(\.flash)) {
                ForEach(FlashSetting.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
        } header: {
            Text("Shooting")
        } footer: {
            Text(s.printPlacement == .mode
                 ? "PHOTO · PRINT · VIDEO: Print is its own mode."
                 : "Print is one of the looks in Photo mode.")
        }
        Section {
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
        } header: {
            Text("Viewfinder")
        } footer: {
            Text("Frame lines show a crop over the viewfinder; the whole sensor frame is always recorded.")
        }
        Section {
            Toggle("Volume buttons take photo", isOn: camera.binding(\.volumeShutter))
            Toggle("Haptics", isOn: camera.binding(\.haptics))
            // Where iOS can't mute it, the click always plays: show that honestly.
            let canMute = camera.canSilenceShutter || TestHooks.isUITest
            Toggle("Shutter sound", isOn: canMute ? camera.binding(\.shutterSound) : .constant(true))
                .disabled(!canMute)
        } header: {
            Text("Controls & Sound")
        } footer: {
            Text((camera.canSilenceShutter || TestHooks.isUITest
                  ? "The shutter is silent unless you turn Shutter sound on. "
                  : "This iPhone or region doesn't let apps mute the shutter (it needs iOS 18, and some countries require the click); the Ring/Silent switch still mutes it. ")
                 + "Tap to focus and meter, hold to lock AE/AF, drag up or down for exposure, swipe sideways to change mode, double-tap for Preferences.")
        }
        videoSection(s)
        Section {
            Button("Reset Camera Settings", role: .destructive) { confirmReset = .camera }
        } footer: {
            Text("Factory settings for RAW format, shooting, viewfinder, controls and video. Your library, export options and default grade aren't touched.")
        }
    }

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
            Text("Videos are saved straight to Photos. 180° shutter locks the shutter at 1/(2 × fps) for natural motion blur and floats ISO to hold exposure. Apple Log needs an iPhone 15 Pro or later; ProRes depends on model and storage.")
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

    // MARK: Processing

    @ViewBuilder
    private func processing(_ s: CameraSettings) -> some View {
        Section {
            Picker("Format", selection: camera.binding(\.exportFormat)) {
                ForEach(ShotRenderer.ExportFormat.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Export Size", selection: camera.binding(\.exportMaxSide)) {
                Text("1,920 px").tag(1920)
                Text("2,880 px").tag(2880)
                Text("3,840 px").tag(3840)
                Text("Actual Size").tag(0)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Export Quality")
                    Spacer()
                    Text("\(Int((s.exportQuality * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: camera.binding(\.exportQuality), in: 0.5...1, step: 0.05)
            }
            Button("Reset to Defaults") { reset(.export) }
                .disabled(s.exportFormat == .heif && s.exportMaxSide == 2880 && s.exportQuality == 1)
        } header: {
            Text("Export Options")
        } footer: {
            Text("For every export and share. Export Size is the longest side; Actual Size keeps each photo's own (cropped) resolution.")
        }
        DefaultGradeSection(camera: camera)
    }

    // MARK: Resets

    private var resetTitle: String {
        switch confirmReset {
        case .general: "Reset General Settings?"
        case .camera: "Reset Camera Settings?"
        default: "Reset?"
        }
    }

    private func reset(_ kind: ResetKind) {
        let fresh = CameraSettings()
        camera.update { s in
            switch kind {
            case .general:
                s.storeForever = fresh.storeForever
                s.autoExport = fresh.autoExport
                s.saveLocation = fresh.saveLocation
            case .camera:
                var next = fresh
                // Keep the library, export and grade settings, and the mode/lens you're on.
                next.storeForever = s.storeForever
                next.autoExport = s.autoExport
                next.saveLocation = s.saveLocation
                next.exportFormat = s.exportFormat
                next.exportMaxSide = s.exportMaxSide
                next.exportQuality = s.exportQuality
                next.defaultGrade = s.defaultGrade
                next.captureLook = s.captureLook
                next.mode = s.mode
                next.lastLensID = s.lastLensID
                s = next
            case .export:
                s.exportFormat = fresh.exportFormat
                s.exportMaxSide = fresh.exportMaxSide
                s.exportQuality = fresh.exportQuality
            case .grade:
                s.defaultGrade = nil
            }
        }
        Haptics.success()
    }
}

/// The grade every new photo starts with: a look plus Tone, Color and Texture sliders, the
/// same ones as the editor. It's also what the editor's "Reset This Image" restores.
struct DefaultGradeSection: View {
    let camera: CameraController
    @State private var open: Set<String> = []

    private var base: EditRecipe {
        camera.settings.defaultGrade ?? Look.named(camera.settings.captureLook)?.recipe ?? EditRecipe()
    }

    private func binding(_ kp: WritableKeyPath<EditRecipe, Double>) -> Binding<Double> {
        Binding(get: { base[keyPath: kp] },
                set: { v in
                    var g = base
                    g[keyPath: kp] = v
                    camera.update { $0.defaultGrade = g }
                })
    }

    private func slider(_ id: String) -> some View {
        let a = Adjustment.catalog[id]!
        let fallback = id == "grain" && base.film != nil ? FilmRecipe.defaultGrain : EditRecipe()[keyPath: a.keyPath]
        return GradeSlider(adjustment: a, value: binding(a.keyPath), defaultValue: fallback)
            .padding(.vertical, 2)
    }

    private func group<Content: View>(_ id: String, _ title: String, summary: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        DisclosureGroup(isExpanded: Binding(get: { open.contains(id) },
                                            set: { if $0 { open.insert(id) } else { open.remove(id) } })) {
            content()
        } label: {
            HStack {
                Text(title)
                Spacer()
                Text(summary).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    var body: some View {
        let g = base
        Section {
            Picker("Look", selection: Binding(get: { g.look ?? "none" },
                                              set: { id in
                                                  let look = Look.all.first { $0.id == id } ?? Look.all[0]
                                                  camera.update {
                                                      $0.defaultGrade = look.recipe
                                                      $0.captureLook = look.id == "none" ? nil : look.id
                                                  }
                                              })) {
                ForEach(Look.all) { Text($0.name).tag($0.id) }
            }
            .accessibilityIdentifier("settings.defaultLook")
            group("tone", "Tone", summary: String(format: "%+.1f Stops · Contrast %d", g.exposure / 50, Int(g.contrast))) {
                slider("exposure")
                slider("contrast")
                slider("highlights")
                slider("shadows")
            }
            group("color", "Color", summary: "Warmth \(Int(g.warmth)) · Sat \(Int(g.saturation))") {
                slider("warmth")
                slider("tint")
                slider("saturation")
                Toggle("B&W", isOn: Binding(get: { g.mono }, set: { v in
                    var next = g
                    next.mono = v
                    camera.update { $0.defaultGrade = next }
                }))
                if g.film != nil { slider("crossover") }
            }
            group("texture", "Texture", summary: "Grain \(Int(g.grain))\(g.film != nil ? " · Halation \(Int(g.filmHalation))" : "")") {
                slider("grain")
                if g.film != nil { slider("halation") }
                slider("vignette")
            }
            Button("Reset to Defaults") { camera.update { $0.defaultGrade = nil } }
                .disabled(camera.settings.defaultGrade == nil)
        } header: {
            Text("Default Grade")
        } footer: {
            Text("The look and settings every new photo starts with, and what the editor's Reset This Image restores. Picking another look in the camera starts from that look instead. Changing this doesn't affect photos you've already taken.")
        }
    }
}

/// How to reach the camera without unlocking.
private struct LockScreenHelp: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Lock Screen") {
                    Text("Touch and hold the Lock Screen, tap Customize, then Lock Screen. Tap a bottom control, remove the default, and pick Point & Shoot → Camera.")
                }
                Section("Control Center") {
                    Text("Open Control Center, tap +, then Add a Control, and pick Point & Shoot → Camera (or Record Video).")
                }
                Section("Action Button") {
                    Text("Settings → Action Button → Controls → Point & Shoot → Camera.")
                }
                Section {
                    Text("Lock Screen shots are RAW and wait until you open the app, then move into the library with your default look.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Lock Screen Camera")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }
}
