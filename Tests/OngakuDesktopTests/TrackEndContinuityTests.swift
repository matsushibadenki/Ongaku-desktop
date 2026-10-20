import AVFoundation
import Foundation
import Combine
import Testing
@testable import OngakuDesktop

// Keep real output-engine tests in the same serialized suite: a second suite
// can otherwise block MainActor while another test's short source is playing.
extension PlaybackTransportIntegrationTests {
    private struct End {
        let generation: UUID
        let trackID: Track.ID
        let nodeID: ObjectIdentifier
        let scheduleID: UUID
    }
    private func eofValue(_ object: Any, _ name: String) -> Any? {
        Mirror(reflecting: object).children.first { $0.label == name || $0.label == "$__lazy_storage_$_" + name }?.value
    }
    private func eofField<T>(_ object: Any, _ name: String, _: T.Type) throws -> T {
        let raw = try #require(eofValue(object, name))
        if let typed = raw as? T { return typed }
        return try #require(Mirror(reflecting: raw).children.first?.value as? T)
    }
    private func eofActiveEnd(_ player: PlaybackController) throws -> End {
        let index = try eofField(player, "activePlayerIndex", Int.self)
        let node = try eofField(player, index == 0 ? "primaryPlayerNode" : "secondaryPlayerNode", AVAudioPlayerNode.self)
        return End(generation: try eofField(player, "playbackGeneration", UUID.self),
                   trackID: try #require(player.currentTrack?.id), nodeID: ObjectIdentifier(node),
                   scheduleID: try eofField(player, "activePlaybackScheduleID", UUID.self))
    }
    private func eofPreparedEnd(_ player: PlaybackController) throws -> End {
        let raw = try #require(eofValue(player, "prerolledTrack"))
        let prepared = try #require(Mirror(reflecting: raw).children.first?.value)
        return End(generation: try eofField(prepared, "generation", UUID.self),
                   trackID: try eofField(prepared, "track", Track.self).id,
                   nodeID: ObjectIdentifier(try eofField(prepared, "playbackNode", AVAudioPlayerNode.self)),
                   scheduleID: try eofField(prepared, "scheduleID", UUID.self))
    }
    private func eofDeliver(_ end: End, to player: PlaybackController) {
        player.didFinishPlaying(generation: end.generation, scheduleID: end.scheduleID, finishedTrackID: end.trackID, finishedNodeID: end.nodeID)
    }
    private func eofSettle(_ player: PlaybackController) async throws {
        let envelope = try eofField(player, "transportEnvelope", TransportOutputEnvelope.self)
        for _ in 0..<300 {
            if !envelope.isBusy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("transport did not settle")
    }
    private func eofFixture() throws -> (URL, [Track]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TrackEnd-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480000))
        pcm.frameLength = pcm.frameCapacity
        for ch in 0..<2 { for f in 0..<Int(pcm.frameLength) {
            pcm.floatChannelData![ch][f] = Float(sin(Double(f) * 0.05)) * 0.01
        } }
        let albumID = UUID()
        let tracks = try (0..<2).map { index in
            let url = root.appendingPathComponent("track-\(index).caf")
            do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: pcm) }
            return Track(id: UUID(), title: "EOF \(index)", artist: "Fixture", album: "Album", duration: 10,
                         fileSize: 0, managedPath: url.path, sha256: "eof-\(index)", addedAt: .now, lastVerifiedAt: .now, health: .verified, albumID: albumID)
        }
        return (root, tracks)
    }
    private func eofConfigure(_ player: PlaybackController) {
        player.volume = 0; player.automaticUpsampling = false
        player.crossfadeDuration = 0
        player.playbackMode = .sequential
    }
    private func eofPrepare(_ player: PlaybackController, tracks: [Track]) async throws {
        player.play(tracks[0], queue: tracks); try await eofSettle(player)
        // Crossfade needs the asynchronously prepared silence analyses.
        for _ in 0..<200 {
            if try eofField(player, "silenceAnalyses", [URL: AudioSilenceAnalysis].self).count >= tracks.count { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        player.seek(to: 8); try await eofSettle(player)
        for _ in 0..<100 {
            if let raw = eofValue(player, "prerolledTrack"), !Mirror(reflecting: raw).children.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try eofPreparedEnd(player)
    }

    @Test("An incoming EOF delivered before outgoing EOF is retained", arguments: [false, true])
    func reorderedEnds(crossfade: Bool) async throws {
        let (root, tracks) = try eofFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let player = PlaybackController(); eofConfigure(player)
        defer { player.clearCurrentTrack() }
        player.crossfadeDuration = crossfade ? 1 : 0
        player.disableCrossfadeWithinAlbum = false
        try await eofPrepare(player, tracks: tracks)
        let outgoing = try eofActiveEnd(player), incoming = try eofPreparedEnd(player)
        eofDeliver(incoming, to: player)
        #expect(player.currentTrack?.id == tracks[0].id)
        eofDeliver(outgoing, to: player)
        #expect(player.currentTrack?.id == tracks[1].id)
        #expect(!player.isPlaying, "incoming EOF was discarded before promotion")
    }

    @Test("Repeated same-track schedules cannot consume an outgoing duplicate")
    func repeatedScheduleIdentity() async throws {
        let (root, tracks) = try eofFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let player = PlaybackController(); eofConfigure(player); player.playbackMode = .repeatOne
        defer { player.clearCurrentTrack() }
        try await eofPrepare(player, tracks: [tracks[0]])
        let outgoing = try eofActiveEnd(player)
        eofDeliver(outgoing, to: player)
        let promoted = try eofActiveEnd(player)
        let promotedStart = try eofField(player, "activeTrackNodeStartSampleTime", AVAudioFramePosition.self)
        eofDeliver(outgoing, to: player)
        #expect(try eofField(player, "activeTrackNodeStartSampleTime", AVAudioFramePosition.self) == promotedStart,
                "outgoing duplicate skipped a same-node repeat schedule")
        #expect(try eofField(player, "playbackGeneration", UUID.self) == promoted.generation,
                "outgoing duplicate restarted the incoming repeat")
        #expect(!(try eofField(player, "transportEnvelope", TransportOutputEnvelope.self)).isStopping)
    }

    @Test("Pause at a queued EOF cannot start the next song")
    func pauseAtBoundary() async throws {
        let (root, tracks) = try eofFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let player = PlaybackController(); eofConfigure(player)
        defer { player.clearCurrentTrack() }
        player.play(tracks[0], queue: tracks); try await eofSettle(player)
        player.seek(to: 9.7); try await eofSettle(player)
        // Hold MainActor briefly so the actual render completion is queued
        // while the next user pause is delivered before that completion.
        usleep(450_000)
        player.pauseForExternalPlayback()
        try await eofSettle(player)
        #expect(player.currentTrack?.id == tracks[0].id, "pause at EOF selected the next song")
        #expect(!player.isPlaying, "empty paused schedule auto-resumed playback")
    }

    @Test("A delayed configuration recovery cannot rewind the next gapless song")
    func recoveryAtBoundary() async throws {
        let (root, tracks) = try eofFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let player = PlaybackController(); eofConfigure(player)
        defer { player.clearCurrentTrack() }
        player.play(tracks[0], queue: tracks); try await eofSettle(player)
        try await Task.sleep(for: .milliseconds(1100)) // Allow the configuration suppression window to expire.
        player.seek(to: 8); try await eofSettle(player)
        let engine = try eofField(player, "engine", AVAudioEngine.self)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        for _ in 0..<20 {
            if Mirror(reflecting: try #require(eofValue(player, "recoveryTask"))).children.first != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let taskValue = try #require(eofValue(player, "recoveryTask"))
        #expect(Mirror(reflecting: taskValue).children.first != nil)
        eofDeliver(try eofActiveEnd(player), to: player)
        let promoted = try eofActiveEnd(player)
        try await Task.sleep(for: .milliseconds(550))
        #expect(player.currentTrack?.id == tracks[1].id)
        #expect(try eofField(player, "playbackGeneration", UUID.self) == promoted.generation,
                "stale recovery rebuilt the next song using the previous song's position")
        #expect(player.elapsed < 1)
    }
    @Test("Deferred and obsolete EOF cannot override pause, resume or selection")
    func newerIntent() async throws {
        let (root, tracks) = try eofFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let player = PlaybackController(); eofConfigure(player)
        defer { player.clearCurrentTrack() }
        try await eofPrepare(player, tracks: tracks)
        let outgoing = try eofActiveEnd(player), incoming = try eofPreparedEnd(player)
        eofDeliver(incoming, to: player)
        player.pauseForExternalPlayback()
        eofDeliver(outgoing, to: player)
        try await eofSettle(player)
        eofDeliver(incoming, to: player); eofDeliver(outgoing, to: player)
        #expect(player.currentTrack?.id == tracks[0].id && !player.isPlaying)
        player.togglePlayback(); try await eofSettle(player)
        eofDeliver(outgoing, to: player)
        #expect(player.currentTrack?.id == tracks[0].id && player.isPlaying)
        player.play(tracks[1], queue: tracks)
        eofDeliver(incoming, to: player)
        try await eofSettle(player)
        #expect(player.currentTrack?.id == tracks[1].id && player.isPlaying)
        player.clearCurrentTrack()
        eofDeliver(incoming, to: player); eofDeliver(outgoing, to: player)
        try await eofSettle(player)
        #expect(player.currentTrack == nil && !player.isPlaying)
    }

    @Test("Rejected preroll preserves the active EOF and falls back to a fresh load")
    func rejectedPreroll() async throws {
        let (root, tracks) = try eofFixture(); defer { try? FileManager.default.removeItem(at: root) }
        var rejectIncoming = true
        var rejected = 0
        let player = PlaybackController(audioFileOpener: { url in
            if rejectIncoming && url.standardizedFileURL == tracks[1].fileURL.standardizedFileURL {
                rejected += 1
                throw NSError(domain: "test.preroll", code: 1)
            }
            return try AVAudioFile(forReading: url)
        })
        eofConfigure(player)
        defer { player.clearCurrentTrack() }
        player.play(tracks[0], queue: tracks); try await eofSettle(player)
        let outgoing = try eofActiveEnd(player)
        #expect(rejected > 0)
        #expect(try eofActiveEnd(player).scheduleID == outgoing.scheduleID)
        rejectIncoming = false
        eofDeliver(outgoing, to: player)
        try await eofSettle(player)
        #expect(player.currentTrack?.id == tracks[1].id && player.isPlaying)
        #expect(player.errorMessage == nil)
    }

    @Test("Real 10 ms tails reach next, repeat-one, queue/album wrap and final stop")
    func shortTailPlayback() async throws {
        let (root, tracks) = try eofFixture(); defer { try? FileManager.default.removeItem(at: root) }
        for (mode, startIndex, expectedIndex, shouldContinue) in [
            (PlaybackMode.sequential, 0, 1, true), (.repeatOne, 0, 0, true),
            (.repeatAll, 1, 0, true), (.repeatAlbum, 1, 0, true), (.sequential, 1, 1, false)
        ] {
            let player = PlaybackController(); eofConfigure(player); player.playbackMode = mode
            defer { player.clearCurrentTrack() }
            var completed: [Track.ID] = []
            let observation = player.playbackEventPublisher.sink {
                if $0.kind == .completed { completed.append($0.trackID) }
            }
            defer { observation.cancel() }
            player.play(tracks[startIndex], queue: tracks); try await eofSettle(player)
            player.seek(to: 9.99)
            for _ in 0..<400 {
                if !completed.isEmpty { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try await eofSettle(player)
            #expect(completed == [tracks[startIndex].id], "short tail must complete exactly once: \(mode)")
            #expect(player.currentTrack?.id == tracks[expectedIndex].id, "wrong next track: \(mode)")
            #expect(player.isPlaying == shouldContinue)
            #expect(player.errorMessage == nil)
            if shouldContinue { #expect(player.elapsed < 2) }
            else { #expect(player.elapsed == player.duration) }
        }
    }

}
