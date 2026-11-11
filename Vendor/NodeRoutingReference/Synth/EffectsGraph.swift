import Foundation

func fxText(_ en: String, _ ja: String, _ zh: String) -> String {
    let language = Locale.preferredLanguages.first ?? "en"
    return language.hasPrefix("ja") ? ja : (language.hasPrefix("zh") ? zh : en)
}

enum EffectKind: Int, Codable, CaseIterable, Identifiable {
    case synth, dimension, sky, time, pedal, ring, studio, mixer, output
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .synth: return "SYNTH/05"
        case .dimension: return "DIMENSION / FLANGE"
        case .sky: return "SKY / REVERB"
        case .time: return "TIME / DELAY"
        case .pedal: return "ECHO / PEDAL"
        case .ring: return "RING / 102"
        case .studio: return "STUDIO / MOD"
        case .mixer: return "MIX / A + B"
        case .output: return "STEREO / OUT"
        }
    }
    var symbol: String {
        switch self {
        case .synth: return "pianokeys"
        case .dimension: return "waveform.path"
        case .sky: return "cloud"
        case .time: return "clock.arrow.circlepath"
        case .pedal: return "guitars"
        case .ring: return "waveform.path.ecg"
        case .studio: return "slider.horizontal.3"
        case .mixer: return "arrow.triangle.merge"
        case .output: return "speaker.wave.2"
        }
    }
    var modes: [String] {
        switch self {
        case .dimension: return ["Dimension", "Flange +", "Flange −"]
        case .sky: return ["Hall", "Plate", "Cloud", "Shimmer"]
        case .time: return ["Digital", "Tape", "Bucket", "Ping-pong"]
        case .pedal: return ["Digital", "Tape", "Reverse", "Loop"]
        case .ring: return ["Sine · Low", "Triangle · Low", "Sine · High", "Triangle · High"]
        case .studio: return ["SC · Chorus", "SC · Flange", "229 · Dynamic"]
        default: return ["Stereo"]
        }
    }
    var reference: String {
        switch self {
        case .dimension: return "Roland Dimension / SBF-325"
        case .sky: return "Strymon BigSky"
        case .time: return "Strymon TimeLine"
        case .pedal: return "Line 6 DL4 MkII"
        case .ring: return "Moog moogerfooger MF-102"
        case .studio: return "t.c. electronic SCF / 2290"
        default: return "UNGE · Audio DAG"
        }
    }
    var controls: [FXControl] {
        switch self {
        case .dimension: return [.init("RATE", "Rate", "速さ", "速率", 0.03, 5, "Hz", true), .init("DEPTH", "Depth", "深さ", "深度"), .init("MANUAL", "Manual delay", "手動ディレイ", "手动延迟", 0.3, 12, "ms"), .init("REGEN", "Feedback", "フィードバック", "反馈", 0, 0.92, ""), .mix]
        case .sky: return [.init("DECAY", "Decay", "残響時間", "衰减时间", 0.4, 24, "s", true), .init("PRE", "Pre-delay", "プリディレイ", "预延迟", 0, 200, "ms"), .init("TONE", "Tone", "トーン", "音色"), .init("MOD", "Modulation", "揺らぎ", "调制"), .mix]
        case .time, .pedal: return [.init("TIME", "Delay time", "ディレイ時間", "延迟时间", 25, 2000, "ms", true), .init("REPEATS", "Repeats", "繰り返し", "重复", 0, 0.94, ""), .init("TONE", "Tone", "トーン", "音色"), .init("MOD", "Modulation", "揺らぎ", "调制"), .mix]
        case .ring: return [.init("FREQ", "Carrier frequency", "キャリア周波数", "载波频率"), .init("LFO", "LFO rate", "LFO速度", "LFO速率", 0.1, 25, "Hz", true), .init("AMOUNT", "LFO amount", "LFO量", "LFO深度"), .init("DRIVE", "Drive", "ドライブ", "驱动", 1, 8, "×"), .mix]
        case .studio: return [.init("RATE", "Rate / delay time", "速度／ディレイ時間", "速率／延迟时间"), .init("DEPTH", "Depth", "深さ", "深度"), .init("TONE", "Tone", "トーン", "音色"), .init("REGEN", "Feedback", "フィードバック", "反馈", 0, 0.92, ""), .mix]
        case .mixer: return [.init("A", "Input A gain", "入力Aのゲイン", "输入A增益"), .init("B", "Input B gain", "入力Bのゲイン", "输入B增益")]
        default: return []
        }
    }
    var defaults: [Float] {
        switch self {
        case .dimension: return [0.35, 0.55, 0.25, 0.4, 0.35]
        case .sky: return [0.53, 0.12, 0.6, 0.3, 0.25]
        case .time, .pedal: return [0.62, 0.42, 0.6, 0.2, 0.25]
        case .ring: return [0.48, 0.25, 0.15, 0.12, 0.4]
        case .studio: return [0.35, 0.5, 0.65, 0.25, 0.3]
        case .mixer: return [0.5, 0.5]
        default: return []
        }
    }
}
struct FXControl {
    let label: String, en: String, ja: String, zh: String
    var lower: Float = 0, upper: Float = 100, unit: String = "%", logarithmic = false
    init(_ label: String, _ en: String, _ ja: String, _ zh: String, _ lower: Float = 0, _ upper: Float = 100, _ unit: String = "%", _ logarithmic: Bool = false) {
        self.label=label; self.en=en; self.ja=ja; self.zh=zh
        self.lower=lower; self.upper=upper; self.unit=unit; self.logarithmic=logarithmic
    }
    static let mix = FXControl("MIX", "Wet / dry", "ウェット／ドライ", "干湿比")
    var title: String { fxText(en, ja, zh) }
    func actual(_ value: Float) -> Float { logarithmic ? lower * powf(upper/lower,value) : lower+(upper-lower)*value }
    func display(_ value: Float) -> String { String(format: actual(value) >= 100 ? "%.0f%@" : "%.2g%@", actual(value), unit) }
}
struct FXSettings: Codable, Equatable {
    var enabled = false
    var mode = 0
    var values: [Float]
    var loopAction = 0
    var loopSerial: UInt32 = 0
    var reverse = false
    var halfSpeed = false
    init(_ kind: EffectKind) { values=kind.defaults }
}

// Native Swift port of UNGE unge-core model.rs / command.rs (MIT).
// Audio is a typed stereo resource; the async UNGE scheduler is deliberately
// replaced with a precompiled, bounded render plan for the real-time callback.
struct FXNode: Codable, Equatable, Identifiable {
    let kind: EffectKind
    var x: Double, y: Double
    var settings: FXSettings
    var id: Int { kind.rawValue }
    var inputs: [String] { kind == .synth ? [] : (kind == .mixer ? ["a", "b"] : ["in"]) }
    var outputs: [String] { kind == .output ? [] : ["out"] }
}
struct FXEdge: Codable, Equatable, Identifiable {
    var from: Int, to: Int
    var port: String
    var id: String { "\(from):out>\(to):\(port)" }
}
struct FXDocument: Codable, Equatable {
    var version = 1
    var nodes: [FXNode]
    var edges: [FXEdge]
    static var initial: Self {
        let nodes=EffectKind.allCases.map { kind in
            FXNode(kind:kind,x:Double(kind.rawValue%3)*240+24,y:Double(kind.rawValue/3)*152+24,settings:FXSettings(kind))
        }
        let chain=[0,1,2,3,4,5,6,8]
        return Self(nodes:nodes,edges:zip(chain,chain.dropFirst()).map { FXEdge(from:$0,to:$1,port:"in") })
    }
    // UNGE Graph::layers: stable Kahn traversal, including disconnected nodes.
    func layers() throws -> [[Int]] {
        var degree=Dictionary(uniqueKeysWithValues:nodes.map { ($0.id,0) })
        for edge in edges { degree[edge.to,default:0] += 1 }
        var ready=degree.keys.filter { degree[$0] == 0 }.sorted()
        var result=[[Int]](), visited=0
        while !ready.isEmpty {
            visited += ready.count; result.append(ready)
            var next=[Int]()
            for id in ready {
                for edge in edges where edge.from == id {
                    degree[edge.to,default:0] -= 1
                    if degree[edge.to] == 0 { next.append(edge.to) }
                }
            }
            ready=next.sorted()
        }
        guard visited == nodes.count else { throw FXGraphError.cycle }
        return result
    }
    func validate() throws {
        guard version == 1, nodes.count == 9, Set(nodes.map(\.id)) == Set(0...8) else { throw FXGraphError.document }
        var occupied=Set<String>(), connections=Set<String>()
        for node in nodes {
            guard node.x.isFinite, node.y.isFinite, (0...700).contains(node.x), (0...480).contains(node.y),
                  node.settings.values.count == node.kind.controls.count,
                  node.settings.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  node.kind.modes.indices.contains(node.settings.mode), (0...4).contains(node.settings.loopAction)
            else { throw FXGraphError.document }
        }
        for edge in edges {
            guard let from=nodes.first(where:{$0.id == edge.from}), let to=nodes.first(where:{$0.id == edge.to}),
                  !from.outputs.isEmpty, to.inputs.contains(edge.port) else { throw FXGraphError.port }
            guard connections.insert(edge.id).inserted else { throw FXGraphError.duplicate }
            guard occupied.insert("\(edge.to):\(edge.port)").inserted else { throw FXGraphError.occupied }
        }
        _ = try layers()
    }
    func configuration() throws -> FXRenderConfiguration {
        try validate()
        var needed=Set([8]), pending=[8]
        while let id=pending.popLast() {
            for edge in edges where edge.to == id {
                if needed.insert(edge.from).inserted { pending.append(edge.from) }
            }
        }
        let ordered=try layers().flatMap{$0}.filter { needed.contains($0) && $0 != 0 }
        let settings=(0...8).map { id in nodes.first(where:{$0.id == id})!.settings }
        let steps=ordered.map { id in
            FXRenderStep(id:id,a:edges.first(where:{$0.to == id && $0.port != "b"})?.from ?? -1,
                         b:edges.first(where:{$0.to == id && $0.port == "b"})?.from ?? -1)
        }
        return FXRenderConfiguration(settings:settings,steps:steps)
    }
}
enum FXGraphError: Error { case document, port, duplicate, occupied, cycle }
struct FXRenderStep: Equatable { let id: Int, a: Int, b: Int }
struct FXRenderConfiguration {
    var settings: [FXSettings]
    var steps: [FXRenderStep]
}
indirect enum FXCommand {
    case connect(FXEdge), disconnect(String), move(Int, Double, Double), settings(Int, FXSettings), batch([FXCommand])
    func apply(to document: inout FXDocument) throws {
        switch self {
        case .connect(let edge): document.edges.append(edge)
        case .disconnect(let id): document.edges.removeAll { $0.id == id }
        case .move(let id,let x,let y):
            guard let index=document.nodes.firstIndex(where:{$0.id == id}) else { throw FXGraphError.document }
            document.nodes[index].x=x; document.nodes[index].y=y
        case .settings(let id,let settings):
            guard let index=document.nodes.firstIndex(where:{$0.id == id}) else { throw FXGraphError.document }
            document.nodes[index].settings=settings
        case .batch(let commands): for command in commands { try command.apply(to:&document) }
        }
    }
}
struct FXEditor {
    private(set) var document: FXDocument
    private var past=[FXDocument](), future=[FXDocument]()
    init(_ document: FXDocument) throws { try document.validate(); self.document=document }
    var canUndo: Bool { !past.isEmpty }; var canRedo: Bool { !future.isEmpty }
    mutating func execute(_ command: FXCommand) throws {
        var next=document
        try command.apply(to:&next); try next.validate()
        guard next != document else { return }
        past.append(document); if past.count > 64 { past.removeFirst() }
        future.removeAll(); document=next
    }
    mutating func undo() { guard let last=past.popLast() else { return }; future.append(document); document=last }
    mutating func redo() { guard let next=future.popLast() else { return }; past.append(document); document=next }
}

final class SharedEffects {
    private let lock=NSLock()
    private var configuration=try! FXDocument.initial.configuration()
    private var loopState=0, loopSeconds: Float=0
    private var document=FXDocument.initial
    func documentSnapshot() -> FXDocument { lock.lock();defer { lock.unlock() };return document }
    func set(_ next: FXRenderConfiguration, document: FXDocument? = nil) {
        lock.lock()
        var next=next
        next.settings[4].loopSerial=configuration.settings[4].loopSerial
        next.settings[4].loopAction=configuration.settings[4].loopAction
        configuration=next
        if let document { self.document=document }
        lock.unlock()
    }
    func sendLoop(_ action: Int) {
        lock.lock(); configuration.settings[4].loopSerial &+= 1
        configuration.settings[4].loopAction=action; lock.unlock()
    }
    func resetLoop() {
        lock.lock(); configuration.settings[4].loopSerial=0; configuration.settings[4].loopAction=0
        loopState=0; loopSeconds=0; lock.unlock()
    }
    func trySnapshot() -> FXRenderConfiguration? {
        guard lock.try() else { return nil }; defer { lock.unlock() }; return configuration
    }
    func reportLoop(state: Int,seconds: Float) {
        guard lock.try() else { return }; loopState=state; loopSeconds=seconds; lock.unlock()
    }
    func readLoop() -> (Int,Float) { lock.lock(); defer { lock.unlock() }; return (loopState,loopSeconds) }
}
