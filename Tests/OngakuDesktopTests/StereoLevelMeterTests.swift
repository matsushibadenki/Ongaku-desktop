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
    private let albumOneFirst = Track(
        id: UUID(), title: "One", artist: "Artist", album: "Album One", duration: 1,
        fileSize: 1, managedPath: "/tmp/one.mp3", sha256: "one", addedAt: .now,
        health: .verified)
    private let albumTwo = Track(
        id: UUID(), title: "Two", artist: "Artist", album: "Album Two", duration: 1,
        fileSize: 1, managedPath: "/tmp/two.mp3", sha256: "two", addedAt: .now,
        health: .verified)
    private let albumOneSecond = Track(
        id: UUID(), title: "Three", artist: "Artist", album: "Album One", duration: 1,
        fileSize: 1, managedPath: "/tmp/three.mp3", sha256: "three", addedAt: .now,
        health: .verified)

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
}
