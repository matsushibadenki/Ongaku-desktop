@preconcurrency import AVFoundation
@testable import OngakuDesktop
import Foundation
import Testing

private final class CapturedStereoLevels: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: StereoLevels?

    func store(_ levels: StereoLevels) {
        lock.lock()
        stored = levels
        lock.unlock()
    }

    func load() -> StereoLevels? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private final class StereoTapInvocation: @unchecked Sendable {
    let tap: AVAudioNodeTapBlock
    let buffer: AVAudioPCMBuffer
    let time: AVAudioTime

    init(tap: @escaping AVAudioNodeTapBlock, buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        self.tap = tap
        self.buffer = buffer
        self.time = time
    }

    func run() {
        tap(buffer, time)
    }
}

@Suite("Stereo level meter")
struct StereoLevelMeterTests {
    @Test("Silence stays at the bottom of the meter")
    func silence() {
        #expect(StereoLevelMath.normalizedRMS([Float](repeating: 0, count: 128)) == 0)
    }

    @Test("A full-scale signal reaches the top of the meter")
    func fullScale() {
        #expect(StereoLevelMath.normalizedRMS([Float](repeating: 1, count: 128)) == 1)
    }

    @Test("A quieter signal produces a lower reading")
    func relativeLevel() {
        let quiet = StereoLevelMath.normalizedRMS([Float](repeating: 0.01, count: 128))
        let loud = StereoLevelMath.normalizedRMS([Float](repeating: 0.5, count: 128))
        #expect(quiet > 0)
        #expect(quiet < loud)
        #expect(loud < 1)
    }

    @Test("The audio tap runs without inheriting MainActor isolation")
    func tapIsNonisolated() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
        buffer.frameLength = 32
        let channels = try #require(buffer.floatChannelData)
        for frame in 0..<Int(buffer.frameLength) {
            channels[0][frame] = 0.5
            channels[1][frame] = 0.25
        }

        let captured = CapturedStereoLevels()
        let tap = makeStereoMeterTapBlock(throttle: StereoMeterThrottle()) { levels in
            captured.store(levels)
        }
        let invocation = StereoTapInvocation(
            tap: tap,
            buffer: buffer,
            time: AVAudioTime(sampleTime: 0, atRate: format.sampleRate)
        )
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue(label: "test.audio-realtime-queue").async {
            invocation.run()
            finished.signal()
        }

        #expect(finished.wait(timeout: .now() + 2) == .success)
        let levels = try #require(captured.load())
        #expect(levels.left > levels.right)
    }
}

@Suite("Playback queue navigation")
struct PlaybackQueueNavigatorTests {
    private let artistID = UUID()
    private let albumOneID = UUID()
    private let albumTwoID = UUID()
    private let trackOneID = UUID()
    private let trackTwoID = UUID()
    private let trackThreeID = UUID()

    private var albumOneFirst: Track {
        Track(
            id: trackOneID, title: "One", artist: "Artist", album: "Album One", duration: 1,
            fileSize: 1, managedPath: "/tmp/one.mp3", sha256: "one", addedAt: .now,
            health: .verified, artistID: artistID, albumID: albumOneID)
    }

    private var albumTwo: Track {
        Track(
            id: trackTwoID, title: "Two", artist: "Artist", album: "Album Two", duration: 1,
            fileSize: 1, managedPath: "/tmp/two.mp3", sha256: "two", addedAt: .now,
            health: .verified, artistID: artistID, albumID: albumTwoID)
    }

    private var albumOneSecond: Track {
        Track(
            id: trackThreeID, title: "Three", artist: "Artist", album: "Album One", duration: 1,
            fileSize: 1, managedPath: "/tmp/three.mp3", sha256: "three", addedAt: .now,
            health: .verified, artistID: artistID, albumID: albumOneID)
    }

    @Test("Sequential playback stops at the end")
    func sequentialStops() {
        let queue = [albumOneFirst, albumTwo, albumOneSecond]
        #expect(PlaybackQueueNavigator.nextTrack(
            after: albumOneFirst, in: queue, mode: .sequential)?.id == albumTwo.id)
        #expect(PlaybackQueueNavigator.nextTrack(
            after: albumOneSecond, in: queue, mode: .sequential) == nil)
    }

    @Test("Repeat one returns the current track")
    func repeatsOne() {
        #expect(PlaybackQueueNavigator.nextTrack(
            after: albumOneFirst, in: [albumOneFirst, albumTwo], mode: .repeatOne)?.id
            == albumOneFirst.id)
    }

    @Test("Repeat all wraps to the first track")
    func repeatsAll() {
        #expect(PlaybackQueueNavigator.nextTrack(
            after: albumTwo, in: [albumOneFirst, albumTwo], mode: .repeatAll)?.id
            == albumOneFirst.id)
    }

    @Test("Repeat album skips other albums and wraps")
    func repeatsAlbum() {
        let queue = [albumOneFirst, albumTwo, albumOneSecond]
        #expect(PlaybackQueueNavigator.nextTrack(
            after: albumOneFirst, in: queue, mode: .repeatAlbum)?.id == albumOneSecond.id)
        #expect(PlaybackQueueNavigator.nextTrack(
            after: albumOneSecond, in: queue, mode: .repeatAlbum)?.id == albumOneFirst.id)
    }

    @Test("Shuffle does not immediately replay the current track")
    func shuffleAvoidsCurrentTrack() {
        let next = PlaybackQueueNavigator.nextTrack(
            after: albumOneFirst,
            in: [albumOneFirst, albumTwo, albumOneSecond],
            mode: .shuffle,
            randomIndex: { _ in 0 }
        )
        #expect(next?.id == albumTwo.id)
        #expect(next?.id != albumOneFirst.id)
    }

    @Test("Previous navigation follows playback mode boundaries")
    func previousNavigation() {
        let queue = [albumOneFirst, albumTwo, albumOneSecond]
        #expect(PlaybackQueueNavigator.previousTrack(
            before: albumTwo, in: queue, mode: .sequential)?.id == albumOneFirst.id)
        #expect(PlaybackQueueNavigator.previousTrack(
            before: albumOneFirst, in: queue, mode: .sequential) == nil)
        #expect(PlaybackQueueNavigator.previousTrack(
            before: albumOneFirst, in: queue, mode: .repeatAll)?.id == albumOneSecond.id)
        #expect(PlaybackQueueNavigator.previousTrack(
            before: albumOneFirst, in: queue, mode: .repeatAlbum)?.id == albumOneSecond.id)
    }

    @Test("Queue edits preserve order and can be undone")
    @MainActor
    func queueEditingAndUndo() {
        let player = PlaybackController()
        player.updatePlaybackQueue([albumOneFirst, albumTwo, albumOneSecond])

        player.enqueueNext([albumOneSecond])
        #expect(player.queuedTracks.map(\.id) == [albumOneSecond.id, albumOneFirst.id, albumTwo.id])

        player.appendToQueue([albumOneFirst])
        #expect(player.queuedTracks.map(\.id) == [albumOneSecond.id, albumTwo.id, albumOneFirst.id])

        player.moveInQueue(albumOneFirst, offset: -1)
        #expect(player.queuedTracks.map(\.id) == [albumOneSecond.id, albumOneFirst.id, albumTwo.id])

        player.removeFromQueue(albumOneSecond)
        #expect(player.queuedTracks.map(\.id) == [albumOneFirst.id, albumTwo.id])
        player.undoLastQueueEdit()
        #expect(player.queuedTracks.map(\.id) == [albumOneSecond.id, albumOneFirst.id, albumTwo.id])

        player.moveInQueue(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(player.queuedTracks.map(\.id) == [albumOneFirst.id, albumTwo.id, albumOneSecond.id])
        player.undoLastQueueEdit()
        #expect(player.queuedTracks.map(\.id) == [albumOneSecond.id, albumOneFirst.id, albumTwo.id])
    }
}

@Suite("Playback history")
struct PlaybackHistoryTests {
    @Test("Pause and resume reuse one playback session")
    func sessionLifecycle() throws {
        let trackID = UUID()
        var tracker = PlaybackSessionTracker()
        let startedEvent = tracker.begin(trackID: trackID, position: 4)
        let started = try #require(startedEvent)
        #expect(tracker.begin(trackID: trackID, position: 8) == nil)

        let skippedEvent = tracker.finish(
            trackID: trackID,
            kind: .skipped,
            position: 12
        )
        let skipped = try #require(skippedEvent)
        #expect(skipped.playbackSessionID == started.playbackSessionID)
        #expect(skipped.kind == .skipped)
        #expect(skipped.position == 12)
        #expect(tracker.finish(
            trackID: trackID,
            kind: .completed,
            position: 90
        ) == nil)

        let restartedEvent = tracker.begin(trackID: trackID, position: 0)
        let restarted = try #require(restartedEvent)
        #expect(restarted.playbackSessionID != started.playbackSessionID)
    }

    @Test("History keeps the latest state for each session in reverse chronological order")
    func resolvesSessions() throws {
        let track = Track(
            id: UUID(), title: "History", artist: "Artist", album: "Album", duration: 90,
            fileSize: 1, managedPath: "/tmp/history.m4a", sha256: "history",
            addedAt: .now, health: .verified
        )
        let olderSession = UUID()
        let newerSession = UUID()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let events = [
            PlaybackEvent(
                trackID: track.id, kind: .started, occurredAt: base,
                position: 0, playbackSessionID: olderSession
            ),
            PlaybackEvent(
                trackID: track.id, kind: .completed, occurredAt: base.addingTimeInterval(90),
                position: 90, playbackSessionID: olderSession
            ),
            PlaybackEvent(
                trackID: track.id, kind: .started, occurredAt: base.addingTimeInterval(120),
                position: 12, playbackSessionID: newerSession
            ),
            PlaybackEvent(
                trackID: UUID(), kind: .skipped, occurredAt: base.addingTimeInterval(150),
                position: 1, playbackSessionID: UUID()
            ),
        ]

        let items = PlaybackHistoryResolver.items(events: events, tracks: [track])
        #expect(items.map(\.id) == [newerSession, olderSession])
        #expect(items[0].event.kind == .started)
        #expect(items[1].event.kind == .completed)
        #expect(items[1].event.position == 90)
    }
}
