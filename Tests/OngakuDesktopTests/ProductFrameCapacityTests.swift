import AVFoundation
import Foundation
import Testing
@testable import OngakuDesktop

// The audit driver is deliberately absent from Release builds.
#if DEBUG
@MainActor @Suite("Product graph frame capacities", .serialized)
struct ProductFrameCapacityTests {
#if ONGAKU_ENABLE_TRUE_PEAK && ONGAKU_ENABLE_AUDIO_THREAD_GAIN
    @Test("Protected product graph bounds strong and high-crest input across rebuilt and retained graphs")
    func strongInputTransitions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProductStrong-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = PlaybackController()
        controller.volume = 1
        let clippingKey = "audio.preventsClipping.v1"
        let savedClipping = UserDefaults.standard.object(forKey: clippingKey)
        defer {
            if let savedClipping { UserDefaults.standard.set(savedClipping, forKey: clippingKey) }
            else { UserDefaults.standard.removeObject(forKey: clippingKey) }
        }
        for clipping in [false, true] {
        controller.preventsClipping = clipping
        for sourceRate in [44_100.0, 48_000] {
            let format = AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 2)!
            for burst in [false, true] {
                let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
                pcm.frameLength = pcm.frameCapacity
                for c in 0..<2 { for i in 0..<Int(pcm.frameLength) {
                    let value: Float = burst
                        ? (i % 1024 == 0 ? (c == 0 ? 4 : -3) : 0)
                        : Float(4 * sin(2 * .pi * 12_000 * Double(i) / sourceRate + Double(c) * 0.7))
                    pcm.floatChannelData![c][i] = value
                } }
                let url = root.appendingPathComponent("\(Int(sourceRate))-\(burst)-\(clipping).caf")
                do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: pcm) }
                let next = root.appendingPathComponent("next-" + url.lastPathComponent)
                try FileManager.default.copyItem(at: url, to: next)
                for maximumFrames: AVAudioFrameCount in [512, 2048] {
                    for outputRate in [88_200.0, 48_000] {
                        let fresh = try controller.auditProductFrames(url: url, outputRate: outputRate,
                            overlap: true, maximumFrames: maximumFrames)
                        let retained = try controller.auditProductFrames(url: next, outputRate: outputRate,
                            overlap: false, maximumFrames: maximumFrames, reuseGraph: true)
                        #expect(retained.generation == fresh.generation)
                        for peak in [fresh.peak, retained.peak] {
                            #expect(peak > 0.00001 && peak <= 0.9,
                                "source=\(sourceRate) output=\(outputRate) burst=\(burst) frames=\(maximumFrames) samplePeak=\(peak)")
                        }
                        print("PRODUCT_STRONG clipping=\(clipping) source=\(sourceRate) output=\(outputRate) burst=\(burst) frames=\(maximumFrames) fresh=\(fresh.peak) retained=\(retained.peak)")
                    }
                }
            }
        }
        }
    }
#endif

    @Test("All real effect branches render across simulated route and track transitions")
    func routeAndTrackTransitions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProductFrames-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = PlaybackController()
        controller.volume = 0.5
        var urls: [URL] = []
        for rate in [44_100.0, 48_000] {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
            pcm.frameLength = pcm.frameCapacity
            for c in 0..<2 { for i in 0..<Int(pcm.frameLength) { pcm.floatChannelData![c][i] = 0.02 * sin(Float(i) * 0.05) } }
            let url = root.appendingPathComponent("\(Int(rate)).caf")
            do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: pcm) }
            urls.append(url)
        }
        for maximumFrames: AVAudioFrameCount in [512, 2048] {
        for rate in [88_200.0, 48_000, 96_000, 88_200] {
            for (index, url) in urls.enumerated() {
                let result = try controller.auditProductFrames(url: url, outputRate: rate, overlap: index == 1, maximumFrames: maximumFrames)
                let nextURL = root.appendingPathComponent("next-" + url.lastPathComponent)
                if !FileManager.default.fileExists(atPath: nextURL.path) { try FileManager.default.copyItem(at: url, to: nextURL) }
                let reused = try controller.auditProductFrames(url: nextURL, outputRate: rate, overlap: index == 0,
                    maximumFrames: maximumFrames, reuseGraph: true)
                #expect(reused.generation == result.generation, "Compatible next file should retain the product graph")
                #expect(reused.peak > 0.00001)
                print("PRODUCT_REUSE max=\(maximumFrames) output=\(rate) generation=\(reused.generation) peak=\(reused.peak)")
                #expect(result.peak > 0.00001)
                #expect(result.mixers.count >= 10, "Internal parallel effect mixers must be present")
                print("PRODUCT_FRAMES max=\(maximumFrames) output=\(rate) source=\(url.lastPathComponent) overlap=\(index == 1) peak=\(result.peak) mixers=\(result.mixers)")
            }
        }
        }
    }
}

#endif
