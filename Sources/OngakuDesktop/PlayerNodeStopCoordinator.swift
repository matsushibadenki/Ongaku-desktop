import AVFoundation
import Foundation

// The controller retains graph ownership. While a node is retiring, it must not
// schedule, detach, or reconnect that node. Only stop() crosses this boundary.
private final class PlayerNodeStopBatch: @unchecked Sendable {
    let engine: AVAudioEngine
    let files: [AVAudioFile]
    let nodes: [AVAudioPlayerNode]
    let stop: @Sendable (AVAudioPlayerNode) -> Void

    init(engine: AVAudioEngine, files: [AVAudioFile], nodes: [AVAudioPlayerNode],
         stop: @escaping @Sendable (AVAudioPlayerNode) -> Void) {
        self.engine = engine; self.files = files; self.nodes = nodes; self.stop = stop
    }
    func run() { nodes.forEach(stop) }
}

@MainActor
final class PlayerNodeStopCoordinator {
    typealias Execute = (@escaping @Sendable () -> Void) -> Void
    // Match AVAudioPlayerNode's internal work rather than making a UI-priority
    // thread wait on it. MainActor only receives the asynchronous completion.
    nonisolated private static let queue = DispatchQueue(label: "Ongaku.player-node-stop", qos: .default)
    private let execute: Execute
    private let stopNode: @Sendable (AVAudioPlayerNode) -> Void
    private var stopped: Set<ObjectIdentifier>
    private var stopping: Set<ObjectIdentifier> = []
    private var waiters: [(Set<ObjectIdentifier>, () -> Void)] = []
    var isBusy: Bool { !stopping.isEmpty }

    init(nodes: [AVAudioPlayerNode],
         execute: @escaping Execute = { work in queue.async(execute: work) },
         stopNode: @escaping @Sendable (AVAudioPlayerNode) -> Void = { $0.stop() }) {
        stopped = Set(nodes.map(ObjectIdentifier.init))
        self.execute = execute; self.stopNode = stopNode
    }

    func isStopping(_ node: AVAudioPlayerNode) -> Bool { stopping.contains(ObjectIdentifier(node)) }

    func areStopped(_ nodes: [AVAudioPlayerNode]) -> Bool {
        nodes.allSatisfy { stopped.contains(ObjectIdentifier($0)) }
    }

    func willSchedule(_ node: AVAudioPlayerNode) {
        let id = ObjectIdentifier(node)
        precondition(!stopping.contains(id), "Scheduling a node whose stop has not completed")
        stopped.remove(id)
    }

    func stop(_ nodes: [AVAudioPlayerNode], engine: AVAudioEngine,
              retaining files: [AVAudioFile], completion: @escaping () -> Void) {
        let wanted = Set(nodes.map(ObjectIdentifier.init))
        if wanted.isSubset(of: stopped) { completion(); return }
        waiters.append((wanted, completion))
        var selected: Set<ObjectIdentifier> = []
        let work = nodes.filter {
            let id = ObjectIdentifier($0)
            return !stopped.contains(id) && !stopping.contains(id) && selected.insert(id).inserted
        }
        guard !work.isEmpty else { return }
        let ids = Set(work.map(ObjectIdentifier.init))
        stopping.formUnion(ids)
        let batch = PlayerNodeStopBatch(engine: engine, files: files, nodes: work, stop: stopNode)
        execute { [weak self, batch] in
            batch.run()
            Task { @MainActor [weak self] in self?.didStop(ids) }
        }
    }

    private func didStop(_ ids: Set<ObjectIdentifier>) {
        stopping.subtract(ids)
        stopped.formUnion(ids)
        let ready = waiters.filter { $0.0.isSubset(of: stopped) }
        waiters.removeAll { $0.0.isSubset(of: stopped) }
        ready.forEach { $0.1() }
    }
}
