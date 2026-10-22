import AVFoundation
import Foundation
import Testing
@testable import OngakuDesktop

// Use the existing isolated/serialized real-engine suite, never race DSP audits.
extension PlaybackTransportIntegrationTests {
    private func cdRender(_ url: URL, enabled: Bool) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        let mixer = AVAudioMixerNode()
        let eq = EqualizerAudioEffect()
        engine.attach(node); engine.attach(mixer); eq.attach(to: engine)
        defer { engine.stop(); eq.detach(from: engine) }
        let processing = try #require(AVAudioFormat(standardFormatWithSampleRate: 96_000,
            channels: max(2, file.processingFormat.channelCount)))
        engine.connect(node, to: mixer, format: file.processingFormat)
        engine.connect(mixer, to: eq.inputNode, format: processing)
        eq.connectInternalNodes(engine: engine, format: processing)
        engine.connect(eq.outputNode, to: engine.mainMixerNode, format: processing)
        var setting = RealtimeAudioEffectSetting(kind: .equalizer, isEnabled: enabled)
        setting.parameters["trim"] = 0 // Substantial attenuation, independent of tone bands.
        eq.apply(setting: setting)
        try engine.enableManualRenderingMode(.offline, format: processing, maximumFrameCount: 1024)
        node.scheduleFile(file, at: nil)
        try engine.start(); node.play()
        let output = try #require(AVAudioPCMBuffer(pcmFormat: processing, frameCapacity: 1024))
        for _ in 0..<24 { #expect(try engine.renderOffline(1024, to: output) == .success) }
        return output
    }

    @Test("CD rip formats retain local playback, real RMS/spectrum and effect response")
    func cdPlaybackAvailability() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CDPlayback-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for channels: AVAudioChannelCount in [1, 2] {
            let source = root.appendingPathComponent("cd-\(channels).aiff")
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: channels))
            let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 352_800))
            pcm.frameLength = pcm.frameCapacity
            for ch in 0..<Int(channels) { for f in 0..<Int(pcm.frameLength) {
                pcm.floatChannelData![ch][f] = Float(0.2 * sin(2 * .pi * 1000 * Double(f) / 44_100))
            } }
            do {
                let file = try AVAudioFile(forWriting: source, settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: true])
                try file.write(from: pcm)
            }
            for kind in AudioCDImportFormat.allCases {
                let url = root.appendingPathComponent("rip-\(channels)-\(kind.rawValue).\(kind.pathExtension)")
                try AudioCDRipper.rip(sourceURL: source, destinationURL: url, format: kind, aacQuality: .high)
                let file = try AVAudioFile(forReading: url)
                #expect(file.processingFormat.sampleRate == 44_100)
                #expect(file.processingFormat.channelCount == channels)
                let bypass = try cdRender(url, enabled: false)
                let active = try cdRender(url, enabled: true)
                let dry = StereoLevelMath.measure(bypass)
                let wet = StereoLevelMath.measure(active)
                #expect(dry.left > 0.1 && dry.right > 0.1)
                #expect(wet.left < dry.left - 0.1 && wet.right < dry.right - 0.1)
                let spectrum = SpectrumMath.measure(bypass)
                #expect(spectrum.left.max()! > 0.1 && spectrum.right.max()! > 0.1)
                let track = Track(id: UUID(), title: "CD fixture", artist: "Fixture", album: "CD",
                    duration: 8, fileSize: 0, managedPath: url.path, sha256: UUID().uuidString,
                    addedAt: .now, lastVerifiedAt: .now, health: .verified)
                let player = PlaybackController()
                player.volume = 0; player.automaticUpsampling = false; player.crossfadeDuration = 0
                player.play(track, queue: [track])
                for _ in 0..<300 {
                    if player.errorMessage != nil || player.signalPathSnapshot != nil { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(player.errorMessage == nil)
                #expect(player.currentTrack?.id == track.id && player.isPlaying)
                #expect(player.signalPathSnapshot?.sourceSampleRate == 44_100)
                #expect(player.signalPathSnapshot?.sourceChannelCount == channels)
                #expect(player.signalPathSnapshot?.processingChannelCount == 2)
                #expect(Mirror(reflecting: player).children.first { $0.label == "isMeterTapInstalled" }?.value as? Bool == true)
                player.clearCurrentTrack()
                try await Task.sleep(for: .milliseconds(150))
                print("CD availability PASS: \(kind.rawValue), channels=\(channels)")
            }
        }
    }
}
