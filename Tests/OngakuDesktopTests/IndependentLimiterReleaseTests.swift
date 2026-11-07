import AVFoundation
import Foundation
import Testing
@testable import OngakuDesktop

#if DEBUG && ONGAKU_ENABLE_TRUE_PEAK && ONGAKU_ENABLE_AUDIO_THREAD_GAIN
@MainActor @Suite("Independent final limiter release", .serialized)
struct IndependentLimiterReleaseTests {
    @Test func quietProbeRecovers() throws {
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        let protection = FinalOutputProtection(enabled: true)
        #expect(protection.isEnabled)
        engine.attach(player); protection.attach(to: engine)
        let source = AVAudioFormat(standardFormatWithSampleRate: 96_000, channels: 2)!
        let output = AVAudioFormat(standardFormatWithSampleRate: 88_200, channels: 2)!
        engine.connect(player, to: protection.inputNode(in: engine), format: source)
        try protection.connect(engine: engine, outputFormat: output)
        protection.setVolume(1, engine: engine)
        try engine.enableManualRenderingMode(.offline, format: output, maximumFrameCount: 1024)
        let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 144_000)!
        input.frameLength = input.frameCapacity
        for c in 0..<2 { for i in 0..<Int(input.frameLength) {
            let t = Double(i) / 96_000
            input.floatChannelData![c][i] = Float((t < 0.1 ? 4 : 0.04) * sin(2 * .pi * 997 * t))
        } }
        player.scheduleBuffer(input, at: nil, options: [], completionHandler: nil)
        try engine.start(); player.play()
        defer { player.stop(); engine.stop() }
        let block = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 1024)!
        var pcm = [[Float](), [Float]()]
        while pcm[0].count < 114_660 {
            #expect(try engine.renderOffline(1024, to: block) == .success)
            for c in 0..<2 { pcm[c].append(contentsOf: UnsafeBufferPointer(start: block.floatChannelData![c], count: Int(block.frameLength))) }
        }
        func rms(_ start: Double, _ end: Double) -> Double {
            let values = pcm[0][Int(start * 88_200)..<Int(end * 88_200)]
            return sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(values.count))
        }
        let early = rms(0.12, 0.14), late = rms(0.8, 1.0), expected = 0.04 / sqrt(2)
        let peak = IndependentIntersampleMeter().peak(pcm)
        #expect(peak <= pow(10, -1.0 / 20))
        #expect(abs(late / expected - 1) < 0.02)
        #expect(late > early * 1.1)
        print("LIMITER_RELEASE earlyRMS=\(early) lateRMS=\(late) expectedRMS=\(expected) isp=\(peak)")
    }
}
#endif
