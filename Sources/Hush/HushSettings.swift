import Foundation

struct KeyBinding: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String
}

struct EQPreset: Codable, Identifiable, Equatable {
    var id: String { name }
    var name: String
    var bands: [Double]
    var preamp: Double

    init(name: String, bands: [Double], preamp: Double = 0) {
        self.name = name
        self.bands = bands
        self.preamp = preamp
    }

    private enum CodingKeys: String, CodingKey { case name, bands, preamp }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        bands = try values.decode([Double].self, forKey: .bands)
        preamp = try values.decodeIfPresent(Double.self, forKey: .preamp) ?? 0
    }
}

struct DynamicsSettings: Codable {
    var compressorEnabled = false
    var limiterEnabled = false
    var threshold = -18.0
    var headroom = 8.0
    var attack = 0.01
    var release = 0.15
    var makeup = 0.0
    var limiterDrive = 0.0
    var limiterAttack = 0.002
    var limiterRelease = 0.02

    mutating func clamp() {
        threshold = min(0, max(-40, threshold))
        headroom = min(40, max(0.1, headroom))
        attack = min(0.2, max(0.001, attack))
        release = min(3, max(0.01, release))
        makeup = min(12, max(-12, makeup))
        limiterDrive = min(18, max(0, limiterDrive))
        limiterAttack = min(0.03, max(0.001, limiterAttack))
        limiterRelease = min(0.06, max(0.001, limiterRelease))
    }
}

struct MasterOptionState: Codable, Equatable {
    var equalizerEnabled: Bool
    var compressorEnabled: Bool
    var limiterEnabled: Bool
    var visualizerEnabled: Bool
}

enum SourceScope: String, Codable, Equatable {
    case all
    case only
    case excluding
}

struct DeviceProfile: Codable {
    var selectedPreset: String
    var bands: [Double]
    var preamp: Double
    var autoPreamp: Bool
    var balance: Double
    var outputTrim: Double
    var dynamics: DynamicsSettings

    private enum CodingKeys: String, CodingKey {
        case selectedPreset, bands, preamp, autoPreamp, balance, outputTrim, dynamics
    }

    init(selectedPreset: String, bands: [Double], preamp: Double, autoPreamp: Bool, balance: Double,
         outputTrim: Double, dynamics: DynamicsSettings) {
        self.selectedPreset = selectedPreset
        self.bands = bands
        self.preamp = preamp
        self.autoPreamp = autoPreamp
        self.balance = balance
        self.outputTrim = outputTrim
        self.dynamics = dynamics
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        selectedPreset = try values.decode(String.self, forKey: .selectedPreset)
        bands = try values.decode([Double].self, forKey: .bands)
        preamp = try values.decode(Double.self, forKey: .preamp)
        autoPreamp = try values.decodeIfPresent(Bool.self, forKey: .autoPreamp) ?? false
        balance = try values.decode(Double.self, forKey: .balance)
        outputTrim = try values.decode(Double.self, forKey: .outputTrim)
        dynamics = try values.decodeIfPresent(DynamicsSettings.self, forKey: .dynamics) ?? DynamicsSettings()
    }
}

struct HushSettings: Codable {
    static let bandLimit = 24.0
    static let frequencies = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let builtIn: [EQPreset] = [
        .init(name: "Flat", bands: Array(repeating: 0, count: 10)),
        .init(name: "Gaming", bands: [-8, -7, -5, -3, -1, 2, 6, 7, 3, 0], preamp: -9),
        .init(name: "Movie", bands: [5, 5, 3, 1, -1, 1, 3, 4, 3, 1], preamp: -6),
        .init(name: "Music", bands: [4, 4, 2, -1, 0, 1, 3, 4, 3, 1], preamp: -6)
    ]

    var masterEnabled = true
    var equalizerEnabled = true
    var masterRestoreState: MasterOptionState?
    /// nil means all discovered sources; an empty set means no sources.
    var equalizerSources: Set<String>? = nil
    var dynamicsSources: Set<String>? = nil
    var equalizerOnlySources: Set<String> = []
    var equalizerExcludedSources: Set<String> = []
    var dynamicsOnlySources: Set<String> = []
    var dynamicsExcludedSources: Set<String> = []
    var equalizerScope: SourceScope = .all
    var dynamicsScope: SourceScope = .all
    var showMenuBar = true
    var visualizerEnabled = true
    var automaticUpdates = true
    var selectedPreset = "Flat"
    var bands = Array(repeating: 0.0, count: 10)
    var preamp = 0.0
    var autoPreamp = false
    var balance = 0.0
    var outputTrim = 1.0
    var dynamics = DynamicsSettings()
    var activeOutputUID = ""
    var deviceProfiles: [String: DeviceProfile] = [:]
    var customPresets: [EQPreset] = []
    var volumes: [String: Double] = [:]
    var mutedApps: Set<String> = []
    var manualSources: Set<String> = []
    var pinnedSources: Set<String> = []
    var dismissedSources: Set<String> = []
    var sourceNames: [String: String] = [:]
    /// Optional per-source output assignment. Missing or invalid assignments use the
    /// current default output, preserving the original single-output behavior.
    var sourceOutputs: [String: String] = [:]
    var shortcuts: [String: KeyBinding] = [:]

    private enum CodingKeys: String, CodingKey {
        case masterEnabled, equalizerEnabled, masterRestoreState, equalizerSources, dynamicsSources,
             equalizerOnlySources, equalizerExcludedSources, dynamicsOnlySources, dynamicsExcludedSources,
             equalizerScope, dynamicsScope,
             showMenuBar, visualizerEnabled, automaticUpdates, selectedPreset, bands, preamp,
             balance, outputTrim, activeOutputUID, deviceProfiles, customPresets,
             autoPreamp,
             volumes, mutedApps, manualSources, pinnedSources, dismissedSources, sourceNames, sourceOutputs, shortcuts, dynamics
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        masterEnabled = try values.decodeIfPresent(Bool.self, forKey: .masterEnabled) ?? true
        equalizerEnabled = try values.decodeIfPresent(Bool.self, forKey: .equalizerEnabled) ?? true
        masterRestoreState = try values.decodeIfPresent(MasterOptionState.self, forKey: .masterRestoreState)
        equalizerSources = try values.decodeIfPresent(Set<String>.self, forKey: .equalizerSources)
        dynamicsSources = try values.decodeIfPresent(Set<String>.self, forKey: .dynamicsSources)
        let decodedEqualizerScope = try values.decodeIfPresent(SourceScope.self, forKey: .equalizerScope) ??
            (equalizerSources == nil ? .all : .only)
        let decodedDynamicsScope = try values.decodeIfPresent(SourceScope.self, forKey: .dynamicsScope) ??
            (dynamicsSources == nil ? .all : .only)
        equalizerOnlySources = try values.decodeIfPresent(Set<String>.self, forKey: .equalizerOnlySources) ??
            (decodedEqualizerScope == .only ? equalizerSources ?? [] : [])
        equalizerExcludedSources = try values.decodeIfPresent(Set<String>.self, forKey: .equalizerExcludedSources) ??
            (decodedEqualizerScope == .excluding ? equalizerSources ?? [] : [])
        dynamicsOnlySources = try values.decodeIfPresent(Set<String>.self, forKey: .dynamicsOnlySources) ??
            (decodedDynamicsScope == .only ? dynamicsSources ?? [] : [])
        dynamicsExcludedSources = try values.decodeIfPresent(Set<String>.self, forKey: .dynamicsExcludedSources) ??
            (decodedDynamicsScope == .excluding ? dynamicsSources ?? [] : [])
        equalizerScope = decodedEqualizerScope
        dynamicsScope = decodedDynamicsScope
        showMenuBar = try values.decodeIfPresent(Bool.self, forKey: .showMenuBar) ?? true
        visualizerEnabled = try values.decodeIfPresent(Bool.self, forKey: .visualizerEnabled) ?? true
        automaticUpdates = try values.decodeIfPresent(Bool.self, forKey: .automaticUpdates) ?? true
        selectedPreset = try values.decodeIfPresent(String.self, forKey: .selectedPreset) ?? "Flat"
        bands = try values.decodeIfPresent([Double].self, forKey: .bands) ?? Array(repeating: 0, count: 10)
        preamp = try values.decodeIfPresent(Double.self, forKey: .preamp) ?? 0
        autoPreamp = try values.decodeIfPresent(Bool.self, forKey: .autoPreamp) ?? false
        balance = try values.decodeIfPresent(Double.self, forKey: .balance) ?? 0
        outputTrim = try values.decodeIfPresent(Double.self, forKey: .outputTrim) ?? 1
        dynamics = try values.decodeIfPresent(DynamicsSettings.self, forKey: .dynamics) ?? DynamicsSettings()
        activeOutputUID = try values.decodeIfPresent(String.self, forKey: .activeOutputUID) ?? ""
        deviceProfiles = try values.decodeIfPresent([String: DeviceProfile].self, forKey: .deviceProfiles) ?? [:]
        customPresets = try values.decodeIfPresent([EQPreset].self, forKey: .customPresets) ?? []
        volumes = try values.decodeIfPresent([String: Double].self, forKey: .volumes) ?? [:]
        mutedApps = try values.decodeIfPresent(Set<String>.self, forKey: .mutedApps) ?? []
        manualSources = try values.decodeIfPresent(Set<String>.self, forKey: .manualSources) ?? []
        pinnedSources = try values.decodeIfPresent(Set<String>.self, forKey: .pinnedSources) ?? []
        dismissedSources = try values.decodeIfPresent(Set<String>.self, forKey: .dismissedSources) ?? []
        sourceNames = try values.decodeIfPresent([String: String].self, forKey: .sourceNames) ?? [:]
        sourceOutputs = try values.decodeIfPresent([String: String].self, forKey: .sourceOutputs) ?? [:]
        shortcuts = try values.decodeIfPresent([String: KeyBinding].self, forKey: .shortcuts) ?? [:]
    }

    var currentProfile: DeviceProfile {
        DeviceProfile(selectedPreset: selectedPreset, bands: bands, preamp: preamp,
                      autoPreamp: autoPreamp,
                      balance: balance, outputTrim: outputTrim, dynamics: dynamics)
    }

    func equalizerSelection(for scope: SourceScope) -> Set<String>? {
        switch scope {
        case .all: nil
        case .only: equalizerOnlySources
        case .excluding: equalizerExcludedSources
        }
    }

    func dynamicsSelection(for scope: SourceScope) -> Set<String>? {
        switch scope {
        case .all: nil
        case .only: dynamicsOnlySources
        case .excluding: dynamicsExcludedSources
        }
    }

    mutating func activateOutput(_ uid: String) {
        guard !uid.isEmpty, uid != activeOutputUID else { return }
        if !activeOutputUID.isEmpty { deviceProfiles[activeOutputUID] = currentProfile }
        if let profile = deviceProfiles[uid], profile.bands.count == Self.frequencies.count {
            selectedPreset = profile.selectedPreset
            bands = profile.bands
            preamp = profile.preamp
            autoPreamp = profile.autoPreamp
            balance = profile.balance
            outputTrim = profile.outputTrim
            dynamics = profile.dynamics
        } else if !activeOutputUID.isEmpty {
            selectedPreset = "Flat"
            bands = Array(repeating: 0, count: Self.frequencies.count)
            preamp = 0
            autoPreamp = false
            balance = 0
            outputTrim = 1
            dynamics = DynamicsSettings()
        }
        activeOutputUID = uid
        deviceProfiles[uid] = currentProfile
    }

    static func load() -> HushSettings {
        guard let data = UserDefaults.standard.data(forKey: "HushSettings"),
              var value = try? JSONDecoder().decode(HushSettings.self, from: data),
              value.bands.count == frequencies.count else { return HushSettings() }
        if value.activeOutputUID.isEmpty,
           let preset = builtIn.first(where: { $0.name == value.selectedPreset }) {
            value.bands = preset.bands
            value.preamp = preset.preamp
        }
        value.bands = value.bands.map { min(bandLimit, max(-bandLimit, $0)) }
        value.preamp = min(12, max(-24, value.preamp))
        value.balance = min(1, max(-1, value.balance))
        value.outputTrim = min(1, max(0, value.outputTrim))
        value.dynamics.clamp()
        value.customPresets = value.customPresets.filter { $0.bands.count == frequencies.count }
        value.customPresets = value.customPresets.map { preset in
            EQPreset(name: preset.name,
                     bands: preset.bands.map { min(bandLimit, max(-bandLimit, $0)) },
                     preamp: min(12, max(-24, preset.preamp)))
        }
        value.deviceProfiles = value.deviceProfiles.filter { $0.value.bands.count == frequencies.count }
        for uid in value.deviceProfiles.keys { value.deviceProfiles[uid]?.dynamics.clamp() }
        return value
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "HushSettings")
        }
    }
}
