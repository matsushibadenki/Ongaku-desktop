import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Audio feature analysis")
struct AudioFeatureAnalysisTests {
    @Test("A sine wave produces stable loudness and spectral centroid estimates")
    func measuresLoudnessAndCentroid() {
        let sampleRate = 24_000.0
        let frequency = 440.0
        let samples = (0..<Int(sampleRate)).map { index in
            Float(0.5 * sin(2 * Double.pi * frequency * Double(index) / sampleRate))
        }

        let analysis = AudioFeatureAnalyzer.analyze(samples: samples, sampleRate: sampleRate)

        #expect(abs(analysis.averageLoudnessDBFS - -9.03) < 0.2)
        #expect(abs((analysis.peakDBFS ?? -120) - -6.02) < 0.1)
        #expect(abs(analysis.spectralCentroidHz - frequency) < 10)
    }

    @Test("A periodic pulse train reports tempo with confidence")
    func estimatesTempo() throws {
        let sampleRate = 1_000.0
        let duration = 12.0
        let beatInterval = 0.6
        var samples = Array(repeating: Float.zero, count: Int(sampleRate * duration))
        var beatTime = 0.0
        while beatTime < duration {
            let start = Int(beatTime * sampleRate)
            for index in start..<min(start + 20, samples.count) { samples[index] = 0.8 }
            beatTime += beatInterval
        }

        let analysis = AudioFeatureAnalyzer.analyze(samples: samples, sampleRate: sampleRate)
        let tempo = try #require(analysis.estimatedTempoBPM)

        #expect(abs(tempo - 100) < 1)
        #expect(analysis.tempoConfidence > 0.7)
        let onsets = try #require(analysis.onsetPositions)
        #expect(onsets.count >= 10)
        let beats = try #require(analysis.beatPositions)
        #expect(beats.count >= 10)
        #expect(abs((beats[1] - beats[0]) - beatInterval) < 0.01)
    }

    @Test("A C major chord resolves its pitch class and mode")
    func estimatesMusicalKey() {
        let sampleRate = 8_000.0
        let frequencies = [261.6256, 329.6276, 391.9954]
        let samples = (0..<Int(sampleRate * 4)).map { index in
            let time = Double(index) / sampleRate
            return Float(frequencies.reduce(0) { partial, frequency in
                partial + sin(2 * Double.pi * frequency * time) * 0.2
            })
        }

        let analysis = AudioFeatureAnalyzer.analyze(samples: samples, sampleRate: sampleRate)

        #expect(analysis.estimatedKeyPitchClass == 0)
        #expect(analysis.estimatedMode == .major)
        #expect((analysis.keyConfidence ?? 0) > 0)
    }

    @Test("The cache preserves current fingerprints and rejects changed files")
    func cacheRoundTripAndInvalidation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AudioFeatureCache(rootURL: root)
        var track = makeTrack(fingerprint: "original")
        let analysis = AudioFeatureAnalysis(
            trackID: track.id,
            contentFingerprint: track.sha256,
            averageLoudnessDBFS: -14,
            spectralCentroidHz: 1_800,
            estimatedTempoBPM: 120,
            tempoConfidence: 0.8
        )

        try await cache.save([track.id: analysis])
        #expect(try await cache.load(validTracks: [track])[track.id] == analysis)

        track.sha256 = "changed"
        #expect(try await cache.load(validTracks: [track]).isEmpty)
    }

    @Test("Version-one feature JSON remains decodable before invalidation")
    func decodesLegacyFeatureJSON() throws {
        let track = makeTrack(fingerprint: "legacy")
        let legacy = AudioFeatureAnalysis(
            trackID: track.id,
            contentFingerprint: track.sha256,
            algorithmVersion: 1,
            averageLoudnessDBFS: -16,
            spectralCentroidHz: 1_200,
            estimatedTempoBPM: 90,
            tempoConfidence: 0.4
        )
        let encoded = try JSONEncoder().encode(legacy)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        [
            "estimatedKeyPitchClass", "estimatedMode", "keyConfidence",
            "onsetPositions", "beatPositions", "peakDBFS",
        ].forEach { object.removeValue(forKey: $0) }
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AudioFeatureAnalysis.self, from: legacyData)

        #expect(decoded.algorithmVersion == 1)
        #expect(decoded.estimatedKeyPitchClass == nil)
        #expect(decoded.peakDBFS == nil)
        #expect(!decoded.isCurrent(for: track))
    }

    @Test("Song normalization reaches its target and respects measured peak headroom")
    func trackLoudnessNormalizationAndPeakProtection() {
        let analysis = AudioFeatureAnalysis(
            trackID: UUID(),
            contentFingerprint: "loudness",
            averageLoudnessDBFS: -20,
            peakDBFS: -3,
            spectralCentroidHz: 1_000,
            estimatedTempoBPM: nil,
            tempoConfidence: 0
        )
        let unrestricted = LoudnessNormalizationPolicy.result(
            mode: .track,
            trackAnalysis: analysis,
            albumAnalyses: [],
            targetDBFS: -14,
            preventsClipping: false
        )
        let protected = LoudnessNormalizationPolicy.result(
            mode: .track,
            trackAnalysis: analysis,
            albumAnalyses: [],
            targetDBFS: -14,
            preventsClipping: true
        )

        #expect(abs(unrestricted.gainDB - 6) < 0.001)
        #expect(!unrestricted.isLimitedByPeak)
        #expect(abs(protected.gainDB - 2) < 0.001)
        #expect(protected.isLimitedByPeak)
    }

    @Test("Album normalization applies one energy-averaged gain to album members")
    func albumLoudnessNormalization() {
        let quiet = AudioFeatureAnalysis(
            trackID: UUID(),
            contentFingerprint: "quiet",
            averageLoudnessDBFS: -20,
            peakDBFS: -8,
            spectralCentroidHz: 1_000,
            estimatedTempoBPM: nil,
            tempoConfidence: 0
        )
        let loud = AudioFeatureAnalysis(
            trackID: UUID(),
            contentFingerprint: "loud",
            averageLoudnessDBFS: -14,
            peakDBFS: -2,
            spectralCentroidHz: 1_000,
            estimatedTempoBPM: nil,
            tempoConfidence: 0
        )
        let album = [quiet, loud]
        let quietResult = LoudnessNormalizationPolicy.result(
            mode: .album,
            trackAnalysis: quiet,
            albumAnalyses: album,
            targetDBFS: -14,
            preventsClipping: false
        )
        let loudResult = LoudnessNormalizationPolicy.result(
            mode: .album,
            trackAnalysis: loud,
            albumAnalyses: album,
            targetDBFS: -14,
            preventsClipping: false
        )

        #expect(abs(quietResult.gainDB - loudResult.gainDB) < 0.0001)
        #expect(quietResult.gainDB > 0)
        #expect(quietResult.gainDB < 3)
    }

    @Test("Audio analysis pauses for low power and elevated thermal pressure")
    func powerPolicyPauseReasons() {
        #expect(
            AudioFeatureAnalysisPowerPolicy.automaticPauseReason(
                isLowPowerModeEnabled: false,
                thermalState: .nominal
            ) == nil
        )
        #expect(
            AudioFeatureAnalysisPowerPolicy.automaticPauseReason(
                isLowPowerModeEnabled: true,
                thermalState: .fair
            ) == .lowPowerMode
        )
        #expect(
            AudioFeatureAnalysisPowerPolicy.automaticPauseReason(
                isLowPowerModeEnabled: false,
                thermalState: .serious
            ) == .thermalPressure
        )
        #expect(
            AudioFeatureAnalysisPowerPolicy.automaticPauseReason(
                isLowPowerModeEnabled: true,
                thermalState: .critical
            ) == .thermalPressure
        )
    }

    private func makeTrack(fingerprint: String) -> Track {
        Track(
            id: UUID(),
            title: "Feature Test",
            artist: "Artist",
            album: "Album",
            duration: 120,
            fileSize: 1,
            managedPath: "/tmp/feature-test.m4a",
            sha256: fingerprint,
            addedAt: .now,
            health: .verified
        )
    }
}
