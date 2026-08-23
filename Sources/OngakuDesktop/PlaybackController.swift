@preconcurrency import AVFoundation
import Accelerate
import AppKit
import Combine
import Foundation

struct StereoLevels: Equatable, Sendable {
    var left: Double
    var right: Double

    static let silent = StereoLevels(left: 0, right: 0)
}

struct StereoSpectrum: Equatable, Sendable {
    static let bandCount = 48

    var left: [Double]
    var right: [Double]

    static let silent = StereoSpectrum(
        left: Array(repeating: 0, count: bandCount),
        right: Array(repeating: 0, count: bandCount)
    )
}

struct AudioVisualizationSnapshot: Equatable, Sendable {
    let levels: StereoLevels
    let spectrum: StereoSpectrum
}

enum PlaybackMode: String, CaseIterable, Identifiable, Sendable {
    case sequential
    case repeatOne
    case repeatAll
    case repeatAlbum
    case shuffle

    var id: String { rawValue }
    var localizationKey: String { "player.mode.\(rawValue)" }

    var systemImage: String {
        switch self {
        case .sequential: "arrow.right"
        case .repeatOne: "repeat.1"
        case .repeatAll: "repeat"
        case .repeatAlbum: "square.stack.3d.up"
        case .shuffle: "shuffle"
        }
    }
}

enum PlaybackQueueNavigator {
    nonisolated static func nextTrack(
        after current: Track,
        in queue: [Track],
        mode: PlaybackMode,
        randomIndex: (Int) -> Int = { Int.random(in: 0..<$0) }
    ) -> Track? {
        let queue = queue.filter {
            !$0.isExcludedFromPlayback || $0.id == current.id
        }
        switch mode {
        case .sequential:
            guard let index = queue.firstIndex(where: { $0.id == current.id }) else {
                return queue.first
            }
            let nextIndex = queue.index(after: index)
            return nextIndex < queue.endIndex ? queue[nextIndex] : nil

        case .repeatOne:
            return current

        case .repeatAll:
            guard !queue.isEmpty else { return nil }
            guard let index = queue.firstIndex(where: { $0.id == current.id }) else {
                return queue.first
            }
            let nextIndex = queue.index(after: index)
            return nextIndex < queue.endIndex ? queue[nextIndex] : queue.first

        case .repeatAlbum:
            let albumTracks = queue.filter {
                $0.albumID == current.albumID
            }
            guard !albumTracks.isEmpty else { return current }
            guard let index = albumTracks.firstIndex(where: { $0.id == current.id }) else {
                return albumTracks.first
            }
            let nextIndex = albumTracks.index(after: index)
            return nextIndex < albumTracks.endIndex ? albumTracks[nextIndex] : albumTracks.first

        case .shuffle:
            let candidates = queue.filter { $0.id != current.id }
            guard !candidates.isEmpty else { return queue.first ?? current }
            let index = min(max(randomIndex(candidates.count), 0), candidates.count - 1)
            return candidates[index]
        }
    }

    nonisolated static func previousTrack(
        before current: Track,
        in queue: [Track],
        mode: PlaybackMode,
        randomIndex: (Int) -> Int = { Int.random(in: 0..<$0) }
    ) -> Track? {
        let queue = queue.filter {
            !$0.isExcludedFromPlayback || $0.id == current.id
        }
        switch mode {
        case .sequential, .repeatOne:
            guard let index = queue.firstIndex(where: { $0.id == current.id }),
                  index > queue.startIndex else { return nil }
            return queue[queue.index(before: index)]

        case .repeatAll:
            guard !queue.isEmpty else { return nil }
            guard let index = queue.firstIndex(where: { $0.id == current.id }) else {
                return queue.last
            }
            return index > queue.startIndex ? queue[queue.index(before: index)] : queue.last

        case .repeatAlbum:
            let albumTracks = queue.filter { $0.albumID == current.albumID }
            guard !albumTracks.isEmpty else { return current }
            guard let index = albumTracks.firstIndex(where: { $0.id == current.id }) else {
                return albumTracks.last
            }
            return index > albumTracks.startIndex
                ? albumTracks[albumTracks.index(before: index)] : albumTracks.last

        case .shuffle:
            let candidates = queue.filter { $0.id != current.id }
            guard !candidates.isEmpty else { return queue.first ?? current }
            let index = min(max(randomIndex(candidates.count), 0), candidates.count - 1)
            return candidates[index]
        }
    }
}

struct PlaybackSessionTracker: Sendable {
    private(set) var sessionID: UUID?

    mutating func begin(
        trackID: Track.ID,
        position: TimeInterval,
        occurredAt: Date = .now
    ) -> PlaybackEvent? {
        guard sessionID == nil else { return nil }
        let id = UUID()
        sessionID = id
        return PlaybackEvent(
            trackID: trackID,
            kind: .started,
            occurredAt: occurredAt,
            position: position,
            playbackSessionID: id
        )
    }

    mutating func finish(
        trackID: Track.ID,
        kind: PlaybackEvent.Kind,
        position: TimeInterval,
        occurredAt: Date = .now
    ) -> PlaybackEvent? {
        guard let id = sessionID else { return nil }
        sessionID = nil
        return PlaybackEvent(
            trackID: trackID,
            kind: kind,
            occurredAt: occurredAt,
            position: position,
            playbackSessionID: id
        )
    }
}

enum StereoLevelMath {
    private static let floorDecibels = -60.0

    nonisolated static func normalizedRMS(_ samples: [Float]) -> Double {
        samples.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return 0 }
            return normalizedRMS(baseAddress, count: buffer.count, stride: 1)
        }
    }

    nonisolated static func normalizedRMS(
        _ samples: UnsafePointer<Float>,
        count: Int,
        stride: Int
    ) -> Double {
        guard count > 0 else { return 0 }
        var squareSum = 0.0
        var index = 0
        for _ in 0..<count {
            let sample = Double(samples[index])
            squareSum += sample * sample
            index += stride
        }
        let rms = sqrt(squareSum / Double(count))
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(max((decibels - floorDecibels) / -floorDecibels, 0), 1)
    }

    nonisolated static func measure(_ buffer: AVAudioPCMBuffer) -> StereoLevels {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, let channels = buffer.floatChannelData else { return .silent }

        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else { return .silent }
        if buffer.format.isInterleaved {
            let left = normalizedRMS(channels[0], count: frameCount, stride: channelCount)
            let right = channelCount > 1
                ? normalizedRMS(channels[0] + 1, count: frameCount, stride: channelCount)
                : left
            return StereoLevels(left: left, right: right)
        }

        let left = normalizedRMS(channels[0], count: frameCount, stride: 1)
        let right = channelCount > 1
            ? normalizedRMS(channels[1], count: frameCount, stride: 1)
            : left
        return StereoLevels(left: left, right: right)
    }
}

enum SpectrumMath {
    private static let floorDecibels = -72.0

    nonisolated static func normalizedBands(
        samples: [Float],
        sampleRate: Double,
        bandCount: Int = StereoSpectrum.bandCount
    ) -> [Double] {
        guard samples.count >= 64, sampleRate > 0, bandCount > 0 else {
            return Array(repeating: 0, count: max(bandCount, 0))
        }
        let transformSize = 1 << Int(floor(log2(Double(min(samples.count, 4_096)))))
        let halfSize = transformSize / 2
        let log2Size = vDSP_Length(log2(Double(transformSize)))
        guard let setup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2)) else {
            return Array(repeating: 0, count: bandCount)
        }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: transformSize)
        var windowed = [Float](repeating: 0, count: transformSize)
        var real = [Float](repeating: 0, count: halfSize)
        var imaginary = [Float](repeating: 0, count: halfSize)
        var magnitudes = [Float](repeating: 0, count: halfSize)
        let input = Array(samples.suffix(transformSize))
        vDSP_hann_window(&window, vDSP_Length(transformSize), Int32(vDSP_HANN_NORM))
        vDSP_vmul(input, 1, window, 1, &windowed, 1, vDSP_Length(transformSize))

        windowed.withUnsafeBufferPointer { inputPointer in
            real.withUnsafeMutableBufferPointer { realPointer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                    guard let inputBase = inputPointer.baseAddress,
                          let realBase = realPointer.baseAddress,
                          let imaginaryBase = imaginaryPointer.baseAddress else { return }
                    inputBase.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) {
                        complexPointer in
                        var split = DSPSplitComplex(
                            realp: realBase,
                            imagp: imaginaryBase
                        )
                        vDSP_ctoz(
                            complexPointer,
                            2,
                            &split,
                            1,
                            vDSP_Length(halfSize)
                        )
                        vDSP_fft_zrip(
                            setup,
                            &split,
                            1,
                            log2Size,
                            FFTDirection(kFFTDirection_Forward)
                        )
                        vDSP_zvmags(
                            &split,
                            1,
                            &magnitudes,
                            1,
                            vDSP_Length(halfSize)
                        )
                    }
                }
            }
        }

        let lowestFrequency = 50.0
        let highestFrequency = min(18_000, sampleRate * 0.46)
        guard highestFrequency > lowestFrequency else {
            return Array(repeating: 0, count: bandCount)
        }
        let frequencyRatio = bandCount > 1
            ? pow(highestFrequency / lowestFrequency, 1 / Double(bandCount - 1))
            : 1
        let frequencyResolution = sampleRate / Double(transformSize)
        let scale = 2 / Double(transformSize)

        return (0..<bandCount).map { band in
            let center = lowestFrequency * pow(frequencyRatio, Double(band))
            let edgeRatio = sqrt(frequencyRatio)
            let lowerIndex = max(Int(floor(center / edgeRatio / frequencyResolution)), 1)
            let upperIndex = min(
                Int(ceil(center * edgeRatio / frequencyResolution)),
                halfSize - 1
            )
            let peakPower = lowerIndex <= upperIndex
                ? magnitudes[lowerIndex...upperIndex].max() ?? 0
                : 0
            let magnitude = max(sqrt(Double(peakPower)) * scale, 0.000_000_1)
            let decibels = 20 * log10(magnitude)
            return min(max((decibels - floorDecibels) / -floorDecibels, 0), 1)
        }
    }

    nonisolated static func measure(_ buffer: AVAudioPCMBuffer) -> StereoSpectrum {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 1, channelCount > 0,
              let channels = buffer.floatChannelData else { return .silent }

        let left = samples(
            channels: channels,
            frameCount: frameCount,
            channelCount: channelCount,
            channel: 0,
            isInterleaved: buffer.format.isInterleaved
        )
        let right = channelCount > 1
            ? samples(
                channels: channels,
                frameCount: frameCount,
                channelCount: channelCount,
                channel: 1,
                isInterleaved: buffer.format.isInterleaved
            )
            : left
        return StereoSpectrum(
            left: normalizedBands(samples: left, sampleRate: buffer.format.sampleRate),
            right: normalizedBands(samples: right, sampleRate: buffer.format.sampleRate)
        )
    }

    nonisolated static func smoothed(
        current: [Double],
        target: [Double]
    ) -> [Double] {
        target.enumerated().map { index, value in
            let existing = current.indices.contains(index) ? current[index] : 0
            let response = value > existing ? 0.72 : 0.20
            return existing + ((value - existing) * response)
        }
    }

    private nonisolated static func samples(
        channels: UnsafePointer<UnsafeMutablePointer<Float>>,
        frameCount: Int,
        channelCount: Int,
        channel: Int,
        isInterleaved: Bool
    ) -> [Float] {
        if isInterleaved {
            return (0..<frameCount).map { channels[0][$0 * channelCount + channel] }
        }
        return Array(UnsafeBufferPointer(start: channels[channel], count: frameCount))
    }
}

final class StereoMeterThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastEmission: TimeInterval = 0

    func shouldEmit(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard now - lastEmission >= 1.0 / 30.0 else { return false }
        lastEmission = now
        return true
    }
}

struct PlaybackRecoveryRequest: Equatable, Sendable {
    let position: TimeInterval
    let shouldResume: Bool
}

struct PlaybackRecoveryState: Equatable, Sendable {
    private(set) var isSleeping = false
    private var positionBeforeSleep: TimeInterval = 0
    private var wasPlayingBeforeSleep = false

    mutating func prepareForSleep(position: TimeInterval, isPlaying: Bool) {
        isSleeping = true
        positionBeforeSleep = max(position, 0)
        wasPlayingBeforeSleep = isPlaying
    }

    mutating func requestAfterWake() -> PlaybackRecoveryRequest? {
        guard isSleeping else { return nil }
        isSleeping = false
        defer {
            positionBeforeSleep = 0
            wasPlayingBeforeSleep = false
        }
        return PlaybackRecoveryRequest(
            position: positionBeforeSleep,
            shouldResume: wasPlayingBeforeSleep
        )
    }
}

struct GaplessAudioFormat: Equatable, Sendable {
    let sampleRate: Double
    let channelCount: UInt32
    let commonFormat: UInt
    let isInterleaved: Bool

    init(_ format: AVAudioFormat) {
        sampleRate = format.sampleRate
        channelCount = format.channelCount
        commonFormat = UInt(format.commonFormat.rawValue)
        isInterleaved = format.isInterleaved
    }

    init(
        sampleRate: Double,
        channelCount: UInt32,
        commonFormat: UInt,
        isInterleaved: Bool
    ) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.commonFormat = commonFormat
        self.isInterleaved = isInterleaved
    }

    func canSharePlayerNode(with other: Self) -> Bool {
        abs(sampleRate - other.sampleRate) < 0.5
            && channelCount == other.channelCount
            && commonFormat == other.commonFormat
            && isInterleaved == other.isInterleaved
    }
}

enum GaplessPrerollPolicy {
    static let leadTime: TimeInterval = 5

    static func shouldPrepare(
        remaining: TimeInterval,
        alreadyPrepared: Bool,
        leadTime: TimeInterval = leadTime
    ) -> Bool {
        !alreadyPrepared && remaining > 0 && remaining <= leadTime
    }
}

enum CrossfadePolicy {
    static let maximumDuration: TimeInterval = 12

    static func effectiveDuration(
        requestedDuration: TimeInterval,
        currentRemaining: TimeInterval,
        nextDuration: TimeInterval,
        isSameAlbum: Bool,
        disablesWithinAlbum: Bool,
        formatsAreCompatible: Bool
    ) -> TimeInterval {
        guard formatsAreCompatible,
              requestedDuration > 0,
              !(disablesWithinAlbum && isSameAlbum) else {
            return 0
        }
        return min(
            max(requestedDuration, 0),
            maximumDuration,
            max(currentRemaining - 0.05, 0),
            max(nextDuration - 0.05, 0)
        )
    }

    static func gains(progress: Double) -> (outgoing: Float, incoming: Float) {
        let clamped = min(max(progress, 0), 1)
        return (
            outgoing: Float(cos(clamped * .pi / 2)),
            incoming: Float(sin(clamped * .pi / 2))
        )
    }
}

struct AudioSilenceAnalysis: Equatable, Sendable {
    let leadingSilence: TimeInterval
    let trailingSilence: TimeInterval

    static let none = AudioSilenceAnalysis(leadingSilence: 0, trailingSilence: 0)
}

enum SilenceAnalysisPolicy {
    static let maximumScanDuration: TimeInterval = 12
    static let blockDuration: TimeInterval = 0.01
    static let thresholdAmplitude = pow(10.0, -50.0 / 20.0)
    static let safetyPadding: TimeInterval = 0.02

    nonisolated static func silenceDuration(
        rmsBlocks: [Double],
        scannedDuration: TimeInterval,
        direction: ScanDirection
    ) -> TimeInterval {
        guard scannedDuration > 0, !rmsBlocks.isEmpty else { return 0 }
        let silentBlockCount: Int
        switch direction {
        case .leading:
            silentBlockCount = rmsBlocks.firstIndex(where: { $0 > thresholdAmplitude })
                ?? rmsBlocks.count
        case .trailing:
            if let lastAudible = rmsBlocks.lastIndex(where: { $0 > thresholdAmplitude }) {
                silentBlockCount = rmsBlocks.count - lastAudible - 1
            } else {
                silentBlockCount = rmsBlocks.count
            }
        }
        let detected = min(Double(silentBlockCount) * blockDuration, scannedDuration)
        return max(detected - safetyPadding, 0)
    }

    enum ScanDirection: Sendable {
        case leading
        case trailing
    }
}

enum AudioSilenceAnalyzer {
    nonisolated static func analyze(url: URL) throws -> AudioSilenceAnalysis {
        let file = try AVAudioFile(forReading: url)
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0, file.length > 0 else { return .none }

        let maximumFrames = AVAudioFramePosition(
            SilenceAnalysisPolicy.maximumScanDuration * sampleRate
        )
        let scanFrames = min(file.length, maximumFrames)
        let blockFrames = max(
            AVAudioFrameCount(SilenceAnalysisPolicy.blockDuration * sampleRate),
            1
        )

        let leadingBlocks = try rmsBlocks(
            file: file,
            startFrame: 0,
            frameCount: scanFrames,
            blockFrames: blockFrames
        )
        let trailingBlocks = try rmsBlocks(
            file: file,
            startFrame: max(file.length - scanFrames, 0),
            frameCount: scanFrames,
            blockFrames: blockFrames
        )
        let scannedDuration = Double(scanFrames) / sampleRate
        return AudioSilenceAnalysis(
            leadingSilence: SilenceAnalysisPolicy.silenceDuration(
                rmsBlocks: leadingBlocks,
                scannedDuration: scannedDuration,
                direction: .leading
            ),
            trailingSilence: SilenceAnalysisPolicy.silenceDuration(
                rmsBlocks: trailingBlocks,
                scannedDuration: scannedDuration,
                direction: .trailing
            )
        )
    }

    private nonisolated static func rmsBlocks(
        file: AVAudioFile,
        startFrame: AVAudioFramePosition,
        frameCount: AVAudioFramePosition,
        blockFrames: AVAudioFrameCount
    ) throws -> [Double] {
        file.framePosition = startFrame
        var remaining = frameCount
        var blocks: [Double] = []
        var squareSum = 0.0
        var samplesInBlock = 0
        let channelCount = Int(file.processingFormat.channelCount)
        let chunkCapacity: AVAudioFrameCount = 8_192

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
                if buffer.format.isInterleaved {
                    for channel in 0..<channelCount {
                        let sample = Double(channels[0][frame * channelCount + channel])
                        squareSum += sample * sample
                        samplesInBlock += 1
                    }
                } else {
                    for channel in 0..<channelCount {
                        let sample = Double(channels[channel][frame])
                        squareSum += sample * sample
                        samplesInBlock += 1
                    }
                }

                if samplesInBlock >= Int(blockFrames) * channelCount {
                    blocks.append(sqrt(squareSum / Double(samplesInBlock)))
                    squareSum = 0
                    samplesInBlock = 0
                }
            }
            remaining -= AVAudioFramePosition(framesRead)
        }

        if samplesInBlock > 0 {
            blocks.append(sqrt(squareSum / Double(samplesInBlock)))
        }
        return blocks
    }
}

// AVAudioEngine invokes tap blocks on its realtime messenger queue. Creating this
// block outside PlaybackController prevents it from inheriting MainActor isolation.
func makeStereoMeterTapBlock(
    throttle: StereoMeterThrottle,
    deliver: @escaping @Sendable (AudioVisualizationSnapshot) -> Void
) -> AVAudioNodeTapBlock {
    { buffer, _ in
        guard throttle.shouldEmit() else { return }
        deliver(AudioVisualizationSnapshot(
            levels: StereoLevelMath.measure(buffer),
            spectrum: SpectrumMath.measure(buffer)
        ))
    }
}

@MainActor
final class PlaybackController: ObservableObject {
    private static let automaticUpsamplingKey = "audio.automaticUpsampling"
    private static let effectSettingsKey = "audio.effectSettings.v1"
    private static let effectsBypassedKey = "audio.effectsBypassed"
    private static let playbackModeKey = "audio.playbackMode.v1"
    private static let crossfadeDurationKey = "audio.crossfadeDuration.v1"
    private static let disableCrossfadeWithinAlbumKey = "audio.disableCrossfadeWithinAlbum.v1"

    @Published private(set) var currentTrack: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var volume: Double = 0.8 {
        didSet { sourceMixerNode.outputVolume = Float(volume) }
    }
    @Published private(set) var errorMessage: String?
    @Published private(set) var sourceSampleRate: Double = 0
    @Published private(set) var outputSampleRate: Double = 0
    @Published private(set) var stereoLevels = StereoLevels.silent
    @Published private(set) var stereoSpectrum = StereoSpectrum.silent
    @Published private(set) var queueState = PlaybackQueueState()
    @Published private(set) var effectSettings: [RealtimeAudioEffectSetting]
    @Published private(set) var effectsBypassed: Bool
    @Published var playbackMode: PlaybackMode {
        didSet { UserDefaults.standard.set(playbackMode.rawValue, forKey: Self.playbackModeKey) }
    }
    @Published var automaticUpsampling: Bool {
        didSet {
            UserDefaults.standard.set(automaticUpsampling, forKey: Self.automaticUpsamplingKey)
        }
    }
    @Published var crossfadeDuration: Double {
        didSet {
            let clamped = min(max(crossfadeDuration, 0), CrossfadePolicy.maximumDuration)
            if crossfadeDuration != clamped {
                crossfadeDuration = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: Self.crossfadeDurationKey)
        }
    }
    @Published var disableCrossfadeWithinAlbum: Bool {
        didSet {
            UserDefaults.standard.set(
                disableCrossfadeWithinAlbum,
                forKey: Self.disableCrossfadeWithinAlbumKey
            )
        }
    }

    let playbackEventPublisher = PassthroughSubject<PlaybackEvent, Never>()

    private let engine = AVAudioEngine()
    private let primaryPlayerNode = AVAudioPlayerNode()
    private let secondaryPlayerNode = AVAudioPlayerNode()
    private let sourceMixerNode = AVAudioMixerNode()
    private var activePlayerIndex = 0
    private var playerNode: AVAudioPlayerNode {
        activePlayerIndex == 0 ? primaryPlayerNode : secondaryPlayerNode
    }
    private var standbyPlayerNode: AVAudioPlayerNode {
        activePlayerIndex == 0 ? secondaryPlayerNode : primaryPlayerNode
    }
    private let effectPipeline: [AudioEffectNode]
    private let outputManager = AudioOutputManager()
    private var audioFile: AVAudioFile?
    private var scheduledStartFrame: AVAudioFramePosition = 0
    private var playbackGeneration = UUID()
    private var playbackQueue: [Track] = []
    private var queueUndoStack: [[Track]] = []
    private var lastPublishedPositionBucket = -1
    private var playbackSession = PlaybackSessionTracker()
    private var timer: Timer?
    private var crossfadeTimer: Timer?
    private var isMeterTapInstalled = false
    private let meterThrottle = StereoMeterThrottle()
    private var recoveryObservations = Set<AnyCancellable>()
    private var recoveryTask: Task<Void, Never>?
    private var recoveryState = PlaybackRecoveryState()
    private var suppressConfigurationRecoveryUntil: TimeInterval = 0
    private var activeTrackNodeStartSampleTime: AVAudioFramePosition = 0
    private var prerolledTrack: PrerolledTrack?
    private var silenceAnalyses: [URL: AudioSilenceAnalysis] = [:]
    private var silenceAnalysisTasks: [URL: Task<Void, Never>] = [:]
    private var externalPlaybackStopHandler: (() -> Void)?

    private struct PrerolledTrack {
        let track: Track
        let file: AVAudioFile
        let generation: UUID
        let nodeStartSampleTime: AVAudioFramePosition
        let playbackNode: AVAudioPlayerNode
        let crossfadeDuration: TimeInterval
        let crossfadeStartHostTime: UInt64?
        let scheduledStartFrame: AVAudioFramePosition
        let outgoingTransitionPosition: TimeInterval
    }

    init() {
        let defaultSettings = AudioEffectModuleRegistry.makeDefaultSettings()
        effectPipeline = AudioEffectModuleRegistry.makePipeline()
        effectSettings = Self.loadEffectSettings(defaults: defaultSettings)
        effectsBypassed = UserDefaults.standard.bool(forKey: Self.effectsBypassedKey)
        playbackMode = UserDefaults.standard.string(forKey: Self.playbackModeKey)
            .flatMap(PlaybackMode.init(rawValue:)) ?? .sequential
        automaticUpsampling = UserDefaults.standard.object(forKey: Self.automaticUpsamplingKey) as? Bool ?? true
        crossfadeDuration = min(
            max(UserDefaults.standard.double(forKey: Self.crossfadeDurationKey), 0),
            CrossfadePolicy.maximumDuration
        )
        disableCrossfadeWithinAlbum = UserDefaults.standard.object(
            forKey: Self.disableCrossfadeWithinAlbumKey
        ) as? Bool ?? true
        engine.attach(primaryPlayerNode)
        engine.attach(secondaryPlayerNode)
        engine.attach(sourceMixerNode)
        effectPipeline.forEach { $0.attach(to: engine) }
        effectSettings.forEach(applyEffectSetting)
        primaryPlayerNode.volume = 1
        secondaryPlayerNode.volume = 1
        sourceMixerNode.outputVolume = Float(volume)
        observeSystemAudioEvents()
    }

    var duration: TimeInterval {
        guard let audioFile else { return currentTrack?.duration ?? 0 }
        return Double(audioFile.length) / audioFile.processingFormat.sampleRate
    }

    var isUpsampling: Bool { outputSampleRate > sourceSampleRate + 1 }

    var enabledEffectCount: Int {
        effectsBypassed ? 0 : effectSettings.count(where: \.isEnabled)
    }

    func setExternalPlaybackStopHandler(_ handler: @escaping () -> Void) {
        externalPlaybackStopHandler = handler
    }

    func pauseForExternalPlayback() {
        guard isPlaying else { return }
        elapsed = currentElapsed()
        stopPlayerNodes()
        if let audioFile {
            let frame = min(
                AVAudioFramePosition(elapsed * audioFile.processingFormat.sampleRate),
                audioFile.length
            )
            schedule(fromFrame: frame)
        }
        isPlaying = false
        clearAudioVisualization()
        stopTimer()
        publishQueueState(force: true)
    }

    var queuedTracks: [Track] { playbackQueue }
    var canUndoQueueEdit: Bool { !queueUndoStack.isEmpty }

    func setEffectsBypassed(_ bypassed: Bool) {
        guard effectsBypassed != bypassed else { return }
        effectsBypassed = bypassed
        UserDefaults.standard.set(bypassed, forKey: Self.effectsBypassedKey)
        effectSettings.forEach(applyEffectSetting)
    }

    func effectSetting(for kind: RealtimeAudioEffectKind) -> RealtimeAudioEffectSetting {
        effectSettings.first(where: { $0.kind == kind }) ?? RealtimeAudioEffectSetting(kind: kind)
    }

    func setEffectEnabled(_ isEnabled: Bool, for kind: RealtimeAudioEffectKind) {
        updateEffect(kind) { $0.isEnabled = isEnabled }
    }

    func setEffectParameter(_ value: Double, key: String, for kind: RealtimeAudioEffectKind) {
        updateEffect(kind) { setting in
            guard let definition = kind.parameterDefinitions.first(where: { $0.key == key }) else { return }
            setting.parameters[key] = min(max(value, definition.range.lowerBound), definition.range.upperBound)
        }
    }

    func resetEffect(_ kind: RealtimeAudioEffectKind) {
        guard let index = effectSettings.firstIndex(where: { $0.kind == kind }) else { return }
        let wasEnabled = effectSettings[index].isEnabled
        effectSettings[index] = RealtimeAudioEffectSetting(kind: kind, isEnabled: wasEnabled)
        applyEffectSetting(effectSettings[index])
        persistEffectSettings()
    }

    var signalPathDescription: String? {
        guard sourceSampleRate > 0, outputSampleRate > 0 else { return nil }
        if isUpsampling {
            return L10n.format(
                "player.upsamplingFormat",
                Self.sampleRateString(sourceSampleRate),
                Self.sampleRateString(outputSampleRate)
            )
        }
        return L10n.format("player.outputFormat", Self.sampleRateString(outputSampleRate))
    }

    func play(_ track: Track) {
        externalPlaybackStopHandler?()
        finishPlaybackSession(kind: .skipped)
        if !playbackQueue.contains(where: { $0.id == track.id }) {
            playbackQueue.append(track)
        }
        load(track, position: 0, autoplay: true)
    }

    func restorePlaybackQueue(_ savedState: PlaybackQueueState?, tracks: [Track]) {
        finishPlaybackSession(kind: .skipped)
        let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        let requestedIDs = savedState?.trackIDs ?? tracks.map(\.id)
        var seen = Set<Track.ID>()
        playbackQueue = requestedIDs.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return tracksByID[id]
        }
        queueUndoStack.removeAll()

        guard let currentID = savedState?.currentTrackID,
              let current = tracksByID[currentID] else {
            clearCurrentTrack()
            publishQueueState(force: true)
            return
        }
        if !playbackQueue.contains(where: { $0.id == currentID }) {
            playbackQueue.append(current)
        }
        load(current, position: savedState?.position ?? 0, autoplay: false)
    }

    func reconcilePlaybackQueue(with tracks: [Track]) {
        let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        playbackQueue = playbackQueue.compactMap { tracksByID[$0.id] }
        if !queueState.trackIDs.isEmpty || currentTrack != nil {
            let queuedIDs = Set(playbackQueue.map(\.id))
            playbackQueue.append(contentsOf: tracks.filter { !queuedIDs.contains($0.id) })
        }
        if let currentID = currentTrack?.id {
            if let updated = tracksByID[currentID] {
                currentTrack = updated
            } else {
                finishPlaybackSession(kind: .skipped)
                stopCurrentPlayback()
                currentTrack = nil
            }
        }
        publishQueueState(force: true)
    }

    func enqueueNext(_ tracks: [Track]) {
        editQueue { queue in
            let incomingIDs = Set(tracks.map(\.id))
            queue.removeAll { incomingIDs.contains($0.id) && $0.id != currentTrack?.id }
            let insertionIndex = currentTrack.flatMap { current in
                queue.firstIndex(where: { $0.id == current.id }).map { $0 + 1 }
            } ?? 0
            queue.insert(contentsOf: tracks.filter { $0.id != currentTrack?.id }, at: insertionIndex)
        }
    }

    func appendToQueue(_ tracks: [Track]) {
        editQueue { queue in
            let incomingIDs = Set(tracks.map(\.id))
            queue.removeAll { incomingIDs.contains($0.id) && $0.id != currentTrack?.id }
            queue.append(contentsOf: tracks.filter { $0.id != currentTrack?.id })
        }
    }

    func removeFromQueue(_ track: Track) {
        guard track.id != currentTrack?.id else { return }
        editQueue { $0.removeAll { $0.id == track.id } }
    }

    func moveInQueue(_ track: Track, offset: Int) {
        editQueue { queue in
            guard let source = queue.firstIndex(where: { $0.id == track.id }) else { return }
            let destination = min(max(source + offset, 0), queue.count - 1)
            guard source != destination else { return }
            let moved = queue.remove(at: source)
            queue.insert(moved, at: destination)
        }
    }

    func moveInQueue(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard !offsets.isEmpty else { return }
        editQueue { queue in
            let validOffsets = offsets.filter { queue.indices.contains($0) }
            guard !validOffsets.isEmpty else { return }
            let moving = validOffsets.map { queue[$0] }
            for index in validOffsets.sorted(by: >) {
                queue.remove(at: index)
            }
            let removedBeforeDestination = validOffsets.count(where: { $0 < destination })
            let insertionIndex = min(
                max(destination - removedBeforeDestination, 0),
                queue.count
            )
            queue.insert(contentsOf: moving, at: insertionIndex)
        }
    }

    func clearUpcomingQueue() {
        editQueue { queue in
            if let currentTrack {
                queue = [currentTrack]
            } else {
                queue.removeAll()
            }
        }
    }

    func undoLastQueueEdit() {
        guard let previous = queueUndoStack.popLast() else { return }
        playbackQueue = previous
        publishQueueState(force: true)
    }

    private func load(_ track: Track, position: TimeInterval, autoplay: Bool) {
        do {
            stopCurrentPlayback()
            let file = try AVAudioFile(forReading: track.fileURL)
            suppressConfigurationRecovery()
            let sourceRate = file.processingFormat.sampleRate
            let configuration = automaticUpsampling
                ? outputManager.configureDefaultOutput(sourceRate: sourceRate)
                : nil

            audioFile = file
            sourceSampleRate = sourceRate
            outputSampleRate = configuration?.actualRate ?? sourceRate
            currentTrack = track
            primeTransitionAnalyses(startingWith: track)
            let fileDuration = Double(file.length) / file.processingFormat.sampleRate
            elapsed = min(max(position, 0), max(fileDuration - 0.01, 0))

            try configureEngine(for: file)
            let frame = AVAudioFramePosition(elapsed * file.processingFormat.sampleRate)
            schedule(fromFrame: min(frame, file.length))
            if autoplay {
                try engine.start()
                playerNode.play()
                isPlaying = true
                startTimer()
                beginPlaybackSessionIfNeeded()
                prepareNextTrackIfNeeded()
            }
            errorMessage = nil
            publishQueueState(force: true)
        } catch {
            stopCurrentPlayback()
            currentTrack = track
            isPlaying = false
            errorMessage = error.localizedDescription
            publishQueueState(force: true)
        }
    }

    func updatePlaybackQueue(_ tracks: [Track]) {
        var seen = Set<Track.ID>()
        playbackQueue = tracks.filter { seen.insert($0.id).inserted }
        if let currentID = currentTrack?.id,
           let updatedCurrent = playbackQueue.first(where: { $0.id == currentID }) {
            currentTrack = updatedCurrent
            primeTransitionAnalyses(startingWith: updatedCurrent)
        }
        publishQueueState(force: true)
    }

    func togglePlayback() {
        guard audioFile != nil else { return }
        if isPlaying {
            elapsed = currentElapsed()
            stopPlayerNodes()
            if let audioFile {
                let frame = min(
                    AVAudioFramePosition(elapsed * audioFile.processingFormat.sampleRate),
                    audioFile.length
                )
                schedule(fromFrame: frame)
            }
            isPlaying = false
            clearAudioVisualization()
            stopTimer()
            publishQueueState(force: true)
        } else {
            do {
                externalPlaybackStopHandler?()
                if elapsed >= duration - 0.01 {
                    stopPlayerNodes()
                    schedule(fromFrame: 0)
                    elapsed = 0
                }
                if !engine.isRunning { try engine.start() }
                playerNode.play()
                isPlaying = true
                errorMessage = nil
                startTimer()
                beginPlaybackSessionIfNeeded()
                prepareNextTrackIfNeeded()
                publishQueueState(force: true)
            } catch {
                isPlaying = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func playPrevious() {
        guard let currentTrack else { return }
        if elapsed > 3 {
            seek(to: 0)
            return
        }
        guard let previous = PlaybackQueueNavigator.previousTrack(
            before: currentTrack,
            in: playbackQueue,
            mode: playbackMode
        ) else {
            seek(to: 0)
            return
        }
        play(previous)
    }

    func playNext() {
        guard let currentTrack else { return }
        let navigationMode: PlaybackMode = playbackMode == .repeatOne ? .sequential : playbackMode
        guard let next = PlaybackQueueNavigator.nextTrack(
            after: currentTrack,
            in: playbackQueue,
            mode: navigationMode
        ) else { return }
        play(next)
    }

    func clearCurrentTrack() {
        finishPlaybackSession(kind: .skipped)
        stopCurrentPlayback()
        currentTrack = nil
        errorMessage = nil
        publishQueueState(force: true)
    }

    func seek(to value: TimeInterval) {
        guard let audioFile else { return }
        let shouldResume = isPlaying
        let clamped = min(max(0, value), duration)
        let frame = min(
            AVAudioFramePosition(clamped * audioFile.processingFormat.sampleRate),
            audioFile.length
        )

        stopPlayerNodes()
        clearAudioVisualization()
        if frame >= audioFile.length {
            playbackGeneration = UUID()
            elapsed = duration
            isPlaying = false
            stopTimer()
            publishQueueState(force: true)
            return
        }
        schedule(fromFrame: frame)
        elapsed = clamped
        if shouldResume {
            do {
                if !engine.isRunning { try engine.start() }
                playerNode.play()
                startTimer()
                prepareNextTrackIfNeeded()
            } catch {
                isPlaying = false
                errorMessage = error.localizedDescription
            }
        }
        publishQueueState(force: true)
    }

    private func configureEngine(for file: AVAudioFile) throws {
        engine.stop()
        removeMeterTapIfNeeded()
        engine.disconnectNodeOutput(primaryPlayerNode)
        engine.disconnectNodeOutput(secondaryPlayerNode)
        engine.disconnectNodeOutput(sourceMixerNode)
        for effect in effectPipeline {
            effect.nodes.forEach { engine.disconnectNodeOutput($0) }
        }
        engine.disconnectNodeOutput(engine.mainMixerNode)

        // Both player nodes share a source mixer so compatible tracks can overlap
        // without rebuilding the DSP graph at the song boundary.
        engine.connect(
            primaryPlayerNode,
            to: sourceMixerNode,
            fromBus: 0,
            toBus: 0,
            format: file.processingFormat
        )
        engine.connect(
            secondaryPlayerNode,
            to: sourceMixerNode,
            fromBus: 0,
            toBus: 1,
            format: file.processingFormat
        )
        var upstream: AVAudioNode = sourceMixerNode
        for effect in effectPipeline {
            engine.connect(upstream, to: effect.inputNode, format: file.processingFormat)
            effect.connectInternalNodes(engine: engine, format: file.processingFormat)
            upstream = effect.outputNode
        }
        engine.connect(upstream, to: engine.mainMixerNode, format: file.processingFormat)
        let hardwareFormat = engine.outputNode.inputFormat(forBus: 0)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: hardwareFormat)
        outputSampleRate = hardwareFormat.sampleRate
        installMeterTap()
        engine.prepare()
    }

    private func observeSystemAudioEvents() {
        NotificationCenter.default.publisher(
            for: .AVAudioEngineConfigurationChange,
            object: engine
        )
        .sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleAudioEngineRecovery()
            }
        }
        .store(in: &recoveryObservations)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.prepareForSystemSleep()
                }
            }
            .store(in: &recoveryObservations)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.recoverAfterSystemWake()
                }
            }
            .store(in: &recoveryObservations)
    }

    private func prepareForSystemSleep() {
        recoveryTask?.cancel()
        recoveryTask = nil
        let position = isPlaying ? currentElapsed() : elapsed
        recoveryState.prepareForSleep(position: position, isPlaying: isPlaying)
        elapsed = position
        stopPlayerNodes()
        isPlaying = false
        clearAudioVisualization()
        stopTimer()
        publishQueueState(force: true)
    }

    private func recoverAfterSystemWake() {
        guard let request = recoveryState.requestAfterWake() else { return }
        recoverAudioEngine(
            position: request.position,
            shouldResume: request.shouldResume
        )
    }

    private func scheduleAudioEngineRecovery() {
        guard !recoveryState.isSleeping,
              audioFile != nil,
              ProcessInfo.processInfo.systemUptime >= suppressConfigurationRecoveryUntil else {
            return
        }
        let request = PlaybackRecoveryRequest(
            position: isPlaying ? currentElapsed() : elapsed,
            shouldResume: isPlaying
        )
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.recoverAudioEngine(
                position: request.position,
                shouldResume: request.shouldResume
            )
        }
    }

    private func recoverAudioEngine(position: TimeInterval, shouldResume: Bool) {
        guard let audioFile else { return }
        do {
            suppressConfigurationRecovery()
            stopPlayerNodes()
            engine.stop()
            stopTimer()
            isPlaying = false
            clearAudioVisualization()

            let sourceRate = audioFile.processingFormat.sampleRate
            let configuration = automaticUpsampling
                ? outputManager.configureDefaultOutput(sourceRate: sourceRate)
                : nil
            sourceSampleRate = sourceRate
            outputSampleRate = configuration?.actualRate ?? sourceRate

            try configureEngine(for: audioFile)
            let fileDuration = Double(audioFile.length) / sourceRate
            elapsed = min(max(position, 0), max(fileDuration - 0.01, 0))
            let frame = AVAudioFramePosition(elapsed * sourceRate)
            schedule(fromFrame: min(frame, audioFile.length))

            if shouldResume {
                try engine.start()
                playerNode.play()
                isPlaying = true
                startTimer()
                beginPlaybackSessionIfNeeded()
                prepareNextTrackIfNeeded()
            }
            errorMessage = nil
            publishQueueState(force: true)
        } catch {
            isPlaying = false
            stopTimer()
            errorMessage = error.localizedDescription
            publishQueueState(force: true)
        }
    }

    private func suppressConfigurationRecovery() {
        suppressConfigurationRecoveryUntil = ProcessInfo.processInfo.systemUptime + 1
    }

    private func installMeterTap() {
        let deliver: @Sendable (AudioVisualizationSnapshot) -> Void = { [weak self] snapshot in
            Task { @MainActor [weak self] in
                self?.applyAudioVisualization(snapshot)
            }
        }
        let tapBlock = makeStereoMeterTapBlock(throttle: meterThrottle, deliver: deliver)
        engine.mainMixerNode.installTap(
            onBus: 0,
            bufferSize: 2_048,
            format: nil,
            block: tapBlock
        )
        isMeterTapInstalled = true
    }

    private func removeMeterTapIfNeeded() {
        guard isMeterTapInstalled else { return }
        engine.mainMixerNode.removeTap(onBus: 0)
        isMeterTapInstalled = false
    }

    private func applyAudioVisualization(_ incoming: AudioVisualizationSnapshot) {
        stereoLevels = StereoLevels(
            left: smoothedMeterLevel(current: stereoLevels.left, target: incoming.levels.left),
            right: smoothedMeterLevel(current: stereoLevels.right, target: incoming.levels.right)
        )
        stereoSpectrum = StereoSpectrum(
            left: SpectrumMath.smoothed(
                current: stereoSpectrum.left,
                target: incoming.spectrum.left
            ),
            right: SpectrumMath.smoothed(
                current: stereoSpectrum.right,
                target: incoming.spectrum.right
            )
        )
    }

    private func smoothedMeterLevel(current: Double, target: Double) -> Double {
        let response = target > current ? 0.72 : 0.24
        return current + ((target - current) * response)
    }

    private func clearAudioVisualization() {
        stereoLevels = .silent
        stereoSpectrum = .silent
    }

    private func schedule(fromFrame frame: AVAudioFramePosition) {
        guard let audioFile, let currentTrack else { return }
        stopPlayerNodes()
        playbackGeneration = UUID()
        let generation = playbackGeneration
        scheduledStartFrame = frame
        activeTrackNodeStartSampleTime = 0
        prerolledTrack = nil
        let remaining = max(0, audioFile.length - frame)
        guard remaining > 0 else {
            didFinishPlaying(generation: generation, finishedTrackID: currentTrack.id)
            return
        }
        let frameCount = AVAudioFrameCount(min(remaining, AVAudioFramePosition(UInt32.max)))
        playerNode.scheduleSegment(
            audioFile,
            startingFrame: frame,
            frameCount: frameCount,
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor in
                self?.didFinishPlaying(
                    generation: generation,
                    finishedTrackID: currentTrack.id
                )
            }
        }
    }

    private func currentElapsed() -> TimeInterval {
        guard let audioFile,
              let renderTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: renderTime) else {
            return elapsed
        }
        let renderedFrames = max(0, playerTime.sampleTime)
        let framesInCurrentTrack = max(0, renderedFrames - activeTrackNodeStartSampleTime)
        let totalFrames = scheduledStartFrame + framesInCurrentTrack
        return min(Double(totalFrames) / audioFile.processingFormat.sampleRate, duration)
    }

    private func didFinishPlaying(generation: UUID, finishedTrackID: Track.ID) {
        guard generation == playbackGeneration,
              currentTrack?.id == finishedTrackID else { return }
        finishPlaybackSession(kind: .completed, position: duration)

        if let prepared = prerolledTrack,
           prepared.generation == generation {
            advanceToPrerolledTrack(prepared)
            return
        }

        if let currentTrack,
           let nextTrack = PlaybackQueueNavigator.nextTrack(
               after: currentTrack,
               in: playbackQueue,
               mode: playbackMode
           ) {
            load(nextTrack, position: 0, autoplay: true)
            return
        }
        isPlaying = false
        elapsed = duration
        clearAudioVisualization()
        stopTimer()
        publishQueueState(force: true)
    }

    private func analysisKey(for url: URL) -> URL {
        url.standardizedFileURL
    }

    private func primeTransitionAnalyses(startingWith track: Track) {
        primeSilenceAnalysis(for: track)
        if let nextTrack = PlaybackQueueNavigator.nextTrack(
            after: track,
            in: playbackQueue,
            mode: playbackMode
        ) {
            primeSilenceAnalysis(for: nextTrack)
        }
    }

    private func primeSilenceAnalysis(for track: Track) {
        let key = analysisKey(for: track.fileURL)
        guard silenceAnalyses[key] == nil, silenceAnalysisTasks[key] == nil else { return }
        silenceAnalysisTasks[key] = Task { [weak self] in
            let analysis = await Task.detached(priority: .utility) {
                (try? AudioSilenceAnalyzer.analyze(url: key)) ?? .none
            }.value
            guard !Task.isCancelled, let self else { return }
            silenceAnalyses[key] = analysis
            silenceAnalysisTasks[key] = nil
            prepareNextTrackIfNeeded()
        }
    }

    private func prepareNextTrackIfNeeded() {
        guard isPlaying, let currentTrack, let audioFile else { return }
        let remaining = duration - currentElapsed()
        let preparationLeadTime = max(
            GaplessPrerollPolicy.leadTime,
            min(crossfadeDuration, CrossfadePolicy.maximumDuration)
                + SilenceAnalysisPolicy.maximumScanDuration + 1
        )
        guard GaplessPrerollPolicy.shouldPrepare(
                  remaining: remaining,
                  alreadyPrepared: prerolledTrack != nil,
                  leadTime: preparationLeadTime
              ),
              let nextTrack = PlaybackQueueNavigator.nextTrack(
                  after: currentTrack,
                  in: playbackQueue,
                  mode: playbackMode
              ),
              let nextFile = try? AVAudioFile(forReading: nextTrack.fileURL) else {
            return
        }

        let formatsAreCompatible = GaplessAudioFormat(audioFile.processingFormat)
            .canSharePlayerNode(with: GaplessAudioFormat(nextFile.processingFormat))
        guard formatsAreCompatible else { return }
        let usesSilenceAwareCrossfade = crossfadeDuration > 0
            && !(disableCrossfadeWithinAlbum && currentTrack.albumID == nextTrack.albumID)
        let currentAnalysis: AudioSilenceAnalysis
        let nextAnalysis: AudioSilenceAnalysis
        if usesSilenceAwareCrossfade {
            guard let cachedCurrent = silenceAnalyses[analysisKey(for: currentTrack.fileURL)],
                  let cachedNext = silenceAnalyses[analysisKey(for: nextTrack.fileURL)] else {
                primeSilenceAnalysis(for: currentTrack)
                primeSilenceAnalysis(for: nextTrack)
                return
            }
            currentAnalysis = cachedCurrent
            nextAnalysis = cachedNext
        } else {
            currentAnalysis = .none
            nextAnalysis = .none
        }
        let nextDuration = Double(nextFile.length) / nextFile.processingFormat.sampleRate
        let audibleCurrentRemaining = max(remaining - currentAnalysis.trailingSilence, 0)
        let audibleNextDuration = max(
            nextDuration - nextAnalysis.leadingSilence - nextAnalysis.trailingSilence,
            0
        )
        let effectiveCrossfadeDuration = CrossfadePolicy.effectiveDuration(
            requestedDuration: crossfadeDuration,
            currentRemaining: audibleCurrentRemaining,
            nextDuration: audibleNextDuration,
            isSameAlbum: currentTrack.albumID == nextTrack.albumID,
            disablesWithinAlbum: disableCrossfadeWithinAlbum,
            formatsAreCompatible: formatsAreCompatible
        )

        let generation = playbackGeneration
        let nodeStartSampleTime = activeTrackNodeStartSampleTime
            + max(0, audioFile.length - scheduledStartFrame)
        let nextStartFrame = effectiveCrossfadeDuration > 0
            ? min(
                AVAudioFramePosition(
                    nextAnalysis.leadingSilence * nextFile.processingFormat.sampleRate
                ),
                nextFile.length
            )
            : 0
        let frameCount = AVAudioFrameCount(
            min(
                max(nextFile.length - nextStartFrame, 0),
                AVAudioFramePosition(UInt32.max)
            )
        )
        guard frameCount > 0 else { return }

        let targetNode: AVAudioPlayerNode
        let crossfadeStartHostTime: UInt64?
        if effectiveCrossfadeDuration > 0 {
            targetNode = standbyPlayerNode
            targetNode.stop()
            targetNode.volume = 0
            crossfadeStartHostTime = mach_absolute_time()
                + AVAudioTime.hostTime(
                    forSeconds: max(audibleCurrentRemaining - effectiveCrossfadeDuration, 0)
                )
        } else {
            targetNode = playerNode
            crossfadeStartHostTime = nil
        }

        prerolledTrack = PrerolledTrack(
            track: nextTrack,
            file: nextFile,
            generation: generation,
            nodeStartSampleTime: effectiveCrossfadeDuration > 0 ? 0 : nodeStartSampleTime,
            playbackNode: targetNode,
            crossfadeDuration: effectiveCrossfadeDuration,
            crossfadeStartHostTime: crossfadeStartHostTime,
            scheduledStartFrame: nextStartFrame,
            outgoingTransitionPosition: max(duration - currentAnalysis.trailingSilence, 0)
        )
        targetNode.scheduleSegment(
            nextFile,
            startingFrame: nextStartFrame,
            frameCount: frameCount,
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor in
                self?.didFinishPlaying(
                    generation: generation,
                    finishedTrackID: nextTrack.id
                )
            }
        }
        if let crossfadeStartHostTime {
            targetNode.play(at: AVAudioTime(hostTime: crossfadeStartHostTime))
            startCrossfadeTimer()
        }
    }

    private func advanceToPrerolledTrack(_ prepared: PrerolledTrack) {
        stopCrossfadeTimer()
        let outgoingNode = playerNode
        let changesPlayerNode = prepared.playbackNode !== outgoingNode
        prerolledTrack = nil
        if changesPlayerNode {
            outgoingNode.stop()
            activePlayerIndex = activePlayerIndex == 0 ? 1 : 0
        }
        primaryPlayerNode.volume = 1
        secondaryPlayerNode.volume = 1
        audioFile = prepared.file
        currentTrack = prepared.track
        primeTransitionAnalyses(startingWith: prepared.track)
        sourceSampleRate = prepared.file.processingFormat.sampleRate
        scheduledStartFrame = prepared.scheduledStartFrame
        activeTrackNodeStartSampleTime = changesPlayerNode ? 0 : prepared.nodeStartSampleTime
        elapsed = currentElapsed()
        errorMessage = nil
        beginPlaybackSessionIfNeeded()
        publishQueueState(force: true)
        prepareNextTrackIfNeeded()
    }

    private func stopCurrentPlayback() {
        recoveryTask?.cancel()
        recoveryTask = nil
        playbackGeneration = UUID()
        prerolledTrack = nil
        activeTrackNodeStartSampleTime = 0
        stopPlayerNodes(resetActivePlayer: true)
        engine.stop()
        stopTimer()
        audioFile = nil
        isPlaying = false
        elapsed = 0
        sourceSampleRate = 0
        outputSampleRate = 0
        clearAudioVisualization()
    }

    private func stopPlayerNodes(resetActivePlayer: Bool = false) {
        stopCrossfadeTimer()
        primaryPlayerNode.stop()
        secondaryPlayerNode.stop()
        primaryPlayerNode.volume = 1
        secondaryPlayerNode.volume = 1
        if resetActivePlayer { activePlayerIndex = 0 }
        prerolledTrack = nil
    }

    private func updateCrossfadeVolumes() {
        guard let prepared = prerolledTrack,
              prepared.crossfadeDuration > 0,
              let startHostTime = prepared.crossfadeStartHostTime else { return }
        let now = mach_absolute_time()
        guard now >= startHostTime else { return }
        let elapsedHostTime = now - startHostTime
        let progress = AVAudioTime.seconds(forHostTime: elapsedHostTime)
            / prepared.crossfadeDuration
        let gains = CrossfadePolicy.gains(progress: progress)
        playerNode.volume = gains.outgoing
        prepared.playbackNode.volume = gains.incoming
        if progress >= 1 {
            finishPlaybackSession(
                kind: .completed,
                position: prepared.outgoingTransitionPosition
            )
            advanceToPrerolledTrack(prepared)
        }
    }

    private func startCrossfadeTimer() {
        stopCrossfadeTimer()
        crossfadeTimer = Timer.scheduledTimer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(crossfadeTick),
            userInfo: nil,
            repeats: true
        )
        if let crossfadeTimer {
            RunLoop.main.add(crossfadeTimer, forMode: .common)
        }
    }

    private func stopCrossfadeTimer() {
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
    }

    @objc private func crossfadeTick() {
        updateCrossfadeVolumes()
    }

    private func beginPlaybackSessionIfNeeded() {
        guard let currentTrack,
              let event = playbackSession.begin(
                  trackID: currentTrack.id,
                  position: elapsed
              ) else { return }
        playbackEventPublisher.send(event)
    }

    private func finishPlaybackSession(
        kind: PlaybackEvent.Kind,
        position explicitPosition: TimeInterval? = nil
    ) {
        guard let currentTrack else { return }
        let position = explicitPosition ?? (isPlaying ? currentElapsed() : elapsed)
        guard let event = playbackSession.finish(
            trackID: currentTrack.id,
            kind: kind,
            position: position
        ) else { return }
        playbackEventPublisher.send(event)
    }

    private func updateEffect(
        _ kind: RealtimeAudioEffectKind,
        mutation: (inout RealtimeAudioEffectSetting) -> Void
    ) {
        guard let index = effectSettings.firstIndex(where: { $0.kind == kind }) else { return }
        mutation(&effectSettings[index])
        applyEffectSetting(effectSettings[index])
        persistEffectSettings()
    }

    private func applyEffectSetting(_ setting: RealtimeAudioEffectSetting) {
        var effectiveSetting = setting
        if effectsBypassed { effectiveSetting.isEnabled = false }
        effectPipeline.first(where: { $0.kind == setting.kind })?.apply(setting: effectiveSetting)
    }

    private func persistEffectSettings() {
        guard let data = try? JSONEncoder().encode(effectSettings) else { return }
        UserDefaults.standard.set(data, forKey: Self.effectSettingsKey)
    }

    private static func loadEffectSettings(
        defaults: [RealtimeAudioEffectSetting]
    ) -> [RealtimeAudioEffectSetting] {
        guard let data = UserDefaults.standard.data(forKey: effectSettingsKey),
              let saved = try? JSONDecoder().decode([RealtimeAudioEffectSetting].self, from: data) else {
            return defaults
        }
        let savedByKind = Dictionary(uniqueKeysWithValues: saved.map { ($0.kind, $0) })
        return defaults.map { defaultSetting in
            guard var restored = savedByKind[defaultSetting.kind] else { return defaultSetting }
            let definitions = defaultSetting.kind.parameterDefinitions
            restored.parameters = Dictionary(uniqueKeysWithValues: definitions.map { definition in
                let savedValue = restored.parameters[definition.key] ?? definition.defaultValue
                return (definition.key, min(max(savedValue, definition.range.lowerBound), definition.range.upperBound))
            })
            return restored
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(timeInterval: 0.25, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func tick() {
        elapsed = currentElapsed()
        publishQueueState()
        prepareNextTrackIfNeeded()
    }

    private func editQueue(_ mutation: (inout [Track]) -> Void) {
        let previous = playbackQueue
        mutation(&playbackQueue)
        guard previous != playbackQueue else { return }
        queueUndoStack.append(previous)
        if queueUndoStack.count > 20 { queueUndoStack.removeFirst() }
        publishQueueState(force: true)
    }

    private func publishQueueState(force: Bool = false) {
        let positionBucket = Int(max(elapsed, 0) / 5)
        guard force || positionBucket != lastPublishedPositionBucket else { return }
        lastPublishedPositionBucket = positionBucket
        let updated = PlaybackQueueState(
            trackIDs: playbackQueue.map(\.id),
            currentTrackID: currentTrack?.id,
            position: currentTrack == nil ? 0 : elapsed
        )
        if force || updated != queueState { queueState = updated }
    }

    private static func sampleRateString(_ rate: Double) -> String {
        let kilohertz = rate / 1_000
        if abs(kilohertz.rounded() - kilohertz) < 0.01 {
            return String(format: "%.0f kHz", kilohertz)
        }
        return String(format: "%.1f kHz", kilohertz)
    }
}
