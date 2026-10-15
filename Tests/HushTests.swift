import XCTest
import AVFoundation
import AudioRing
@testable import Hush

final class HushTests: XCTestCase {
    func testRingCarriesStereoAndFillsOnlyMissingFrames() {
        let ring = AudioRingCreate(4)!
        defer { AudioRingDestroy(ring) }
        let source: [Float] = [1, 2, 3, 4]
        source.withUnsafeBufferPointer { AudioRingWrite(ring, $0.baseAddress, nil, 2, 1) }
        var left = [Float](repeating: -1, count: 3)
        var right = [Float](repeating: -1, count: 3)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in AudioRingRead(ring, l.baseAddress, r.baseAddress, 3) }
        }
        XCTAssertEqual(left, [1, 3, 0])
        XCTAssertEqual(right, [2, 4, 0])
        XCTAssertEqual(AudioRingGetStats(ring).underrunFrames, 1)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in AudioRingRead(ring, l.baseAddress, r.baseAddress, 2) }
        }
        XCTAssertEqual(Array(left.prefix(2)), [0, 0])
        XCTAssertEqual(Array(right.prefix(2)), [0, 0])
        XCTAssertEqual(AudioRingRecentlyActive(ring), 1)
    }

    func testRingSkipsBacklogToBoundDelay() {
        let ring = AudioRingCreate(8)!
        defer { AudioRingDestroy(ring) }
        let source = (1...8).map(Float.init)
        source.withUnsafeBufferPointer { AudioRingWrite(ring, $0.baseAddress, nil, 8, 0) }
        var left = [Float](repeating: 0, count: 2)
        var right = left
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in AudioRingRead(ring, l.baseAddress, r.baseAddress, 2) }
        }
        XCTAssertEqual(left, [5, 6])
        XCTAssertEqual(AudioRingGetStats(ring).skippedFrames, 4)
        let next: [Float] = [9, 10]
        next.withUnsafeBufferPointer { AudioRingWrite(ring, $0.baseAddress, nil, 2, 0) }
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in AudioRingRead(ring, l.baseAddress, r.baseAddress, 2) }
        }
        XCTAssertEqual(left, [7, 8])
        XCTAssertEqual(AudioRingGetStats(ring).queuedFrames, 2)
    }

    func testEqualizerRangeAndResponse() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let engine = AVAudioEngine()
        let equalizer = AudioRouter.makeEqualizer()
        var phase = 0.0
        var frequency = 1_000.0
        let source = AVAudioSourceNode(format: format) { _, _, count, output in
            let buffers = UnsafeMutableAudioBufferListPointer(output)
            for frame in 0..<Int(count) {
                let sample = Float(sin(phase) * 0.01)
                phase += 2 * .pi * frequency / 48_000
                for buffer in buffers {
                    buffer.mData!.assumingMemoryBound(to: Float.self)[frame] = sample
                }
            }
            return noErr
        }
        engine.attach(source)
        engine.attach(equalizer)
        engine.connect(source, to: equalizer, format: format)
        engine.connect(equalizer, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        try engine.start()
        defer { engine.stop() }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        func rms() throws -> Double {
            var sum = 0.0
            for block in 0..<64 {
                XCTAssertEqual(try engine.renderOffline(512, to: buffer), .success)
                if block >= 16 {
                    for sample in UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 512) {
                        sum += Double(sample * sample)
                    }
                }
            }
            return sqrt(sum / (48 * 512))
        }
        for (index, center) in HushSettings.frequencies.enumerated() {
            frequency = Double(center)
            let band = equalizer.bands[index]
            XCTAssertEqual(band.frequency, Float(center))
            XCTAssertEqual(band.bandwidth, 1)
            equalizer.bypass = true
            let flat = try rms()
            equalizer.bypass = false
            band.gain = 24
            XCTAssertEqual(band.gain, 24)
            let boost = try rms()
            band.gain = -24
            XCTAssertEqual(band.gain, -24)
            let cut = try rms()
            XCTAssertEqual(20 * log10(boost / flat), 24, accuracy: 1, "\(center) Hz")
            XCTAssertEqual(20 * log10(cut / flat), -24, accuracy: 1, "\(center) Hz")
            band.gain = 0
        }
        let gaming = HushSettings.builtIn.first { $0.name == "Gaming" }!
        equalizer.bypass = true
        frequency = 64
        let flatBass = try rms()
        frequency = 4_000
        let flatPresence = try rms()
        for (band, gain) in zip(equalizer.bands, gaming.bands) { band.gain = Float(gain) }
        equalizer.globalGain = Float(gaming.preamp)
        equalizer.bypass = false
        frequency = 64
        let bass = try rms()
        frequency = 4_000
        let presence = try rms()
        let bassGain = 20 * log10(bass / flatBass)
        let presenceGain = 20 * log10(presence / flatPresence)
        XCTAssertGreaterThan(presenceGain - bassGain, 10)
        XCTAssertLessThan(presenceGain, 2)
    }

    func testOutputProfilesStayIndependent() {
        var settings = HushSettings()
        settings.activateOutput("earbuds")
        settings.bands[6] = 6
        settings.preamp = -4
        settings.dynamics.compressorEnabled = true
        settings.activateOutput("speakers")
        XCTAssertEqual(settings.bands[6], 0)
        XCTAssertFalse(settings.dynamics.compressorEnabled)
        settings.bands[1] = 3
        settings.activateOutput("earbuds")
        XCTAssertEqual(settings.bands[6], 6)
        XCTAssertEqual(settings.bands[1], 0)
        XCTAssertEqual(settings.preamp, -4)
        XCTAssertTrue(settings.dynamics.compressorEnabled)
        settings.activateOutput("speakers")
        XCTAssertEqual(settings.bands[1], 3)
    }

    func testAutoPreampDefaultsOffAndSurvivesProfileRoundTrip() throws {
        var settings = HushSettings()
        settings.activateOutput("headphones")
        settings.bands = [2, -1, 7, 0, 3, 0, 0, 0, 0, 0]
        settings.autoPreamp = true
        settings.activateOutput("speakers")
        settings.autoPreamp = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(HushSettings.self, from: data)
        XCTAssertTrue(decoded.autoPreamp)
        XCTAssertTrue(decoded.deviceProfiles["headphones"]?.autoPreamp == true)

        let legacy = #"{"selectedPreset":"Flat","bands":[0,0,0,0,0,0,0,0,0,0],"preamp":0,"balance":0,"outputTrim":1}"#.data(using: .utf8)!
        XCTAssertFalse(try JSONDecoder().decode(DeviceProfile.self, from: legacy).autoPreamp)
    }

    func testMasterRestoreStateRoundTrip() throws {
        let settings = MasterOptionState(equalizerEnabled: true, compressorEnabled: false,
                                         limiterEnabled: true, visualizerEnabled: false)
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(MasterOptionState.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    func testSourceEffectScopesRoundTripAndLegacyDefaultsToAll() throws {
        var settings = HushSettings()
        settings.equalizerSources = ["music"]
        settings.equalizerScope = .only
        settings.equalizerOnlySources = ["music"]
        settings.equalizerExcludedSources = ["browser"]
        settings.dynamicsSources = []
        settings.dynamicsScope = .excluding
        settings.dynamicsExcludedSources = ["chat"]
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(HushSettings.self, from: data)
        XCTAssertEqual(decoded.equalizerSources, ["music"])
        XCTAssertEqual(decoded.equalizerScope, .only)
        XCTAssertEqual(decoded.equalizerOnlySources, ["music"])
        XCTAssertEqual(decoded.equalizerExcludedSources, ["browser"])
        XCTAssertEqual(decoded.dynamicsSources, [])
        XCTAssertEqual(decoded.dynamicsScope, .excluding)
        XCTAssertEqual(decoded.dynamicsExcludedSources, ["chat"])

        let legacy = #"{"masterEnabled":true,"equalizerEnabled":true}"#.data(using: .utf8)!
        let old = try JSONDecoder().decode(HushSettings.self, from: legacy)
        XCTAssertNil(old.equalizerSources)
        XCTAssertNil(old.dynamicsSources)
    }

    func testMixerSourcesPersistIndependentlyFromActiveAudio() throws {
        var settings = HushSettings()
        settings.manualSources = ["com.example.player"]
        settings.pinnedSources = ["com.example.browser"]
        settings.dismissedSources = ["com.example.hidden"]
        settings.sourceNames = [
            "com.example.player": "Player",
            "com.example.browser": "Browser"
        ]
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(HushSettings.self, from: data)
        XCTAssertEqual(decoded.manualSources, ["com.example.player"])
        XCTAssertEqual(decoded.pinnedSources, ["com.example.browser"])
        XCTAssertEqual(decoded.dismissedSources, ["com.example.hidden"])
        XCTAssertEqual(decoded.sourceNames["com.example.player"], "Player")
    }

    func testSourceOutputAssignmentsRoundTripAndLegacyDefaultsToFallback() throws {
        var settings = HushSettings()
        settings.sourceOutputs["com.example.player"] = "headphones"
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(HushSettings.self, from: data)
        XCTAssertEqual(decoded.sourceOutputs["com.example.player"], "headphones")

        let legacy = #"{"masterEnabled":true,"equalizerEnabled":true}"#.data(using: .utf8)!
        XCTAssertTrue(try JSONDecoder().decode(HushSettings.self, from: legacy).sourceOutputs.isEmpty)
    }

    func testOlderOutputProfileDecode() throws {
        let data = #"{"selectedPreset":"Flat","bands":[0,0,0,0,0,0,0,0,0,0],"preamp":0,"balance":0,"outputTrim":1}"#.data(using: .utf8)!
        let profile = try JSONDecoder().decode(DeviceProfile.self, from: data)
        XCTAssertFalse(profile.dynamics.compressorEnabled)
        XCTAssertFalse(profile.dynamics.limiterEnabled)
    }

    func testNativeCompressorAndLimiterProcessAudio() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let engine = AVAudioEngine()
        let compressor = AudioRouter.makeEffect(kAudioUnitSubType_DynamicsProcessor)
        let limiter = AudioRouter.makeEffect(kAudioUnitSubType_PeakLimiter)
        XCTAssertEqual(compressor.auAudioUnit.componentDescription.componentManufacturer,
                       kAudioUnitManufacturer_Apple)
        XCTAssertEqual(limiter.auAudioUnit.componentDescription.componentManufacturer,
                       kAudioUnitManufacturer_Apple)
        var phase = 0.0
        let source = AVAudioSourceNode(format: format) { _, _, count, output in
            for buffer in UnsafeMutableAudioBufferListPointer(output) {
                let samples = buffer.mData!.assumingMemoryBound(to: Float.self)
                for frame in 0..<Int(count) {
                    samples[frame] = Float(0.8 * sin(phase + Double(frame) * 2 * .pi * 1_000 / 48_000))
                }
            }
            phase += Double(count) * 2 * .pi * 1_000 / 48_000
            return noErr
        }
        engine.attach(source)
        engine.attach(compressor)
        engine.attach(limiter)
        engine.connect(source, to: compressor, format: format)
        engine.connect(compressor, to: limiter, format: format)
        engine.connect(limiter, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        try engine.start()
        defer { engine.stop() }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        func measure() throws -> (rms: Double, peak: Double) {
            var sum = 0.0
            var peak = 0.0
            for block in 0..<64 {
                XCTAssertEqual(try engine.renderOffline(512, to: buffer), .success)
                if block >= 16 {
                    for sample in UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 512) {
                        sum += Double(sample * sample)
                        peak = max(peak, abs(Double(sample)))
                    }
                }
            }
            return (sqrt(sum / (48 * 512)), peak)
        }
        compressor.bypass = true
        limiter.bypass = true
        let plain = try measure()
        compressor.auAudioUnit.parameterTree?.parameter(withAddress: AUParameterAddress(kDynamicsProcessorParam_Threshold))?.value = -18
        compressor.auAudioUnit.parameterTree?.parameter(withAddress: AUParameterAddress(kDynamicsProcessorParam_HeadRoom))?.value = 8
        compressor.bypass = false
        let compressed = try measure()
        XCTAssertLessThan(compressed.rms, plain.rms * 0.8)
        XCTAssertGreaterThan(compressor.auAudioUnit.parameterTree?
            .parameter(withAddress: AUParameterAddress(kDynamicsProcessorParam_CompressionAmount))?.value ?? 0, 2)
        compressor.bypass = true
        limiter.auAudioUnit.parameterTree?.parameter(withAddress: AUParameterAddress(kLimiterParam_PreGain))?.value = 12
        limiter.bypass = false
        let limited = try measure()
        XCTAssertLessThanOrEqual(limited.peak, 1.01)
        XCTAssertGreaterThan(compressor.latency, 0)
        XCTAssertGreaterThan(limiter.latency, 0)
    }

    func testOlderSavedPresetsDecode() throws {
        let data = #"{"name":"Old","bands":[0,0,0,0,0,0,0,0,0,0]}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(EQPreset.self, from: data).preamp, 0)
    }

    func testPresetShape() {
        XCTAssertTrue(HushSettings.builtIn.allSatisfy { $0.bands.count == HushSettings.frequencies.count })
    }

    func testEqualizerIsAppleAudioUnit() {
        XCTAssertEqual(AudioRouter.makeEqualizer().auAudioUnit.componentDescription.componentManufacturer,
                       kAudioUnitManufacturer_Apple)
    }
}
