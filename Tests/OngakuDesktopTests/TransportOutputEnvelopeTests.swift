import AVFoundation
import Foundation
import Testing
@testable import OngakuDesktop

@MainActor private final class TransportClock {
    var now = 0.0
    var events: [(Double, Int, @MainActor () -> Void)] = []
    var serial = 0
    func schedule(_ delay: Double, _ action: @escaping @MainActor () -> Void) {
        serial += 1; events.append((now + delay, serial, action))
    }
    func advance(_ target: Double) {
        while let next = events.enumerated().filter({ $0.element.0 <= target })
            .min(by: { ($0.element.0, $0.element.1) < ($1.element.0, $1.element.1) }) {
            let event = events.remove(at: next.offset); now = event.0; event.2()
        }
        now = target
    }
}

@Suite("Transport output continuity", .serialized)
@MainActor struct TransportOutputEnvelopeTests {
    @Test("Render gating, fade and drain keep sources alive until zero")
    func ordering() {
        let clock = TransportClock(); var gain: Float = 1; var ready = false; var alive = true
        let ramp = TransportOutputEnvelope(schedule: clock.schedule) { gain = $0 }
        ramp.start(ready: { ready }, failed: { Issue.record("unexpected render timeout") })
        clock.advance(0.020); #expect(gain == 0 && ramp.isStarting)
        ready = true; clock.advance(0.049); #expect(gain == 1 && !ramp.isBusy)
        ramp.stop(running: true, drain: 0.012) { #expect(gain == 0); alive = false }
        clock.advance(0.0731); #expect(gain == 0 && alive)
        clock.advance(0.0851); #expect(!alive && !ramp.isBusy)
    }

    @Test("Repeated stop and superseding seek/load commit only the newest action")
    func supersession() {
        let clock = TransportClock(); var commits: [Int] = []
        let ramp = TransportOutputEnvelope(schedule: clock.schedule) { _ in }
        ramp.start(ready: { true }, failed: {})
        clock.advance(0.025)
        ramp.stop(running: true, drain: 0.012) { commits.append(1) }
        clock.advance(0.030)
        ramp.stop(running: true, drain: 9) { commits.append(2) }
        clock.advance(0.062)
        #expect(commits == [2]) // The second stop must not extend the original drain.
        ramp.start(ready: { true }, failed: {})
        clock.advance(0.100)
        #expect(ramp.gain == 1)
        clock.advance(10); #expect(commits == [2] && ramp.gain == 1)
    }

    @Test("Stop cancels startup and late callbacks; render timeout remains silent")
    func cancelAndTimeout() {
        let clock = TransportClock(); var failed = 0; var stopped = 0
        let ramp = TransportOutputEnvelope(schedule: clock.schedule) { _ in }
        ramp.start(ready: { false }, failed: { failed += 1 })
        clock.advance(0.01)
        ramp.stop(running: true, drain: 0.012) { stopped += 1 }
        clock.advance(2); #expect(stopped == 1 && failed == 0 && ramp.gain == 0)
        ramp.start(ready: { false }, failed: { failed += 1 })
        clock.advance(3.1); #expect(failed == 1 && ramp.gain == 0 && !ramp.isBusy)
        ramp.stop(running: false, drain: 100) { stopped += 1 }
        #expect(stopped == 2)
    }

    @Test("Transport, user volume and bypass gains remain independent in both output paths")
    func gainComposition() throws {
        for enabled in [false, true] {
            let engine = AVAudioEngine(); let stage = FinalOutputProtection(enabled: enabled)
            stage.attach(to: engine)
            let mixer = try #require(stage.inputNode(in: engine) as? AVAudioMixerNode)
            stage.setVolume(0.8, engine: engine)
            stage.setTransitionGain(0.5, engine: engine)
            stage.setTransportGain(0.25, engine: engine)
            #expect(abs(mixer.outputVolume - 0.1) < 0.00001)
            stage.setVolume(0.4, engine: engine)
            stage.setTransitionGain(1, engine: engine)
            #expect(abs(mixer.outputVolume - 0.1) < 0.00001)
            stage.setTransportGain(0, engine: engine)
            stage.setTransitionGain(1, engine: engine)
            #expect(mixer.outputVolume == 0)
            if enabled { #expect(engine.mainMixerNode.outputVolume == 1) }
        }
    }

    @Test("Ordinary and true-peak PCM fade/drain satisfy iPhone step and silence criteria")
    func pcm() throws {
        for enabled in [false, true] { for rate in [44_100.0, 48_000.0, 96_000.0] {
            let clock = TransportClock(), engine = AVAudioEngine(), player = AVAudioPlayerNode()
            let stage = FinalOutputProtection(enabled: enabled)
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
            engine.attach(player); stage.attach(to: engine)
            engine.connect(player, to: stage.inputNode(in: engine), format: format)
            try stage.connect(engine: engine, outputFormat: format)
            let ramp = TransportOutputEnvelope(schedule: clock.schedule) { stage.setTransportGain($0, engine: engine) }
            stage.setVolume(1, engine: engine)
            stage.setTransportGain(0, engine: engine)
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 32)
            let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate)))
            input.frameLength = input.frameCapacity
            for ch in 0..<2 { input.floatChannelData![ch].initialize(repeating: ch == 0 ? 0.4 : -0.2, count: Int(input.frameLength)) }
            let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
            player.scheduleBuffer(input); try engine.start(); player.play()
            clock.schedule(0.02) { ramp.start(ready: { true }, failed: {}) }
            var sourceStopped = false
            clock.schedule(0.08) { ramp.stop(running: true, drain: 0.012 + stage.latency) {
                #expect(ramp.gain == 0); player.stop(); sourceStopped = true
            } }
            var previous = [Float](repeating: 0, count: 2), maxStep: Float = 0, tailPeak: Float = 0
            for index in 0..<Int(rate * 0.2 / 32) {
                let t = Double(index * 32) / rate; clock.advance(t)
                #expect(try engine.renderOffline(32, to: output) == .success)
                for ch in 0..<2 { for f in 0..<Int(output.frameLength) {
                    let sample = output.floatChannelData![ch][f]
                    #expect(sample.isFinite)
                    maxStep = max(maxStep, abs(sample - previous[ch])); previous[ch] = sample
                    if t > 0.15 { tailPeak = max(tailPeak, abs(sample)) }
                } }
            }
            #expect(sourceStopped && tailPeak < 0.000001)
            #expect(Double(maxStep) * rate < 25)
            print("MAC_TRANSPORT_PCM candidate=\(enabled) rate=\(rate) maxStep=\(maxStep) tailPeak=\(tailPeak)")
            engine.stop()
        } }
    }
}
