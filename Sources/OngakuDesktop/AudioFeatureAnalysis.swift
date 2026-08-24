import AVFoundation
import Foundation

enum MusicalMode: String, Codable, Sendable {
    case major
    case minor
}

struct AudioFeatureAnalysis: Codable, Equatable, Sendable {
    static let currentAlgorithmVersion = 4

    let trackID: Track.ID
    let contentFingerprint: String
    let algorithmVersion: Int
    let analyzedAt: Date
    let averageLoudnessDBFS: Double
    let peakDBFS: Double?
    let spectralCentroidHz: Double
    let estimatedTempoBPM: Double?
    let tempoConfidence: Double
    let estimatedKeyPitchClass: Int?
    let estimatedMode: MusicalMode?
    let keyConfidence: Double?
    let onsetPositions: [TimeInterval]?
    let beatPositions: [TimeInterval]?

    init(
        trackID: Track.ID,
        contentFingerprint: String,
        algorithmVersion: Int = currentAlgorithmVersion,
        analyzedAt: Date = .now,
        averageLoudnessDBFS: Double,
        peakDBFS: Double? = nil,
        spectralCentroidHz: Double,
        estimatedTempoBPM: Double?,
        tempoConfidence: Double,
        estimatedKeyPitchClass: Int? = nil,
        estimatedMode: MusicalMode? = nil,
        keyConfidence: Double? = nil,
        onsetPositions: [TimeInterval]? = nil,
        beatPositions: [TimeInterval]? = nil
    ) {
        self.trackID = trackID
        self.contentFingerprint = contentFingerprint
        self.algorithmVersion = algorithmVersion
        self.analyzedAt = analyzedAt
        self.averageLoudnessDBFS = averageLoudnessDBFS
        self.peakDBFS = peakDBFS
        self.spectralCentroidHz = spectralCentroidHz
        self.estimatedTempoBPM = estimatedTempoBPM
        self.tempoConfidence = tempoConfidence
        self.estimatedKeyPitchClass = estimatedKeyPitchClass
        self.estimatedMode = estimatedMode
        self.keyConfidence = keyConfidence
        self.onsetPositions = onsetPositions
        self.beatPositions = beatPositions
    }

    nonisolated func isCurrent(for track: Track) -> Bool {
        trackID == track.id
            && contentFingerprint == track.sha256
            && algorithmVersion == Self.currentAlgorithmVersion
    }
}

enum AudioFeatureAnalyzer {
    static let maximumAnalysisDuration: TimeInterval = 60
    private static let envelopeBlockDuration: TimeInterval = 0.02
    private static let minimumTempo = 60.0
    private static let maximumTempo = 200.0

    nonisolated static func analyze(track: Track) throws -> AudioFeatureAnalysis {
        let file = try AVAudioFile(forReading: track.fileURL)
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0, file.length > 0 else {
            return silentAnalysis(for: track)
        }
        let maximumFrames = AVAudioFramePosition(maximumAnalysisDuration * sampleRate)
        let frameLimit = min(file.length, maximumFrames)
        let samplingStride = max(Int(sampleRate / 12_000), 1)
        let analysisSampleRate = sampleRate / Double(samplingStride)
        var samples: [Float] = []
        samples.reserveCapacity(Int(min(frameLimit / AVAudioFramePosition(samplingStride), 750_000)))
        var remaining = frameLimit
        var sourceFrameIndex = 0
        let channelCount = Int(file.processingFormat.channelCount)
        let chunkCapacity: AVAudioFrameCount = 16_384

        while remaining > 0 {
            let requested = AVAudioFrameCount(
                min(remaining, AVAudioFramePosition(chunkCapacity))
            )
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: requested
            ) else { break }
            try file.read(into: buffer, frameCount: requested)
            let framesRead = Int(buffer.frameLength)
            guard framesRead > 0, channelCount > 0,
                  let channels = buffer.floatChannelData else { break }

            for frame in 0..<framesRead {
                defer { sourceFrameIndex += 1 }
                guard sourceFrameIndex.isMultiple(of: samplingStride) else { continue }
                var mono: Float = 0
                if buffer.format.isInterleaved {
                    for channel in 0..<channelCount {
                        mono += channels[0][frame * channelCount + channel]
                    }
                } else {
                    for channel in 0..<channelCount {
                        mono += channels[channel][frame]
                    }
                }
                samples.append(mono / Float(channelCount))
            }
            remaining -= AVAudioFramePosition(framesRead)
        }
        return analyze(
            samples: samples,
            sampleRate: analysisSampleRate,
            trackID: track.id,
            contentFingerprint: track.sha256
        )
    }

    nonisolated static func analyze(
        samples: [Float],
        sampleRate: Double,
        trackID: Track.ID = UUID(),
        contentFingerprint: String = "test"
    ) -> AudioFeatureAnalysis {
        guard sampleRate > 0, !samples.isEmpty else {
            return AudioFeatureAnalysis(
                trackID: trackID,
                contentFingerprint: contentFingerprint,
                averageLoudnessDBFS: -120,
                spectralCentroidHz: 0,
                estimatedTempoBPM: nil,
                tempoConfidence: 0
            )
        }

        var energy = 0.0
        var peakAmplitude = 0.0
        var derivativeEnergy = 0.0
        var previous = Double(samples[0])
        let blockSize = max(Int(sampleRate * envelopeBlockDuration), 1)
        var envelope: [Double] = []
        envelope.reserveCapacity(samples.count / blockSize + 1)
        var blockEnergy = 0.0
        var blockSamples = 0

        for sampleValue in samples {
            let sample = Double(sampleValue)
            peakAmplitude = max(peakAmplitude, abs(sample))
            energy += sample * sample
            let difference = sample - previous
            derivativeEnergy += difference * difference
            previous = sample
            blockEnergy += sample * sample
            blockSamples += 1
            if blockSamples == blockSize {
                envelope.append(sqrt(blockEnergy / Double(blockSamples)))
                blockEnergy = 0
                blockSamples = 0
            }
        }
        if blockSamples > 0 {
            envelope.append(sqrt(blockEnergy / Double(blockSamples)))
        }

        let meanSquare = energy / Double(samples.count)
        let loudness = meanSquare > 0 ? max(10 * log10(meanSquare), -120) : -120
        let peakDBFS = peakAmplitude > 0 ? max(20 * log10(peakAmplitude), -120) : -120
        let centroid: Double
        if energy > 0 {
            centroid = min(
                sampleRate / (2 * .pi) * sqrt(derivativeEnergy / energy),
                sampleRate / 2
            )
        } else {
            centroid = 0
        }
        let tempo = estimateTempo(envelope: envelope, blockDuration: envelopeBlockDuration)
        let onsets = detectOnsets(envelope: envelope, blockDuration: envelopeBlockDuration)
        let duration = Double(samples.count) / sampleRate
        let beats = beatGrid(bpm: tempo.bpm, onsets: onsets, duration: duration)
        let key = estimateKey(samples: samples, sampleRate: sampleRate)

        return AudioFeatureAnalysis(
            trackID: trackID,
            contentFingerprint: contentFingerprint,
            averageLoudnessDBFS: min(loudness, 0),
            peakDBFS: min(peakDBFS, 0),
            spectralCentroidHz: max(centroid, 0),
            estimatedTempoBPM: tempo.bpm,
            tempoConfidence: tempo.confidence,
            estimatedKeyPitchClass: key.pitchClass,
            estimatedMode: key.mode,
            keyConfidence: key.confidence,
            onsetPositions: onsets,
            beatPositions: beats
        )
    }

    private nonisolated static func detectOnsets(
        envelope: [Double],
        blockDuration: TimeInterval
    ) -> [TimeInterval] {
        guard envelope.count > 2 else { return [] }
        let flux = zip(envelope.dropFirst(), envelope).map { pair in
            max(pair.0 - pair.1, 0)
        }
        let mean = flux.reduce(0, +) / Double(flux.count)
        let variance = flux.reduce(0) { $0 + pow($1 - mean, 2) } / Double(flux.count)
        let threshold = mean + sqrt(variance) * 1.5
        let minimumSeparation = max(Int(0.08 / blockDuration), 1)
        var lastIndex = -minimumSeparation
        var positions: [TimeInterval] = []
        for index in flux.indices where flux[index] > threshold {
            guard index - lastIndex >= minimumSeparation else { continue }
            positions.append(Double(index + 1) * blockDuration)
            lastIndex = index
            if positions.count == 512 { break }
        }
        return positions
    }

    private nonisolated static func beatGrid(
        bpm: Double?,
        onsets: [TimeInterval],
        duration: TimeInterval
    ) -> [TimeInterval] {
        guard let bpm, bpm > 0, duration > 0 else { return [] }
        let interval = 60 / bpm
        let anchor = onsets.first ?? 0
        var first = anchor
        while first - interval >= 0 { first -= interval }
        var beats: [TimeInterval] = []
        var position = first
        while position <= duration, beats.count < 2_048 {
            beats.append(position)
            position += interval
        }
        return beats
    }

    private nonisolated static func estimateKey(
        samples: [Float],
        sampleRate: Double
    ) -> (pitchClass: Int?, mode: MusicalMode?, confidence: Double?) {
        guard sampleRate > 0, samples.count >= Int(sampleRate) else {
            return (nil, nil, nil)
        }
        let stride = max(Int(sampleRate / 8_000), 1)
        let analysisRate = sampleRate / Double(stride)
        let frameLimit = min(samples.count, Int(sampleRate * 12))
        let reduced = Swift.stride(from: 0, to: frameLimit, by: stride).map { samples[$0] }
        guard !reduced.isEmpty else { return (nil, nil, nil) }

        var chroma = Array(repeating: 0.0, count: 12)
        for midi in 36...83 {
            let frequency = 440 * pow(2, Double(midi - 69) / 12)
            guard frequency < analysisRate / 2 else { continue }
            chroma[midi % 12] += goertzelPower(
                samples: reduced,
                sampleRate: analysisRate,
                frequency: frequency
            )
        }
        let chromaEnergy = chroma.reduce(0, +)
        guard chromaEnergy > 1e-9 else { return (nil, nil, nil) }
        chroma = chroma.map { $0 / chromaEnergy }

        let major = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
        let minor = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
        var scores: [(pitchClass: Int, mode: MusicalMode, score: Double)] = []
        for root in 0..<12 {
            scores.append((root, .major, profileScore(chroma: chroma, profile: major, root: root)))
            scores.append((root, .minor, profileScore(chroma: chroma, profile: minor, root: root)))
        }
        scores.sort { $0.score > $1.score }
        guard let best = scores.first else { return (nil, nil, nil) }
        let second = scores.dropFirst().first?.score ?? 0
        let confidence = min(max((best.score - second) / max(abs(best.score), 1e-9), 0), 1)
        return (best.pitchClass, best.mode, confidence)
    }

    private nonisolated static func goertzelPower(
        samples: [Float],
        sampleRate: Double,
        frequency: Double
    ) -> Double {
        let coefficient = 2 * cos(2 * Double.pi * frequency / sampleRate)
        var previous = 0.0
        var previousPrevious = 0.0
        for sample in samples {
            let value = Double(sample) + coefficient * previous - previousPrevious
            previousPrevious = previous
            previous = value
        }
        return max(previousPrevious * previousPrevious + previous * previous
            - coefficient * previous * previousPrevious, 0)
    }

    private nonisolated static func profileScore(
        chroma: [Double],
        profile: [Double],
        root: Int
    ) -> Double {
        zip(chroma.indices, chroma).reduce(0) { result, item in
            result + item.1 * profile[(item.0 - root + 12) % 12]
        }
    }

    private nonisolated static func estimateTempo(
        envelope: [Double],
        blockDuration: TimeInterval
    ) -> (bpm: Double?, confidence: Double) {
        guard envelope.count >= Int(4 / blockDuration) else { return (nil, 0) }
        let mean = envelope.reduce(0, +) / Double(envelope.count)
        let centered = envelope.map { $0 - mean }
        let minimumLag = max(Int(60 / maximumTempo / blockDuration), 1)
        let maximumLag = min(
            Int(60 / minimumTempo / blockDuration),
            centered.count / 2
        )
        guard minimumLag <= maximumLag else { return (nil, 0) }

        var bestLag = 0
        var bestCorrelation = 0.0
        for lag in minimumLag...maximumLag {
            var product = 0.0
            var lhsEnergy = 0.0
            var rhsEnergy = 0.0
            for index in lag..<centered.count {
                let lhs = centered[index]
                let rhs = centered[index - lag]
                product += lhs * rhs
                lhsEnergy += lhs * lhs
                rhsEnergy += rhs * rhs
            }
            let denominator = sqrt(lhsEnergy * rhsEnergy)
            let correlation = denominator > 0 ? product / denominator : 0
            if correlation > bestCorrelation {
                bestCorrelation = correlation
                bestLag = lag
            }
        }
        let confidence = min(max(bestCorrelation, 0), 1)
        guard bestLag > 0, confidence >= 0.12 else { return (nil, confidence) }
        return (60 / (Double(bestLag) * blockDuration), confidence)
    }

    private nonisolated static func silentAnalysis(for track: Track) -> AudioFeatureAnalysis {
        AudioFeatureAnalysis(
            trackID: track.id,
            contentFingerprint: track.sha256,
            averageLoudnessDBFS: -120,
            spectralCentroidHz: 0,
            estimatedTempoBPM: nil,
            tempoConfidence: 0
        )
    }
}

actor AudioFeatureCache {
    private struct Document: Codable {
        static let currentSchema = 1
        var schemaVersion = currentSchema
        var entries: [Track.ID: AudioFeatureAnalysis] = [:]
    }

    private let fileURL: URL
    private let fileManager: FileManager

    init(rootURL: URL, fileManager: FileManager = .default) {
        fileURL = rootURL.appendingPathComponent("audio-features-v1.json")
        self.fileManager = fileManager
    }

    func load(validTracks: [Track]) throws -> [Track.ID: AudioFeatureAnalysis] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [:] }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: fileURL))
        guard document.schemaVersion == Document.currentSchema else { return [:] }
        let tracksByID = Dictionary(uniqueKeysWithValues: validTracks.map { ($0.id, $0) })
        return document.entries.filter { id, analysis in
            tracksByID[id].map(analysis.isCurrent(for:)) ?? false
        }
    }

    func save(_ entries: [Track.ID: AudioFeatureAnalysis]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Document(entries: entries)).write(to: fileURL, options: [.atomic])
    }
}
