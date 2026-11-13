import SwiftUI

enum DialKind: String, CaseIterable, Identifiable {
    case focus, wb, iso, shutter, ev, look
    var id: String { rawValue }
}

/// The row of exposure readouts. Yellow = you're in control; white = the camera is.
struct ControlStrip: View {
    let camera: CameraController
    @Binding var active: DialKind?

    var body: some View {
        HStack(spacing: 2) {
            item(.focus, title: "FOCUS", value: focusText,
                 manual: camera.focusMode != .auto, enabled: camera.supportsManualFocus)
            item(.wb, title: "WB", value: wbText,
                 manual: camera.whiteBalance != .auto, enabled: camera.supportsCustomWB)
            item(.iso, title: "ISO", value: "\(Int(camera.iso.rounded()))",
                 manual: camera.exposureMode == .manual, enabled: camera.supportsCustomExposure)
            item(.shutter, title: "SHUTTER", value: Stops.shutterLabel(camera.shutter),
                 manual: camera.exposureMode != .auto, enabled: camera.supportsCustomExposure)
            item(.ev, title: camera.exposureMode == .manual ? "METER" : "EV",
                 value: camera.exposureMode == .manual ? Stops.evLabel(camera.meterOffset) : Stops.evLabel(camera.exposureBias),
                 manual: camera.exposureBias != 0, enabled: camera.exposureMode != .manual)
            if camera.settings.mode == .photo {
                item(.look, title: "LOOK", value: Look.named(camera.settings.captureLook)?.name ?? "Off",
                     manual: camera.settings.captureLook != nil, enabled: true)
            }
        }
        .padding(.horizontal, 10)
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
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(active == kind ? Color.white.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}

struct DialPanel: View {
    let kind: DialKind
    let camera: CameraController

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
        switch kind {
        case .focus: camera.setFocusAuto()
        case .wb: camera.setWhiteBalance(.auto)
        case .iso: if camera.exposureMode == .manual { camera.setExposureMode(.shutterPriority) }
        case .shutter: camera.setExposureMode(.auto)
        case .ev: camera.setExposureBias(0)
        case .look: camera.setCaptureLook(nil)
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
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Look.all.filter { $0.id != "none" }) { look in
                            let selected = camera.settings.captureLook == look.id
                            Button {
                                camera.haptic(.light)
                                camera.setCaptureLook(selected ? nil : look.id)
                            } label: {
                                Text(look.name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .foregroundStyle(selected ? Color.black : Color.white)
                                    .background(selected ? Color.yellow : Color.white.opacity(0.14), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .id(look.id)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .onAppear {
                    if let id = camera.settings.captureLook { proxy.scrollTo(id, anchor: .center) }
                }
            }
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
