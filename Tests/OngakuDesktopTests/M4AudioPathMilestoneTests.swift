import AVFoundation
import Foundation
import Testing
@testable import OngakuDesktop

@Suite("M4 audio quality and output milestone", .serialized)
struct M4AudioPathMilestoneTests {
    @Test("The diagnostic record explains format, DSP, normalization, output, and source safety")
    func diagnosticRecordIsComplete() {
        let snapshot = AudioSignalPathSnapshot(
            sourceSampleRate: 44_100,
            sourceChannelCount: 2,
            processingSampleRate: 44_100,
            processingChannelCount: 2,
            outputSampleRate: 192_000,
            outputChannelCount: 2,
            enabledEffects: [.equalizer, .space],
            effectsBypassed: false,
            normalizationMode: .track,
            normalizationGainDB: 2,
            normalizationLimitedByPeak: true
        )

        #expect(snapshot.sourceIsUnmodified)
        #expect(snapshot.diagnosticLine.contains("source=44100Hz/2ch"))
        #expect(snapshot.diagnosticLine.contains("processing=44100Hz/2ch"))
        #expect(snapshot.diagnosticLine.contains("dsp=equalizer,space"))
        #expect(snapshot.diagnosticLine.contains("normalization=track:+2.00dB:peak-limited"))
        #expect(snapshot.diagnosticLine.contains("output=192000Hz/2ch"))
        #expect(snapshot.diagnosticLine.contains("sourceMutation=none"))
    }

    @Test("Loading and processing a real file leaves every source byte unchanged")
    @MainActor
    func playbackPathDoesNotRewriteSource() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ongaku-M4-Path-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audioURL = root.appendingPathComponent("source.caf")
        try writeSilentAudio(to: audioURL)
        let sourceBefore = try Data(contentsOf: audioURL)
        let track = Track(
            id: UUID(), title: "Signal Path", artist: "Artist", album: "Album",
            duration: 1, fileSize: Int64(sourceBefore.count), managedPath: audioURL.path,
            sha256: try LibraryRepository.sha256(of: audioURL), addedAt: .now,
            lastVerifiedAt: .now, health: .verified
        )
        let analysis = AudioFeatureAnalysis(
            trackID: track.id,
            contentFingerprint: track.sha256,
            averageLoudnessDBFS: -20,
            peakDBFS: -3,
            spectralCentroidHz: 1_000,
            estimatedTempoBPM: nil,
            tempoConfidence: 0
        )
        let player = PlaybackController()
        player.setEffectsBypassed(false)
        player.setEffectEnabled(true, for: .equalizer)
        player.loudnessNormalizationMode = .track
        player.loudnessTargetDBFS = -14
        player.preventsClipping = true
        player.updateAudioFeatures([track.id: analysis])

        player.restorePlaybackQueue(
            PlaybackQueueState(
                trackIDs: [track.id], currentTrackID: track.id, position: 0.25
            ),
            tracks: [track]
        )

        let path = try #require(player.signalPathSnapshot)
        #expect(path.sourceSampleRate == 44_100)
        #expect(path.sourceChannelCount == 2)
        #expect(path.processingSampleRate == path.sourceSampleRate)
        #expect(path.processingChannelCount == path.sourceChannelCount)
        #expect(path.outputSampleRate > 0)
        #expect(path.outputChannelCount > 0)
        #expect(path.enabledEffects.contains(.equalizer))
        #expect(path.normalizationMode == .track)
        #expect(abs(path.normalizationGainDB - 2) < 0.01)
        #expect(path.normalizationLimitedByPeak)
        #expect(path.sourceIsUnmodified)
        #expect(try Data(contentsOf: audioURL) == sourceBefore)
    }

    private func writeSilentAudio(to url: URL) throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 2,
            interleaved: false
        ))
        let frames = AVAudioFrameCount(format.sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
