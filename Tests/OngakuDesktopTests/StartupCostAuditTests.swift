import AVFoundation
import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Matched startup cost", .serialized)
@MainActor struct StartupCostAuditTests {
    @Test func matchedStartup() async throws {
#if ONGAKU_STARTUP_AUDIT
        guard let path = ProcessInfo.processInfo.environment["ONGAKU_STARTUP_REPORT"] else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OngakuStartup-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = ["audio.effectSettings.v1", "audio.effectsBypassed", "audio.automaticUpsampling", "audio.crossfadeDuration.v1", "audio.disableCrossfadeWithinAlbum.v1", "audio.loudnessNormalizationMode.v1", "audio.loudnessTargetLUFS.v2", "audio.preventsClipping.v1"]
        let saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer { for (key,value) in saved { if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } } }
        var samples: [[String: Any]] = []
        for rate in [44_100.0, 96_000.0] {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
            let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 10)))
            pcm.frameLength = pcm.frameCapacity
            for ch in 0..<2 { for f in 0..<Int(pcm.frameLength) { pcm.floatChannelData![ch][f] = Float(sin(Double(f) * 2 * .pi * 440 / rate)) * 0.01 } }
            let url = root.appendingPathComponent("\(Int(rate)).caf")
            do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: pcm) }
            let track = Track(id: UUID(), title: "Startup", artist: "Audit", album: "Audit", duration: 10, fileSize: 0, managedPath: url.path, sha256: "startup", addedAt: .now, lastVerifiedAt: .now, health: .verified)
            StartupCostAudit.rows = []
            let player = StartupCostAudit.measure("controller.init") { PlaybackController() }
            player.automaticUpsampling = false; player.volume = 0; player.crossfadeDuration = 0
            player.loudnessNormalizationMode = .off; player.preventsClipping = false
            player.setEffectsBypassed(false)
            for setting in player.effectSettings { player.setEffectEnabled(false, for: setting.kind) }
            func settle() async throws {
                let deadline = ContinuousClock.now.advanced(by: .seconds(30))
                while ContinuousClock.now < deadline {
                    let value = Mirror(reflecting: player).children.first { $0.label == "transportEnvelope" || $0.label == "$__lazy_storage_$_transportEnvelope" }!.value
                    let owner = (value as? TransportOutputEnvelope) ?? Mirror(reflecting: value).children.first?.value as? TransportOutputEnvelope
                    if let owner, !owner.isBusy { return }
                    try await Task.sleep(for: .milliseconds(2))
                }
                throw NSError(domain: "StartupAudit.Timeout", code: 1)
            }
            for phase in ["cold-load", "same-instance-reload"] {
                let start = StartupCostAudit.begin()
                StartupCostAudit.measure(phase + ".call") { player.play(track, queue: [track]) }
                try await settle()
                StartupCostAudit.end(phase + ".ready", start)
                #expect(player.isPlaying && player.errorMessage == nil)
                let pause = StartupCostAudit.begin(); player.pauseForExternalPlayback(); try await settle(); StartupCostAudit.end(phase + ".pause", pause)
                #expect(!player.isPlaying)
                let resume = StartupCostAudit.begin(); player.togglePlayback(); try await settle(); StartupCostAudit.end(phase + ".resume", resume)
                #expect(player.isPlaying)
            }
            // Matched control: the same controller, source and output format,
            // with explicit destructive cleanup forcing a full graph rebuild.
            let forced = StartupCostAudit.begin()
            player.clearCurrentTrack(); try await settle()
            player.play(track, queue: [track]); try await settle()
            StartupCostAudit.end("full-rebuild.ready", forced)
            #expect(player.isPlaying && player.errorMessage == nil)
            let engine = try #require(Mirror(reflecting: player).children.first { $0.label == "engine" }?.value as? AVAudioEngine)
            let hardware = engine.outputNode.inputFormat(forBus: 0)
            samples.append(["source_rate":rate,"processing_rate":AudioProcessingPolicy.processingSampleRate(for: rate),"output_rate":hardware.sampleRate,"output_channels":hardware.channelCount,"rows":StartupCostAudit.rows])
            player.clearCurrentTrack(); try await settle(); #expect(!engine.isRunning)
        }
        let report: [String:Any] = ["configuration":StartupCostAudit.configuration,"platform":"macOS","os":ProcessInfo.processInfo.operatingSystemVersionString,"samples":samples]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath:path), options:.atomic)
#endif
    }
}
