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
