import AppKit
import SwiftUI

private let panel = Color.black.opacity(0.045)

private struct AudioKnob: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let scale: Double
    let unit: String
    let digits: Int
    let valueText: String
    let resetValue: Double?
    var logarithmic = false

    private var fraction: Double {
        logarithmic ? log(value / range.lowerBound) / log(range.upperBound / range.lowerBound) :
            (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    private func value(at fraction: Double) -> Double {
        let amount = min(1, max(0, fraction))
        return logarithmic ? range.lowerBound * pow(range.upperBound / range.lowerBound, amount) :
            range.lowerBound + amount * (range.upperBound - range.lowerBound)
    }

    private func fraction(at location: CGPoint, in size: CGSize) -> Double {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let angle = (atan2(location.y - center.y, location.x - center.x) * 180 / .pi + 360)
            .truncatingRemainder(dividingBy: 360)
        let progress = (angle - 135 + 360).truncatingRemainder(dividingBy: 360)
        // The inactive bottom arc chooses the closer endpoint.
        return progress <= 270 ? progress / 270 : (progress < 315 ? 1 : 0)
    }

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                Circle().trim(from: 0, to: 0.75)
                    .stroke(Color.secondary.opacity(0.17), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle().trim(from: 0, to: 0.75 * fraction)
                    .stroke(.blue, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle().fill(.blue).frame(width: 9, height: 9)
                    .offset(x: 41 * cos((135 + 270 * fraction) * .pi / 180),
                            y: 41 * sin((135 + 270 * fraction) * .pi / 180))
                Text(valueText).font(.callout.weight(.semibold)).monospacedDigit()
            }
            .frame(width: 94, height: 94)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { drag in
                    value = self.value(at: fraction(at: drag.location, in: CGSize(width: 94, height: 94)))
                })
            .onTapGesture(count: 2) { if let resetValue { value = resetValue } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(valueText)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: value = self.value(at: fraction + 0.01)
                case .decrement: value = self.value(at: fraction - 0.01)
                @unknown default: break
                }
            }
            Text(title).font(.callout.weight(.medium)).lineLimit(1)
            HStack(spacing: 3) {
                TextField(title, value: Binding(get: { value * scale },
                                                set: { value = min(range.upperBound,
                                                                   max(range.lowerBound, $0 / scale)) }),
                          format: .number.precision(.fractionLength(digits)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .frame(width: 64)
                Text(unit).foregroundStyle(.secondary).font(.caption)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(12).background(panel, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct MetricCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold()).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16).background(panel, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct DashboardMetrics: View {
    @ObservedObject var diagnostics: DiagnosticsStore
    let activeApps: Int

    var body: some View {
        HStack(spacing: 14) {
            MetricCard(title: "Active apps", value: "\(activeApps)")
            MetricCard(title: "Routing buffer", value: activeApps == 0 ? "—" :
                       String(format: "%.1f ms", diagnostics.value.queuedMs))
            MetricCard(title: "Reported output latency",
                       value: String(format: "%.1f ms", diagnostics.value.outputLatencyMs))
        }
    }
}

private struct RoutingDiagnostics: View {
    @ObservedObject var diagnostics: DiagnosticsStore
    let activeApps: Int

    var body: some View {
        HStack(spacing: 12) {
            MetricCard(title: "Hush queue", value: activeApps == 0 ? "—" :
                       String(format: "%.1f ms", diagnostics.value.queuedMs))
            MetricCard(title: "Missing frames", value: "\(diagnostics.value.underrunFrames)")
            MetricCard(title: "Skipped backlog", value: "\(diagnostics.value.skippedFrames)")
        }
        Text("Hush queue measures app routing only. macOS reports output latency, which can be much higher over Bluetooth.")
            .font(.caption).foregroundStyle(.secondary)
        Text(String(format: "Routes started: %d · Last setup: %.0f ms",
                    diagnostics.value.routeStarts, diagnostics.value.lastRouteSetupMs))
            .font(.caption).foregroundStyle(.secondary)
    }
}

private struct GainReductionMeter: View {
    @ObservedObject var diagnostics: DiagnosticsStore

    var body: some View {
        HStack {
            Text("Gain reduction")
            Spacer()
            Text(String(format: "%.1f dB", diagnostics.value.gainReductionDb))
                .monospacedDigit().foregroundStyle(.secondary)
        }
        ProgressView(value: min(24, diagnostics.value.gainReductionDb), total: 24).tint(.blue)
    }
}

private struct EffectLatencyNote: View {
    @ObservedObject var diagnostics: DiagnosticsStore

    var body: some View {
        Text(String(format: "Enabled effects add about %.1f ms of processing latency at the current sample rate.",
                    diagnostics.value.effectLatencyMs))
            .font(.caption).foregroundStyle(.secondary)
    }
}

private struct AppSlider: View {
    @ObservedObject var model: HushModel
    let app: AudioApp
    var showShortcut = false

    var body: some View {
        HStack(spacing: 12) {
            if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 26, height: 26) }
            else { Image(systemName: "app.fill").frame(width: 26, height: 26) }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(app.name).lineLimit(1)
                    Spacer()
                    Text("\(Int((model.settings.volumes[app.id] ?? 1) * 100))%")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: Binding(get: { model.settings.volumes[app.id] ?? 1 },
                                      set: { model.setVolume(app.id, $0) }), in: 0...1)
            }
            Button { model.toggleMute(app.id) } label: {
                Image(systemName: model.settings.mutedApps.contains(app.id) ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 24)
            }
            .buttonStyle(.borderless)
            .help(model.settings.mutedApps.contains(app.id) ? "Unmute" : "Mute")
        }
        if showShortcut {
            HStack {
                Text("Mute shortcut").foregroundStyle(.secondary)
                Spacer()
                ShortcutRecorder(binding: model.settings.shortcuts[app.id],
                                 onChange: { model.setShortcut(app.id, $0) })
                    .frame(width: 145, height: 26)
                if model.settings.shortcuts[app.id] != nil {
                    Button("Clear") { model.setShortcut(app.id, nil) }
                        .buttonStyle(.borderless)
                }
            }.padding(.leading, 38)
        }
    }
}

private struct PresetPicker: View {
    @ObservedObject var model: HushModel
    var undoManager: UndoManager? = nil

    var body: some View {
        Picker("Preset", selection: Binding(get: { model.settings.selectedPreset },
                                            set: { model.selectPreset($0, undoManager: undoManager) })) {
            ForEach(HushSettings.builtIn + model.settings.customPresets) { preset in
                Text(preset.name).tag(preset.name)
            }
            if model.settings.selectedPreset == "Custom" { Text("Custom").tag("Custom") }
        }
    }
}

private struct OutputPicker: View {
    @ObservedObject var model: HushModel

    var body: some View {
        Picker("Output", selection: Binding(
            get: { model.outputDevices.first(where: \.isDefault)?.id ?? "" },
            set: { model.selectOutput($0) })) {
                if model.outputDevices.isEmpty { Text("No output devices").tag("") }
                ForEach(model.outputDevices) { device in Text(device.name).tag(device.id) }
            }
    }
}

private struct SystemVolume: View {
    @ObservedObject var model: HushModel

    private var selected: OutputDevice? { model.outputDevices.first(where: \.isDefault) }

    var body: some View {
        HStack {
            Text("System volume")
            Slider(value: Binding(get: { selected?.volume ?? 0 },
                                  set: { model.setSystemVolume($0) }), in: 0...1)
                .disabled(selected?.volume == nil)
            Text(selected?.volume.map { "\(Int($0 * 100))%" } ?? "Unavailable")
                .monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 82, alignment: .trailing)
        }
        .help("Controls the selected macOS output device when it supports system volume")
    }
}

private struct EQGraph: View {
    @ObservedObject var model: HushModel
    let undoManager: UndoManager
    @State private var dragBand: Int?
    @State private var dragStart = 0.0
    @State private var dragPreset = "Flat"

    private func point(_ index: Int, in size: CGSize) -> CGPoint {
        let margin: CGFloat = 16
        let x = size.width * (CGFloat(index) + 0.5) / 10
        let y = margin + (size.height - 2 * margin) *
            CGFloat((HushSettings.bandLimit - model.settings.bands[index]) / (2 * HushSettings.bandLimit))
        return CGPoint(x: x, y: y)
    }

    private func curve(in size: CGSize) -> Path {
        let points = HushSettings.frequencies.indices.map { point($0, in: size) }
        var path = Path()
        path.move(to: points[0])
        for index in 0..<(points.count - 1) {
            let before = points[max(index - 1, 0)]
            let start = points[index]
            let end = points[index + 1]
            let after = points[min(index + 2, points.count - 1)]
            path.addCurve(to: end,
                          control1: CGPoint(x: start.x + (end.x - before.x) / 6,
                                            y: start.y + (end.y - before.y) / 6),
                          control2: CGPoint(x: end.x - (after.x - start.x) / 6,
                                            y: end.y - (after.y - start.y) / 6))
        }
        return path
    }

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geometry in
                ZStack {
                    ForEach([-24.0, -12.0, 0.0, 12.0, 24.0], id: \.self) { level in
                        Path { path in
                            let y = 16 + (geometry.size.height - 32) * CGFloat((24 - level) / 48)
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                        }
                        .stroke(level == 0 ? Color.secondary.opacity(0.45) : Color.secondary.opacity(0.15),
                                style: StrokeStyle(lineWidth: 1, dash: level == 0 ? [] : [3, 4]))
                    }
                    curve(in: geometry.size)
                        .stroke(.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    ForEach(HushSettings.frequencies.indices, id: \.self) { index in
                        Circle().fill(.white).frame(width: 14, height: 14)
                            .overlay(Circle().stroke(.blue, lineWidth: 3))
                            .position(point(index, in: geometry.size))
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let index = dragBand ?? Int((drag.startLocation.x / max(1, geometry.size.width) * 10)
                            .rounded(.down)).clamped(to: 0...9)
                        if dragBand == nil {
                            dragBand = index
                            dragStart = model.settings.bands[index]
                            dragPreset = model.settings.selectedPreset
                        }
                        let ratio = (drag.location.y - 16) / max(1, geometry.size.height - 32)
                        model.setBand(index, HushSettings.bandLimit * (1 - 2 * Double(ratio)))
                    }
                    .onEnded { _ in
                        if let index = dragBand {
                            model.registerBandUndo(index, value: dragStart, preset: dragPreset,
                                                   undoManager: undoManager)
                        }
                        dragBand = nil
                    })
            }
            .frame(height: 240)
            HStack(spacing: 2) {
                ForEach(HushSettings.frequencies.indices, id: \.self) { index in
                    VStack(spacing: 3) {
                        Text(HushSettings.frequencies[index] >= 1000
                             ? "\(HushSettings.frequencies[index] / 1000)k"
                             : "\(HushSettings.frequencies[index])")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("dB", value: Binding(get: { model.settings.bands[index] },
                                                        set: { model.setBand(index, $0, undoManager: undoManager) }),
                                  format: .number.precision(.fractionLength(1)))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.center)
                            .accessibilityLabel("\(HushSettings.frequencies[index]) hertz gain")
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int { Swift.min(range.upperBound, Swift.max(range.lowerBound, self)) }
}

struct QuickPanel: View {
    @ObservedObject var model: HushModel
    let openSettings: () -> Void
    let quit: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Hush controls").font(.title2.bold())
                    Spacer()
                    Button(action: openSettings) { Image(systemName: "gearshape") }
                        .buttonStyle(.borderless).help("Full settings")
                }
                HStack {
                    Label("Audio", systemImage: "waveform")
                    Spacer()
                    Toggle("", isOn: Binding(get: { model.settings.masterEnabled },
                                             set: { value in model.change { $0.masterEnabled = value } }))
                        .labelsHidden()
                }
                VStack(spacing: 8) {
                    OutputPicker(model: model)
                    SystemVolume(model: model)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Applications").font(.headline)
                        Spacer()
                        Text("\(model.apps.count) active").foregroundStyle(.secondary)
                    }
                    if model.apps.isEmpty {
                        Text("Apps playing audio appear here.").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 62)
                    } else {
                        ForEach(model.apps) { app in AppSlider(model: model, app: app) }
                    }
                }
                .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Equalizer").font(.headline)
                        Spacer()
                        Toggle("", isOn: Binding(get: { model.settings.equalizerEnabled },
                                                 set: { value in model.change { $0.equalizerEnabled = value } }))
                            .labelsHidden()
                    }
                    PresetPicker(model: model)
                }
                .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                if let error = model.audioError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.caption)
                }
                Divider()
                HStack {
                    Button("Full settings", action: openSettings)
                    Spacer()
                    Button("Quit", action: quit)
                }
            }
            .padding(18)
        }
        .frame(width: 400, height: 510)
        .tint(.blue)
    }
}

struct SettingsView: View {
    @ObservedObject var model: HushModel
    let visibilityChanged: () -> Void
    let undoManager: UndoManager
    @State private var presetName = ""
    @State private var preampStart = 0.0
    @State private var preampPreset = "Flat"

    var body: some View {
        TabView {
            dashboard.tabItem { Label("Dashboard", systemImage: "square.grid.2x2") }
            advanced.tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
            shortcuts.tabItem { Label("Shortcuts", systemImage: "keyboard") }
            general.tabItem { Label("General", systemImage: "gearshape") }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 580)
        .preferredColorScheme(.light)
        .tint(.blue)
    }

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hush audio").font(.largeTitle.bold())
                        Text("Your output, app levels, and sound profile at a glance.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Processing", isOn: Binding(get: { model.settings.masterEnabled },
                                                        set: { value in model.change { $0.masterEnabled = value } }))
                }
                VStack(alignment: .leading, spacing: 12) {
                    Label("Output", systemImage: "hifispeaker.and.homepod").font(.headline)
                    OutputPicker(model: model)
                    SystemVolume(model: model)
                }
                .padding(18).background(panel, in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Sound profile", systemImage: "waveform.path").font(.headline)
                        Spacer()
                        Toggle("Equalizer", isOn: Binding(get: { model.settings.equalizerEnabled },
                                                          set: { value in model.change { $0.equalizerEnabled = value } }))
                    }
                    PresetPicker(model: model, undoManager: undoManager)
                    Text(presetDescription).font(.callout).foregroundStyle(.secondary)
                }
                .padding(18).background(panel, in: RoundedRectangle(cornerRadius: 16))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var presetDescription: String {
        switch model.settings.selectedPreset {
        case "Gaming": "Reduces rumble and emphasizes 2–4 kHz cues such as footsteps. Results vary by game and headphones."
        case "Movie": "More impact in bass and clearer dialogue and effects."
        case "Music": "Fuller lows and more presence while keeping the middle balanced."
        case "Flat": "No equalizer adjustment."
        default: "Your custom profile for this output device."
        }
    }

    private var advanced: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                outputControls
                mixer
                equalizer
                dynamics
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var outputControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Output chain").font(.title2.bold())
            OutputPicker(model: model)
            let device = model.outputDevices.first(where: \.isDefault)
            if let device {
                Text("\(Int(device.sampleRate)) Hz · \(device.bufferFrames) frame device buffer")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 20) {
                AudioKnob(title: "System", value: Binding(get: { device?.volume ?? 0 },
                                                            set: { model.setSystemVolume($0) }),
                          range: 0...1, scale: 100, unit: "%", digits: 0,
                          valueText: device?.volume.map { "\(Int($0 * 100))%" } ?? "—", resetValue: nil)
                    .disabled(device?.volume == nil)
                AudioKnob(title: "Hush level", value: Binding(get: { model.settings.outputTrim },
                                                                set: { model.setOutputTrim($0) }),
                          range: 0...1, scale: 100, unit: "%", digits: 0,
                          valueText: "\(Int(model.settings.outputTrim * 100))%", resetValue: 1)
                AudioKnob(title: "Balance", value: Binding(get: { model.settings.balance },
                                                             set: { model.setBalance($0) }),
                          range: -1...1, scale: 100, unit: "%", digits: 0,
                          valueText: model.settings.balance < -0.01 ? "L \(Int(-model.settings.balance * 100))" :
                            model.settings.balance > 0.01 ? "R \(Int(model.settings.balance * 100))" : "Center",
                          resetValue: 0)
            }
        }
    }

    private var mixer: some View {
        VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Application mixer").font(.title2.bold())
                        Text("Adjust apps with active audio streams.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("On", isOn: Binding(get: { model.settings.masterEnabled },
                                                set: { value in model.change { $0.masterEnabled = value } }))
                }
                if model.apps.isEmpty { Text("Play audio in an app to see it here.").foregroundStyle(.secondary) }
                ForEach(model.apps) { app in
                    VStack(spacing: 10) { AppSlider(model: model, app: app, showShortcut: true) }
                        .padding(14).background(panel, in: RoundedRectangle(cornerRadius: 12))
                }
                if let error = model.audioError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var equalizer: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                VStack(alignment: .leading) {
                    Text("10-band equalizer").font(.title2.bold())
                    Text("Applies to all audio routed through Hush.").foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("On", isOn: Binding(get: { model.settings.equalizerEnabled },
                                            set: { value in model.change { $0.equalizerEnabled = value } }))
            }
            HStack {
                PresetPicker(model: model, undoManager: undoManager)
                Spacer()
                Button("Reset", systemImage: "arrow.counterclockwise") {
                    model.selectPreset("Flat", undoManager: undoManager)
                }
                .disabled(model.settings.selectedPreset == "Flat")
            }
            Text(presetDescription).font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("Band gains · drag a point or enter a value")
                    .font(.callout.weight(.medium))
                HStack(alignment: .top, spacing: 8) {
                    VStack {
                        Text("+24")
                        Spacer()
                        Text("0")
                        Spacer()
                        Text("−24")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 28, height: 240)
                    EQGraph(model: model, undoManager: undoManager)
                }
            }
            .padding(16)
            .background(panel, in: RoundedRectangle(cornerRadius: 14))
            HStack(spacing: 12) {
                Text("Preamp").frame(width: 60, alignment: .leading)
                Slider(value: Binding(get: { model.settings.preamp },
                                      set: { model.setPreamp($0) }), in: -24...12,
                       onEditingChanged: { editing in
                    if editing {
                        preampStart = model.settings.preamp
                        preampPreset = model.settings.selectedPreset
                    } else {
                        model.registerPreampUndo(value: preampStart, preset: preampPreset,
                                                 undoManager: undoManager)
                    }
                }).disabled(model.settings.autoPreamp)
                TextField("dB", value: Binding(get: { model.settings.preamp },
                                                set: { model.setPreamp($0, undoManager: undoManager) }),
                          format: .number.precision(.fractionLength(1)))
                    .disabled(model.settings.autoPreamp)
                    .textFieldStyle(.roundedBorder).frame(width: 56)
                Text("dB").foregroundStyle(.secondary)
            }
            Toggle("Auto preamp", isOn: Binding(get: { model.settings.autoPreamp },
                                                set: { model.setAutoPreamp($0) }))
                .help("Automatically attenuates the equalizer by the highest boost to preserve headroom.")
            Text("Lower the preamp when boosting several bands to preserve headroom.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("New preset name", text: $presetName)
                Button("Save preset") { model.savePreset(presetName); presetName = "" }
                    .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                if model.settings.customPresets.contains(where: { $0.name == model.settings.selectedPreset }) {
                    Button("Delete preset") { model.deletePreset(model.settings.selectedPreset) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dynamicsKnob(_ title: String, _ key: WritableKeyPath<DynamicsSettings, Double>,
                              range: ClosedRange<Double>, scale: Double = 1, unit: String,
                              digits: Int = 0, reset: Double, logarithmic: Bool = false) -> some View {
        let amount = model.settings.dynamics[keyPath: key]
        return AudioKnob(title: title,
                         value: Binding(get: { model.settings.dynamics[keyPath: key] },
                                        set: { value in model.updateDynamics { $0[keyPath: key] = value } }),
                         range: range, scale: scale, unit: unit, digits: digits,
                         valueText: String(format: "%.*f %@", digits, amount * scale, unit),
                         resetValue: reset, logarithmic: logarithmic)
    }

    private var dynamics: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Dynamics").font(.title2.bold())
            Text("Optional processing after the equalizer. Each effect is bypassed when off.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Compressor", systemImage: "waveform.path").font(.headline)
                    Spacer()
                    Toggle("On", isOn: Binding(get: { model.settings.dynamics.compressorEnabled },
                                                set: { value in model.updateDynamics { $0.compressorEnabled = value } }))
                }
                Text("Controls loud peaks and narrows the difference between quiet and loud sounds. Lower headroom means stronger compression.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 10) {
                    dynamicsKnob("Threshold", \.threshold, range: -40...0, unit: "dB", reset: -18)
                    dynamicsKnob("Headroom", \.headroom, range: 0.1...40, unit: "dB", digits: 1, reset: 8)
                    dynamicsKnob("Attack", \.attack, range: 0.001...0.2,
                                 scale: 1_000, unit: "ms", digits: 1, reset: 0.01, logarithmic: true)
                    dynamicsKnob("Release", \.release, range: 0.01...3,
                                 scale: 1_000, unit: "ms", digits: 0, reset: 0.15, logarithmic: true)
                    dynamicsKnob("Makeup", \.makeup, range: -12...12, unit: "dB", reset: 0)
                }
                GainReductionMeter(diagnostics: model.diagnostics)
            }
            .padding(16).background(panel, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Peak limiter", systemImage: "waveform.badge.minus").font(.headline)
                    Spacer()
                    Toggle("On", isOn: Binding(get: { model.settings.dynamics.limiterEnabled },
                                                set: { value in model.updateDynamics { $0.limiterEnabled = value } }))
                }
                Text("Catches peaks near full scale. Drive raises the input into the limiter; start at 0 dB.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 10) {
                    dynamicsKnob("Drive", \.limiterDrive, range: 0...18, unit: "dB", reset: 0)
                    dynamicsKnob("Attack", \.limiterAttack, range: 0.001...0.03,
                                 scale: 1_000, unit: "ms", digits: 1, reset: 0.002, logarithmic: true)
                    dynamicsKnob("Release", \.limiterRelease, range: 0.001...0.06,
                                 scale: 1_000, unit: "ms", digits: 1, reset: 0.02, logarithmic: true)
                }
            }
            .padding(16).background(panel, in: RoundedRectangle(cornerRadius: 14))
            EffectLatencyNote(diagnostics: model.diagnostics)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Keyboard shortcuts").font(.title2.bold())
            Text("Click a shortcut, then press a key with ⌘, ⌥, or ⌃. Press Escape to clear.")
                .foregroundStyle(.secondary)
            shortcutRow("Master on / off", id: "master")
            shortcutRow("Equalizer on / off", id: "equalizer")
            shortcutRow("Compressor on / off", id: "compressor")
            shortcutRow("Limiter on / off", id: "limiter")
            Text("Set an app's mute shortcut from Advanced while it is playing audio.")
                .foregroundStyle(.secondary)
            if let error = model.shortcutError { Text(error).foregroundStyle(.orange) }
            Spacer()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shortcutRow(_ title: String, id: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            ShortcutRecorder(binding: model.settings.shortcuts[id],
                             onChange: { model.setShortcut(id, $0) })
                .frame(width: 150, height: 26)
            Button("Clear") { model.setShortcut(id, nil) }
                .disabled(model.settings.shortcuts[id] == nil)
        }.padding(12).background(panel, in: RoundedRectangle(cornerRadius: 10))
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("General").font(.title2.bold())
            Toggle("Show Hush in menu bar", isOn: Binding(get: { model.settings.showMenuBar },
                set: { value in model.change { $0.showMenuBar = value }; visibilityChanged() }))
            Text(model.settings.showMenuBar
                 ? "The quick controls open from the menu bar. Turn this off to use the Dock and full settings window."
                 : "Hush is in the Dock. Click its Dock icon to open these settings.")
                .foregroundStyle(.secondary)
            Text("Hush needs System Audio Recording permission to process other apps' sound. macOS asks the first time an audio tap starts.")
                .foregroundStyle(.secondary)
            Spacer()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
