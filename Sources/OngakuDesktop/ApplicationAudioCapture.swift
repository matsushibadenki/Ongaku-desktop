import AppKit
import Combine
import Observation
import CoreAudio
import SwiftUI
import UniformTypeIdentifiers
#if canImport(OngakuAudioDSP)
import OngakuAudioDSP
#endif

struct ApplicationAudioSource: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let processIDs: [AudioObjectID]
}

@available(macOS 14.2, *)
enum ApplicationAudioSources {
    static func list() throws -> [ApplicationAudioSource] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size))
        guard size > 0 else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try processes.withUnsafeMutableBytes {
            try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!))
        }
        processes = Array(processes.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var groups: [String: (name: String, ids: [AudioObjectID])] = [:]
        for process in processes {
            var pid: pid_t = 0
            address.mSelector = kAudioProcessPropertyPID
            size = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &pid) == noErr,
                  pid != ProcessInfo.processInfo.processIdentifier else { continue }
            address.mSelector = kAudioProcessPropertyBundleID
            var bundle: Unmanaged<CFString>?
            size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &bundle) == noErr else { continue }
            let bundleID = bundle.map { $0.takeRetainedValue() as String } ?? ""
            guard !bundleID.isEmpty, !belongs(bundleID, to: "com.ongaku.desktop"),
                  !belongs(bundleID, to: Bundle.main.bundleIdentifier ?? "com.ongaku.desktop") else { continue }
            // Match helper bundle IDs to their running host, preferring the longest match.
            let app = apps.filter { app in
                app.processIdentifier == pid || app.bundleIdentifier.map { belongs(bundleID, to: $0) } == true
            }.max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
            guard let app else { continue }
            let key = app.bundleIdentifier ?? bundleID
            var group = groups[key] ?? (app.localizedName ?? bundleID, [])
            group.ids.append(process)
            groups[key] = group
        }
        return groups.map { ApplicationAudioSource(id: $0.key, name: $0.value.name, processIDs: $0.value.ids.sorted()) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func belongs(_ bundleID: String, to owner: String) -> Bool {
        bundleID == owner || bundleID.hasPrefix(owner + ".")
    }

    private static func check(_ status: OSStatus) throws {
        if status != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

// Live data is observed only by the meter and clock leaf views, never by the
// canvas owner. Native audio keeps its own state; this is UI telemetry only.
@MainActor @Observable
final class ApplicationAudioLevels {
    private(set) var peaks: [UUID: Float] = [:]
    var waveforms: [UUID: [Float]] = [:]
    private(set) var elapsedSeconds = 0
    private(set) var clippedNodes: Set<UUID> = []
    @ObservationIgnored var clearPendingClipping: ((UUID) -> Void)?
    func clearClipping(_ id: UUID) {
        clearPendingClipping?(id)
        clippedNodes.remove(id)
    }
    func startSession() {
        clippedNodes.removeAll()
        waveforms.removeAll()
        update(peaks: [:], duration: 0)
    }
    func update(peaks: [UUID: Float], duration: TimeInterval, clipped: Set<UUID> = []) {
        let nextClipped = clippedNodes.union(clipped).union(peaks.filter { $0.value > 1 }.map(\.key))
        if clippedNodes != nextClipped { clippedNodes = nextClipped }
        if self.peaks != peaks { self.peaks = peaks }
        let seconds = Int(max(0, duration).rounded(.down))
        if elapsedSeconds != seconds { elapsedSeconds = seconds }
    }
}

@available(macOS 14.2, *)
@MainActor
final class ApplicationAudioCaptureController: ObservableObject {
    // A session belongs to the app, not to the currently selected library/page.
    static let shared = ApplicationAudioCaptureController()
    let routing = AudioRoutingStore()
    let levels = ApplicationAudioLevels()
    private var activePlan: AudioRoutingPlan?
    @Published private(set) var outputs: [ApplicationAudioOutput] = []
    @Published private(set) var recordsAudio = false
    @Published private(set) var monitorsAudio = false
    private(set) var monitoredFrames: UInt64 = 0
    private(set) var monitorUnderruns: UInt64 = 0
    @Published private(set) var sources: [ApplicationAudioSource] = []
    @Published var selectedSourceID = "" {
        didSet { UserDefaults.standard.set(selectedSourceID, forKey: "applicationAudio.source.v1") }
    }
    @Published private(set) var isRecording = false
    @Published private(set) var isChoosingDestination = false
    private(set) var duration: TimeInterval = 0
    private(set) var peak: Float = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var hasReceivedSignal = false
    private var engine: OngakuApplicationAudioCapture?
    private var polling: Task<Void, Never>?
    private var sessionSource: ApplicationAudioSource?
    private var destination: URL?
    private var scopedURLs: [URL] = []
    private var observers: [NSObjectProtocol] = []

    init() {
        levels.clearPendingClipping = { [weak self] id in
            guard let self, let index = self.activePlan?.steps.firstIndex(where: { $0.id == id }) else { return }
            _ = self.engine?.takeClipping(atStep: UInt(index))
        }
        selectedSourceID = UserDefaults.standard.string(forKey: "applicationAudio.source.v1") ?? ""
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated {
            guard let self, self.isRecording else { return }
            self.stop(message: L10n.text("capture.interrupted"))
        } })
    }

    func refresh() {
        guard !isRecording, !isChoosingDestination else { return }
        outputs = ApplicationAudioOutputs.list()
        do {
            sources = try ApplicationAudioSources.list()
            if !sources.contains(where: { $0.id == selectedSourceID }) {
                selectedSourceID = ""
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func chooseDestinationAndStart() {
        guard !isRecording, !isChoosingDestination else { return }
        guard let source = sources.first(where: { $0.id == selectedSourceID }) else { return }
        let plan: AudioRoutingPlan
        do { plan = try routing.document.plan() }
        catch { errorMessage = error.localizedDescription; return }
        if plan.monitors {
            guard let uid = routing.document.nodes.first(where: { $0.kind == .device })?.deviceUID,
                  ApplicationAudioOutputs.list().contains(where: { $0.id == uid }) else {
                errorMessage = L10n.text("routing.chooseDevice"); return
            }
        }
        if !plan.records {
            routing.setLocked(true)
            start(source: source, url: nil, plan: plan)
            return
        }
        guard let recorder = routing.document.nodes.first(where: { $0.kind == .recorder }) else { return }
        let settings = recorder.recording ?? AudioRecordingSettings()
        do {
            try settings.validate()
            let folder = try settings.resolveDirectory()
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
                  FileManager.default.isWritableFile(atPath: folder.path) else { throw RecordingSettingsError.directory }
            routing.setLocked(true)
            start(source: source, url: settings.recordingURL(in: folder, source: source.name), plan: plan,
                  folder: folder, settings: settings)
        } catch {
            errorMessage = error.localizedDescription
            openNodeSettings(recorder.id)
        }
    }

    func openNodeSettings(_ id: UUID) {
        guard let node = routing.document.nodes.first(where: { $0.id == id }) else { return }
        AudioNodeSettingsWindows.shared.show(node: node, store: routing) {
            AudioNodeSettingsView(capture: self, store: routing, nodeID: id)
        }
    }

    func chooseRecordingDirectory(_ settings: AudioRecordingSettings, completion: @escaping (AudioRecordingSettings) -> Void) {
        guard !isRecording, !isChoosingDestination else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.prompt = L10n.text("recording.chooseFolder")
        isChoosingDestination = true
        let finished: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            self.isChoosingDestination = false
            guard response == .OK, let url = panel.url else { return }
            do {
                var updated = settings
                try updated.selectDirectory(url)
                self.errorMessage = nil
                completion(updated)
            } catch { self.errorMessage = error.localizedDescription }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow { panel.beginSheetModal(for: window, completionHandler: finished) }
        else { panel.begin(completionHandler: finished) }
    }

    private func start(source: ApplicationAudioSource, url: URL?, plan: AudioRoutingPlan, folder: URL? = nil, settings: AudioRecordingSettings? = nil) {
        guard !isRecording else { return }
        defer { if !isRecording { routing.setLocked(false) } }
        let newScope = folder.flatMap { $0.startAccessingSecurityScopedResource() ? $0 : nil }
        defer { if !isRecording { newScope?.stopAccessingSecurityScopedResource() } }
        // Revalidate source membership immediately before creating the process tap.
        do {
            guard let current = try ApplicationAudioSources.list().first(where: { $0.id == source.id }) else {
                errorMessage = L10n.text("capture.sourceChanged"); return
            }
            let capture = OngakuApplicationAudioCapture()
            if let settings {
                try capture.setRecordingBitDepth(UInt32(settings.quality.rawValue), sampleRate: Double(settings.sampleRate.rawValue), info: settings.infoData, id3: settings.id3Data)
            }
            let steps = plan.nativeSteps
            try steps.withUnsafeBufferPointer { pointer in
                try capture.setRouteSteps(pointer.baseAddress!, count: UInt(pointer.count))
            }
            if plan.monitors {
                guard let node = routing.document.nodes.first(where: { $0.kind == .device }),
                      let uid = node.deviceUID,
                      ApplicationAudioOutputs.list().contains(where: { $0.id == uid }) else { throw AudioRoutingError.device }
                try capture.setOutputDeviceUID(uid)
                try capture.setMonitorSampleRate(Double((node.outputRate ?? .source).rawValue))
            }
            try capture.startProcesses(current.processIDs.map { NSNumber(value: $0) }, url: url)
            for scoped in scopedURLs { scoped.stopAccessingSecurityScopedResource() }
            scopedURLs = newScope.map { [$0] } ?? []
            engine = capture
            activePlan = plan
            routing.setLiveUpdate { [weak self] document in
                guard let self, let engine = self.engine, let active = self.activePlan else { throw AudioRoutingError.locked }
                let next = try document.plan()
                guard next.steps.map(\.id) == active.steps.map(\.id) else { throw AudioRoutingError.document }
                let steps = next.nativeSteps
                try steps.withUnsafeBufferPointer { try engine.updateParameters($0.baseAddress!, count: UInt($0.count)) }
            }
            levels.startSession()
            sessionSource = current
            destination = url
            lastRecordingURL = nil
            errorMessage = nil
            duration = 0; peak = 0; hasReceivedSignal = false
            recordsAudio = plan.records; monitorsAudio = plan.monitors
            monitoredFrames = 0; monitorUnderruns = 0
            isRecording = true
            AudioRoutingRenderDiagnostics.begin()
            polling = Task { [weak self] in
                var tick = 0
                var stalledOutputTicks = 0
                var previousOutputFrames: UInt64 = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, let self, let engine = self.engine else { break }
                    let latestDuration = engine.duration
                    let advanced = latestDuration > self.duration
                    self.peak = advanced ? engine.peak : 0
                    self.duration = latestDuration
                    self.monitoredFrames = engine.monitoredFrames
                    self.monitorUnderruns = engine.monitorUnderruns
                    if self.monitorsAudio && latestDuration > 3 && advanced {
                        stalledOutputTicks = engine.monitoredFrames == previousOutputFrames ? stalledOutputTicks + 1 : 0
                        if stalledOutputTicks >= 10 {
                            self.stop(message: L10n.text("routing.sessionChanged")); break
                        }
                    }
                    previousOutputFrames = engine.monitoredFrames
                    if let plan = self.activePlan {
                        var waveforms: [UUID: [Float]] = [:]
                        if advanced {
                            for (index, step) in plan.steps.enumerated() where step.kind == .waveform {
                                var pairs = [Float](repeating: 0, count: 256)
                                pairs.withUnsafeMutableBufferPointer {
                                    engine.copyWaveform(atStep: UInt(index), into: $0.baseAddress!, count: 128)
                                }
                                waveforms[step.id] = pairs
                            }
                        }
                        if self.levels.waveforms != waveforms { self.levels.waveforms = waveforms }
                        self.levels.update(peaks: Dictionary(uniqueKeysWithValues: plan.steps.enumerated().map {
                            ($0.element.id, advanced ? engine.peak(atStep: UInt($0.offset)) : 0)
                        }), duration: latestDuration, clipped: self.consumeClipping(engine, plan: plan))
                    }
                    if !self.hasReceivedSignal && engine.peak(atStep: 0) > 0.00001 { self.hasReceivedSignal = true }
                    if engine.status != noErr {
                        self.stop(message: L10n.format("capture.writeError", engine.status)); break
                    }
                    tick += 1
                    if tick % 10 == 0 {
                        do {
                            let current = try ApplicationAudioSources.list().first { $0.id == self.sessionSource?.id }
                            guard current == self.sessionSource, engine.formatIsCurrent else {
                                self.stop(message: L10n.text("routing.sessionChanged")); break
                            }
                        } catch { self.stop(message: error.localizedDescription); break }
                    }
                }
            }
        } catch {
            errorMessage = L10n.format("capture.startError", error.localizedDescription)
            // Any failed partial file remains available to the user; never delete an existing destination.

        }
    }

    private func consumeClipping(_ engine: OngakuApplicationAudioCapture, plan: AudioRoutingPlan) -> Set<UUID> {
        Set(plan.steps.enumerated().compactMap {
            engine.takeClipping(atStep: UInt($0.offset)) ? $0.element.id : nil
        })
    }

    func stop(message: String? = nil) {
        guard let engine else { return }
        routing.setLiveUpdate(nil) // commit any active slider before stopping IO
        AudioRoutingRenderDiagnostics.end()
        polling?.cancel(); polling = nil
        let result = engine.stop() // waits for queued PCM writes and finalizes the WAV header
        duration = engine.duration
        levels.waveforms.removeAll()
        if let plan = activePlan {
            levels.update(peaks: [:], duration: duration, clipped: consumeClipping(engine, plan: plan))
        }
        monitoredFrames = engine.monitoredFrames; monitorUnderruns = engine.monitorUnderruns
        #if DEBUG
        NSLog("Ongaku application audio stopped: duration=%.3f outputFrames=%llu underruns=%llu status=%d", duration, monitoredFrames, monitorUnderruns, result)
        #endif
        lastRecordingURL = destination
        self.engine = nil; destination = nil; sessionSource = nil
        isRecording = false; peak = 0
        routing.setLocked(false); activePlan = nil; levels.update(peaks: [:], duration: duration)
        if let message { errorMessage = message }
        else if result != noErr { errorMessage = L10n.format("capture.writeError", result) }
    }
}

@available(macOS 14.2, *)
struct ApplicationAudioCaptureView: View {
    @StateObject private var capture = ApplicationAudioCaptureController.shared
    @ObservedObject private var routing = ApplicationAudioCaptureController.shared.routing
    @EnvironmentObject private var library: LibraryStore
    @State private var isImporting = false
    @State private var pendingImport: CaptureImportRequest?

    var body: some View {
        AudioRoutingGraphView(store: capture.routing, levels: capture.levels,
                              outputs: capture.outputs, sessionError: capture.errorMessage,
                              refreshDevices: { capture.refresh() }, showNodeSettings: capture.openNodeSettings) {
            sourceControls
        } recorderControls: {
            recordingControls
        }
        .onAppear { capture.refresh() }
        .sheet(item: $pendingImport) { request in
            RequiredImportMetadataView(drafts: request.drafts) { reviewed in
                pendingImport = nil
                isImporting = true
                Task {
                    await library.importFiles([request.url], requiredMetadataOverrides:
                        Dictionary(uniqueKeysWithValues: reviewed.map { ($0.id, $0) }))
                    isImporting = false
                }
            }
        }
    }
    private var sourceControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(L10n.text("capture.source"), selection: $capture.selectedSourceID) {
                Text(L10n.text(capture.sources.isEmpty ? "capture.noSources" : "routing.chooseSource")).tag("")
                ForEach(capture.sources) { Text($0.name).tag($0.id) }
            }
            .labelsHidden().disabled(capture.isRecording || capture.isChoosingDestination)
            HStack(spacing: 6) {
                Button {
                    if capture.isRecording { capture.stop() }
                    else { capture.chooseDestinationAndStart() }
                } label: {
                    Label(L10n.text(capture.isRecording ? "routing.stop" : (routing.document.nodes.contains { $0.kind == .recorder } ? "capture.start" : "routing.start")),
                          systemImage: capture.isRecording ? "stop.fill" : "play.fill")
                }
                .disabled(!capture.isRecording && (capture.sources.isEmpty || capture.selectedSourceID.isEmpty) || isImporting || capture.isChoosingDestination)
                Spacer(minLength: 0)
                Button { capture.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help(L10n.text("capture.refresh")).accessibilityLabel(L10n.text("capture.refresh"))
                    .disabled(capture.isRecording || capture.isChoosingDestination)
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                    .help(L10n.text(capture.sources.isEmpty ? "capture.noSourcesHelp" : "capture.help"))
            }
            ApplicationAudioSessionStatus(levels: capture.levels,
                status: capture.isRecording ? (capture.recordsAudio ? "capture.recording" : "routing.monitoring") : "capture.ready")
        }
    }
    @ViewBuilder private var recordingControls: some View {
        if let node = routing.document.nodes.first(where: { $0.kind == .recorder }) {
            let settings = node.recording ?? AudioRecordingSettings()
            HStack(spacing: 8) {
                Button {
                    capture.chooseRecordingDirectory(settings) { routing.perform(.recording(node.id, $0)) }
                } label: {
                    Label(settings.directoryPath.isEmpty ? L10n.text("recording.chooseFolder") : URL(fileURLWithPath: settings.directoryPath).lastPathComponent, systemImage: "folder")
                        .lineLimit(1).truncationMode(.middle)
                }.disabled(capture.isRecording || capture.isChoosingDestination)
                    .help(settings.directoryPath).accessibilityIdentifier("recording.node-folder")
                Spacer(minLength: 0)
                Button { capture.openNodeSettings(node.id) } label: { Image(systemName: "slider.horizontal.3") }
                    .help(L10n.text("routing.settings")).accessibilityLabel(L10n.text("routing.settings"))
            }
            Text(settings.summary).font(.body).foregroundStyle(.secondary).lineLimit(2)
        }
        if capture.isRecording && capture.recordsAudio {
            ApplicationAudioSessionStatus(levels: capture.levels, status: "capture.recording", showsRecordingIndicator: true)
        }
        if let url = capture.lastRecordingURL {
            Text(url.lastPathComponent).font(.body).lineLimit(1).truncationMode(.middle).help(url.path)
            HStack {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Image(systemName: "folder")
                }.help(L10n.text("capture.reveal")).accessibilityLabel(L10n.text("capture.reveal"))
                Spacer(minLength: 0)
                Button {
                    isImporting = true
                    Task {
                        let drafts = await library.requiredImportMetadata(for: [url])
                        if drafts.isEmpty { await library.importFiles([url]) }
                        else { pendingImport = CaptureImportRequest(url: url, drafts: drafts) }
                        isImporting = false
                    }
                } label: { Image(systemName: "plus") }
                .help(L10n.text("capture.import")).accessibilityLabel(L10n.text("capture.import"))
                .disabled(isImporting || library.isSwitchingLibrary || capture.duration == 0)
            }
        }
    }

}

private struct ApplicationAudioSessionStatus: View {
    let levels: ApplicationAudioLevels
    let status: String
    var showsRecordingIndicator = false
    var body: some View {
        let _ = AudioRoutingRenderDiagnostics.count("clockBody")
        HStack(spacing: 4) {
            if showsRecordingIndicator {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
            Text(L10n.text(status))
            Spacer(minLength: 0)
            Text(Duration.seconds(levels.elapsedSeconds).formatted(.time(pattern: .hourMinuteSecond))).monospacedDigit()
        }.font(.body).foregroundStyle(.secondary)
    }
}

@available(macOS 14.2, *)
struct ApplicationAudioCaptureSidebarStatus: View {
    @ObservedObject private var capture = ApplicationAudioCaptureController.shared
    var body: some View {
        if capture.isRecording {
            Button { capture.stop() } label: {
                Label(L10n.text("routing.stop"), systemImage: "stop.circle")
            }
            .help(L10n.text(capture.recordsAudio ? "capture.recording" : "routing.monitoring"))
        }
    }
}

private struct CaptureImportRequest: Identifiable {
    let id = UUID()
    let url: URL
    let drafts: [RequiredImportMetadataDraft]
}
