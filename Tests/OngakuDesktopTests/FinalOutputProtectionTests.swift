import AVFoundation
import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Final output true-peak", .serialized)
struct FinalOutputProtectionTests {
    @Test("Build condition controls activation and diagnostics")
    func activation() {
        let stage = FinalOutputProtection()
        #if ONGAKU_ENABLE_TRUE_PEAK
        #expect(stage.isEnabled)
        #else
        #expect(!stage.isEnabled)
        #expect(stage.nodes.isEmpty)
        #expect(stage.latency == 0)
        #endif
    }

    @Test("Final conversion, user volume, latency and reset survive rate/channel rebuilds")
    func reconfigure() throws {
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        let stage = FinalOutputProtection(enabled: true)
        engine.attach(player); stage.attach(to: engine)
        let input = try #require(AVAudioFormat(standardFormatWithSampleRate: 96_000, channels: 2))
        for (rate, channels) in [(44_100.0, UInt32(2)), (48_000.0, 1), (96_000.0, 2), (192_000.0, 2), (384_000.0, 2), (48_000.0, 2)] {
            let output = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
            engine.disconnectNodeOutput(player)
            stage.nodes.forEach { engine.disconnectNodeOutput($0) }
            engine.disconnectNodeOutput(engine.mainMixerNode)
            engine.connect(player, to: stage.inputNode(in: engine), format: input)
            try stage.connect(engine: engine, outputFormat: output)
            stage.setVolume(0.01, engine: engine)
            try engine.enableManualRenderingMode(.offline, format: output, maximumFrameCount: 512)
            let protector = try #require(stage.protector)
            #expect(protector.inputFormat(forBus: 0).sampleRate == rate)
            #expect(protector.outputFormat(forBus: 0).sampleRate == rate)
            #expect(protector.outputFormat(forBus: 0).channelCount == channels)
            #expect(engine.mainMixerNode.outputFormat(forBus: 0).sampleRate == rate)
            #expect(engine.mainMixerNode.outputVolume == 1)
            #expect(abs(stage.latency * rate - (ceil(rate * 0.004) + 64)) < 0.00001)

            // 4.0 * .01 = .04: if volume moves after the limiter, this test fails.
            let source = try #require(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 9_600))
            source.frameLength = source.frameCapacity
            for c in 0..<2 { for f in 0..<9_600 {
                source.floatChannelData![c][f] = Float(4 * sin(2 * .pi * 997 * Double(f) / 96_000))
            } }
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 512))
            player.scheduleBuffer(source); try engine.start(); player.play()
            var peak: Float = 0
            for _ in 0..<Int(rate * 0.12 / 512) + 2 {
                #expect(try engine.renderOffline(512, to: buffer) == .success)
                for f in 0..<Int(buffer.frameLength) { peak = max(peak, abs(buffer.floatChannelData![0][f])) }
            }
            // Apple's stereo -> mono mixer uses equal-power summation (+3 dB
            // for these identical channels). Mapping still precedes protection.
            let expectedPeak: Float = channels == 1 ? 0.04 * sqrt(2) : 0.04
            #expect(abs(peak - expectedPeak) < 0.005,
                    "rate=\(rate) channels=\(channels) peak=\(peak)")
            engine.stop(); player.stop()

            // Leave hot audio queued in the lookahead, then exercise the transport reset.
            stage.setVolume(1, engine: engine)
            player.scheduleBuffer(source); try engine.start(); player.play()
            #expect(try engine.renderOffline(127, to: buffer) == .success)
            engine.stop(); player.stop(); stage.resetWhileStopped(engine: engine)
            let silence = try #require(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 4_096))
            silence.frameLength = silence.frameCapacity
            for c in 0..<2 { silence.floatChannelData![c].initialize(repeating: 0, count: 4_096) }
            player.scheduleBuffer(silence); try engine.start(); player.play()
            for _ in 0..<8 {
                #expect(try engine.renderOffline(512, to: buffer) == .success)
                for c in 0..<Int(channels) { for f in 0..<512 {
                    #expect(buffer.floatChannelData![c][f] == 0)
                } }
            }
            engine.stop(); player.stop(); engine.disableManualRenderingMode()
        }
    }

    @Test("Invalid output format fails instead of bypassing protection")
    func unsupportedFormat() throws {
        let stage = FinalOutputProtection(enabled: true), engine = AVAudioEngine()
        stage.attach(to: engine)
        let output = try #require(AVAudioFormat(standardFormatWithSampleRate: 4_000, channels: 2))
        #expect(throws: (any Error).self) { try stage.connect(engine: engine, outputFormat: output) }
    }
    @Test("Transition envelope multiplies the latest user volume before final protection")
    func independentEnvelope() throws {
        for enabled in [false, true] {
            let engine = AVAudioEngine(), stage = FinalOutputProtection(enabled: enabled)
            stage.attach(to: engine)
            let mixer = try #require(stage.inputNode(in: engine) as? AVAudioMixerNode)
            stage.setVolume(0.8, engine: engine)
            stage.setTransitionGain(0.25, engine: engine)
            #expect(abs(mixer.outputVolume - 0.2) < 0.000001)
            stage.setVolume(0.4, engine: engine)
            #expect(abs(mixer.outputVolume - 0.1) < 0.000001)
            stage.setTransitionGain(0, engine: engine)
            stage.setVolume(0.7, engine: engine)
            #expect(mixer.outputVolume == 0)
            stage.setTransitionGain(1, engine: engine)
            #expect(mixer.outputVolume == 0.7)
            if enabled { #expect(engine.mainMixerNode.outputVolume == 1) }
        }
    }

}
