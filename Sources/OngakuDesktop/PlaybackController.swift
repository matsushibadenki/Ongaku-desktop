@preconcurrency import AVFoundation
import Combine
import Foundation

struct StereoLevels: Equatable, Sendable {
    var left: Double
    var right: Double

    static let silent = StereoLevels(left: 0, right: 0)
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

// AVAudioEngine invokes tap blocks on its realtime messenger queue. Creating this
// block outside PlaybackController prevents it from inheriting MainActor isolation.
func makeStereoMeterTapBlock(
    throttle: StereoMeterThrottle,
    deliver: @escaping @Sendable (StereoLevels) -> Void
) -> AVAudioNodeTapBlock {
    { buffer, _ in
        guard throttle.shouldEmit() else { return }
        deliver(StereoLevelMath.measure(buffer))
    }
}

@MainActor
final class PlaybackController: ObservableObject {
    private static let automaticUpsamplingKey = "audio.automaticUpsampling"
    private static let effectSettingsKey = "audio.effectSettings.v1"
    private static let effectsBypassedKey = "audio.effectsBypassed"

    @Published private(set) var currentTrack: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var volume: Double = 0.8 {
        didSet { playerNode.volume = Float(volume) }
    }
    @Published private(set) var errorMessage: String?
    @Published private(set) var sourceSampleRate: Double = 0
    @Published private(set) var outputSampleRate: Double = 0
    @Published private(set) var stereoLevels = StereoLevels.silent
    @Published private(set) var effectSettings: [RealtimeAudioEffectSetting]
    @Published private(set) var effectsBypassed: Bool
    @Published var automaticUpsampling: Bool {
        didSet {
            UserDefaults.standard.set(automaticUpsampling, forKey: Self.automaticUpsamplingKey)
        }
    }

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let effectPipeline: [AudioEffectNode]
    private let outputManager = AudioOutputManager()
    private var audioFile: AVAudioFile?
    private var scheduledStartFrame: AVAudioFramePosition = 0
    private var playbackGeneration = UUID()
    private var timer: Timer?
    private var isMeterTapInstalled = false
    private let meterThrottle = StereoMeterThrottle()

    init() {
        let defaultSettings = AudioEffectModuleRegistry.makeDefaultSettings()
        effectPipeline = AudioEffectModuleRegistry.makePipeline()
        effectSettings = Self.loadEffectSettings(defaults: defaultSettings)
        effectsBypassed = UserDefaults.standard.bool(forKey: Self.effectsBypassedKey)
        automaticUpsampling = UserDefaults.standard.object(forKey: Self.automaticUpsamplingKey) as? Bool ?? true
        engine.attach(playerNode)
        effectPipeline.forEach { $0.attach(to: engine) }
        effectSettings.forEach(applyEffectSetting)
        playerNode.volume = Float(volume)
    }

    var duration: TimeInterval {
        guard let audioFile else { return currentTrack?.duration ?? 0 }
        return Double(audioFile.length) / audioFile.processingFormat.sampleRate
    }

    var isUpsampling: Bool { outputSampleRate > sourceSampleRate + 1 }

    var enabledEffectCount: Int {
        effectsBypassed ? 0 : effectSettings.count(where: \.isEnabled)
    }

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
        do {
            stopCurrentPlayback()
            let file = try AVAudioFile(forReading: track.fileURL)
            let sourceRate = file.processingFormat.sampleRate
            let configuration = automaticUpsampling
                ? outputManager.configureDefaultOutput(sourceRate: sourceRate)
                : nil

            audioFile = file
            sourceSampleRate = sourceRate
            outputSampleRate = configuration?.actualRate ?? sourceRate
            currentTrack = track
            elapsed = 0

            try configureEngine(for: file)
            schedule(fromFrame: 0)
            try engine.start()
            playerNode.play()
            isPlaying = true
            errorMessage = nil
            startTimer()
        } catch {
            stopCurrentPlayback()
            currentTrack = track
            isPlaying = false
            errorMessage = error.localizedDescription
        }
    }

    func togglePlayback() {
        guard audioFile != nil else { return }
        if playerNode.isPlaying {
            elapsed = currentElapsed()
            playerNode.pause()
            isPlaying = false
            stereoLevels = .silent
            stopTimer()
        } else {
            do {
                if elapsed >= duration - 0.01 {
                    playerNode.stop()
                    schedule(fromFrame: 0)
                    elapsed = 0
                }
                if !engine.isRunning { try engine.start() }
                playerNode.play()
                isPlaying = true
                errorMessage = nil
                startTimer()
            } catch {
                isPlaying = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func seek(to value: TimeInterval) {
        guard let audioFile else { return }
        let shouldResume = isPlaying
        let clamped = min(max(0, value), duration)
        let frame = min(
            AVAudioFramePosition(clamped * audioFile.processingFormat.sampleRate),
            audioFile.length
        )

        playerNode.stop()
        stereoLevels = .silent
        if frame >= audioFile.length {
            playbackGeneration = UUID()
            elapsed = duration
            isPlaying = false
            stopTimer()
            return
        }
        schedule(fromFrame: frame)
        elapsed = clamped
        if shouldResume {
            do {
                if !engine.isRunning { try engine.start() }
                playerNode.play()
                startTimer()
            } catch {
                isPlaying = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func configureEngine(for file: AVAudioFile) throws {
        engine.stop()
        removeMeterTapIfNeeded()
        engine.disconnectNodeOutput(playerNode)
        for effect in effectPipeline {
            effect.nodes.forEach { engine.disconnectNodeOutput($0) }
        }
        engine.disconnectNodeOutput(engine.mainMixerNode)

        // Keep the player at the file's native rate. The mixer performs the single
        // sample-rate conversion into the actual hardware output format.
        var upstream: AVAudioNode = playerNode
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

    private func installMeterTap() {
        let deliver: @Sendable (StereoLevels) -> Void = { [weak self] levels in
            Task { @MainActor [weak self] in
                self?.applyMeterLevels(levels)
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

    private func applyMeterLevels(_ incoming: StereoLevels) {
        stereoLevels = StereoLevels(
            left: smoothedMeterLevel(current: stereoLevels.left, target: incoming.left),
            right: smoothedMeterLevel(current: stereoLevels.right, target: incoming.right)
        )
    }

    private func smoothedMeterLevel(current: Double, target: Double) -> Double {
        let response = target > current ? 0.72 : 0.24
        return current + ((target - current) * response)
    }

    private func schedule(fromFrame frame: AVAudioFramePosition) {
        guard let audioFile else { return }
        playbackGeneration = UUID()
        let generation = playbackGeneration
        scheduledStartFrame = frame
        let remaining = max(0, audioFile.length - frame)
        guard remaining > 0 else {
            didFinishPlaying(generation: generation)
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
                self?.didFinishPlaying(generation: generation)
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
        let totalFrames = scheduledStartFrame + renderedFrames
        return min(Double(totalFrames) / audioFile.processingFormat.sampleRate, duration)
    }

    private func didFinishPlaying(generation: UUID) {
        guard generation == playbackGeneration else { return }
        isPlaying = false
        elapsed = duration
        stereoLevels = .silent
        stopTimer()
    }

    private func stopCurrentPlayback() {
        playbackGeneration = UUID()
        playerNode.stop()
        engine.stop()
        stopTimer()
        audioFile = nil
        isPlaying = false
        elapsed = 0
        sourceSampleRate = 0
        outputSampleRate = 0
        stereoLevels = .silent
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
    }

    private static func sampleRateString(_ rate: Double) -> String {
        let kilohertz = rate / 1_000
        if abs(kilohertz.rounded() - kilohertz) < 0.01 {
            return String(format: "%.0f kHz", kilohertz)
        }
        return String(format: "%.1f kHz", kilohertz)
    }
}
