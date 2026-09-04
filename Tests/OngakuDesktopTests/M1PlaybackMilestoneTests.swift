import AVFoundation
import Combine
import Foundation
import Testing
@testable import OngakuDesktop

@Suite("M1 playback parity milestone")
struct M1PlaybackMilestoneTests {
    private static let trackCount = 1_000

    @Test("A 1,000-track sequential queue completes in exact order")
    func completesThousandTrackSequentialQueue() throws {
        let tracks = Self.makeTracks()
        var current = tracks[0]

        for expectedIndex in 1..<tracks.count {
            current = try #require(PlaybackQueueNavigator.nextTrack(
                after: current,
                in: tracks,
                mode: .sequential
            ))
            #expect(current.id == tracks[expectedIndex].id)
        }

        #expect(PlaybackQueueNavigator.nextTrack(
            after: current,
            in: tracks,
            mode: .sequential
        ) == nil)
    }

    @Test("A 1,000-track shuffle run always selects a playable non-current song")
    func completesThousandTrackShuffleRun() throws {
        let tracks = Self.makeTracks()
        let playableIDs = Set(tracks.map(\.id))
        var current = tracks[0]
        var generator = DeterministicIndexGenerator(seed: 0x4F4E_4741_4B55)

        for _ in 0..<Self.trackCount {
            let previousID = current.id
            current = try #require(PlaybackQueueNavigator.nextTrack(
                after: current,
                in: tracks,
                mode: .shuffle,
                randomIndex: { generator.next(upperBound: $0) }
            ))
            #expect(playableIDs.contains(current.id))
            #expect(current.id != previousID)
        }
    }

    @Test("A 1,000-track queue and position survive process replacement")
    @MainActor
    func restoresLargeQueueAfterProcessReplacement() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ongaku-M1-Restart-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audioURL = root.appendingPathComponent("restoration.caf")
        try Self.writeSilentAudio(to: audioURL, duration: 2)

        let tracks = Self.makeTracks(fileURL: audioURL)
        let current = tracks[731]
        let state = PlaybackQueueState(
            trackIDs: tracks.reversed().map(\.id),
            currentTrackID: current.id,
            position: 1.25
        )
        let repository = LibraryRepository(rootURL: root)
        try await repository.save(tracks: tracks)
        try await repository.save(playbackQueue: state)

        // A fresh repository and player represent a new process after an abrupt exit.
        let restoredDocument = try await LibraryRepository(rootURL: root).load().document
        let restoredPlayer = PlaybackController()
        restoredPlayer.restorePlaybackQueue(
            restoredDocument.playbackQueue,
            tracks: restoredDocument.tracks
        )

        #expect(restoredPlayer.queuedTracks.map(\.id) == state.trackIDs)
        #expect(restoredPlayer.currentTrack?.id == current.id)
        #expect(abs(restoredPlayer.elapsed - state.position) < 0.02)
        #expect(restoredPlayer.queueState.currentTrackID == current.id)
        #expect(abs(restoredPlayer.queueState.position - state.position) < 0.02)
    }

    @Test("A missing current file does not erase the persisted queue position")
    @MainActor
    func preservesPositionWhileCurrentFileIsUnavailable() {
        let tracks = Self.makeTracks()
        let current = tracks[417]
        let state = PlaybackQueueState(
            trackIDs: tracks.map(\.id),
            currentTrackID: current.id,
            position: 37.5
        )
        let player = PlaybackController()

        player.restorePlaybackQueue(state, tracks: tracks)

        #expect(player.queuedTracks.map(\.id) == state.trackIDs)
        #expect(player.currentTrack?.id == current.id)
        #expect(player.elapsed == 37.5)
        #expect(player.queueState.position == 37.5)
        #expect(player.errorMessage != nil)
    }

    @Test("Starting a stale library entry reports its missing file")
    @MainActor
    func reportsFileRemovedAfterLibraryRegistration() {
        var track = Self.makeTracks()[0]
        track.health = .verified
        let player = PlaybackController()
        var reportedIDs: [Track.ID] = []
        let observation = player.missingTrackPublisher.sink { reportedIDs.append($0) }

        player.play(track)

        #expect(reportedIDs == [track.id])
        #expect(player.isPlaying == false)
        #expect(player.errorMessage != nil)
        withExtendedLifetime(observation) {}
    }

    private static func makeTracks(fileURL: URL? = nil) -> [Track] {
        (0..<trackCount).map { index in
            let id = UUID(uuidString: String(
                format: "00000000-0000-0000-0000-%012X",
                index + 1
            ))!
            return Track(
                id: id,
                title: "Milestone Track \(index + 1)",
                artist: "M1 Artist",
                album: "M1 Endurance",
                duration: fileURL == nil ? 180 : 2,
                fileSize: 1,
                managedPath: fileURL?.path ?? "/missing/m1-\(index).caf",
                sha256: "m1-\(index)",
                addedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                health: fileURL == nil ? .missing : .verified
            )
        }
    }

    private static func writeSilentAudio(to url: URL, duration: TimeInterval) throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 2,
            interleaved: false
        ))
        let frameCount = AVAudioFrameCount(format.sampleRate * duration)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}

private struct DeterministicIndexGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next(upperBound: Int) -> Int {
        guard upperBound > 0 else { return 0 }
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int(state % UInt64(upperBound))
    }
}
