import AVFoundation
import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Gapless playback planning")
struct GaplessPlaybackTests {
    @Test("Equivalent processing formats can share one player node")
    func compatibleFormats() {
        let first = GaplessAudioFormat(
            sampleRate: 44_100,
            channelCount: 2,
            commonFormat: 1,
            isInterleaved: false
        )
        let second = GaplessAudioFormat(
            sampleRate: 44_100,
            channelCount: 2,
            commonFormat: 1,
            isInterleaved: false
        )

        #expect(first.canSharePlayerNode(with: second))
    }

    @Test("Rate, channel, encoding, and interleave differences require safe rebuild")
    func incompatibleFormats() {
        let base = GaplessAudioFormat(
            sampleRate: 44_100,
            channelCount: 2,
            commonFormat: 1,
            isInterleaved: false
        )

        #expect(!base.canSharePlayerNode(with: .init(
            sampleRate: 48_000,
            channelCount: 2,
            commonFormat: 1,
            isInterleaved: false
        )))
        #expect(!base.canSharePlayerNode(with: .init(
            sampleRate: 44_100,
            channelCount: 1,
            commonFormat: 1,
            isInterleaved: false
        )))
        #expect(!base.canSharePlayerNode(with: .init(
            sampleRate: 44_100,
            channelCount: 2,
            commonFormat: 2,
            isInterleaved: false
        )))
        #expect(!base.canSharePlayerNode(with: .init(
            sampleRate: 44_100,
            channelCount: 2,
            commonFormat: 1,
            isInterleaved: true
        )))
    }

    @Test("Preroll begins only once inside the five-second window")
    func prerollWindow() {
        #expect(!GaplessPrerollPolicy.shouldPrepare(remaining: 5.1, alreadyPrepared: false))
        #expect(GaplessPrerollPolicy.shouldPrepare(remaining: 5, alreadyPrepared: false))
        #expect(GaplessPrerollPolicy.shouldPrepare(remaining: 0.01, alreadyPrepared: false))
        #expect(!GaplessPrerollPolicy.shouldPrepare(remaining: 0, alreadyPrepared: false))
        #expect(!GaplessPrerollPolicy.shouldPrepare(remaining: 3, alreadyPrepared: true))
    }

    @Test("Crossfade duration is clamped and disabled for album playback")
    func crossfadeDurationPolicy() {
        #expect(CrossfadePolicy.effectiveDuration(
            requestedDuration: 20,
            currentRemaining: 30,
            nextDuration: 30,
            isSameAlbum: false,
            disablesWithinAlbum: true,
            formatsAreCompatible: true
        ) == 12)
        #expect(CrossfadePolicy.effectiveDuration(
            requestedDuration: 6,
            currentRemaining: 8,
            nextDuration: 4,
            isSameAlbum: false,
            disablesWithinAlbum: true,
            formatsAreCompatible: true
        ) == 3.95)
        #expect(CrossfadePolicy.effectiveDuration(
            requestedDuration: 6,
            currentRemaining: 8,
            nextDuration: 8,
            isSameAlbum: true,
            disablesWithinAlbum: true,
            formatsAreCompatible: true
        ) == 0)
    }

    @Test("Crossfade uses equal-power gains")
    func equalPowerGains() {
        let start = CrossfadePolicy.gains(progress: 0)
        let middle = CrossfadePolicy.gains(progress: 0.5)
        let end = CrossfadePolicy.gains(progress: 1)

        #expect(start.outgoing == 1)
        #expect(abs(start.incoming) < 0.0001)
        #expect(abs(Double(middle.outgoing) - 0.7071) < 0.001)
        #expect(abs(Double(middle.incoming) - 0.7071) < 0.001)
        #expect(abs(end.outgoing) < 0.0001)
        #expect(end.incoming == 1)
    }

    @Test("Silence policy preserves a safety margin around audible content")
    func silencePolicy() {
        let blocks = Array(repeating: 0.0, count: 10)
            + Array(repeating: 0.25, count: 20)
            + Array(repeating: 0.0, count: 15)

        let leading = SilenceAnalysisPolicy.silenceDuration(
            rmsBlocks: blocks,
            scannedDuration: 0.45,
            direction: .leading
        )
        let trailing = SilenceAnalysisPolicy.silenceDuration(
            rmsBlocks: blocks,
            scannedDuration: 0.45,
            direction: .trailing
        )

        #expect(abs(leading - 0.08) < 0.0001)
        #expect(abs(trailing - 0.13) < 0.0001)
    }

    @Test("Audio analyzer detects leading and trailing silence in a PCM file")
    func audioSilenceAnalyzer() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ongaku-silence-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let sampleRate = 8_000.0
        let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        )!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3_600)!
            buffer.frameLength = 3_600
            let samples = buffer.floatChannelData![0]
            for frame in 0..<3_600 {
                samples[frame] = frame >= 800 && frame < 2_400 ? 0.25 : 0
            }
            try file.write(from: buffer)
        }

        let analysis = try AudioSilenceAnalyzer.analyze(url: url)

        #expect(abs(analysis.leadingSilence - 0.08) < 0.015)
        #expect(abs(analysis.trailingSilence - 0.13) < 0.015)
    }
}
