import AVFoundation
import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Independent intersample meter")
struct IndependentIntersampleMeterTests {
    @Test func analyticCalibration() {
        let meter = IndependentIntersampleMeter()
        let n = 4096
        let sine = (0..<n).map { Float(sin(.pi * 0.5 * Double($0) + .pi / 4)) }
        let sample = sine.map { abs($0) }.max()!
        let reconstructed = meter.peak([sine], trimming: 192)
        #expect(abs(Double(sample) - sqrt(0.5)) < 0.00001)
        #expect(abs(reconstructed - 1) < 0.001)
        #expect(Double(sample) < pow(10, -1.0 / 20))
        #expect(reconstructed > pow(10, -1.0 / 20), "Known intersample violation must fail the -1 dBTP gate")
        #expect(20 * log10(reconstructed / Double(sample)) > 2.99)
        #expect(abs(meter.peak([Array(repeating: 0.25, count: n)], trimming: 192) - 0.25) < 1e-10)
        #expect(meter.peak([Array(repeating: 0, count: n)]) == 0)
        var edge = [Float](repeating: 0, count: n); edge[0] = 1; edge[n - 1] = -1
        #expect(abs(meter.peak([edge]) - 1) < 0.0001)
        #expect(abs(IndependentIntersampleMeter(radius: 192, phases: 64).peak([sine], trimming: 384) - reconstructed) < 0.001)
        print("ISP_CALIBRATION sample=\(sample) reconstructed=\(reconstructed) expected=1")
    }
}

#if DEBUG && ONGAKU_ENABLE_TRUE_PEAK && ONGAKU_ENABLE_AUDIO_THREAD_GAIN
@MainActor @Suite("Independent product intersample peaks", .serialized)
struct ProductIntersampleTests {
    private func fixture(_ root: URL, rate: Double, phase: Double, amplitude: Double, incoming: Bool) throws -> URL {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 9))!
        pcm.frameLength = pcm.frameCapacity
        for c in 0..<2 { for i in 0..<Int(pcm.frameLength) {
            let t = Double(i) / rate
            let start = incoming ? 0.045 : 0.0
            let level = t < start ? 0 : (t < start + 0.12 ? amplitude : (t < 0.4 ? 0.04 : 0))
            let skew = c == 0 ? 0.0 : 0.9
            let gain = c == 0 ? 1.0 : 0.65
            let tone = sin(2 * .pi * 12_000 * t + phase + skew)
            let impulse = i % 1024 == 0 && t < 0.12 ? amplitude * 0.25 : 0
            pcm.floatChannelData![c][i] = Float(gain * (level * tone + impulse))
        } }
        let url = root.appendingPathComponent(UUID().uuidString + ".caf")
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: pcm) }
        return url
    }

    private func rms(_ pcm: [[Float]], rate: Double, from: Double, to: Double) -> Double {
        let a = Int(from * rate), b = min(pcm[0].count, Int(to * rate))
        guard b > a else { return 0 }
        return sqrt(pcm.flatMap { $0[a..<b] }.reduce(0.0) { $0 + Double($1) * Double($1) } / Double((b - a) * pcm.count))
    }

    @Test func phaseLevelAndLongTail() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProductISP-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = "audio.preventsClipping.v1", saved = UserDefaults.standard.object(forKey: "audio.preventsClipping.v1")
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        let player = PlaybackController(); player.preventsClipping = false
        let meter = IndependentIntersampleMeter()
        var largest = 0.0, worstPCM: [[Float]] = []
        var index = 0
        for sourceRate in [44_100.0, 48_000] {
            for outputRate in [88_200.0, 48_000] {
                for variant in 0..<4 {
                    player.volume = variant % 2 == 0 ? 1 : 0.3
                    let phase = variant / 2 == 0 ? Double.pi / 4 : 3 * .pi / 4
                    let outgoing = try fixture(root, rate: sourceRate, phase: phase, amplitude: 4, incoming: false)
                    let incoming = try fixture(root, rate: sourceRate, phase: phase + 1.3, amplitude: 1.4, incoming: true)
                    var pcm = [[Float](), [Float]()]
                    let result = try player.auditProductFrames(url: outgoing, outputRate: outputRate, overlap: true,
                        maximumFrames: variant % 2 == 0 ? 512 : 2048, incomingURL: incoming, renderSeconds: 0.8,
                        capturePCM: { buffer in
                            for c in 0..<2 { pcm[c].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![c], count: Int(buffer.frameLength))) }
                        })
                    let peak = meter.peak(pcm)
                    #expect(peak <= pow(10, -1.0 / 20), "ISP case=\(index) truePeak=\(peak)")
                    #expect(peak > 0.00001)
                    if peak > largest { largest = peak; worstPCM = pcm }
                    print("PRODUCT_ISP case=\(index) source=\(sourceRate) output=\(outputRate) volume=\(player.volume) phase=\(phase) sample=\(result.peak) isp=\(peak)")
                    index += 1
                }
            }
        }
        for (sourceRate, outputRate) in [(44_100.0, 88_200.0), (48_000.0, 48_000.0)] {
            player.volume = 1
            let file = try fixture(root, rate: sourceRate, phase: .pi / 3, amplitude: 4, incoming: false)
            var pcm = [[Float](), [Float]()]
            let result = try player.auditProductFrames(url: file, outputRate: outputRate, overlap: false,
                maximumFrames: 2048, renderSeconds: 8, spaceSize: 0.9,
                capturePCM: { buffer in
                    for c in 0..<2 { pcm[c].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![c], count: Int(buffer.frameLength))) }
                })
            let peak = meter.peak(pcm)
            let earlyTail = rms(pcm, rate: outputRate, from: 0.8, to: 1.3)
            let lateTail = rms(pcm, rate: outputRate, from: 7.5, to: 8)
            #expect(peak <= pow(10, -1.0 / 20))
            #expect(earlyTail > 1e-8 && lateTail < earlyTail)
            if peak > largest { largest = peak; worstPCM = pcm }
            print("PRODUCT_LONG source=\(sourceRate) output=\(outputRate) seconds=8 sample=\(result.peak) isp=\(peak) earlyRMS=\(earlyTail) lateRMS=\(lateTail)")
        }
        let dense = IndependentIntersampleMeter(radius: 192, phases: 64).peak(worstPCM)
        #expect(dense <= pow(10, -1.0 / 20))
        #expect(abs(20 * log10(dense / largest)) < 0.05)
        print("PRODUCT_CONVERGENCE primary=\(largest) dense=\(dense) deltaDB=\(20 * log10(dense / largest))")
    }
}
#endif
