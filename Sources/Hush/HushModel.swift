import AppKit
import Combine

final class DiagnosticsStore: ObservableObject {
    @Published var value = AudioDiagnostics()
}

final class HushModel: ObservableObject {
    @Published private(set) var settings = HushSettings.load()
    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var sourceApps: [AudioApp] = []
    @Published private(set) var outputDevices: [OutputDevice] = []
    let diagnostics = DiagnosticsStore()
    @Published var audioError: String?
    @Published var shortcutError: String?
    let audio = AudioRouter()
    let hotkeys = Hotkeys()
    private let audioQueue = DispatchQueue(label: "com.hushapp.audio")
    private var audioBusy = false
    private var timer: Timer?
    private var hiddenActiveSources: Set<String> = []

    var mixerApps: [AudioApp] {
        let active = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        let available = Dictionary(uniqueKeysWithValues: sourceApps.map { ($0.id, $0) })
        let stored = settings.manualSources.union(settings.pinnedSources)
        return Set(active.keys).union(stored).subtracting(hiddenActiveSources).compactMap { id in
            active[id] ?? available[id] ??
                AudioApp(id: id, name: settings.sourceNames[id] ?? id, icon: nil, processIDs: [])
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var addableSourceApps: [AudioApp] {
        let knownIDs = Set(sourceApps.map(\.id))
        let stored = settings.manualSources.union(settings.pinnedSources)
            .subtracting(knownIDs)
            .map { AudioApp(id: $0, name: settings.sourceNames[$0] ?? $0, icon: nil, processIDs: []) }
        return (sourceApps + stored).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    init() {
        hotkeys.onPress = { [weak self] id in self?.toggleShortcut(id) }
        hotkeys.register(settings.shortcuts)
    }

    func start() {
        guard settings.masterEnabled else {
            timer = nil
            return
        }
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
        guard settings.masterEnabled else { return }
        guard !audioBusy else { return }
        let devices = audio.outputDevices()
        if outputDevices != devices { outputDevices = devices }
        if let selected = devices.first(where: \.isDefault), selected.id != settings.activeOutputUID {
            settings.activateOutput(selected.id)
            settings.save()
        }

        let discovered = audio.discover()
        let allApplications = audio.allApplications()
        if !sourceApps.elementsEqual(allApplications, by: {
            $0.id == $1.id && $0.name == $1.name
        }) { sourceApps = allApplications }
        audioBusy = true
        let settings = settings
        audioQueue.async { [weak self] in
            guard let self else { return }
            let result = Result { (try self.audio.sync(discovered, settings: settings), self.audio.diagnostics()) }
            DispatchQueue.main.async {
                switch result {
                case .success(let snapshot):
                    let activeIDs = Set(snapshot.0.map(\.id))
                    self.hiddenActiveSources = self.hiddenActiveSources.intersection(activeIDs)
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

    func refreshDiagnostics() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            let value = self.audio.diagnostics()
            DispatchQueue.main.async { self.diagnostics.value = value }
        }
    }

    func change(_ edit: (inout HushSettings) -> Void) {
        let wasEnabled = settings.masterEnabled
        let previousOptions = MasterOptionState(
            equalizerEnabled: settings.equalizerEnabled,
            compressorEnabled: settings.dynamics.compressorEnabled,
            limiterEnabled: settings.dynamics.limiterEnabled,
            visualizerEnabled: settings.visualizerEnabled
        )
        edit(&settings)
        if wasEnabled && !settings.masterEnabled {
            settings.masterRestoreState = previousOptions
            settings.equalizerEnabled = false
            settings.dynamics.compressorEnabled = false
            settings.dynamics.limiterEnabled = false
            settings.visualizerEnabled = false
        } else if !wasEnabled && settings.masterEnabled {
            let restore = settings.masterRestoreState
            settings.equalizerEnabled = restore?.equalizerEnabled ?? settings.equalizerEnabled
            settings.dynamics.compressorEnabled = restore?.compressorEnabled ?? settings.dynamics.compressorEnabled
            settings.dynamics.limiterEnabled = restore?.limiterEnabled ?? settings.dynamics.limiterEnabled
            settings.visualizerEnabled = restore?.visualizerEnabled ?? settings.visualizerEnabled
            settings.masterRestoreState = nil
        } else if !settings.masterEnabled {
            settings.equalizerEnabled = false
            settings.dynamics.compressorEnabled = false
            settings.dynamics.limiterEnabled = false
            settings.visualizerEnabled = false
        }
        if !settings.activeOutputUID.isEmpty {
            settings.deviceProfiles[settings.activeOutputUID] = settings.currentProfile
        }
        settings.save()
        let snapshot = settings
        if wasEnabled != settings.masterEnabled {
            if settings.masterEnabled {
                audio.startMonitoring(on: audioQueue) { [weak self] in
                    DispatchQueue.main.async { self?.refresh() }
                }
                do {
                    try audio.prepare()
                } catch {
                    audioError = error.localizedDescription
                }
                if timer == nil {
                    timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
                        [weak self] _ in self?.refresh()
                    }
                }
                refresh()
            } else {
                timer?.invalidate()
                timer = nil
                audio.stopMonitoring()
                audioQueue.sync { audio.stop() }
            }
        } else if settings.masterEnabled {
            audioQueue.async { [weak self] in self?.audio.apply(snapshot) }
        }
    }

    func setVolume(_ id: String, _ value: Double) {
        change { $0.volumes[id] = value }
    }

    /// Assign a source to a physical output. Passing nil removes the assignment
    /// and restores the default-output fallback.
    func setSourceOutput(_ sourceID: String, _ outputUID: String?) {
        change { settings in
            if let outputUID, !outputUID.isEmpty {
                settings.sourceOutputs[sourceID] = outputUID
            } else {
                settings.sourceOutputs.removeValue(forKey: sourceID)
            }
        }
        refresh()
    }

    func toggleMute(_ id: String) {
        change { if !$0.mutedApps.insert(id).inserted { $0.mutedApps.remove(id) } }
    }

    func addSource(_ app: AudioApp) {
        change {
            $0.manualSources.insert(app.id)
            $0.pinnedSources.insert(app.id)
            $0.sourceNames[app.id] = app.name
        }
        hiddenActiveSources.remove(app.id)
    }

    func removeSource(_ id: String) {
        change {
            $0.manualSources.remove(id)
            $0.pinnedSources.remove(id)
        }
        hiddenActiveSources.insert(id)
    }

    func togglePin(_ id: String) {
        change { settings in
            if !settings.pinnedSources.insert(id).inserted {
                settings.pinnedSources.remove(id)
            }
        }
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

    func setEqualizerSources(_ sources: Set<String>?) {
        change {
            switch $0.equalizerScope {
            case .all: break
            case .only: $0.equalizerOnlySources = sources ?? []
            case .excluding: $0.equalizerExcludedSources = sources ?? []
            }
            $0.equalizerSources = sources
        }
    }

    func setDynamicsSources(_ sources: Set<String>?) {
        change {
            switch $0.dynamicsScope {
            case .all: break
            case .only: $0.dynamicsOnlySources = sources ?? []
            case .excluding: $0.dynamicsExcludedSources = sources ?? []
            }
            $0.dynamicsSources = sources
        }
    }

    func setEqualizerScope(_ scope: SourceScope) {
        change {
            $0.equalizerScope = scope
            $0.equalizerSources = $0.equalizerSelection(for: scope)
        }
    }

    func setDynamicsScope(_ scope: SourceScope) {
        change {
            $0.dynamicsScope = scope
            $0.dynamicsSources = $0.dynamicsSelection(for: scope)
        }
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
