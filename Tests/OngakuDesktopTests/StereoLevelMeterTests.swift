@preconcurrency import AVFoundation
@testable import OngakuDesktop
import Foundation
import SwiftUI
import Testing

private final class CapturedAudioVisualization: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AudioVisualizationSnapshot?

    func store(_ snapshot: AudioVisualizationSnapshot) {
        lock.lock()
        stored = snapshot
        lock.unlock()
    }

    func load() -> AudioVisualizationSnapshot? {
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
    @Test("VU meter renders at the player-slot size")
    @MainActor
    func vuMeterRendering() throws {
        let renderer = ImageRenderer(
            content: ChannelVUMeterView(
                channel: "L",
                level: 0,
                backlight: .cyan
            )
            .frame(width: 280, height: 80)
        )
        renderer.scale = 2

        let image = try #require(renderer.nsImage)
        #expect(image.size == NSSize(width: 280, height: 80))
    }

    @Test("VU meter uses a shallow arc and keeps both needle extremes visible")
    func vuMeterGeometry() {
        for size in [CGSize(width: 280, height: 80), CGSize(width: 200, height: 80)] {
            let geometry = VUMeterGeometry.layout(for: size)
            let silentTip = geometry.needleTip(position: 0)
            let overloadTip = geometry.needleTip(position: 1)

            #expect(geometry.pivot.y > size.height)
            #expect(geometry.scaleRadius > size.width)
            #expect(geometry.halfAngle < 30 * .pi / 180)
            #expect((0...size.width).contains(silentTip.x))
            #expect((0..<size.height).contains(silentTip.y))
            #expect((0...size.width).contains(overloadTip.x))
            #expect((0..<size.height).contains(overloadTip.y))
        }
    }

    @Test("VU needle exposes its position to SwiftUI animation")
    @MainActor
    func vuNeedleAnimation() {
        var needle = VUMeterNeedle(position: 0)
        needle.animatableData = 0.625

        #expect(needle.position == 0.625)
    }

    @Test("VU needle settles slowly after playback stops")
    func vuNeedleStopMotion() {
        #expect(VUMeterMotion.duration(isActive: false) > 0.5)
        #expect(
            VUMeterMotion.duration(isActive: false)
                > VUMeterMotion.duration(isActive: true)
        )
    }

    @Test("VU readings are sampled densely enough for fine motion")
    func meterRefreshRate() {
        let throttle = StereoMeterThrottle()

        #expect(throttle.shouldEmit(now: 1))
        #expect(!throttle.shouldEmit(now: 1 + (1.0 / 120.0)))
        #expect(throttle.shouldEmit(now: 1 + (1.0 / 60.0) + 0.000_001))
        #expect(AudioVisualizationConfiguration.tapBufferSize == 1_024)
    }

    @Test("VU ballistics preserve small changes and release more gently")
    func meterBallistics() {
        let interval = 1.0 / 48.0
        let smallChange = VUMeterBallistics.smoothed(
            current: 0.50,
            target: 0.52,
            elapsed: interval
        )
        let attack = VUMeterBallistics.smoothed(current: 0.2, target: 0.8, elapsed: interval)
        let release = VUMeterBallistics.smoothed(current: 0.8, target: 0.2, elapsed: interval)

        #expect(smallChange > 0.50)
        #expect(smallChange < 0.52)
        #expect(attack - 0.2 > 0.8 - release)
        #expect(release > 0.2)
    }

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

    @Test("Left and right spectra resolve different frequency bands")
    func stereoSpectrum() throws {
        let sampleRate = 48_000.0
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
        )
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_048))
        buffer.frameLength = 2_048
        let channels = try #require(buffer.floatChannelData)
        for frame in 0..<Int(buffer.frameLength) {
            let time = Double(frame) / sampleRate
            channels[0][frame] = Float(sin(2 * .pi * 220 * time) * 0.8)
            channels[1][frame] = Float(sin(2 * .pi * 6_000 * time) * 0.8)
        }

        let spectrum = SpectrumMath.measure(buffer)
        let leftPeak = try #require(spectrum.left.indices.max(by: {
            spectrum.left[$0] < spectrum.left[$1]
        }))
        let rightPeak = try #require(spectrum.right.indices.max(by: {
            spectrum.right[$0] < spectrum.right[$1]
        }))

        #expect(spectrum.left.count == StereoSpectrum.bandCount)
        #expect(spectrum.right.count == StereoSpectrum.bandCount)
        #expect(leftPeak < rightPeak)
        #expect(spectrum.left[leftPeak] > 0.5)
        #expect(spectrum.right[rightPeak] > 0.5)
    }

    @Test("Spectrum smoothing attacks faster than it releases")
    func spectrumSmoothing() {
        let attack = SpectrumMath.smoothed(current: [0], target: [1])[0]
        let release = SpectrumMath.smoothed(current: [1], target: [0])[0]

        #expect(attack == 0.72)
        #expect(release == 0.8)
    }

    @Test("Spectrum presentation uses the full meter height for musical peaks")
    func spectrumPresentationHeight() {
        #expect(SpectrumPresentation.height(for: -1) == 0)
        #expect(SpectrumPresentation.height(for: 0) == 0)
        #expect(SpectrumPresentation.height(for: 0.5) > 0.8)
        #expect(SpectrumPresentation.height(for: 0.7) == 1)
        #expect(SpectrumPresentation.height(for: 2) == 1)
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

        let captured = CapturedAudioVisualization()
        let tap = makeStereoMeterTapBlock(throttle: StereoMeterThrottle()) { snapshot in
            captured.store(snapshot)
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
        let snapshot = try #require(captured.load())
        #expect(snapshot.levels.left > snapshot.levels.right)
        #expect(snapshot.spectrum.left.count == StereoSpectrum.bandCount)
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

    @Test("Automatic navigation skips excluded tracks")
    func skipsExcludedTracks() {
        var excluded = albumTwo
        excluded.isExcludedFromPlayback = true
        let queue = [albumOneFirst, excluded, albumOneSecond]

        #expect(PlaybackQueueNavigator.nextTrack(
            after: albumOneFirst, in: queue, mode: .sequential)?.id == albumOneSecond.id)
        #expect(PlaybackQueueNavigator.previousTrack(
            before: albumOneSecond, in: queue, mode: .sequential)?.id == albumOneFirst.id)
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

    @Test("Playback statistics count completions and skips and keep the latest activity")
    func resolvesPlaybackStatistics() throws {
        let trackID = UUID()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let events = [
            PlaybackEvent(trackID: trackID, kind: .started, occurredAt: base),
            PlaybackEvent(
                trackID: trackID,
                kind: .completed,
                occurredAt: base.addingTimeInterval(60)
            ),
            PlaybackEvent(
                trackID: trackID,
                kind: .started,
                occurredAt: base.addingTimeInterval(120)
            ),
            PlaybackEvent(
                trackID: trackID,
                kind: .skipped,
                occurredAt: base.addingTimeInterval(135)
            ),
        ]

        let statistics = try #require(
            PlaybackStatisticsResolver.statistics(events: events)[trackID]
        )
        #expect(statistics.playCount == 1)
        #expect(statistics.skipCount == 1)
        #expect(statistics.lastPlayedAt == base.addingTimeInterval(135))
    }
}
