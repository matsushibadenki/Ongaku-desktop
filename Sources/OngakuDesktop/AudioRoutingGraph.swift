import Combine
import Foundation
#if canImport(OngakuAudioDSP)
import OngakuAudioDSP
#endif

// Adapted from Synth EffectsGraph.swift and UNGE model.rs / command.rs (MIT).
// See Vendor/NodeRoutingReference for original sources and adaptation boundaries.
enum AudioRoutingKind: Int, Codable, CaseIterable, Identifiable, Sendable {
    case application, gain, lowpass, delay, mixer, meter, recorder, device, waveform, equalizer, compressor, limiter
    var id: Int { rawValue }
    var title: String { L10n.text("routing.node.\(rawValue)") }
    var symbol: String {
        switch self {
        case .application: "app"
        case .gain: "slider.horizontal.3"
        case .lowpass: "line.diagonal"
        case .delay: "clock.arrow.circlepath"
        case .mixer: "arrow.triangle.merge"
        case .meter: "waveform.path"
        case .waveform: "waveform"
        case .equalizer: "slider.vertical.3"
        case .compressor: "waveform.path.ecg"
        case .limiter: "waveform.badge.minus"
        case .recorder: "record.circle"
        case .device: "speaker.wave.2"
        }
    }
    var inputs: [String] { self == .application ? [] : self == .mixer ? ["a", "b"] : ["in"] }
    var isSink: Bool { self == .recorder || self == .device }
    var hasOutput: Bool { !isSink }
    var defaults: [Double] {
        switch self {
        case .application, .gain, .device: [1]
        case .equalizer: Array(repeating: 0, count: 10)
        case .limiter: [-1, 100]
        case .compressor: [-18, 4, 10, 100, 0]
        case .lowpass: [8000]
        case .delay: [250, 0.25, 0.35]
        case .mixer: [0.5, 0.5]
        default: []
        }
    }
    var ranges: [ClosedRange<Double>] {
        switch self {
        case .application: [1...10]
        case .gain: [0...10]
        case .equalizer: Array(repeating: -12...12, count: 10)
        case .limiter: [-24...0, 10...1000]
        case .compressor: [-60...0, 1...20, 1...100, 10...1000, 0...24]
        case .device: [0...1]
        case .lowpass: [20...20000]
        case .delay: [1...2000, 0...0.9, 0...1]
        case .mixer: [0...1, 0...1]
        default: []
        }
    }
    static let equalizerBandLabels = ["31", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    var parameterKeys: [String] {
        switch self {
        case .application: ["routing.inputBoost"]
        case .gain: ["routing.gain"]
        case .limiter: ["routing.ceiling", "routing.release"]
        case .compressor: ["routing.threshold", "routing.ratio", "routing.attack", "routing.release", "routing.makeup"]
        case .device: ["routing.monitorVolume"]
        case .lowpass: ["routing.cutoff"]
        case .delay: ["routing.time", "routing.feedback", "routing.mix"]
        case .mixer: ["routing.inputA", "routing.inputB"]
        default: []
        }
    }
}

struct AudioRoutingNode: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    let kind: AudioRoutingKind
    var x: Double
    var y: Double
    var parameters: [Double]
    var deviceUID: String?
    var outputRate: AudioRecordingSettings.Rate?
    var recording: AudioRecordingSettings?
    var bypassed = false
    init(kind: AudioRoutingKind, x: Double, y: Double) {
        self.kind = kind; self.x = x; self.y = y; parameters = kind.defaults
    }
    private enum CodingKeys: String, CodingKey { case id,kind,x,y,parameters,deviceUID,outputRate,recording,bypassed }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self,forKey: .id)
        kind = try c.decode(AudioRoutingKind.self,forKey: .kind)
        x = try c.decode(Double.self,forKey: .x); y = try c.decode(Double.self,forKey: .y)
        parameters = try c.decode([Double].self,forKey: .parameters)
        // Earlier source/output nodes had no controls and used unity gain.
        if [.application, .device].contains(kind) && parameters.isEmpty { parameters = [1] }
        deviceUID = try c.decodeIfPresent(String.self,forKey: .deviceUID)
        outputRate = try c.decodeIfPresent(AudioRecordingSettings.Rate.self, forKey: .outputRate)
        recording = try c.decodeIfPresent(AudioRecordingSettings.self,forKey: .recording)
        bypassed = try c.decodeIfPresent(Bool.self,forKey: .bypassed) ?? false
    }
}
struct AudioRoutingEdge: Codable, Equatable, Identifiable, Sendable {
    let from: UUID
    let to: UUID
    let port: String
    var id: String { "\(from):out>\(to):\(port)" }
}
// A concrete terminal, including mixer A/B. Drag direction does not change
// signal direction: an edge always runs from output to input.
struct AudioRoutingPort: Equatable, Sendable {
    let nodeID: UUID
    let isOutput: Bool
    let name: String
    func connection(to other: Self) throws -> AudioRoutingEdge {
        guard nodeID != other.nodeID, isOutput != other.isOutput else { throw AudioRoutingError.port }
        let output = isOutput ? self : other, input = isOutput ? other : self
        return AudioRoutingEdge(from: output.nodeID, to: input.nodeID, port: input.name)
    }
    func connections(in document: AudioRoutingDocument) -> [AudioRoutingEdge] {
        document.edges.filter { isOutput ? $0.from == nodeID : $0.to == nodeID && $0.port == name }
    }
}
enum AudioRoutingError: String, Error, LocalizedError {
    case document, port, occupied, cycle, disconnected, revision, locked, persistence, device
    var errorDescription: String? { L10n.text("routing.error.\(rawValue)") }
}
struct AudioRoutingDocument: Codable, Equatable, Sendable {
    var version = 1
    var nodes: [AudioRoutingNode]
    var edges: [AudioRoutingEdge]
    static var initial: Self {
        let input = AudioRoutingNode(kind: .application, x: 24, y: 60)
        let gain = AudioRoutingNode(kind: .gain, x: 264, y: 60)
        let meter = AudioRoutingNode(kind: .meter, x: 504, y: 60)
        let output = AudioRoutingNode(kind: .recorder, x: 744, y: 60)
        return Self(nodes: [input, gain, meter, output], edges: [
            .init(from: input.id, to: gain.id, port: "in"),
            .init(from: gain.id, to: meter.id, port: "in"),
            .init(from: meter.id, to: output.id, port: "in")
        ])
    }
    static var parallel: Self {
        let source = AudioRoutingNode(kind: .application, x: 24, y: 180)
        let gain = AudioRoutingNode(kind: .gain, x: 264, y: 60)
        let delay = AudioRoutingNode(kind: .delay, x: 264, y: 300)
        let mixer = AudioRoutingNode(kind: .mixer, x: 504, y: 180)
        let meter = AudioRoutingNode(kind: .meter, x: 744, y: 180)
        let sink = AudioRoutingNode(kind: .recorder, x: 984, y: 180)
        return Self(nodes: [source, gain, delay, mixer, meter, sink], edges: [
            .init(from: source.id, to: gain.id, port: "in"),
            .init(from: source.id, to: delay.id, port: "in"),
            .init(from: gain.id, to: mixer.id, port: "a"),
            .init(from: delay.id, to: mixer.id, port: "b"),
            .init(from: mixer.id, to: meter.id, port: "in"),
            .init(from: meter.id, to: sink.id, port: "in")
        ])
    }
    static var monitoring: Self {
        var doc = initial
        let old = doc.nodes.removeLast()
        let output = AudioRoutingNode(kind: .device, x: old.x, y: old.y)
        doc.edges = doc.edges.map { .init(from: $0.from, to: $0.to == old.id ? output.id : $0.to, port: $0.port) }
        doc.nodes.append(output)
        return doc
    }
    static var recordingAndMonitoring: Self {
        var doc = initial
        let output = AudioRoutingNode(kind: .device,x: 744,y: 300)
        doc.nodes.append(output)
        doc.edges.append(.init(from: doc.nodes[2].id,to: output.id,port: "in"))
        return doc
    }
    // Add the other destination at the same pre-sink signal. Never route a
    // recorder through the monitoring gain or change existing recording settings.
    func addingNode(_ node: AudioRoutingNode) -> AudioRoutingCommand {
        guard node.kind.isSink,
              let other = nodes.first(where: { $0.kind.isSink && $0.kind != node.kind }),
              let edge = edges.first(where: { $0.to == other.id && $0.port == "in" }) else { return .add(node) }
        return .batch([.add(node),.connect(.init(from: edge.from,to: node.id,port: "in"))])
    }
    // Stable Kahn traversal ported through Synth from UNGE Graph::layers.
    func orderedIDs() throws -> [UUID] {
        guard Set(nodes.map(\.id)).count == nodes.count else { throw AudioRoutingError.document }
        var degree = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, 0) })
        for edge in edges { degree[edge.to, default: 0] += 1 }
        var ready = nodes.filter { degree[$0.id] == 0 }.map(\.id)
        var result: [UUID] = []
        while !ready.isEmpty {
            let id = ready.removeFirst(); result.append(id)
            for edge in edges where edge.from == id {
                degree[edge.to, default: 0] -= 1
                if degree[edge.to] == 0 { ready.append(edge.to) }
            }
        }
        guard result.count == nodes.count else { throw AudioRoutingError.cycle }
        return result
    }
    func validate() throws {
        guard version == 1, (2...16).contains(nodes.count), edges.count <= 32,
              Set(nodes.map(\.id)).count == nodes.count,
              nodes.filter({ $0.kind == .application }).count == 1,
              nodes.filter({ $0.kind == .recorder }).count <= 1,
              nodes.filter({ $0.kind == .device }).count <= 1,
              nodes.contains(where: { $0.kind.isSink }) else { throw AudioRoutingError.document }
        for node in nodes {
            if let settings = node.recording {
                guard node.kind == .recorder else { throw AudioRoutingError.document }
                try settings.validate()
            }
            guard node.x.isFinite, node.y.isFinite, (0...2200).contains(node.x), (0...1400).contains(node.y),
                  node.parameters.count == node.kind.ranges.count,
                  zip(node.parameters, node.kind.ranges).allSatisfy({ $0.isFinite && $1.contains($0) }),
                  ![.application, .recorder, .device, .mixer, .meter, .waveform].contains(node.kind) || !node.bypassed
            else { throw AudioRoutingError.document }
        }
        var occupied = Set<String>()
        for edge in edges {
            guard let from = nodes.first(where: { $0.id == edge.from }),
                  let to = nodes.first(where: { $0.id == edge.to }),
                  from.kind.hasOutput, to.kind.inputs.contains(edge.port) else { throw AudioRoutingError.port }
            guard occupied.insert("\(edge.to):\(edge.port)").inserted else { throw AudioRoutingError.occupied }
        }
        _ = try orderedIDs()
    }
    func plan() throws -> AudioRoutingPlan {
        try validate()
        let sinks = nodes.filter { $0.kind.isSink }
        let source = nodes.first { $0.kind == .application }!
        var needed = Set(sinks.map(\.id)), pending = sinks.map(\.id)
        while let id = pending.popLast() {
            for edge in edges where edge.to == id {
                if needed.insert(edge.from).inserted { pending.append(edge.from) }
            }
        }
        guard needed.contains(source.id) else { throw AudioRoutingError.disconnected }
        // Every active processor input must be connected. A partial graph remains
        // editable, but cannot silently record a broken or half-wired route.
        for node in nodes where needed.contains(node.id) {
            guard node.kind.inputs.allSatisfy({ port in edges.contains { $0.to == node.id && $0.port == port } })
            else { throw AudioRoutingError.disconnected }
        }
        let order = try orderedIDs().filter { needed.contains($0) }
        let steps = order.map { id -> AudioRoutingStep in
            let node = nodes.first { $0.id == id }!
            func upstream(_ port: String) -> Int32 {
                guard let edge = edges.first(where: { $0.to == id && $0.port == port }),
                      let index = order.firstIndex(of: edge.from) else { return -1 }
                return Int32(index)
            }
            return AudioRoutingStep(id: id, kind: node.kind, inputA: upstream(node.kind == .mixer ? "a" : "in"),
                                    inputB: upstream("b"), parameters: node.parameters, bypassed: node.bypassed)
        }
        return AudioRoutingPlan(steps: steps)
    }
}
struct AudioRoutingStep: Equatable, Sendable {
    let id: UUID
    let kind: AudioRoutingKind
    let inputA: Int32
    let inputB: Int32
    let parameters: [Double]
    let bypassed: Bool
}
struct AudioRoutingPlan: Equatable, Sendable {
    let steps: [AudioRoutingStep]
    var records: Bool { steps.contains { $0.kind == .recorder } }
    var monitors: Bool { steps.contains { $0.kind == .device } }
    var nativeSteps: [OngakuAudioRouteStep] {
        steps.map { step in
            var result = OngakuAudioRouteStep()
            result.kind = UInt32(step.kind.rawValue)
            result.inputA = step.inputA; result.inputB = step.inputB
            result.bypassed = ObjCBool(step.bypassed)
            result.p0 = Float(step.parameters.first ?? 0)
            result.p1 = Float(step.parameters.dropFirst().first ?? 0)
            result.p2 = Float(step.parameters.dropFirst(2).first ?? 0)
            if step.kind == .compressor {
                result.p3 = Float(step.parameters[3])
                result.p4 = Float(step.parameters[4])
            }
            if step.kind == .equalizer {
                withUnsafeMutableBytes(of: &result.eqGains) { bytes in
                    let gains = bytes.bindMemory(to: Float.self)
                    for (index, gain) in step.parameters.enumerated() { gains[index] = Float(gain) }
                }
            }
            return result
        }
    }
}
indirect enum AudioRoutingCommand {
    case add(AudioRoutingNode), remove(UUID), connect(AudioRoutingEdge), disconnect(String)
    case move(UUID, Double, Double), parameters(UUID, [Double]), bypass(UUID, Bool), device(UUID, String)
    case batch([AudioRoutingCommand]), replace(AudioRoutingDocument)
    case outputRate(UUID, AudioRecordingSettings.Rate)
    case recording(UUID, AudioRecordingSettings)
    var adjustsParametersOnly: Bool {
        switch self {
        case .parameters, .bypass: true
        default: false
        }
    }
    var changesPositionOnly: Bool {
        if case .move = self { return true }
        return false
    }
    func apply(to document: inout AudioRoutingDocument) throws {
        switch self {
        case .add(let node): document.nodes.append(node)
        case .remove(let id):
            guard let node = document.nodes.first(where: { $0.id == id }),
                  node.kind != .application else { throw AudioRoutingError.document }
            document.nodes.removeAll { $0.id == id }; document.edges.removeAll { $0.from == id || $0.to == id }
        case .connect(let edge): document.edges.append(edge)
        case .disconnect(let id): document.edges.removeAll { $0.id == id }
        case .move(let id, let x, let y):
            guard let i = document.nodes.firstIndex(where: { $0.id == id }) else { throw AudioRoutingError.document }
            document.nodes[i].x = x; document.nodes[i].y = y
        case .parameters(let id, let parameters):
            guard let i = document.nodes.firstIndex(where: { $0.id == id }) else { throw AudioRoutingError.document }
            document.nodes[i].parameters = parameters
        case .bypass(let id, let bypass):
            guard let i = document.nodes.firstIndex(where: { $0.id == id }) else { throw AudioRoutingError.document }
            document.nodes[i].bypassed = bypass
        case .recording(let id, let settings):
            guard let i = document.nodes.firstIndex(where: { $0.id == id }), document.nodes[i].kind == .recorder else { throw AudioRoutingError.document }
            try settings.validate(); document.nodes[i].recording = settings
        case .outputRate(let id, let rate):
            guard let i = document.nodes.firstIndex(where: { $0.id == id && $0.kind == .device }) else { throw AudioRoutingError.document }
            document.nodes[i].outputRate = rate
        case .device(let id, let uid):
            guard let i = document.nodes.firstIndex(where: { $0.id == id }), document.nodes[i].kind == .device, !uid.isEmpty, uid.utf8.count <= 1024 else { throw AudioRoutingError.document }
            document.nodes[i].deviceUID = uid
        case .batch(let commands): for command in commands { try command.apply(to: &document) }
        case .replace(let value): document = value
        }
    }
}
struct AudioRoutingEditor {
    private(set) var document: AudioRoutingDocument
    private(set) var revision: UInt64 = 0
    private var past: [AudioRoutingDocument] = [], future: [AudioRoutingDocument] = []
    init(_ document: AudioRoutingDocument) throws { try document.validate(); self.document = document }
    var canUndo: Bool { !past.isEmpty }; var canRedo: Bool { !future.isEmpty }
    mutating func execute(_ command: AudioRoutingCommand, expectedRevision: UInt64) throws {
        guard revision == expectedRevision else { throw AudioRoutingError.revision }
        var next = document
        try command.apply(to: &next); try next.validate()
        guard next != document else { return }
        past.append(document); if past.count > 64 { past.removeFirst() }
        future.removeAll(); document = next; revision &+= 1
    }
    mutating func undo() { guard let last = past.popLast() else { return }; future.append(document); document = last; revision &+= 1 }
    mutating func redo() { guard let next = future.popLast() else { return }; past.append(document); document = next; revision &+= 1 }
}

@MainActor
final class AudioRoutingStore: ObservableObject {
    @Published private(set) var editor: AudioRoutingEditor
    @Published private(set) var error: String?
    @Published private(set) var isLocked = false
    @Published private(set) var canAdjustLive = false
    private var liveUpdate: ((AudioRoutingDocument) throws -> Void)?
    private var parameterPreview: (id: UUID, values: [Double])?
    private let defaults: UserDefaults
    private let key = "applicationAudio.routing.v1"
    var document: AudioRoutingDocument { editor.document }
    private(set) var hasCompleteRoute: Bool
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var document = AudioRoutingDocument.initial
        var loadError: String?
        if let data = defaults.data(forKey: key) {
            do {
                guard data.count <= 128 * 1024 else { throw AudioRoutingError.document }
                let saved = try JSONDecoder().decode(AudioRoutingDocument.self, from: data)
                try saved.validate(); document = saved
            } catch { loadError = L10n.text("routing.error.persistence") }
        }
        hasCompleteRoute = (try? document.plan()) != nil
        editor = try! AudioRoutingEditor(document)
        error = loadError
    }
    func setLocked(_ locked: Bool) { isLocked = locked }
    func setLiveUpdate(_ update: ((AudioRoutingDocument) throws -> Void)?) {
        finishParameterEdit()
        liveUpdate = update
        canAdjustLive = update != nil
    }
    // The UI keeps its own slider draft. Only the DSP receives pointer-frequency
    // previews; persistence, graph publication and Undo occur once on release.
    @discardableResult
    func previewParameters(_ id: UUID, _ values: [Double]) -> Bool {
        guard isLocked, let liveUpdate else { return false }
        if let preview = parameterPreview, preview.id != id { finishParameterEdit() }
        do {
            var next = document
            try AudioRoutingCommand.parameters(id, values).apply(to: &next)
            try next.validate()
            try liveUpdate(next)
            parameterPreview = (id, values)
            if error != nil { error = nil }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func finishParameterEdit() {
        guard let preview = parameterPreview else { return }
        parameterPreview = nil
        perform(.parameters(preview.id, preview.values))
    }
    func perform(_ command: AudioRoutingCommand, revision: UInt64? = nil) {
        finishParameterEdit()
        guard !isLocked || command.changesPositionOnly || (canAdjustLive && command.adjustsParametersOnly) else {
            error = AudioRoutingError.locked.localizedDescription; return
        }
        do {
            var next = editor
            try next.execute(command, expectedRevision: revision ?? editor.revision)
            try commit(next, updatesAudio: !command.changesPositionOnly)
        } catch { self.error = error.localizedDescription }
    }
    func undo() { guard !isLocked else { return }; var next = editor; next.undo(); save(next) }
    func redo() { guard !isLocked else { return }; var next = editor; next.redo(); save(next) }
    private func save(_ next: AudioRoutingEditor) {
        do { try commit(next) } catch { self.error = error.localizedDescription }
    }
    private func commit(_ next: AudioRoutingEditor, updatesAudio: Bool = true) throws {
        let data = try JSONEncoder().encode(next.document)
        guard data.count <= 128 * 1024 else { throw AudioRoutingError.document }
        // Layout edits never publish DSP controls or recompile the active plan.
        if isLocked && updatesAudio { try liveUpdate?(next.document) }
        defaults.set(data, forKey: key)
        if updatesAudio { hasCompleteRoute = (try? next.document.plan()) != nil }
        editor = next; error = nil
    }
}
