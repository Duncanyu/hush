import AppKit
import AVFoundation
import AudioRing
import AudioToolbox
import CoreAudio
import Darwin

struct AudioApp: Identifiable {
    let id: String
    let name: String
    let icon: NSImage?
    let processIDs: [AudioObjectID]
}

struct OutputDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let volume: Double?
    let sampleRate: Double
    let bufferFrames: UInt32
    let isDefault: Bool
}

struct AudioDiagnostics {
    var queuedFrames = 0
    var underrunFrames: UInt64 = 0
    var skippedFrames: UInt64 = 0
    var sampleRate = 0.0
    var outputLatencyMs = 0.0
    var effectLatencyMs = 0.0
    var routeStarts = 0
    var lastRouteSetupMs = 0.0
    var gainReductionDb = 0.0
    var queuedMs: Double { sampleRate > 0 ? Double(queuedFrames) / sampleRate * 1_000 : 0 }
}

private func address(_ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

private func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         as type: T.Type = T.self,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> T? {
    let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { value.deallocate() }
    var size = UInt32(MemoryLayout<T>.size)
    var key = address(selector, scope: scope, element: element)
    guard AudioObjectGetPropertyData(object, &key, 0, nil, &size, value) == noErr,
          size == MemoryLayout<T>.size else { return nil }
    return value.move()
}

private func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<CFString>.size)
    var key = address(selector)
    guard AudioObjectGetPropertyData(object, &key, 0, nil, &size, &value) == noErr,
          let value else { return nil }
    return value.takeRetainedValue() as String
}

private func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
    var key = address(selector, scope: scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &key, 0, nil, &size) == noErr, size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(object, &key, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

private func outputVolume(_ device: AudioObjectID) -> Double? {
    for element in [kAudioObjectPropertyElementMain, 1, 2] {
        if let value: Float32 = property(device, kAudioDevicePropertyVolumeScalar,
                                         scope: kAudioDevicePropertyScopeOutput, element: element) {
            return Double(value)
        }
    }
    return nil
}

private final class AppRoute {
    let ids: [AudioObjectID]
    let ring: OpaquePointer
    let source: AVAudioSourceNode
    let mixer = AVAudioMixerNode()
    var tap: AudioObjectID = 0
    var aggregate: AudioObjectID = 0
    var ioProc: AudioDeviceIOProcID?

    init(ids: [AudioObjectID], sampleRate: Double) throws {
        self.ids = ids
        guard let ring = AudioRingCreate(8192) else { throw HushAudioError("Could not allocate audio buffer") }
        self.ring = ring
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                   channels: 2, interleaved: false)!
        source = AVAudioSourceNode(format: format) { _, _, frameCount, output in
            let buffers = UnsafeMutableAudioBufferListPointer(output)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return kAudio_ParamError }
            AudioRingRead(ring, left, right, frameCount)
            return noErr
        }
    }

    deinit { AudioRingDestroy(ring) }
}

struct HushAudioError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

final class AudioRouter {
    private let engine = AVAudioEngine()
    private let equalizer = AudioRouter.makeEqualizer()
    private let compressor = AudioRouter.makeEffect(kAudioUnitSubType_DynamicsProcessor)
    private let limiter = AudioRouter.makeEffect(kAudioUnitSubType_PeakLimiter)
    private var routes: [String: AppRoute] = [:]
    private var lastSeen: [String: TimeInterval] = [:]
    // Keep disconnected app nodes alive until the engine stops: removing a mixer from a
    // running AVAudioEngine can invalidate its render graph.
    private var retired: [AppRoute] = []
    private var listenerQueue: DispatchQueue?
    private var listenerBlocks: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var processListenerBlocks: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var processOutputChanged: (() -> Void)?
    private var outputID: AudioObjectID = 0
    private var outputUID = ""
    private var outputRate = 0.0
    private var engineReady = false
    private var routeStarts = 0
    private var lastRouteSetupMs = 0.0

    init() {
        engine.attach(equalizer)
        engine.attach(compressor)
        engine.attach(limiter)
        engine.disconnectNodeOutput(engine.mainMixerNode)
        engine.connect(engine.mainMixerNode, to: equalizer, format: nil)
        engine.connect(equalizer, to: compressor, format: nil)
        engine.connect(compressor, to: limiter, format: nil)
        engine.connect(limiter, to: engine.outputNode, format: nil)
        compressor.bypass = true
        limiter.bypass = true
    }

    func startMonitoring(on queue: DispatchQueue, changed: @escaping () -> Void) {
        guard listenerBlocks.isEmpty else { return }
        processOutputChanged = changed
        let system = AudioObjectID(kAudioObjectSystemObject)
        let addresses = [
            address(kAudioHardwarePropertyProcessObjectList),
            address(kAudioHardwarePropertyDefaultOutputDevice)
        ]
        listenerQueue = queue
        for var key in addresses {
            let block: AudioObjectPropertyListenerBlock = { _, _ in changed() }
            guard AudioObjectAddPropertyListenerBlock(system, &key, queue, block) == noErr else { continue }
            listenerBlocks.append((key, block))
        }
    }

    func prepare() throws {
        guard !engineReady else { return }
        let system = AudioObjectID(kAudioObjectSystemObject)
        let device = property(system, kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self) ?? 0
        guard device != 0, let uid = stringProperty(device, kAudioDevicePropertyDeviceUID) else {
            throw HushAudioError("No output device is available")
        }
        let rate = property(device, kAudioDevicePropertyNominalSampleRate, as: Float64.self) ?? 0
        guard rate > 0 else { throw HushAudioError("Output sample rate is unavailable") }
        outputID = device
        outputUID = uid
        outputRate = rate
        do {
            try engine.start()
            engineReady = true
        } catch {
            outputID = 0
            outputUID = ""
            outputRate = 0
            throw HushAudioError("Audio pipeline could not start: \(error.localizedDescription)")
        }
    }

    static func makeEqualizer() -> AVAudioUnitEQ {
        let equalizer = AVAudioUnitEQ(numberOfBands: HushSettings.frequencies.count)
        for (band, frequency) in zip(equalizer.bands, HushSettings.frequencies) {
            band.filterType = .parametric
            band.frequency = Float(frequency)
            band.bandwidth = 1
            band.gain = 0
            band.bypass = false
        }
        equalizer.bypass = true
        return equalizer
    }

    static func makeEffect(_ subtype: OSType) -> AVAudioUnitEffect {
        AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: subtype,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0))
    }

    private func setParameter(_ effect: AVAudioUnitEffect, _ id: AudioUnitParameterID, _ value: Double) {
        effect.auAudioUnit.parameterTree?.parameter(withAddress: AUParameterAddress(id))?.value = Float(value)
    }

    func outputDevices() -> [OutputDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let current = property(system, kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self)
        return objectList(system, kAudioHardwarePropertyDevices).compactMap { device in
            guard !objectList(device, kAudioDevicePropertyStreams,
                              scope: kAudioDevicePropertyScopeOutput).isEmpty,
                  property(device, kAudioDevicePropertyDeviceCanBeDefaultDevice,
                           as: UInt32.self, scope: kAudioDevicePropertyScopeOutput) == 1,
                  let uid = stringProperty(device, kAudioDevicePropertyDeviceUID) else { return nil }
            return OutputDevice(id: uid,
                                name: stringProperty(device, kAudioObjectPropertyName) ?? uid,
                                volume: outputVolume(device),
                                sampleRate: property(device, kAudioDevicePropertyNominalSampleRate,
                                                     as: Float64.self) ?? 0,
                                bufferFrames: property(device, kAudioDevicePropertyBufferFrameSize,
                                                       as: UInt32.self) ?? 0,
                                isDefault: device == current)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func selectOutput(_ uid: String) throws {
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard var device = objectList(system, kAudioHardwarePropertyDevices).first(where: {
            stringProperty($0, kAudioDevicePropertyDeviceUID) == uid &&
                !objectList($0, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput).isEmpty &&
                property($0, kAudioDevicePropertyDeviceCanBeDefaultDevice,
                         as: UInt32.self, scope: kAudioDevicePropertyScopeOutput) == 1
        }) else { throw HushAudioError("Output device is unavailable") }
        var key = address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectSetPropertyData(system, &key, 0, nil,
                                                UInt32(MemoryLayout<AudioObjectID>.size), &device)
        guard status == noErr else { throw HushAudioError("Could not select output (\(status))") }
    }

    func setSystemVolume(_ value: Double, for uid: String) throws {
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard let device = objectList(system, kAudioHardwarePropertyDevices).first(where: {
            stringProperty($0, kAudioDevicePropertyDeviceUID) == uid
        }) else { throw HushAudioError("Output device is unavailable") }
        var level = Float32(min(1, max(0, value)))
        var changed = false
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            var key = address(kAudioDevicePropertyVolumeScalar,
                              scope: kAudioDevicePropertyScopeOutput, element: element)
            if AudioObjectSetPropertyData(device, &key, 0, nil,
                                          UInt32(MemoryLayout<Float32>.size), &level) == noErr {
                changed = true
                if element == kAudioObjectPropertyElementMain { break }
            }
        }
        guard changed else { throw HushAudioError("This output has no system volume control") }
    }

    func diagnostics() -> AudioDiagnostics {
        var result = AudioDiagnostics()
        result.sampleRate = outputRate
        result.routeStarts = routeStarts
        result.lastRouteSetupMs = lastRouteSetupMs
        result.effectLatencyMs = (equalizer.latency + (compressor.bypass ? 0 : compressor.latency) +
                                  (limiter.bypass ? 0 : limiter.latency)) * 1_000
        result.outputLatencyMs = engine.outputNode.presentationLatency * 1_000
        if !compressor.bypass {
            let reduction = Double(compressor.auAudioUnit.parameterTree?
                .parameter(withAddress: AUParameterAddress(kDynamicsProcessorParam_CompressionAmount))?.value ?? 0)
            result.gainReductionDb = reduction > 0.05 ? reduction : 0
        }
        for route in routes.values {
            let stats = AudioRingGetStats(route.ring)
            result.queuedFrames = max(result.queuedFrames, Int(stats.queuedFrames))
            result.underrunFrames += stats.underrunFrames
            result.skippedFrames += stats.skippedFrames
        }
        return result
    }

    func discover() -> [AudioApp] {
        let processObjects = objectList(AudioObjectID(kAudioObjectSystemObject),
                                        kAudioHardwarePropertyProcessObjectList)
        monitorProcessOutput(processObjects)
        let grouped = Dictionary(grouping: processObjects.compactMap { object -> (String, pid_t, AudioObjectID)? in
            guard let running: UInt32 = property(object, kAudioProcessPropertyIsRunningOutput), running != 0,
                  let pid: pid_t = property(object, kAudioProcessPropertyPID), pid != getpid() else { return nil }
            let bundle = stringProperty(object, kAudioProcessPropertyBundleID) ?? "pid:\(pid)"
            return (bundle, pid, object)
        }, by: { $0.0 })
        return grouped.map { id, processes in
            let app = NSWorkspace.shared.runningApplications.first {
                $0.bundleIdentifier == id && $0.activationPolicy == .regular
            } ?? NSRunningApplication(processIdentifier: processes[0].1)
            var bytes = [CChar](repeating: 0, count: 256)
            let executable = proc_name(processes[0].1, &bytes, UInt32(bytes.count)) > 0
                ? String(cString: bytes) : nil
            let name = [app?.localizedName, app?.executableURL?.deletingPathExtension().lastPathComponent,
                        executable, id].compactMap { $0 }.first { !$0.isEmpty } ?? id
            return AudioApp(id: id, name: name, icon: app?.icon,
                            processIDs: processes.map(\.2).sorted())
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func monitorProcessOutput(_ processObjects: [AudioObjectID]) {
        guard let queue = listenerQueue else { return }
        let current = Set(processObjects)
        for object in processObjects where processListenerBlocks[object] == nil {
            var key = address(kAudioProcessPropertyIsRunningOutput)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.processOutputChanged?()
            }
            if AudioObjectAddPropertyListenerBlock(object, &key, queue, block) == noErr {
                processListenerBlocks[object] = block
            }
        }
        for object in processListenerBlocks.keys where !current.contains(object) {
            guard let block = processListenerBlocks.removeValue(forKey: object) else { continue }
            var key = address(kAudioProcessPropertyIsRunningOutput)
            AudioObjectRemovePropertyListenerBlock(object, &key, queue, block)
        }
    }

    func sync(_ apps: [AudioApp], settings: HushSettings) throws -> [AudioApp] {
        guard settings.masterEnabled else { stop(); return [] }
        let now = ProcessInfo.processInfo.systemUptime
        for app in apps { lastSeen[app.id] = now }
        let liveProcesses = Set(objectList(AudioObjectID(kAudioObjectSystemObject),
                                           kAudioHardwarePropertyProcessObjectList))
        guard !apps.isEmpty || routes.keys.contains(where: { route in
            routes[route]?.ids.contains(where: liveProcesses.contains) == true
        }) else {
            return []
        }
        let newOutput = property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                                 as: AudioObjectID.self) ?? 0
        guard newOutput != 0, let uid = stringProperty(newOutput, kAudioDevicePropertyDeviceUID) else {
            throw HushAudioError("No output device is available")
        }
        let rate = property(newOutput, kAudioDevicePropertyNominalSampleRate, as: Float64.self) ?? 0
        guard rate > 0 else { throw HushAudioError("Output sample rate is unavailable") }
        if newOutput != outputID || rate != outputRate || (engineReady && !engine.isRunning) {
            stop()
            outputID = newOutput
            outputUID = uid
            outputRate = rate
            for app in apps { lastSeen[app.id] = now }
        }
        apply(settings)
        let wanted = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        for (id, route) in routes {
            if let app = wanted[id] {
                if app.processIDs != route.ids { remove(id) }
            } else if route.ids.allSatisfy({ !liveProcesses.contains($0) }) { remove(id) }
        }
        do {
            for app in apps where routes[app.id] == nil { try add(app, settings: settings) }
        } catch {
            if routes.isEmpty { stop() }
            throw error
        }
        return apps.filter { app in routes[app.id].map { AudioRingRecentlyActive($0.ring) != 0 } ?? false }
    }

    func apply(_ settings: HushSettings) {
        equalizer.bypass = !settings.equalizerEnabled
        let peakBoost = settings.bands.max() ?? 0
        let preamp = settings.autoPreamp ? min(0, -peakBoost) : settings.preamp
        equalizer.globalGain = Float(preamp)
        engine.mainMixerNode.outputVolume = Float(settings.outputTrim)
        // Pan each app's stereo bus. The main mixer can preserve channel balance
        // when its output is negotiated as mono, so it is not the source of truth.
        for (band, gain) in zip(equalizer.bands, settings.bands) { band.gain = Float(gain) }
        let dynamics = settings.dynamics
        setParameter(compressor, kDynamicsProcessorParam_Threshold, dynamics.threshold)
        setParameter(compressor, kDynamicsProcessorParam_HeadRoom, dynamics.headroom)
        setParameter(compressor, kDynamicsProcessorParam_AttackTime, dynamics.attack)
        setParameter(compressor, kDynamicsProcessorParam_ReleaseTime, dynamics.release)
        setParameter(compressor, kDynamicsProcessorParam_OverallGain, dynamics.makeup)
        compressor.bypass = !dynamics.compressorEnabled
        setParameter(limiter, kLimiterParam_PreGain, dynamics.limiterDrive)
        setParameter(limiter, kLimiterParam_AttackTime, dynamics.limiterAttack)
        setParameter(limiter, kLimiterParam_DecayTime, dynamics.limiterRelease)
        limiter.bypass = !dynamics.limiterEnabled
        for (id, route) in routes {
            route.mixer.outputVolume = settings.mutedApps.contains(id) ? 0 : Float(settings.volumes[id] ?? 1)
            route.mixer.pan = Float(settings.balance)
        }
    }

    func stop() {
        engine.stop()
        engineReady = false
        for id in Array(routes.keys) { remove(id) }
        for route in retired {
            engine.detach(route.source)
            engine.detach(route.mixer)
        }
        retired.removeAll()
        lastSeen.removeAll()
        outputID = 0
        outputUID = ""
        outputRate = 0
    }

    deinit {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for (var key, block) in listenerBlocks {
            AudioObjectRemovePropertyListenerBlock(system, &key, listenerQueue, block)
        }
        if let queue = listenerQueue {
            for (object, block) in processListenerBlocks {
                var key = address(kAudioProcessPropertyIsRunningOutput)
                AudioObjectRemovePropertyListenerBlock(object, &key, queue, block)
            }
        }
    }

    private func add(_ app: AudioApp, settings: HushSettings) throws {
        let setupStarted = ProcessInfo.processInfo.systemUptime
        let tapUUID = UUID()
        let description = CATapDescription(processes: app.processIDs, deviceUID: outputUID, stream: 0)
        description.uuid = tapUUID
        description.name = "Hush: \(app.name)"
        description.isPrivate = true
        description.isMixdown = true
        description.isMono = false
        description.muteBehavior = .mutedWhenTapped
        var tap: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr else { throw HushAudioError("Tap for \(app.name) failed (\(tapStatus))") }
        do {
            guard let format = property(tap, kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self),
                  format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked)
                    == (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked),
                  format.mBitsPerChannel == 32, (1...2).contains(format.mChannelsPerFrame),
                  format.mBytesPerFrame == (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
                    ? 4 * format.mChannelsPerFrame : 4),
                  format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
                  format.mSampleRate > 0 else {
                throw HushAudioError("Unsupported audio format for \(app.name)")
            }
            let route = try AppRoute(ids: app.processIDs, sampleRate: format.mSampleRate)
            route.tap = tap
            do {
                let details: [String: Any] = [
                    kAudioAggregateDeviceNameKey: "Hush \(app.name)",
                    kAudioAggregateDeviceUIDKey: UUID().uuidString,
                    kAudioAggregateDeviceIsPrivateKey: true,
                    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                    kAudioAggregateDeviceMainSubDeviceKey: outputUID
                ]
                let aggregateStatus = AudioHardwareCreateAggregateDevice(details as CFDictionary, &route.aggregate)
                guard aggregateStatus == noErr else {
                    throw HushAudioError("Audio device for \(app.name) failed (\(aggregateStatus))")
                }
                var alive = false
                for _ in 0..<50 {
                    if property(route.aggregate, kAudioDevicePropertyDeviceIsAlive, as: UInt32.self) == 1 {
                        alive = true
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.01)
                }
                guard alive else { throw HushAudioError("Audio device for \(app.name) did not start") }
                engine.attach(route.source)
                engine.attach(route.mixer)
                engine.connect(route.source, to: route.mixer, format: route.source.outputFormat(forBus: 0))
                engine.connect(route.mixer, to: engine.mainMixerNode, format: nil)
                route.mixer.outputVolume = settings.mutedApps.contains(app.id) ? 0 : Float(settings.volumes[app.id] ?? 1)
                route.mixer.pan = Float(settings.balance)
                // Keep the app's native path audible until our output graph can render it.
                if !engineReady {
                    try engine.start()
                    engineReady = true
                }
                let status = AudioDeviceCreateIOProcIDWithBlock(&route.ioProc, route.aggregate, nil) { _, input, _, output, _ in
                    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                    if let buffer = buffers.last, let data = buffer.mData {
                        let count = buffer.mDataByteSize / UInt32(MemoryLayout<Float>.size)
                        if buffer.mNumberChannels == 2 {
                            AudioRingWrite(route.ring, data.assumingMemoryBound(to: Float.self), nil, count / 2, 1)
                        } else if buffer.mNumberChannels == 1, buffers.count >= 2,
                                  let right = buffers[buffers.count - 1].mData {
                            AudioRingWrite(route.ring, buffers[buffers.count - 2].mData?.assumingMemoryBound(to: Float.self),
                                           right.assumingMemoryBound(to: Float.self), count, 0)
                        } else if buffer.mNumberChannels == 1 {
                            AudioRingWrite(route.ring, data.assumingMemoryBound(to: Float.self), nil, count, 0)
                        }
                    }
                    for buffer in UnsafeMutableAudioBufferListPointer(output) {
                        if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                    }
                }
                guard status == noErr else { throw HushAudioError("Capture for \(app.name) failed (\(status))") }
                var tapList: CFArray = [tapUUID.uuidString] as CFArray
                var tapAddress = address(kAudioAggregateDevicePropertyTapList)
                let tapStatus = withUnsafeMutablePointer(to: &tapList) {
                    AudioObjectSetPropertyData(route.aggregate, &tapAddress, 0, nil,
                                               UInt32(MemoryLayout<CFArray>.size), $0)
                }
                guard tapStatus == noErr else { throw HushAudioError("Attaching \(app.name) failed (\(tapStatus))") }
                let start = AudioDeviceStart(route.aggregate, route.ioProc)
                guard start == noErr else { throw HushAudioError("Starting \(app.name) failed (\(start))") }
                routes[app.id] = route
                routeStarts += 1
                lastRouteSetupMs = (ProcessInfo.processInfo.systemUptime - setupStarted) * 1_000
            } catch {
                if let ioProc = route.ioProc { AudioDeviceDestroyIOProcID(route.aggregate, ioProc) }
                if route.aggregate != 0 { AudioHardwareDestroyAggregateDevice(route.aggregate) }
                if route.source.engine != nil { engine.detach(route.source) }
                if route.mixer.engine != nil { engine.detach(route.mixer) }
                throw error
            }
        } catch {
            AudioHardwareDestroyProcessTap(tap)
            throw error
        }
    }

    private func remove(_ id: String) {
        guard let route = routes.removeValue(forKey: id) else { return }
        if let ioProc = route.ioProc {
            AudioDeviceStop(route.aggregate, ioProc)
            AudioDeviceDestroyIOProcID(route.aggregate, ioProc)
        }
        route.mixer.outputVolume = 0
        AudioHardwareDestroyAggregateDevice(route.aggregate)
        AudioHardwareDestroyProcessTap(route.tap)
        if engine.isRunning {
            engine.disconnectNodeOutput(route.source)
            retired.append(route)
        } else {
            engine.detach(route.source)
            engine.detach(route.mixer)
        }
    }
}
