import AppKit
import Combine
import SwiftUI

struct AudioRecordingSettings: Codable, Equatable, Sendable {
    enum Quality: Int, Codable, CaseIterable, Identifiable, Sendable {
        case pcm16 = 16, pcm24 = 24, float32 = 32
        var id: Int { rawValue }
        var title: String { L10n.text("recording.quality.\(rawValue)") }
    }
    enum Rate: Int, Codable, CaseIterable, Identifiable, Sendable {
        case source = 0, hz44100 = 44100, hz48000 = 48000, hz88200 = 88200, hz96000 = 96000, hz176400 = 176400, hz192000 = 192000
        var id: Int { rawValue }
        var title: String { self == .source ? L10n.text("recording.sourceRate") : "\(Double(rawValue) / 1000) kHz" }
    }
    var directoryBookmark: Data?
    var directoryPath = ""
    var quality: Quality = .float32
    var sampleRate: Rate = .source
    var fileName = ""
    var title = ""
    var artist = ""
    var album = ""
    var genre = ""
    var comment = ""

    var summary: String { "WAV · \(quality.title) · \(sampleRate.title)" }
    func validate() throws {
        guard (directoryBookmark?.count ?? 0) <= 48 * 1024, directoryPath.utf8.count <= 4096,
              [fileName,title,artist,album,genre,comment].allSatisfy({ $0.utf8.count <= 2048 && !$0.contains("\0") })
        else { throw RecordingSettingsError.invalid }
    }
    mutating func selectDirectory(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw RecordingSettingsError.directory }
        directoryBookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        directoryPath = url.path
    }
    func resolveDirectory() throws -> URL {
        guard let directoryBookmark else { throw RecordingSettingsError.directory }
        var stale = false
        // Never silently fall back to a stored path and lose sandbox access.
        return try URL(resolvingBookmarkData: directoryBookmark, options: [.withSecurityScope, .withoutUI],
                       relativeTo: nil, bookmarkDataIsStale: &stale)
    }
    func recordingURL(in directory: URL, source: String, now: Date = Date(), id: UUID = UUID()) -> URL {
        let proposed = [fileName,title,source].first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? "Ongaku"
        let cleaned = proposed.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = String(cleaned.prefix(40))
        let stamp = now.formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
        return directory.appendingPathComponent("\(prefix.isEmpty ? "Ongaku" : prefix) \(stamp) \(id.uuidString.prefix(8)).wav")
    }
    // ID3v2.4 provides Unicode tags to readers that do not expose RIFF INFO.
    var id3Data: Data {
        func size(_ n: Int) -> [UInt8] { [UInt8((n >> 21) & 127), UInt8((n >> 14) & 127), UInt8((n >> 7) & 127), UInt8(n & 127)] }
        var frames = Data()
        for (key,value) in [("TIT2",title),("TPE1",artist),("TALB",album),("TCON",genre),("COMM",comment)] {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            var payload = Data([3]) // UTF-8
            if key == "COMM" { payload.append(contentsOf: [101,110,103,0]) }
            payload.append(contentsOf: text.utf8)
            frames.append(contentsOf: key.utf8); frames.append(contentsOf: size(payload.count))
            frames.append(contentsOf: [0,0]); frames.append(payload)
        }
        guard !frames.isEmpty else { return Data() }
        var data = Data([73,68,51,4,0,0]); data.append(contentsOf: size(frames.count)); data.append(frames)
        return data
    }
    // RIFF LIST/INFO payload, encoded before IO. CoreAudio writes the chunk and
    // updates container lengths; PCM data never passes through Swift.
    var infoData: Data {
        var result = Data("INFO".utf8)
        for (key,value) in [("INAM",title),("IART",artist),("IPRD",album),("IGNR",genre),("ICMT",comment)] {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            var bytes = Data(text.utf8); bytes.append(0)
            result.append(contentsOf: key.utf8)
            var length = UInt32(bytes.count).littleEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(bytes)
            if bytes.count % 2 != 0 { result.append(0) }
        }
        return result.count == 4 ? Data() : result
    }
}

enum RecordingSettingsError: Error, LocalizedError {
    case directory, invalid
    var errorDescription: String? { L10n.text(self == .directory ? "recording.chooseDirectoryFirst" : "recording.invalid") }
}

// All node detail windows use this host. One window per node; the store remains
// the owner of settings. Removing a node also closes its window and subscription.
@MainActor
final class AudioNodeSettingsWindows: NSObject, NSWindowDelegate {
    static let shared = AudioNodeSettingsWindows()
    private var windows: [UUID: NSWindowController] = [:]
    private var subscriptions: [UUID: AnyCancellable] = [:]
    func show<Content: View>(node: AudioRoutingNode, store: AudioRoutingStore, @ViewBuilder content: () -> Content) {
        if let controller = windows[node.id] { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 520,height: node.kind == .recorder ? 600 : 360),
                              styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.title = L10n.format("routing.settingsTitle",node.kind.title)
        window.identifier = NSUserInterfaceItemIdentifier("routing.settings.\(node.id)")
        window.contentMinSize = NSSize(width: 480,height: node.kind == .recorder ? 520 : 280)
        window.appearance = NSApp.mainWindow?.effectiveAppearance
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content())
        window.delegate = self
        let controller = NSWindowController(window: window)
        windows[node.id] = controller
        subscriptions[node.id] = store.$editor.sink { [weak self] editor in
            if !editor.document.nodes.contains(where: { $0.id == node.id }) { self?.close(node.id) }
        }
        window.center(); controller.showWindow(nil); window.makeKeyAndOrderFront(nil)
    }
    func close(_ id: UUID) { windows[id]?.close() }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = windows.first(where: { $0.value.window === window })?.key else { return }
        subscriptions.removeValue(forKey: id); windows.removeValue(forKey: id)
    }
}

@available(macOS 14.2, *)
struct AudioNodeSettingsView: View {
    @ObservedObject var capture: ApplicationAudioCaptureController
    @ObservedObject var store: AudioRoutingStore
    let nodeID: UUID
    @AppStorage(AppAppearanceSettings.defaultsKey) private var appearance = "system"
    var body: some View {
        Group {
            if let node = store.document.nodes.first(where: { $0.id == nodeID }) {
                if node.kind == .recorder {
                    AudioRecordingSettingsView(capture: capture, store: store, node: node)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                Label(node.kind.title,systemImage: node.kind.symbol).font(.title2)
                                if !node.kind.ranges.isEmpty && ![.application, .device].contains(node.kind) {
                                    AudioRoutingParameterView(node: node,store: store)
                                    if [.gain,.lowpass,.delay,.equalizer,.compressor,.limiter].contains(node.kind) {
                                        Toggle(L10n.text("routing.bypass"),isOn: Binding(get: { node.bypassed },set: { store.perform(.bypass(node.id,$0)) }))
                                            .disabled(store.isLocked && !store.canAdjustLive)
                                    }
                                } else if node.kind == .application {
                                    Picker(L10n.text("capture.source"),selection: $capture.selectedSourceID) {
                                        Text(L10n.text("routing.chooseSource")).tag("")
                                        ForEach(capture.sources) { Text($0.name).tag($0.id) }
                                    }.disabled(store.isLocked)
                                    AudioRoutingParameterView(node: node,store: store)
                                        .help(L10n.text("routing.inputBoostHelp"))
                                } else if node.kind == .device {
                                    Picker(L10n.text("routing.device"),selection: Binding(get: { node.deviceUID ?? "" },set: { store.perform(.device(node.id,$0)) })) {
                                        Text(L10n.text("routing.chooseDevice")).tag("")
                                        ForEach(capture.outputs) { Text($0.name).tag($0.id) }
                                    }.disabled(store.isLocked)
                                    Picker(L10n.text("recording.sampleRate"), selection: Binding(
                                        get: { node.outputRate ?? .source },
                                        set: { store.perform(.outputRate(node.id, $0)) }
                                    )) {
                                        ForEach(AudioRecordingSettings.Rate.allCases) { rate in
                                            Text(rate == .source ? L10n.text("routing.deviceCurrentRate") : rate.title).tag(rate)
                                        }
                                    }.disabled(store.isLocked)
                                    AudioRoutingParameterView(node: node,store: store)
                                        .help(L10n.text("routing.monitorVolumeHelp"))
                                } else { Text(L10n.text("routing.noExtraSettings")).foregroundStyle(.secondary) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                        }
                        HStack {
                            Spacer()
                            Button(L10n.text("recording.done")) { AudioNodeSettingsWindows.shared.close(nodeID) }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                    }
                }
            }
        }.background(AppTheme.canvas).preferredColorScheme(AppAppearance(rawValue: appearance)?.colorScheme)
    }
}

@available(macOS 14.2, *)
private struct AudioRecordingSettingsView: View {
    @ObservedObject var capture: ApplicationAudioCaptureController
    @ObservedObject var store: AudioRoutingStore
    let node: AudioRoutingNode
    @State private var draft: AudioRecordingSettings
    @State private var error: String?
    init(capture: ApplicationAudioCaptureController, store: AudioRoutingStore, node: AudioRoutingNode) {
        self.capture = capture; self.store = store; self.node = node
        _draft = State(initialValue: node.recording ?? AudioRecordingSettings())
    }
    var body: some View {
        VStack(spacing: 12) {
            Form {
                Section(L10n.text("recording.destination")) {
                    LabeledContent(L10n.text("recording.folder")) {
                        Button {
                            capture.chooseRecordingDirectory(draft) { draft = $0 }
                        } label: {
                            Label(draft.directoryPath.isEmpty ? L10n.text("recording.chooseFolder") : URL(fileURLWithPath: draft.directoryPath).lastPathComponent,systemImage: "folder")
                                .lineLimit(1).truncationMode(.middle)
                        }.help(draft.directoryPath).accessibilityIdentifier("recording.choose-folder")
                    }
                    TextField(L10n.text("recording.filename"),text: $draft.fileName)
                        .accessibilityIdentifier("recording.filename")
                }
                Section(L10n.text("recording.quality")) {
                    Picker(L10n.text("recording.bitDepth"),selection: $draft.quality) {
                        ForEach(AudioRecordingSettings.Quality.allCases) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("recording.quality")
                    Picker(L10n.text("recording.sampleRate"),selection: $draft.sampleRate) {
                        ForEach(AudioRecordingSettings.Rate.allCases) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("recording.sample-rate")
                    Image(systemName: "info.circle").foregroundStyle(.secondary).help(L10n.text("recording.qualityHelp"))
                }
                Section(L10n.text("recording.metadata")) {
                    TextField(L10n.text("recording.title"),text: $draft.title).accessibilityIdentifier("recording.title")
                    TextField(L10n.text("recording.artist"),text: $draft.artist).accessibilityIdentifier("recording.artist")
                    TextField(L10n.text("recording.album"),text: $draft.album).accessibilityIdentifier("recording.album")
                    TextField(L10n.text("recording.genre"),text: $draft.genre)
                    TextField(L10n.text("recording.comment"),text: $draft.comment,axis: .vertical).lineLimit(2...3)
                }
            }.formStyle(.grouped)
                .disabled(store.isLocked || capture.isChoosingDestination)
            if let message = error ?? capture.errorMessage { Text(message).font(.callout).foregroundStyle(.secondary).padding(.horizontal,20) }
            HStack {
                Button(L10n.text("common.cancel")) { AudioNodeSettingsWindows.shared.close(node.id) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.text("recording.save")) {
                    do {
                        try draft.validate()
                        store.perform(.recording(node.id,draft))
                        if let issue = store.error { error = issue }
                        else { AudioNodeSettingsWindows.shared.close(node.id) }
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(store.isLocked || capture.isChoosingDestination)
                    .accessibilityIdentifier("recording.save")
            }.padding(.horizontal,20).padding(.bottom,16)
        }
        .onChange(of: node.recording) { _, settings in draft = settings ?? AudioRecordingSettings() }
    }
}
