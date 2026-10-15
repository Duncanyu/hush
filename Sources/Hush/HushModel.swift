import AppKit
import Combine

final class DiagnosticsStore: ObservableObject {
    @Published var value = AudioDiagnostics()
}

final class HushModel: ObservableObject {
    @Published private(set) var settings = HushSettings.load()
    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var outputDevices: [OutputDevice] = []
    let diagnostics = DiagnosticsStore()
    @Published var audioError: String?
    @Published var shortcutError: String?
    let audio = AudioRouter()
    let hotkeys = Hotkeys()
    private let audioQueue = DispatchQueue(label: "com.hushapp.audio")
    private var audioBusy = false
    private var timer: Timer?

    init() {
        hotkeys.onPress = { [weak self] id in self?.toggleShortcut(id) }
        hotkeys.register(settings.shortcuts)
    }

    func start() {
        audio.startMonitoring(on: audioQueue) { [weak self] in
            DispatchQueue.main.async { self?.refresh() }
        }
        do {
            try audio.prepare()
        } catch {
            audioError = error.localizedDescription
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func shutdown() {
        timer?.invalidate()
        audioQueue.sync { audio.stop() }
    }

    func refresh() {
        guard !audioBusy else { return }
        let devices = audio.outputDevices()
        if outputDevices != devices { outputDevices = devices }
        if let selected = devices.first(where: \.isDefault), selected.id != settings.activeOutputUID {
            settings.activateOutput(selected.id)
            settings.save()
        }
        let discovered = audio.discover()
        audioBusy = true
        let settings = settings
        audioQueue.async { [weak self] in
            guard let self else { return }
            let result = Result { (try self.audio.sync(discovered, settings: settings), self.audio.diagnostics()) }
            DispatchQueue.main.async {
                switch result {
                case .success(let snapshot):
                    if !self.apps.elementsEqual(snapshot.0, by: {
                        $0.id == $1.id && $0.name == $1.name && $0.processIDs == $1.processIDs
                    }) { self.apps = snapshot.0 }
                    self.diagnostics.value = snapshot.1
                    if self.audioError != nil { self.audioError = nil }
                case .failure(let error):
                    if self.audioError != error.localizedDescription { self.audioError = error.localizedDescription }
                }
                self.audioBusy = false
            }
        }
    }

    func change(_ edit: (inout HushSettings) -> Void) {
        let wasEnabled = settings.masterEnabled
        edit(&settings)
        if !settings.activeOutputUID.isEmpty {
            settings.deviceProfiles[settings.activeOutputUID] = settings.currentProfile
        }
        settings.save()
        let snapshot = settings
        audioQueue.async { [weak self] in self?.audio.apply(snapshot) }
        if wasEnabled != settings.masterEnabled { refresh() }
    }

    func setVolume(_ id: String, _ value: Double) {
        change { $0.volumes[id] = value }
    }

    func toggleMute(_ id: String) {
        change { if !$0.mutedApps.insert(id).inserted { $0.mutedApps.remove(id) } }
    }

    func selectOutput(_ uid: String) {
        do {
            try audio.selectOutput(uid)
            refresh()
        } catch { audioError = error.localizedDescription }
    }

    func setSystemVolume(_ value: Double) {
        guard let selected = outputDevices.first(where: \.isDefault) else { return }
        do {
            try audio.setSystemVolume(value, for: selected.id)
            outputDevices = audio.outputDevices()
        } catch { audioError = error.localizedDescription }
    }

    func setBalance(_ value: Double) { change { $0.balance = min(1, max(-1, value)) } }
    func setOutputTrim(_ value: Double) { change { $0.outputTrim = min(1, max(0, value)) } }

    func updateDynamics(_ edit: (inout DynamicsSettings) -> Void) {
        change { settings in
            edit(&settings.dynamics)
            settings.dynamics.clamp()
        }
    }

    func selectPreset(_ name: String, undoManager: UndoManager? = nil) {
        guard let preset = (HushSettings.builtIn + settings.customPresets).first(where: { $0.name == name }) else { return }
        setEqualizer(name: name, bands: preset.bands, preamp: preset.preamp, undoManager: undoManager)
    }

    func setBand(_ index: Int, _ value: Double, undoManager: UndoManager? = nil) {
        guard settings.bands.indices.contains(index) else { return }
        var bands = settings.bands
        bands[index] = min(HushSettings.bandLimit, max(-HushSettings.bandLimit, value))
        setEqualizer(name: "Custom", bands: bands, preamp: settings.preamp, undoManager: undoManager)
    }

    func setPreamp(_ value: Double, undoManager: UndoManager? = nil) {
        setEqualizer(name: "Custom", bands: settings.bands,
                     preamp: min(12, max(-24, value)), undoManager: undoManager)
    }

    func setAutoPreamp(_ enabled: Bool) {
        change { $0.autoPreamp = enabled }
    }

    func registerBandUndo(_ index: Int, value: Double, preset: String, undoManager: UndoManager?) {
        guard let undoManager, settings.bands.indices.contains(index), settings.bands[index] != value else { return }
        var bands = settings.bands
        bands[index] = value
        let preamp = settings.preamp
        undoManager.registerUndo(withTarget: self) {
            $0.setEqualizer(name: preset, bands: bands, preamp: preamp, undoManager: undoManager)
        }
        undoManager.setActionName("Adjust Equalizer")
    }

    func registerPreampUndo(value: Double, preset: String, undoManager: UndoManager?) {
        guard let undoManager, settings.preamp != value else { return }
        let bands = settings.bands
        undoManager.registerUndo(withTarget: self) {
            $0.setEqualizer(name: preset, bands: bands, preamp: value, undoManager: undoManager)
        }
        undoManager.setActionName("Adjust Preamp")
    }

    func savePreset(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !HushSettings.builtIn.contains(where: { $0.name == clean }) else { return }
        change {
            $0.customPresets.removeAll { $0.name == clean }
            $0.customPresets.append(EQPreset(name: clean, bands: $0.bands, preamp: $0.preamp))
            $0.selectedPreset = clean
        }
    }

    func deletePreset(_ name: String) {
        change { $0.customPresets.removeAll { $0.name == name } }
        if settings.selectedPreset == name { selectPreset("Flat") }
    }

    func setShortcut(_ id: String, _ binding: KeyBinding?) {
        var next = settings.shortcuts
        next[id] = binding
        if let conflict = next.first(where: { $0.key != id && $0.value == binding }) {
            shortcutError = "Shortcut already used by \(conflict.key)."
            return
        }
        shortcutError = hotkeys.register(next)
        guard shortcutError == nil else { return }
        change { $0.shortcuts = next }
    }

    private func toggleShortcut(_ id: String) {
        switch id {
        case "master": change { $0.masterEnabled.toggle() }
        case "equalizer": change { $0.equalizerEnabled.toggle() }
        case "compressor": updateDynamics { $0.compressorEnabled.toggle() }
        case "limiter": updateDynamics { $0.limiterEnabled.toggle() }
        default: toggleMute(id)
        }
    }

    private func setEqualizer(name: String, bands: [Double], preamp: Double, undoManager: UndoManager?) {
        guard settings.selectedPreset != name || settings.bands != bands || settings.preamp != preamp else { return }
        let oldName = settings.selectedPreset
        let oldBands = settings.bands
        let oldPreamp = settings.preamp
        change { $0.selectedPreset = name; $0.bands = bands; $0.preamp = preamp }
        undoManager?.registerUndo(withTarget: self) {
            $0.setEqualizer(name: oldName, bands: oldBands, preamp: oldPreamp, undoManager: undoManager)
        }
        undoManager?.setActionName("Adjust Equalizer")
    }
}
