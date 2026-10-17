import AVFoundation
import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Audio fidelity policy", .serialized)
struct AudioFidelityPolicyTests {
    @Test("Full-track stereo loudness survives opposite polarity and includes audio after 60 seconds")
    func fullTrackStereoMeasurement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("opposite.caf")
        let rate = 48_000.0
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        buffer.frameLength = 4_800
        var reference = IntegratedLoudnessMeter(sampleRate: rate, channelCount: 2)!
        for block in 0..<640 {
            for frame in 0..<4_800 {
                let sample = block < 610 ? Float.zero : Float(0.1 * sin(2 * .pi * 1_000 * Double(frame) / rate))
                buffer.floatChannelData![0][frame] = sample
                buffer.floatChannelData![1][frame] = -sample
            }
            try file.write(from: buffer)
            reference.process(frameCount: 4_800) { buffer.floatChannelData![$0][$1] }
        }
        let track = makeTrack(url: url, duration: 64)
        let result = try AudioFeatureAnalyzer.analyze(track: track)
        let measured = try #require(result.integratedLoudnessLUFS)
        #expect(abs(measured - reference.integratedLUFS!) < 0.001)
        #expect(measured > -24 && measured < -19)
        #expect(abs((result.peakDBFS ?? 0) + 20) < 0.01)
        #expect(result.loudnessBlockEnergies?.count == 637)
    }

    @Test("Missing or old LUFS never reuses legacy RMS as loudness")
    func rejectsLegacyRMS() {
        let legacy = AudioFeatureAnalysis(trackID: UUID(), contentFingerprint: "x",
            averageLoudnessDBFS: -30, peakDBFS: -8, spectralCentroidHz: 0,
            estimatedTempoBPM: nil, tempoConfidence: 0)
        #expect(LoudnessNormalizationPolicy.result(mode: .track, trackAnalysis: legacy,
            albumMeasurement: nil, targetLUFS: -16, preventsClipping: true) == .unity)
    }

    @Test("192kHz files use the shared effect rate and keep Space enabled")
    @MainActor func highRateFileKeepsSpatialStage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("high-rate.caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 192_000, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192_000))
        buffer.frameLength = 192_000
        for ch in 0..<2 { for f in 0..<192_000 { buffer.floatChannelData![ch][f] = 0 } }
        try file.write(from: buffer)
        let track = makeTrack(url: url, duration: 1)
        let player = PlaybackController()
        let previousUpsampling = player.automaticUpsampling
        let previousBypass = player.effectsBypassed
        defer { player.automaticUpsampling = previousUpsampling; player.setEffectsBypassed(previousBypass) }
        player.automaticUpsampling = false // Never change the host DAC during tests.
        player.setEffectsBypassed(false)
        player.restorePlaybackQueue(PlaybackQueueState(trackIDs: [track.id], currentTrackID: track.id, position: 0), tracks: [track])
        let path = try #require(player.signalPathSnapshot)
        #expect(path.sourceSampleRate == 192_000)
        #expect(path.processingSampleRate == 96_000)
        #expect(path.finalTruePeakEnabled == FinalOutputProtection.enabledForBuild)
        if path.finalTruePeakEnabled {
            #expect(abs(path.finalProtectionLatency * path.outputSampleRate
                        - (ceil(path.outputSampleRate * 0.004) + 64)) < 0.00001)
            #expect(path.diagnosticLine.contains("finalTruePeak=qualification"))
        } else {
            #expect(path.finalProtectionLatency == 0)
        }
        #expect(player.errorMessage == nil)
        // Exercise the actual rate-dependent effect guard on the shared format.
        let engine = AVAudioEngine()
        let space = SpaceAudioEffect()
        space.attach(to: engine)
        defer { space.detach(from: engine) }
        space.connectInternalNodes(engine: engine, format: AVAudioFormat(standardFormatWithSampleRate: path.processingSampleRate, channels: 2))
        space.apply(setting: RealtimeAudioEffectSetting(kind: .space, isEnabled: true))
        #expect(space.isEnabled)
    }

    @Test("File-rate source mixer feeds audible spatial processing at every final rate")
    func rendersCommonRateGraph() throws {
        for sourceRate in [44_100.0, 48_000, 192_000] {
            for outputRate in [44_100.0, 48_000, 96_000] {
                let engine = AVAudioEngine()
                let player = AVAudioPlayerNode()
                let mixer = AVAudioMixerNode()
                let space = SpaceAudioEffect()
                let source = AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 2)!
                let processing = AVAudioFormat(standardFormatWithSampleRate: AudioProcessingPolicy.effectSampleRate, channels: 2)!
                let output = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2)!
                engine.attach(player); engine.attach(mixer); space.attach(to: engine)
                engine.connect(player, to: mixer, format: source)
                engine.connect(mixer, to: space.inputNode, format: processing)
                space.connectInternalNodes(engine: engine, format: processing)
                engine.connect(space.outputNode, to: engine.mainMixerNode, format: processing)
                try engine.enableManualRenderingMode(.offline, format: output, maximumFrameCount: 512)
                space.apply(setting: RealtimeAudioEffectSetting(kind: .space, isEnabled: true))
                #expect(space.isEnabled)
                let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(sourceRate))!
                input.frameLength = input.frameCapacity
                for f in 0..<Int(input.frameLength) {
                    let sample = Float(0.1 * sin(2 * .pi * 997 * Double(f) / sourceRate))
                    input.floatChannelData![0][f] = sample
                    input.floatChannelData![1][f] = -sample * 0.5
                }
                player.scheduleBuffer(input)
                try engine.start(); player.play()
                defer { player.stop(); engine.stop(); space.detach(from: engine) }
                let rendered = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 512)!
                var peaks: [Float] = [0, 0]
                for _ in 0..<64 {
                    #expect(try engine.renderOffline(512, to: rendered) == .success)
                    for ch in 0..<2 { for f in 0..<Int(rendered.frameLength) {
                        let sample = rendered.floatChannelData![ch][f]
                        #expect(sample.isFinite)
                        peaks[ch] = max(peaks[ch], abs(sample))
                    } }
                }
                #expect(peaks.allSatisfy { $0 > 0.01 && $0 < 0.5 })
            }
        }
    }

    @Test("Album analysis runs asynchronously and discards stale feature revisions")
    @MainActor func albumCacheRejectsStaleResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("album.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = buffer.frameCapacity
        for ch in 0..<2 { for f in 0..<48_000 { buffer.floatChannelData![ch][f] = 0 } }
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        let track = makeTrack(url: url, duration: 1)
        let player = PlaybackController()
        let oldUpsampling = player.automaticUpsampling
        let oldMode = player.loudnessNormalizationMode
        let oldTarget = player.loudnessTargetLUFS
        let oldProtection = player.preventsClipping
        defer {
            player.loudnessNormalizationMode = oldMode
            player.loudnessTargetLUFS = oldTarget
            player.preventsClipping = oldProtection
            player.automaticUpsampling = oldUpsampling
        }
        player.automaticUpsampling = false
        player.loudnessNormalizationMode = .off
        player.loudnessTargetLUFS = -16
        player.preventsClipping = false
        player.restorePlaybackQueue(PlaybackQueueState(trackIDs: [track.id], currentTrackID: track.id, position: 0), tracks: [track])
        func analysis(_ lufs: Double) -> AudioFeatureAnalysis {
            AudioFeatureAnalysis(trackID: track.id, contentFingerprint: track.sha256,
                averageLoudnessDBFS: -30, peakDBFS: -2, integratedLoudnessLUFS: lufs,
                loudnessBlockEnergies: Array(repeating: pow(10, (lufs + 0.691) / 10), count: 10_000),
                spectralCentroidHz: 0, estimatedTempoBPM: nil, tempoConfidence: 0)
        }
        player.updateAudioFeatures([track.id: analysis(-24)])
        player.loudnessNormalizationMode = .album
        #expect(player.signalPathSnapshot?.normalizationGainDB == 0)
        player.updateAudioFeatures([track.id: analysis(-12)])
        for _ in 0..<100 {
            if let gain = player.signalPathSnapshot?.normalizationGainDB, abs(gain + 4) < 0.001 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let gain = try #require(player.signalPathSnapshot?.normalizationGainDB)
        #expect(abs(gain + 4) < 0.001)
    }

    private func makeTrack(url: URL, duration: Double) -> Track {
        Track(id: UUID(), title: "Fixture", artist: "Artist", album: "Album", duration: duration,
              fileSize: 0, managedPath: url.path, sha256: "fixture", addedAt: .now,
              lastVerifiedAt: .now, health: .verified)
    }
}
