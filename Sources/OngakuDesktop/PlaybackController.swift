@preconcurrency import AVFoundation
import AppKit
import Combine
import Foundation

struct StereoLevels: Equatable, Sendable {
    var left: Double
    var right: Double

    static let silent = StereoLevels(left: 0, right: 0)
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
    private static let playbackModeKey = "audio.playbackMode.v1"

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

    let playbackEventPublisher = PassthroughSubject<PlaybackEvent, Never>()

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
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
    private var isMeterTapInstalled = false
    private let meterThrottle = StereoMeterThrottle()
    private var recoveryObservations = Set<AnyCancellable>()
    private var recoveryTask: Task<Void, Never>?
    private var recoveryState = PlaybackRecoveryState()
    private var suppressConfigurationRecoveryUntil: TimeInterval = 0

    init() {
        let defaultSettings = AudioEffectModuleRegistry.makeDefaultSettings()
        effectPipeline = AudioEffectModuleRegistry.makePipeline()
        effectSettings = Self.loadEffectSettings(defaults: defaultSettings)
        effectsBypassed = UserDefaults.standard.bool(forKey: Self.effectsBypassedKey)
        playbackMode = UserDefaults.standard.string(forKey: Self.playbackModeKey)
            .flatMap(PlaybackMode.init(rawValue:)) ?? .sequential
        automaticUpsampling = UserDefaults.standard.object(forKey: Self.automaticUpsamplingKey) as? Bool ?? true
        engine.attach(playerNode)
        effectPipeline.forEach { $0.attach(to: engine) }
        effectSettings.forEach(applyEffectSetting)
        playerNode.volume = Float(volume)
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
        }
        publishQueueState(force: true)
    }

    func togglePlayback() {
        guard audioFile != nil else { return }
        if playerNode.isPlaying {
            elapsed = currentElapsed()
            playerNode.pause()
            isPlaying = false
            stereoLevels = .silent
            stopTimer()
            publishQueueState(force: true)
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
                beginPlaybackSessionIfNeeded()
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

        playerNode.stop()
        stereoLevels = .silent
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
        playerNode.pause()
        isPlaying = false
        stereoLevels = .silent
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
            playerNode.stop()
            engine.stop()
            stopTimer()
            isPlaying = false
            stereoLevels = .silent

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
        finishPlaybackSession(kind: .completed, position: duration)
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
        stereoLevels = .silent
        stopTimer()
        publishQueueState(force: true)
    }

    private func stopCurrentPlayback() {
        recoveryTask?.cancel()
        recoveryTask = nil
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
