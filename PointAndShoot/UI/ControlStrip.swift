import SwiftUI

enum DialKind: String, CaseIterable, Identifiable {
    case focus, wb, iso, shutter, ev, look
    var id: String { rawValue }
}

/// The row of exposure readouts. Yellow = you're in control; white = the camera is.
struct ControlStrip: View {
    let camera: CameraController
    @Binding var active: DialKind?

    /// Any pro control currently off automatic (shown as a dot on PRO when collapsed).
    private var manualActive: Bool {
        camera.focusMode != .auto || camera.whiteBalance != .auto || camera.exposureMode != .auto
    }

    var body: some View {
        let pro = camera.settings.proControls
        HStack(spacing: 2) {
            if pro {
                item(.focus, title: "FOCUS", value: focusText,
                     manual: camera.focusMode != .auto, enabled: camera.supportsManualFocus)
                item(.wb, title: "WB", value: wbText,
                     manual: camera.whiteBalance != .auto, enabled: camera.supportsCustomWB)
                item(.iso, title: "ISO", value: "\(Int(camera.iso.rounded()))",
                     manual: camera.exposureMode == .manual, enabled: camera.supportsCustomExposure)
                item(.shutter, title: "SHUTTER", value: Stops.shutterLabel(camera.shutter),
                     manual: camera.exposureMode != .auto, enabled: camera.supportsCustomExposure)
            }
            item(.ev, title: camera.exposureMode == .manual ? "METER" : "EV",
                 value: camera.exposureMode == .manual ? Stops.evLabel(camera.meterOffset) : Stops.evLabel(camera.exposureBias),
                 manual: camera.exposureBias != 0, enabled: camera.exposureMode != .manual)
            if camera.settings.mode == .photo {
                item(.look, title: "FILTER", value: Look.named(camera.settings.captureLook)?.name ?? "Off",
                     manual: camera.settings.captureLook != nil, enabled: true)
            }
            proToggle(expanded: pro)
        }
        .padding(.horizontal, 10)
        .animation(.snappy(duration: 0.25), value: pro)
    }

    /// Progressive disclosure: the manual controls are one tap away, not always in the way.
    private func proToggle(expanded: Bool) -> some View {
        Button {
            camera.haptic(.light)
            withAnimation(.snappy(duration: 0.25)) {
                if expanded, let kind = active, [.focus, .wb, .iso, .shutter].contains(kind) { active = nil }
                camera.update { $0.proControls.toggle() }
            }
        } label: {
            VStack(spacing: 2) {
                Text("PRO")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(expanded ? Color.yellow : .white.opacity(0.5))
                Image(systemName: expanded ? "chevron.right" : "slider.horizontal.3")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(expanded || manualActive ? Color.yellow : Color.white)
            }
            .frame(width: 44, height: 44)
            .overlay(alignment: .topTrailing) {
                if !expanded && manualActive {
                    Circle().fill(Color.yellow).frame(width: 6, height: 6).offset(x: -6, y: 6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle(scale: 0.9))
        .accessibilityIdentifier("strip.pro")
        .accessibilityLabel(expanded ? "Hide pro controls" : "Show pro controls")
    }

    private var focusText: String {
        switch camera.focusMode {
        case .manual: String(format: "%.2f", camera.lensPosition)
        case .locked: "LOCK"
        case .auto: "AF"
        }
    }

    private var wbText: String {
        switch camera.whiteBalance {
        case .auto: "A \(Int((camera.measuredKelvin / 100).rounded()) * 100)K"
        case .kelvin(let k): "\(Int(k))K"
        }
    }

    private func item(_ kind: DialKind, title: String, value: String, manual: Bool, enabled: Bool) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { active = active == kind ? nil : kind }
        } label: {
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.5))
                Text(value)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(manual ? Color.yellow : Color.white)
                    .contentTransition(.numericText())
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(active == kind ? Color.white.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(PressScaleStyle(scale: 0.94))
        // Double-tap any control to put it back on automatic.
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            camera.resetToAuto(kind)
            withAnimation(.snappy(duration: 0.2)) { active = nil }
            camera.haptic(.medium)
            camera.toast = kind == .look ? "Filter off" : "\(title.capitalized) → Auto"
        })
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityIdentifier("strip.\(kind.rawValue)")
        .accessibilityHint("Double-tap to reset to automatic")
    }
}

struct DialPanel: View {
    let kind: DialKind
    let camera: CameraController
    @State private var thumbnails: [String: UIImage] = [:]
    @State private var showGuide = false

    private static let fullISO: Set<Float> = [25, 50, 100, 200, 400, 800, 1600, 3200, 6400, 12800]
    private static let fullShutter: [Double] = [1.0 / 8000, 1.0 / 4000, 1.0 / 2000, 1.0 / 1000, 1.0 / 500, 1.0 / 250,
                                                1.0 / 125, 1.0 / 60, 1.0 / 30, 1.0 / 15, 1.0 / 8, 1.0 / 4, 0.5, 1]

    var body: some View {
        HStack(spacing: 10) {
            Button(action: resetToAuto) {
                Text("A")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(isAuto ? Color.yellow : Color.white.opacity(0.15)))
                    .foregroundStyle(isAuto ? Color.black : Color.white)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("dial.auto")
            dial
        }
        .padding(.horizontal, 12)
    }

    private var isAuto: Bool {
        switch kind {
        case .focus: camera.focusMode != .manual
        case .wb: camera.whiteBalance == .auto
        case .iso: camera.exposureMode != .manual
        case .shutter: camera.exposureMode == .auto
        case .ev: camera.exposureBias == 0
        case .look: camera.settings.captureLook == nil
        }
    }

    private func resetToAuto() {
        camera.haptic(.light)
        camera.resetToAuto(kind)
    }

    /// Square live previews of each filter, like a social camera's filter strip, plus a
    /// guide that explains every filter.
    private var filterStrip: some View {
        HStack(spacing: 6) {
            filterCards
            // Always visible (not scrolled away at the end of the strip).
            Button { showGuide = true } label: {
                VStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 44, height: 50)
                        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text("About").font(.system(size: 10, weight: .semibold))
                }
                .frame(width: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle(scale: 0.94))
            .accessibilityIdentifier("filter.info")
            .accessibilityLabel("About filters")
        }
        // Refresh the previews from the live camera every couple of seconds while open.
        .task {
            while !Task.isCancelled {
                camera.renderer.filterThumbnails(side: 120) { thumbnails = $0 }
                try? await Task.sleep(for: .seconds(TestHooks.isUITest ? 3600 : 2))
            }
        }
        .sheet(isPresented: $showGuide) {
            FilterGuide(thumbnails: thumbnails, selectedID: camera.settings.captureLook) { id in
                camera.setCaptureLook(id)
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var filterCards: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Look.all.filter { $0.id != "none" }) { look in
                        let selected = camera.settings.captureLook == look.id
                        Button {
                            camera.haptic(.light)
                            camera.setCaptureLook(selected ? nil : look.id)
                        } label: {
                            VStack(spacing: 4) {
                                FilterSwatch(image: thumbnails[look.id], selected: selected, side: 50)
                                Text(look.name)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(selected ? Color.yellow : Color.white)
                                    .lineLimit(1)
                            }
                            .frame(width: 58)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressScaleStyle(scale: 0.94))
                        .id(look.id)
                        .accessibilityIdentifier("filter.\(look.id)")
                        .accessibilityLabel(look.name)
                    }
                }
                .padding(.horizontal, 4)
            }
            .onAppear {
                if let id = camera.settings.captureLook { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private var dial: some View {
        switch kind {
        case .iso:
            let values = Stops.iso.filter { camera.isoRange.contains($0) }
            if values.isEmpty {
                Spacer()
            } else {
                ScrubDial(count: values.count,
                          index: Stops.nearestIndex(camera.iso, in: values, logScale: true),
                          label: { Self.fullISO.contains(values[$0]) ? "\(Int(values[$0]))" : nil },
                          onChange: { camera.setISO(values[$0]) })
            }
        case .shutter:
            let values = Stops.shutter.filter { camera.shutterRange.contains($0) }
            if values.isEmpty {
                Spacer()
            } else {
                ScrubDial(count: values.count,
                          index: Stops.nearestIndex(camera.shutter, in: values, logScale: true),
                          label: { i in
                              let v = values[i]
                              return Self.fullShutter.contains { abs($0 - v) / v < 0.02 } ? Stops.shutterLabel(v) : nil
                          },
                          onChange: { camera.setShutter(values[$0]) })
            }
        case .ev:
            let values = Stops.ev
            ScrubDial(count: values.count,
                      index: Stops.nearestIndex(camera.exposureBias, in: values),
                      label: { i in
                          let v = values[i]
                          return abs(v - v.rounded()) < 0.01 ? (v == 0 ? "0" : String(format: "%+.0f", v)) : nil
                      },
                      onChange: { camera.setExposureBias(values[$0]) })
        case .wb:
            let values = Stops.kelvin
            let current: Float = {
                if case .kelvin(let k) = camera.whiteBalance { return k }
                return camera.measuredKelvin
            }()
            ScrubDial(count: values.count,
                      index: Stops.nearestIndex(current, in: values),
                      label: { i in Int(values[i]) % 1000 == 0 ? "\(Int(values[i]) / 1000)K" : nil },
                      onChange: { camera.setWhiteBalance(.kelvin(values[$0])) },
                      accent: .orange)
        case .look:
            filterStrip
        case .focus:
            ScrubDial(count: 101,
                      index: Int((camera.lensPosition * 100).rounded()),
                      label: { i in
                          if i == 0 { return "NEAR" }
                          if i == 100 { return "∞" }
                          return i % 20 == 0 ? String(format: "%.1f", Double(i) / 100) : nil
                      },
                      onChange: { camera.setManualFocus(Float($0) / 100) },
                      accent: .green)
        }
    }
}
