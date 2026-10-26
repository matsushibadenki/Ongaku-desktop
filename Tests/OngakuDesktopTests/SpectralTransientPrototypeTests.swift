import AVFoundation
import Testing
@testable import OngakuDesktop

@Suite("Spectral transient prototype", .serialized)
@MainActor
struct SpectralTransientPrototypeTests {
    @Test func defaultOffAndStateRestoration() throws {
        let setting = try #require(AudioEffectModuleRegistry.makeDefaultSettings().first { $0.kind == .spectralTransient })
        #expect(!setting.isEnabled)
        #expect(setting.parameters["intensity"] == 0.20)
        let node = SpectralTransientAudioEffect()
        node.apply(setting: setting)
        #expect(!node.isEnabled && node.estimatedGainBoostDB == 0)
        var on = setting; on.isEnabled = true
        let restored = try JSONDecoder().decode(RealtimeAudioEffectSetting.self,from:JSONEncoder().encode(on))
        node.apply(setting: restored)
        #expect(node.isEnabled && abs(node.estimatedGainBoostDB - 0.3) < 0.00001)
        on.parameters["intensity"] = 0
        node.apply(setting:on)
        #expect(!node.isEnabled)
        on.parameters["intensity"] = .nan
        node.apply(setting:on)
        #expect(!node.isEnabled && node.estimatedGainBoostDB == 0)
    }

    @Test func impulseLatencyAndProtectedOverload() throws {
        for rate in [44_100.0,48_000,96_000,192_000] {
            var setting = RealtimeAudioEffectSetting(kind:.spectralTransient)
            let dry = try AudioEffectSignalTests.render([SpectralTransientAudioEffect()],settings:[setting],rate:rate,amplitude:0.5,impulse:true)
            let bare = try AudioEffectSignalTests.render([],settings:[],rate:rate,amplitude:0.5,impulse:true)
            #expect(dry == bare)
            setting.isEnabled = true; setting.parameters["intensity"] = 1
            let effect = SpectralTransientAudioEffect()
            let wet = try AudioEffectSignalTests.render([effect],settings:[setting],rate:rate,amplitude:0.5,impulse:true)
            #expect(effect.estimatedLatencyFrames == 0 && effect.transitionLatency == 0)
            #expect(dry.firstIndex(where:{ abs($0)>1e-6 }) == wet.firstIndex(where:{ abs($0)>1e-6 }))
            #expect(wet.allSatisfy { $0.isFinite })
            #expect((wet.map { abs($0) }.max() ?? 0) > (dry.map { abs($0) }.max() ?? 0) + 0.0001)
            for impulse in [false,true] {
                let protected = try AudioEffectSignalTests.render([SpectralTransientAudioEffect()],settings:[setting],rate:rate,amplitude:8,frequency:min(15000,rate*0.4),protected:true,impulse:impulse)
                let peak = protected.map { abs($0) }.max() ?? 0
                print("TRANSIENT APPLE PROTECTION rate=\(rate) impulse=\(impulse) peak=\(peak)")
                #expect(peak <= 0.90 && peak > 0.001)
            }
        }
    }

    @Test func switchingPreservesUpstreamReverb() throws {
        let engine = AVAudioEngine(), player = AVAudioPlayerNode(), reverb = AVAudioUnitReverb()
        let effect = SpectralTransientAudioEffect()
        let rate = 48_000.0, format = AVAudioFormat(standardFormatWithSampleRate:48_000,channels:2)!
        engine.attach(player); engine.attach(reverb); effect.attach(to:engine)
        engine.connect(player,to:reverb,format:format)
        engine.connect(reverb,to:effect.inputNode,format:format)
        engine.connect(effect.outputNode,to:engine.mainMixerNode,format:format)
        reverb.loadFactoryPreset(.largeHall); reverb.wetDryMix = 70
        var setting = RealtimeAudioEffectSetting(kind:.spectralTransient,isEnabled:true)
        setting.parameters["intensity"] = 1; effect.apply(setting:setting)
        defer { engine.stop(); effect.detach(from:engine) }
        try engine.enableManualRenderingMode(.offline,format:format,maximumFrameCount:256)
        let input = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:48_000)!
        input.frameLength = input.frameCapacity
        for ch in 0..<2 { for i in 0..<48_000 { input.floatChannelData![ch][i] = i == 4096 ? 0.8 : 0 } }
        player.scheduleBuffer(input); try engine.start(); player.play()
        let output = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:256)!
        var samples:[Float] = []
        while samples.count < 48_000 {
            if samples.count == 12_288 { setting.isEnabled=false; effect.apply(setting:setting) }
            if samples.count == 20_480 { setting.isEnabled=true; effect.apply(setting:setting) }
            if samples.count == 28_672 { setting.isEnabled=false; effect.apply(setting:setting) }
            let result = try engine.renderOffline(256,to:output)
            #expect(result == .success)
            guard result == .success else { return }
            samples.append(contentsOf:UnsafeBufferPointer(start:output.floatChannelData![0],count:Int(output.frameLength)))
        }
        #expect(samples.allSatisfy { $0.isFinite })
        for position in [12_288,20_480,28_672] {
            let energy = samples[(position+2048)..<(position+4096)].reduce(0.0) { $0+Double($1)*Double($1) }
            #expect(energy > 1e-8)
            let jump = abs(samples[position]-samples[position-1])
            #expect(jump < 0.05)
            print("TRANSIENT TAIL switch=\(Double(position)/rate) energy=\(energy) boundaryJump=\(jump)")
        }
    }
}
