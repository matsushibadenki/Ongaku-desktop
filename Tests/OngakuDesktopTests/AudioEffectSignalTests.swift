import AVFoundation
import Testing
@testable import OngakuDesktop

@Suite("Effect signal audit", .serialized)
@MainActor
struct AudioEffectSignalTests {
    static func render(_ effects: [AudioEffectNode], settings: [RealtimeAudioEffectSetting],
                       rate: Double = 48_000, amplitude: Double = 0.1,
                       frequency: Double = 1_000, protected: Bool = false, volume: Float = 1, impulse: Bool = false) throws -> [Float] {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        engine.attach(player)
        var upstream: AVAudioNode = player
        for effect in effects {
            effect.attach(to: engine)
            engine.connect(upstream, to: effect.inputNode, format: format)
            effect.connectInternalNodes(engine: engine, format: format)
            upstream = effect.outputNode
        }
        let protection = EffectOutputProtection()
        if protected {
            protection.attach(to: engine)
            protection.connect(from: upstream, engine: engine, format: format)
            protection.setEnabled(settings.contains { $0.isEnabled })
        } else {
            engine.connect(upstream, to: engine.mainMixerNode, format: format)
        }
        engine.mainMixerNode.outputVolume = volume
        for (effect, setting) in zip(effects, settings) { effect.apply(setting: setting) }
        defer { engine.stop(); effects.forEach { $0.detach(from: engine) } }
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let frames = Int(rate)
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        input.frameLength = input.frameCapacity
        for channel in 0..<2 {
            for i in 0..<frames {
                input.floatChannelData![channel][i] = Float(impulse ? (i == 4096 ? amplitude : 0) : amplitude * sin(2 * .pi * frequency * Double(i) / rate))
            }
        }
        player.scheduleBuffer(input)
        try engine.start()
        player.play()
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        var samples: [Float] = []
        while samples.count < frames {
            let count = AVAudioFrameCount(min(1024, frames - samples.count))
            let status = try engine.renderOffline(count, to: output)
            guard status == .success else { throw NSError(domain: "Render", code: Int(status.rawValue)) }
            samples.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
        }
        return samples
    }

    @Test func auditEveryEffect() throws {
        for rate in [44_100.0, 48_000, 96_000] {
            for (effect, var setting) in zip(AudioEffectModuleRegistry.makePipeline(), AudioEffectModuleRegistry.makeDefaultSettings()) {
                setting.isEnabled = false
                let bypass = try Self.render([effect], settings: [setting], rate: rate)
                let rms = sqrt(bypass.dropFirst(Int(rate / 4)).reduce(0.0) { $0 + Double($1 * $1) } / Double(bypass.count - Int(rate / 4)))
                print("BYPASS \(setting.kind) \(rate): \(rms)")
                #expect(abs(rms - 0.1 / sqrt(2)) < 0.001)
                setting.isEnabled = true
                setting.parameters["flutter"] = 0
                let active = try Self.render([effect], settings: [setting], rate: rate)
                #expect(active.allSatisfy { $0.isFinite })
                let peak = active.map { abs($0) }.max()!
                print("ACTIVE \(setting.kind) \(rate): peak \(peak)")
                #expect(peak > 0.001)
            }
        }
    }

    @Test func dynamicsUseSecondsAndDisableExpansion() {
        let effect = OptoFETAudioEffect()
        let engine = AVAudioEngine()
        effect.attach(to: engine)
        defer { effect.detach(from: engine) }
        for unit in effect.nodes.compactMap({ $0 as? AVAudioUnitEffect })
        where unit.audioComponentDescription.componentSubType == kAudioUnitSubType_DynamicsProcessor {
            let tree = unit.auAudioUnit.parameterTree!
            #expect(abs(tree.parameter(withAddress: 4)!.value - 0.020) < 0.00001)
            #expect(abs(tree.parameter(withAddress: 5)!.value - 0.200) < 0.00001)
            #expect(tree.parameter(withAddress: 2)!.value == 1)
        }
    }

    @Test func frequencyAndLevelMatrix() throws {
        for rate in [44_100.0, 48_000, 96_000, 192_000] {
            for maximum in [false, true] {
                for var setting in AudioEffectModuleRegistry.makeDefaultSettings() {
                    setting.isEnabled = true
                    if maximum { for key in setting.parameters.keys { setting.parameters[key] = 1 } }
                    setting.parameters["flutter"] = 0
                    var largestPeak: Float = 0
                    for frequency in [80.0, 250, 1_000, 6_000, 12_000] {
                        let effect = AudioEffectModuleRegistry.makePipeline().first { $0.kind == setting.kind }!
                        let samples = try Self.render([effect], settings: [setting], rate: rate,
                                                      amplitude: 0.9, frequency: frequency)
                        #expect(samples.allSatisfy { $0.isFinite })
                        let peak = samples.map { abs($0) }.max()!
                        #expect(peak > 0.0001)
                        largestPeak = max(largestPeak, peak)
                    }
                    print("MATRIX \(rate) \(setting.kind) max=\(maximum) peak=\(largestPeak)")
                }
                var settings = AudioEffectModuleRegistry.makeDefaultSettings()
                for i in settings.indices {
                    settings[i].isEnabled = true
                    if maximum { for key in settings[i].parameters.keys { settings[i].parameters[key] = 1 } }
                    settings[i].parameters["flutter"] = 0
                }
                for frequency in [80.0, 250, 1_000, 6_000, 12_000] {
                    let samples = try Self.render(AudioEffectModuleRegistry.makePipeline(), settings: settings,
                        rate: rate, amplitude: 0.99, frequency: frequency, protected: true)
                    let peak = samples.map { abs($0) }.max()!
                    print("FINAL \(rate) max=\(maximum) Hz=\(frequency) peak=\(peak)")
                    #expect(samples.allSatisfy { $0.isFinite })
                    #expect(peak <= 0.90)
                    #expect(peak > 0.0001)
                }
            }
        }
    }

    @Test func limiterHandlesOverloadAndBypass() throws {
        var setting = AudioEffectModuleRegistry.makeDefaultSettings()[0]
        for rate in [44_100.0, 48_000, 96_000, 192_000] {
            setting.isEnabled = true
            for impulse in [false, true] {
                let samples = try Self.render([], settings: [setting], rate: rate,
                    amplitude: 16, protected: true, impulse: impulse)
                let peak = samples.map { abs($0) }.max()!
                print("LIMITER \(rate) impulse=\(impulse) peak=\(peak)")
                #expect(samples.allSatisfy { $0.isFinite })
                #expect(peak <= 0.90)
                #expect(peak > 0.01)
            }
            setting.isEnabled = false
            let samples = try Self.render([], settings: [setting], rate: rate, protected: true)
            #expect(abs(samples.map { abs($0) }.max()! - 0.1) < 0.00001)
        }
    }

    @Test func warmAndExciterFiltersAreActiveAndWarmHasFourDistinctInputs() throws {
        for effect: AudioEffectNode in [WarmAudioEffect(), ExciterAudioEffect()] {
            let engine = AVAudioEngine()
            effect.attach(to: engine)
            defer { effect.detach(from: engine) }
            let eqs = effect.nodes.compactMap { $0 as? AVAudioUnitEQ }
            #expect(eqs.allSatisfy { $0.bands.allSatisfy { !$0.bypass } })
            if effect.kind == .warm {
                let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
                effect.connectInternalNodes(engine: engine, format: format)
                for bus in 0..<4 {
                    #expect(engine.inputConnectionPoint(for: effect.outputNode, inputBus: AVAudioNodeBus(bus)) != nil)
                }
            }
        }
    }

    @Test func silenceAndOutputVolume() throws {
        var settings = AudioEffectModuleRegistry.makeDefaultSettings()
        for i in settings.indices { settings[i].isEnabled = true; settings[i].parameters["flutter"] = 0 }
        let silence = try Self.render(AudioEffectModuleRegistry.makePipeline(), settings: settings,
                                      amplitude: 0, protected: true)
        #expect(silence.allSatisfy { $0.isFinite && abs($0) < 0.00001 })
        let full = try Self.render(AudioEffectModuleRegistry.makePipeline(), settings: settings, protected: true)
        let half = try Self.render(AudioEffectModuleRegistry.makePipeline(), settings: settings, protected: true, volume: 0.5)
        #expect(zip(full, half).allSatisfy { abs($0 * 0.5 - $1) < 0.00001 })
    }
}
