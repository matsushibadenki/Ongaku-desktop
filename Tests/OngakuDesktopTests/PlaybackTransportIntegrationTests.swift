import AVFoundation
import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Playback transport integration", .serialized)
@MainActor struct PlaybackTransportIntegrationTests {
    private func field<T>(_ player: PlaybackController, _ name: String, _: T.Type) throws -> T {
        let value = try #require(Mirror(reflecting: player).children.first {
            $0.label == name || $0.label == "$__lazy_storage_$_" + name
        }?.value)
        if let typed = value as? T { return typed }
        return try #require(Mirror(reflecting: value).children.first?.value as? T)
    }
    private func settle(_ player: PlaybackController) async throws {
        let envelope = try field(player, "transportEnvelope", TransportOutputEnvelope.self)
        for _ in 0..<300 {
            if !envelope.isBusy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("transport did not settle")
    }
    private func fixture() throws -> (URL, [Track]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TransportIntegration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480_000))
        pcm.frameLength = pcm.frameCapacity
        for ch in 0..<2 { for f in 0..<Int(pcm.frameLength) {
            pcm.floatChannelData![ch][f] = Float(sin(Double(f) * 0.05)) * 0.02
        } }
        var tracks: [Track] = []
        for index in 0..<2 {
            let url = root.appendingPathComponent("track-\(index).caf")
            do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: pcm) }
            tracks.append(Track(id: UUID(), title: "Track \(index)", artist: "Fixture", album: "Album \(index)", duration: 10,
                fileSize: 0, managedPath: url.path, sha256: "fixture-\(index)", addedAt: .now, lastVerifiedAt: .now, health: .verified))
        }
        return (root, tracks)
    }
    private func analysis(_ track: Track, _ lufs: Double) -> AudioFeatureAnalysis {
        .init(trackID: track.id, contentFingerprint: track.sha256, averageLoudnessDBFS: -30,
            peakDBFS: -2, integratedLoudnessLUFS: lufs,
            loudnessBlockEnergies: Array(repeating: pow(10, (lufs + 0.691) / 10), count: 20),
            spectralCentroidHz: 0, estimatedTempoBPM: nil, tempoConfidence: 0)
    }
    private func configure(_ player: PlaybackController) {
        player.automaticUpsampling = false; player.volume = 0
        player.loudnessNormalizationMode = .track; player.loudnessTargetLUFS = -16
        player.preventsClipping = false; player.playbackMode = .sequential
    }

    @Test("Real controller retains sources during drain and latest pause/seek/load wins")
    func transportRaces() async throws {
        let (root, tracks) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let player = PlaybackController(); configure(player)
        player.crossfadeDuration = 0
        defer { player.clearCurrentTrack() }
        player.play(tracks[0], queue: tracks)
        try await settle(player)
        let primary = try field(player, "primaryPlayerNode", AVAudioPlayerNode.self)
        #expect(player.isPlaying && primary.isPlaying)
        player.seek(to: 3); player.seek(to: 4); player.pauseForExternalPlayback()
        #expect(!player.isPlaying && primary.isPlaying)
        try await settle(player)
        #expect(!primary.isPlaying && abs(player.elapsed - 4) < 0.05)
#if ONGAKU_ENABLE_TRUE_PEAK
        let protection = try field(player, "finalOutputProtection", FinalOutputProtection.self)
        #expect(protection.protector?.auAudioUnit.renderResourcesAllocated == true,
                "protected pause must retain the prepared true-peak render resources")
#endif
        player.togglePlayback(); try await settle(player)
        #expect(player.isPlaying)
        player.seek(to: 2)
        player.play(tracks[1], queue: tracks)
        player.togglePlayback() // Pause the pending selected track, not the outgoing track.
        try await settle(player)
        #expect(player.currentTrack?.id == tracks[1].id && !player.isPlaying)
        #expect(abs(player.elapsed) < 0.01)
        player.togglePlayback(); try await settle(player)
        player.clearCurrentTrack()
        #expect(player.currentTrack == nil && !player.isPlaying)
        try await settle(player)
        let engine = try field(player, "engine", AVAudioEngine.self)
        #expect(!engine.isRunning && !primary.isPlaying)
    }

    @Test("A stopped render clock recovers from the last position and honors a later pause")
    func configurationRecoveryWithStoppedClock() async throws {
        let (root, tracks) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let player = PlaybackController(); configure(player); player.crossfadeDuration = 0
        defer { player.clearCurrentTrack() }
        let engine = try field(player, "engine", AVAudioEngine.self)
        player.play(tracks[0], queue: tracks); try await settle(player)
        player.seek(to: 3); try await settle(player)
        try await Task.sleep(for: .milliseconds(1200)) // Configuration-notification suppression expires.
        let lastPosition = player.elapsed
        #expect(player.isPlaying && engine.isRunning && lastPosition >= 3)
        engine.stop() // Simulate the device invalidating the running graph before delivery.
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        for _ in 0..<300 {
            if engine.isRunning && player.isPlaying { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(engine.isRunning && player.isPlaying)
        #expect(player.currentTrack?.id == tracks[0].id)
        #expect(player.elapsed >= lastPosition - 0.25 && player.elapsed < lastPosition + 3)
        #expect(player.errorMessage == nil)

        try await Task.sleep(for: .milliseconds(1200))
        engine.stop()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        try await Task.sleep(for: .milliseconds(50))
        player.pauseForExternalPlayback()
        try await Task.sleep(for: .milliseconds(500))
        #expect(!player.isPlaying && !engine.isRunning)
        #expect(player.currentTrack?.id == tracks[0].id)
    }

    @Test("Device-side output format wins over a previously negotiated engine input")
    func deviceOutputScope() async throws {
        let (root, tracks) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let player = PlaybackController(); configure(player); player.crossfadeDuration = 0
        let engine = try field(player, "engine", AVAudioEngine.self)
        let device = engine.outputNode.outputFormat(forBus: 0)
        let staleRate = device.sampleRate == 44_100 ? 48_000.0 : 44_100.0
        let staleInput = try #require(AVAudioFormat(standardFormatWithSampleRate: staleRate, channels: device.channelCount))
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: staleInput)
        #expect(engine.outputNode.inputFormat(forBus: 0).sampleRate == staleRate)
        #expect(engine.outputNode.outputFormat(forBus: 0).sampleRate == device.sampleRate)
        player.play(tracks[0], queue: [tracks[0]])
        #expect(player.isPlaying && player.errorMessage == nil)
        #expect(player.signalPathSnapshot?.outputSampleRate == device.sampleRate)
        #expect(engine.outputNode.inputFormat(forBus: 0).sampleRate == device.sampleRate)
#if ONGAKU_ENABLE_TRUE_PEAK
        let protection = try field(player, "finalOutputProtection", FinalOutputProtection.self)
        #expect(protection.protector?.outputFormat(forBus: 0).sampleRate == device.sampleRate)
#endif
        engine.pause()
        player.clearCurrentTrack(); try await settle(player)
    }

    @Test("Compatible file reload retains the graph but retires source, gain and tail ownership")
    func compatibleGraphReuse() async throws {
        let (root, tracks) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let player = PlaybackController(); configure(player); player.crossfadeDuration = 0
        player.setEffectsBypassed(false)
        player.setEffectEnabled(true, for: .space)
        player.setEffectEnabled(true, for: .gloss)
        defer { player.clearCurrentTrack() }
        player.updateAudioFeatures([tracks[0].id: analysis(tracks[0], -24), tracks[1].id: analysis(tracks[1], -12)])
        player.play(tracks[0], queue: tracks); try await settle(player)
        let generation = try field(player, "graphConfigurationGeneration", UInt64.self)
        let pipeline = try field(player, "effectPipeline", [AudioEffectNode].self)
        let identities = pipeline.flatMap(\.nodes).map(ObjectIdentifier.init)
        #expect(generation == 1)
        #expect((player.signalPathSnapshot?.normalizationGainDB ?? 0) > 0)
        player.play(tracks[1], queue: tracks); try await settle(player)
        #expect(player.currentTrack?.id == tracks[1].id && player.isPlaying)
        #expect(try field(player, "graphConfigurationGeneration", UInt64.self) == generation)
        #expect(pipeline.flatMap(\.nodes).map(ObjectIdentifier.init) == identities)
        #expect(abs((player.signalPathSnapshot?.normalizationGainDB ?? 99) + 4) < 0.001)
        player.pauseForExternalPlayback(); try await settle(player)
        player.togglePlayback(); try await settle(player); #expect(player.isPlaying)

        let mono = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 441_000))
        pcm.frameLength = pcm.frameCapacity
        pcm.floatChannelData![0].initialize(repeating: 0, count: Int(pcm.frameLength))
        let url = root.appendingPathComponent("incompatible.caf")
        do { let file = try AVAudioFile(forWriting: url, settings: mono.settings); try file.write(from: pcm) }
        let incompatible = Track(id: UUID(), title: "Mono", artist: "Fixture", album: "Other", duration: 10,
            fileSize: 0, managedPath: url.path, sha256: "mono", addedAt: .now, lastVerifiedAt: .now, health: .verified)
        player.play(incompatible); try await settle(player)
        #expect(player.isPlaying && player.currentTrack?.id == incompatible.id)
        #expect(try field(player, "graphConfigurationGeneration", UInt64.self) == generation + 1)
        player.clearCurrentTrack(); try await settle(player)
        let engine = try field(player, "engine", AVAudioEngine.self)
        #expect(!engine.isRunning)
        player.play(incompatible); try await settle(player)
        #expect(player.isPlaying)
        #expect(try field(player, "graphConfigurationGeneration", UInt64.self) == generation + 2)
    }

    @Test("Late track analysis survives pause/resume and changes only at new load")
    func lateTrackAnalysis() async throws {
        let (root, tracks) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let player = PlaybackController(); configure(player); player.crossfadeDuration = 0
        defer { player.clearCurrentTrack() }
        player.updateAudioFeatures([tracks[0].id: analysis(tracks[0], -24)])
        player.play(tracks[0], queue: [tracks[0]]); try await settle(player)
        let initial = try #require(player.signalPathSnapshot?.normalizationGainDB)
        #expect(initial > 0)
        player.updateAudioFeatures([tracks[0].id: analysis(tracks[0], -12)])
        #expect(player.signalPathSnapshot?.normalizationGainDB == initial)
        player.pauseForExternalPlayback(); try await settle(player)
        player.togglePlayback(); try await settle(player)
        #expect(player.signalPathSnapshot?.normalizationGainDB == initial)
        player.play(tracks[0]); try await settle(player)
        #expect(abs((player.signalPathSnapshot?.normalizationGainDB ?? 99) + 4) < 0.001)
    }

    @Test("Incoming analysis is frozen before overlap, including repeat-one")
    func incomingReference() async throws {
        for repeating in [false, true] {
            let (root, tracks) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let player = PlaybackController(); configure(player)
            player.crossfadeDuration = 1; player.disableCrossfadeWithinAlbum = false
            player.playbackMode = repeating ? .repeatOne : .sequential
            defer { player.clearCurrentTrack() }
            let incoming = repeating ? tracks[0] : tracks[1]
            player.updateAudioFeatures([tracks[0].id: analysis(tracks[0], -12), tracks[1].id: analysis(tracks[1], -12)])
            player.play(tracks[0], queue: repeating ? [tracks[0]] : tracks)
            try await settle(player)
            player.seek(to: 8.5); try await settle(player)
            let secondary = try field(player, "secondaryPlayerNode", AVAudioPlayerNode.self)
            for _ in 0..<100 {
                if secondary.isPlaying { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(secondary.isPlaying)
            player.updateAudioFeatures([tracks[0].id: analysis(tracks[0], -24), tracks[1].id: analysis(tracks[1], -24)])
            for _ in 0..<250 {
                if try field(player, "activePlayerIndex", Int.self) == 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(player.currentTrack?.id == incoming.id)
            #expect(try field(player, "activePlayerIndex", Int.self) == 1)
            try await Task.sleep(for: .milliseconds(200)) // Outgoing EOF must not complete a repeated incoming track.
            #expect(try field(player, "activePlayerIndex", Int.self) == 1)
            #expect(abs((player.signalPathSnapshot?.normalizationGainDB ?? 99) + 4) < 0.001)
        }
    }

    @Test("Both crossfade schedules survive pause drain and incoming reference survives late analysis")
    func crossfade() async throws {
        let (root, tracks) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let player = PlaybackController(); configure(player)
        player.crossfadeDuration = 1; player.disableCrossfadeWithinAlbum = false
        defer { player.clearCurrentTrack() }
        player.updateAudioFeatures([tracks[0].id: analysis(tracks[0], -24), tracks[1].id: analysis(tracks[1], -12)])
        player.play(tracks[0], queue: tracks); try await settle(player)
        player.seek(to: 8.5); try await settle(player)
        let primary = try field(player, "primaryPlayerNode", AVAudioPlayerNode.self)
        let secondary = try field(player, "secondaryPlayerNode", AVAudioPlayerNode.self)
        for _ in 0..<200 {
            if secondary.volume > 0.01 && secondary.volume < 0.99 && secondary.isPlaying { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(primary.isPlaying && secondary.isPlaying && player.currentTrack?.id == tracks[0].id)
        player.updateAudioFeatures([tracks[0].id: analysis(tracks[0], -12), tracks[1].id: analysis(tracks[1], -24)])
        player.pauseForExternalPlayback()
        #expect(primary.isPlaying && secondary.isPlaying)
        try await settle(player)
        #expect(!primary.isPlaying && !secondary.isPlaying && !player.isPlaying)
        // Resume prepares a fresh incoming schedule; its reference is frozen again.
        player.togglePlayback(); try await settle(player)
        for _ in 0..<250 {
            if player.currentTrack?.id == tracks[1].id { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(player.currentTrack?.id == tracks[1].id && player.isPlaying)
        let settled = try #require(player.signalPathSnapshot?.normalizationGainDB)
        player.updateAudioFeatures([tracks[1].id: analysis(tracks[1], -12)])
        #expect(player.signalPathSnapshot?.normalizationGainDB == settled)
    }
}
