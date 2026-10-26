import Foundation
import Testing
@testable import OngakuDesktop

private final class ChunkSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [DeviceSyncMessage] = []
    private var states: [UUID: DeviceTransferState] = [:]
    private var checkpointValues: [DeviceTransferCheckpointSummary] = []
    private var committedValues: [(DeviceChunkTransferDescriptor, URL, DeviceReceivedLibrarySnapshot?)] = []
    private var callbackValues: [Bool] = []
    private var didStop = false
    func send(_ value: DeviceSyncMessage) { lock.withLock { messages.append(value) } }
    func callback(_ error: Error?) { lock.withLock { callbackValues.append(error == nil) } }
    func record(_ event: DeviceChunkTransferWorker.Event) {
        lock.withLock {
            switch event {
            case .state(_, let value): states[value.id] = value
            case .checkpoints(let values): checkpointValues = values
            case .committed(let descriptor, let url, let snapshot): committedValues.append((descriptor,url,snapshot))
            case .stopped: didStop = true
            case .storageFailure: break
            case .barrier: break
            }
        }
    }
    func state(_ id: UUID) -> DeviceTransferState? { lock.withLock { states[id] } }
    var checkpoints: [DeviceTransferCheckpointSummary] { lock.withLock { checkpointValues } }
    var commits: [(DeviceChunkTransferDescriptor, URL, DeviceReceivedLibrarySnapshot?)] { lock.withLock { committedValues } }
    var callbacks: [Bool] { lock.withLock { callbackValues } }
    var stopped: Bool { lock.withLock { didStop } }
    var offers: [DeviceChunkTransferDescriptor] { lock.withLock { messages.compactMap { if case .chunkOffer(let v) = $0 { v } else { nil } } } }
    var requests: [DeviceChunkRequest] { lock.withLock { messages.compactMap { if case .chunkRequest(let v) = $0 { v } else { nil } } } }
    var payloads: [DeviceChunkPayload] { lock.withLock { messages.compactMap { if case .chunkPayload(let v) = $0 { v } else { nil } } } }
    var completions: [DeviceChunkCompletion] { lock.withLock { messages.compactMap { if case .chunkCompletion(let v) = $0 { v } else { nil } } } }
    var controls: [DeviceTransferControl] { lock.withLock { messages.compactMap { if case .transferControl(let v) = $0 { v } else { nil } } } }
}

/// Tests block only the private I/O executor, never MainActor or the lifecycle
/// actor. Admission barriers, not guessed sleeps, establish control ordering.
private final class ChunkIOGate: @unchecked Sendable {
    let point: DeviceChunkTransferWorker.Point
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var armed = true, enteredValue = false, timeoutValue = false
    init(_ point: DeviceChunkTransferWorker.Point) { self.point = point }
    func hit(_ point: DeviceChunkTransferWorker.Point) {
        let block = lock.withLock { () -> Bool in
            guard armed, self.point == point else { return false }
            armed = false; enteredValue = true; return true
        }
        if block && release.wait(timeout: .now() + 15) == .timedOut {
            lock.withLock { timeoutValue = true }
        }
    }
    func open() { release.signal() }
    var entered: Bool { lock.withLock { enteredValue } }
    var timedOut: Bool { lock.withLock { timeoutValue } }
}

private final class ChunkHarness: @unchecked Sendable {
    let worker: DeviceChunkTransferWorker
    let spy = ChunkSpy()
    let recorder: Task<Void, Never>
    init(checkpoints: URL, destination: DeviceChunkTransferWorker.Destination, gate: ChunkIOGate? = nil,
         canReceive: @escaping @Sendable (Int64) -> Bool = { _ in true },
         forward: @escaping @Sendable (DeviceSyncMessage) throws -> Void = { _ in }) {
        let spy = spy
        let worker = DeviceChunkTransferWorker(checkpointDirectory: checkpoints, destination: destination,
            canReceive: canReceive, beforeIO: { gate?.hit($0) }, send: { message in spy.send(message); try forward(message) })
        self.worker = worker
        let events = worker.events, client = worker.client
        recorder = Task {
            for await event in events {
                if case .barrier(let done) = event { done() }
                else if case .state(let connection, _) = event, !client.isCurrent(connection) { continue }
                else { spy.record(event) }
            }
        }
    }
    var client: DeviceChunkTransferClient { worker.client }
    func admitted() async { await withCheckedContinuation { c in client.submit(.barrier { c.resume() }) } }
    func flush() async { await withCheckedContinuation { c in client.submit(.flush { c.resume() }) } }
    func close() async {
        client.shutdown()
        do { try await chunkWait { self.spy.stopped } } catch { Issue.record("Worker shutdown failed: \(error)") }
        recorder.cancel()
    }
}

private final class ChunkFixture: @unchecked Sendable {
    let root: URL
    let source: URL
    let item: DeviceSyncItem
    private let lock = NSLock()
    private var sessions: [ChunkHarness] = []
    private var gates: [ChunkIOGate] = []
    init(count: Int) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("OngakuChunkActor-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        source = root.appendingPathComponent("source.flac")
        let bytes = Data((0..<count).map { UInt8($0 % 251) })
        try bytes.write(to: source)
        item = .init(id: UUID(), title: "Actor Fixture", artist: "Ongaku", album: "Sync", fileName: "source.flac",
            fileSize: Int64(count), sha256: DeviceChunkTransfer.sha256(bytes), modifiedAt: .now)
    }
    func make(_ name: String = "receiver", gate: ChunkIOGate? = nil,
              destination: DeviceChunkTransferWorker.Destination? = nil,
              canReceive: @escaping @Sendable (Int64) -> Bool = { _ in true },
              forward: @escaping @Sendable (DeviceSyncMessage) throws -> Void = { _ in }) -> ChunkHarness {
        let harness = ChunkHarness(checkpoints: root.appendingPathComponent(name),
            destination: destination ?? .directory(root.appendingPathComponent("incoming")), gate: gate,
            canReceive: canReceive, forward: forward)
        lock.withLock { sessions.append(harness); if let gate { gates.append(gate) } }
        return harness
    }
    func descriptor() throws -> DeviceChunkTransferDescriptor {
        try DeviceChunkTransfer.descriptor(for: item, at: source, direction: .macToPhone, chunkSize: 65_536)
    }
    func payload(_ descriptor: DeviceChunkTransferDescriptor, _ index: Int) throws -> DeviceChunkPayload {
        try DeviceChunkTransfer.payload(descriptor: descriptor, index: index, fileURL: source)
    }
    func cleanup() async {
        let (sessions,gates) = lock.withLock { (sessions,gates) }
        gates.forEach { $0.open() }
        for session in sessions { await session.close() }
        for gate in gates { #expect(!gate.timedOut) }
        try? FileManager.default.removeItem(at: root)
    }
}

private enum ChunkTestError: Error { case timeout }
private func chunkWait(_ condition: @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while !condition() {
        guard ContinuousClock.now < deadline else { throw ChunkTestError.timeout }
        try await Task.sleep(for: .milliseconds(5))
    }
}
private func withChunkFixture(_ count: Int = 150_123, _ body: (ChunkFixture) async throws -> Void) async throws {
    let fixture = try ChunkFixture(count: count)
    do { try await body(fixture) } catch { await fixture.cleanup(); throw error }
    await fixture.cleanup()
}
private func finishChunks(_ fixture: ChunkFixture, _ harness: ChunkHarness, _ descriptor: DeviceChunkTransferDescriptor,
                          startingAt requestNumber: Int = 0) async throws {
    var requestNumber = requestNumber
    while harness.spy.state(descriptor.transferID)?.phase != .completed {
        let expected = requestNumber
        try await chunkWait { harness.spy.requests.count > expected || harness.spy.state(descriptor.transferID)?.phase == .completed }
        if harness.spy.state(descriptor.transferID)?.phase == .completed { return }
        let request = harness.spy.requests[requestNumber]; requestNumber += 1
        guard let index = request.missingIndexes.first else { throw ChunkTestError.timeout }
        harness.client.submit(.payload(try fixture.payload(descriptor,index)))
    }
}

private final class ChunkRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var target: DeviceChunkTransferClient?
    private let legacyOffers: Bool
    init(legacyOffers: Bool = false) { self.legacyOffers = legacyOffers }
    func connect(_ target: DeviceChunkTransferClient) { lock.withLock { self.target = target } }
    func send(_ message: DeviceSyncMessage) throws {
        guard let target = lock.withLock({ target }) else { throw URLError(.networkConnectionLost) }
        // Exercise the actual wire DTO rather than sharing trusted snapshots.
        var wire = message
        if legacyOffers, case .chunkOffer(var descriptor) = wire {
            descriptor.supportsCompactRequests = nil
            wire = .chunkOffer(descriptor)
        }
        let decoded = try JSONDecoder().decode(DeviceSyncMessage.self, from: JSONEncoder().encode(wire))
        switch decoded {
        case .chunkOffer(let v): target.submit(.offer(v))
        case .chunkRequest(let v): target.submit(.request(v))
        case .chunkPayload(let v): target.submit(.payload(v))
        case .chunkCompletion(let v): target.submit(.completion(v))
        case .transferControl(let v): target.submit(.control(v, notifyPeer: false))
        default: break
        }
    }
}

@Suite("Actor-owned chunk transfer", .serialized)
struct ChunkTransferWorkerTests {
    @Test("Pause preparation, resume once, then cancel without reviving the source")
    func pausePreparingSource() async throws {
        try await withChunkFixture { f in
            let gate = ChunkIOGate(.descriptor), id = UUID()
            let h = f.make("sender", gate: gate)
            h.client.submit(.outgoing(id,f.item,f.source,.macToPhone,h.spy.callback))
            try await chunkWait { gate.entered }
            h.client.submit(.control(.init(transferID:id,action:.pause),notifyPeer:true))
            await h.admitted()
            try await chunkWait { h.spy.state(id)?.phase == .paused }
            gate.open(); await h.flush()
            #expect(h.spy.offers.isEmpty)
            h.client.submit(.control(.init(transferID:id,action:.resume),notifyPeer:true))
            try await chunkWait { h.spy.offers.count == 1 }
            h.client.submit(.control(.init(transferID:id,action:.cancel),notifyPeer:true))
            try await chunkWait { h.spy.state(id)?.phase == .cancelled && h.spy.callbacks.count == 1 }
            await h.flush()
            h.client.submit(.outgoing(id,f.item,f.source,.macToPhone,h.spy.callback))
            h.client.submit(.completion(.init(transferID:id,sha256:f.item.sha256)))
            await h.admitted()
            #expect(h.spy.callbacks == [false]); #expect(h.spy.offers.count == 1)
            let verified = try DeviceSyncFileIntegrity.verified(f.source,matches:f.item)
            #expect(verified)
        }
    }
    @Test("Cancel during descriptor I/O never offers and calls completion exactly once")
    func cancelPreparingSource() async throws {
        try await withChunkFixture { f in
            let gate = ChunkIOGate(.descriptor), id = UUID()
            let h = f.make("sender",gate:gate)
            h.client.submit(.outgoing(id,f.item,f.source,.macToPhone,h.spy.callback))
            try await chunkWait { gate.entered }
            h.client.submit(.control(.init(transferID:id,action:.cancel),notifyPeer:true))
            await h.admitted()
            try await chunkWait { h.spy.callbacks.count == 1 }
            gate.open(); await h.flush()
            #expect(h.spy.offers.isEmpty); #expect(h.spy.state(id)?.phase == .cancelled)
            #expect(h.spy.callbacks == [false])
        }
    }
    @Test("A paused read is deferred and rechecked against source bytes on resume")
    func pauseReadingSource() async throws {
        try await withChunkFixture { f in
            let gate = ChunkIOGate(.read), id = UUID()
            let h = f.make("sender",gate:gate)
            h.client.submit(.outgoing(id,f.item,f.source,.macToPhone,h.spy.callback))
            try await chunkWait { h.spy.offers.count == 1 }
            let descriptor = h.spy.offers[0]
            h.client.submit(.request(.init(transferID:id,missingIndexes:descriptor.chunkHashes.indices.map { $0 })))
            try await chunkWait { gate.entered }
            h.client.submit(.control(.init(transferID:id,action:.pause),notifyPeer:true))
            await h.admitted(); gate.open(); await h.flush()
            #expect(h.spy.payloads.isEmpty)
            let handle = try FileHandle(forWritingTo:f.source)
            try handle.write(contentsOf:Data([255])); try handle.close()
            h.client.submit(.control(.init(transferID:id,action:.resume),notifyPeer:true))
            try await chunkWait { h.spy.callbacks.count == 1 }
            if case .failed? = h.spy.state(id)?.phase {} else { Issue.record("Changed source was not rejected") }
            #expect(h.spy.payloads.isEmpty); #expect(h.spy.callbacks == [false])
        }
    }
    @Test("Cancel during checkpoint I/O deletes only the cancelled session's partial")
    func cancelAcceptingChunk() async throws {
        try await withChunkFixture { f in
            let gate = ChunkIOGate(.acceptResult), h = f.make(gate:gate)
            let descriptor = try f.descriptor()
            h.client.submit(.offer(descriptor)); try await chunkWait { h.spy.requests.count == 1 }
            h.client.submit(.payload(try f.payload(descriptor,0)))
            try await chunkWait { gate.entered }
            h.client.submit(.control(.init(transferID:descriptor.transferID,action:.cancel),notifyPeer:true))
            await h.admitted(); gate.open(); await h.flush()
            #expect(h.spy.state(descriptor.transferID)?.phase == .cancelled)
            #expect(h.spy.completions.isEmpty && h.spy.commits.isEmpty)
            #expect(try DeviceTransferCheckpointStore(directory:f.root.appendingPathComponent("receiver")).summaries().isEmpty)
            #expect(h.spy.checkpoints.isEmpty)
        }
    }
    @Test("Pause can persist one requested in-flight chunk but sends no next request")
    func pauseReceiver() async throws {
        try await withChunkFixture { f in
            let gate = ChunkIOGate(.acceptResult), h = f.make(gate:gate)
            let descriptor = try f.descriptor()
            h.client.submit(.offer(descriptor)); try await chunkWait { h.spy.requests.count == 1 }
            h.client.submit(.payload(try f.payload(descriptor,0))); try await chunkWait { gate.entered }
            h.client.submit(.control(.init(transferID:descriptor.transferID,action:.pause),notifyPeer:true))
            await h.admitted(); gate.open(); await h.flush()
            #expect(h.spy.state(descriptor.transferID)?.phase == .paused)
            #expect(h.spy.requests.count == 1)
            h.client.submit(.discardCheckpoints); await h.flush()
            #expect(h.spy.checkpoints.first?.completedBytes == 65_536)
            // An unsolicited second chunk while paused is not persisted.
            h.client.submit(.payload(try f.payload(descriptor,1))); await h.flush()
            #expect(h.spy.checkpoints.first?.completedBytes == 65_536)
            h.client.submit(.control(.init(transferID:descriptor.transferID,action:.resume),notifyPeer:true))
            try await finishChunks(f,h,descriptor,startingAt:1)
            #expect(h.spy.commits.count == 1 && h.spy.completions.count == 1)
        }
    }
    @Test("Pause at verification retains staged data until resume")
    func pauseVerifying() async throws {
        try await withChunkFixture(1000) { f in
            let gate = ChunkIOGate(.stageResult), h = f.make(gate:gate)
            let descriptor = try f.descriptor()
            h.client.submit(.offer(descriptor)); try await chunkWait { h.spy.requests.count == 1 }
            h.client.submit(.payload(try f.payload(descriptor,0))); try await chunkWait { gate.entered }
            h.client.submit(.control(.init(transferID:descriptor.transferID,action:.pause),notifyPeer:true))
            await h.admitted(); gate.open(); await h.flush()
            #expect(h.spy.state(descriptor.transferID)?.phase == .paused)
            #expect(h.spy.commits.isEmpty && h.spy.completions.isEmpty)
            h.client.submit(.control(.init(transferID:descriptor.transferID,action:.resume),notifyPeer:true))
            try await chunkWait { h.spy.state(descriptor.transferID)?.phase == .completed }
            #expect(h.spy.commits.count == 1 && h.spy.completions.count == 1)
        }
    }
    @Test("Cancellation before the commit claim never installs a received file")
    func cancelVerifying() async throws {
        try await withChunkFixture(1000) { f in
            let gate = ChunkIOGate(.stageResult), h = f.make(gate:gate)
            let descriptor = try f.descriptor()
            h.client.submit(.offer(descriptor)); try await chunkWait { h.spy.requests.count == 1 }
            h.client.submit(.payload(try f.payload(descriptor,0))); try await chunkWait { gate.entered }
            h.client.submit(.control(.init(transferID:descriptor.transferID,action:.cancel),notifyPeer:true))
            await h.admitted(); gate.open(); await h.flush()
            #expect(h.spy.state(descriptor.transferID)?.phase == .cancelled)
            #expect(h.spy.commits.isEmpty && h.spy.completions.isEmpty)
            #expect(!FileManager.default.fileExists(atPath:f.root.appendingPathComponent("incoming").path))
            #expect(h.spy.checkpoints.isEmpty)
        }
    }
    @Test("A claimed durable commit wins over late cancel and publishes only once")
    func commitBoundary() async throws {
        try await withChunkFixture(1000) { f in
            let repository = DeviceReceivedLibraryRepository(directory:f.root.appendingPathComponent("library"))
            let gate = ChunkIOGate(.commit), h = f.make(gate:gate,destination:.library(repository))
            let descriptor = try f.descriptor()
            h.client.submit(.offer(descriptor)); try await chunkWait { h.spy.requests.count == 1 }
            h.client.submit(.payload(try f.payload(descriptor,0))); try await chunkWait { gate.entered }
            h.client.submit(.control(.init(transferID:descriptor.transferID,action:.cancel),notifyPeer:true))
            await h.admitted(); gate.open(); await h.flush()
            try await chunkWait { h.spy.state(descriptor.transferID)?.phase == .completed }
            #expect(h.spy.commits.count == 1 && h.spy.completions.count == 1)
            #expect(!h.spy.controls.contains { $0.action == .cancel })
            #expect(try repository.load().items.count == 1)
        }
    }
    @Test("Disconnect retains checkpoint; restart resumes under a new ID and ignores old packets")
    func disconnectRestart() async throws {
        try await withChunkFixture { f in
            let h = f.make(), descriptor = try f.descriptor()
            h.client.submit(.offer(descriptor)); try await chunkWait { h.spy.requests.count == 1 }
            h.client.submit(.payload(try f.payload(descriptor,0)))
            try await chunkWait { h.spy.requests.count == 2 }
            let oldConnection = h.client.connection
            h.client.disconnect()
            #expect(!h.client.isCurrent(oldConnection))
            await h.admitted(); await h.flush()
            h.client.submit(.payload(try f.payload(descriptor,1)),connection:oldConnection)
            await h.admitted(); await h.flush()
            #expect(h.spy.checkpoints.first?.completedBytes == 65_536)
            #expect(h.spy.state(descriptor.transferID)?.phase == .interrupted)
            await h.close()
            let restarted = f.make()
            var resumed = descriptor; resumed.transferID = UUID()
            restarted.client.submit(.offer(resumed))
            try await chunkWait { restarted.spy.requests.count == 1 }
            #expect(restarted.spy.requests[0].missingIndexes == [1])
            #expect(restarted.spy.requests[0].remainingChunkCount == 2)
            #expect(restarted.spy.state(resumed.transferID)?.resumedFromCheckpoint == true)
            try await finishChunks(f,restarted,resumed)
            #expect(restarted.spy.commits.count == 1)
            #expect(try DeviceSyncFileIntegrity.verified(restarted.spy.commits[0].1,matches:f.item))
        }
    }
    @Test("Disconnect while final commit runs keeps the local commit and suppresses old-link acknowledgement")
    func disconnectCommitting() async throws {
        try await withChunkFixture(1000) { f in
            let gate = ChunkIOGate(.commit), h = f.make(gate:gate)
            let descriptor = try f.descriptor()
            h.client.submit(.offer(descriptor)); try await chunkWait { h.spy.requests.count == 1 }
            h.client.submit(.payload(try f.payload(descriptor,0))); try await chunkWait { gate.entered }
            h.client.disconnect(); await h.admitted(); gate.open(); await h.flush()
            try await chunkWait { h.spy.commits.count == 1 }
            #expect(h.spy.completions.isEmpty)
            #expect(try DeviceSyncFileIntegrity.verified(h.spy.commits[0].1,matches:f.item))
        }
    }
    @Test("Finalization failure retains a complete checkpoint for retry")
    func storageRecovery() async throws {
        try await withChunkFixture(1000) { f in
            let blocked = f.root.appendingPathComponent("blocked")
            try Data("file".utf8).write(to:blocked)
            let h = f.make(destination:.directory(blocked)), descriptor = try f.descriptor()
            h.client.submit(.offer(descriptor)); try await chunkWait { h.spy.requests.count == 1 }
            h.client.submit(.payload(try f.payload(descriptor,0)))
            try await chunkWait { if case .failed? = h.spy.state(descriptor.transferID)?.phase { true } else { false } }
            await h.flush()
            #expect(h.spy.commits.isEmpty && h.spy.completions.isEmpty)
            #expect(h.spy.checkpoints.first?.completedBytes == f.item.fileSize)
            await h.close()
            let retry = f.make()
            var resumed = descriptor; resumed.transferID = UUID()
            retry.client.submit(.offer(resumed))
            let resumedID = resumed.transferID
            try await chunkWait { retry.spy.state(resumedID)?.phase == .completed }
            #expect(retry.spy.commits.count == 1)
        }
    }
    @Test("Cancel and immediate reopen do not let stale I/O delete or revive the new session")
    func cancelThenReopen() async throws {
        try await withChunkFixture { f in
            let gate = ChunkIOGate(.accept), h = f.make(gate:gate)
            let first = try f.descriptor()
            h.client.submit(.offer(first)); try await chunkWait { h.spy.requests.count == 1 }
            h.client.submit(.payload(try f.payload(first,0))); try await chunkWait { gate.entered }
            h.client.submit(.control(.init(transferID:first.transferID,action:.cancel),notifyPeer:true))
            var second = first; second.transferID = UUID()
            h.client.submit(.offer(second)); await h.admitted(); gate.open(); await h.flush()
            #expect(h.spy.state(first.transferID)?.phase == .cancelled)
            #expect(h.spy.state(second.transferID)?.bytesTransferred == 0)
            #expect(h.spy.requests.last?.missingIndexes == [0])
            #expect(h.spy.requests.last?.remainingChunkCount == 3)
            try await finishChunks(f,h,second,startingAt:1)
            #expect(h.spy.commits.count == 1)
        }
    }
    @Test("Duplicate offers cannot take an active SHA checkpoint from its owner")
    func duplicateOfferOwnership() async throws {
        try await withChunkFixture { f in
            let h = f.make(), first = try f.descriptor()
            h.client.submit(.offer(first)); try await chunkWait { h.spy.requests.count == 1 }
            h.client.submit(.payload(try f.payload(first,0))); try await chunkWait { h.spy.requests.count == 2 }
            var duplicate = first; duplicate.transferID = UUID()
            h.client.submit(.offer(duplicate)); await h.flush()
            #expect(h.spy.state(first.transferID)?.isActive == true)
            #expect(h.spy.checkpoints.first?.completedBytes == 65_536)
            if case .failed? = h.spy.state(duplicate.transferID)?.phase {} else { Issue.record("Duplicate was not rejected") }
            try await finishChunks(f,h,first,startingAt:1)
            #expect(h.spy.commits.count == 1)
        }
    }
    @Test("Disconnect during preparation invalidates old callbacks even when an ID is reused")
    func disconnectPreparing() async throws {
        try await withChunkFixture { f in
            let gate = ChunkIOGate(.descriptorResult), h = f.make("sender",gate:gate), id = UUID()
            h.client.submit(.outgoing(id,f.item,f.source,.macToPhone,h.spy.callback))
            try await chunkWait { gate.entered }
            let old = h.client.connection
            h.client.disconnect()
            h.client.submit(.outgoing(id,f.item,f.source,.macToPhone,h.spy.callback))
            await h.admitted(); gate.open(); await h.flush()
            #expect(h.spy.callbacks == [false] && h.spy.offers.count == 1)
            h.client.submit(.request(.init(transferID:id,missingIndexes:[0])),connection:old)
            await h.flush(); #expect(h.spy.payloads.isEmpty)
            h.client.submit(.completion(.init(transferID:id,sha256:f.item.sha256)))
            try await chunkWait { h.spy.callbacks == [false,true] }
        }
    }
    @Test("Capacity rejection does not request payload or discard retryable checkpoint data")
    func capacityRejection() async throws {
        try await withChunkFixture { f in
            let h = f.make(canReceive:{ _ in false }), descriptor = try f.descriptor()
            h.client.submit(.offer(descriptor))
            try await chunkWait { h.spy.state(descriptor.transferID)?.phase == .insufficientStorage }
            await h.flush()
            #expect(h.spy.requests.isEmpty && h.spy.commits.isEmpty)
            #expect(h.spy.controls.last?.action == .insufficientStorage)
            #expect(h.spy.checkpoints.count == 1)
        }
    }
    @Test("Send failures finish an outgoing callback once and cannot revive on completion replay")
    func networkFailure() async throws {
        try await withChunkFixture { f in
            let h = f.make("sender",forward:{ _ in throw URLError(.networkConnectionLost) }), id = UUID()
            h.client.submit(.outgoing(id,f.item,f.source,.macToPhone,h.spy.callback))
            try await chunkWait { h.spy.callbacks == [false] }
            h.client.submit(.completion(.init(transferID:id,sha256:f.item.sha256))); await h.flush()
            #expect(h.spy.callbacks == [false])
            if case .failed? = h.spy.state(id)?.phase {} else { Issue.record("Send failure was not reported") }
        }
    }
    @Test("A failed old-connection commit cannot cancel a new link")
    func failedOldCommit() async throws {
        try await withChunkFixture(1000) { f in
            let blocked = f.root.appendingPathComponent("blocked")
            try Data("file".utf8).write(to:blocked)
            let gate = ChunkIOGate(.commit), h = f.make(gate:gate,destination:.directory(blocked))
            let first = try f.descriptor()
            h.client.submit(.offer(first)); try await chunkWait { h.spy.requests.count == 1 }
            h.client.submit(.payload(try f.payload(first,0))); try await chunkWait { gate.entered }
            h.client.disconnect(); await h.admitted(); gate.open(); await h.flush()
            #expect(h.spy.commits.isEmpty && h.spy.completions.isEmpty)
            #expect(!h.spy.controls.contains { $0.action == .cancel })
            #expect(h.spy.checkpoints.first?.completedBytes == f.item.fileSize)
            try FileManager.default.removeItem(at:blocked)
            var second = first; second.transferID = UUID()
            let id = second.transferID
            h.client.submit(.offer(second))
            try await chunkWait { h.spy.state(id)?.phase == .completed }
            #expect(h.spy.completions.map(\.transferID) == [id])
        }
    }
    @Test("Shutdown drains blocked work and finishes callbacks without reviving offers")
    func shutdownBlockedIO() async throws {
        try await withChunkFixture { f in
            let gate = ChunkIOGate(.descriptorResult), h = f.make("sender",gate:gate), id = UUID()
            h.client.submit(.outgoing(id,f.item,f.source,.macToPhone,h.spy.callback))
            try await chunkWait { gate.entered }
            h.client.shutdown()
            try await chunkWait { h.spy.callbacks == [false] }
            gate.open(); await h.close()
            #expect(h.spy.offers.isEmpty && h.spy.payloads.isEmpty)
            #expect(h.spy.stopped)
        }
    }
    @Test("Legacy offers retain full requests and sender progress stays compatible")
    func legacyRequestFallback() async throws {
        try await withChunkFixture(150_123) { f in
            let h = f.make()
            var descriptor = try f.descriptor()
            descriptor.supportsCompactRequests = nil
            h.client.submit(.offer(descriptor))
            try await chunkWait { h.spy.requests.count == 1 }
            #expect(h.spy.requests[0].missingIndexes == [0,1,2])
            #expect(h.spy.requests[0].remainingChunkCount == nil)
            try await finishChunks(f,h,descriptor)
            #expect(h.spy.commits.count == 1)
        }
    }

    @Test("Compact remaining count preserves sender progress and rejects invalid counts")
    func compactSenderProgress() async throws {
        try await withChunkFixture(600_123) { f in
            let h = f.make(), id = UUID()
            h.client.submit(.outgoing(id,f.item,f.source,.macToPhone,nil))
            try await chunkWait { h.spy.offers.count == 1 }
            #expect(h.spy.offers[0].supportsCompactRequests == true)
            h.client.submit(.request(.init(transferID:id,missingIndexes:[0],remainingChunkCount:3)))
            try await chunkWait { h.spy.payloads.count == 1 }
            #expect(h.spy.state(id)?.bytesTransferred == 262_144)
            h.client.submit(.request(.init(transferID:id,missingIndexes:[1,2])))
            try await chunkWait { h.spy.payloads.count == 2 }
            #expect(h.spy.state(id)?.bytesTransferred == 524_288)
            h.client.submit(.request(.init(transferID:id,missingIndexes:[2],remainingChunkCount:0)))
            await h.admitted(); await h.flush()
            if case .failed? = h.spy.state(id)?.phase {} else { Issue.record("Invalid remaining count was not rejected") }
            #expect(h.spy.payloads.count == 2)
        }
    }

    @Test("Whole-file verification cooperates with cancellation without changing the default digest")
    func cooperativeVerification() async throws {
        try await withChunkFixture(2_100_000) { f in
            let digest = try DeviceSyncFileIntegrity.sha256(of:f.source)
            #expect(digest == f.item.sha256)
            var checks = 0
            #expect(throws: CancellationError.self) {
                try DeviceSyncFileIntegrity.verified(f.source,matches:f.item,checkCancellation:{
                    checks += 1
                    if checks == 3 { throw CancellationError() }
                })
            }
            #expect(checks == 3)
            let verified = try DeviceSyncFileIntegrity.verified(f.source,matches:f.item)
            #expect(verified)
        }
    }
    @Test("Encoded loopback completes Mac-directory and mobile durable-library destinations")
    func loopbackParity() async throws {
        for (count,legacy) in [(0,false),(150_123,false),(600_123,false),(600_123,true)] {
            for library in [false,true] {
                try await withChunkFixture(count) { f in
                    let toReceiver = ChunkRelay(legacyOffers:legacy), toSender = ChunkRelay()
                    let destination: DeviceChunkTransferWorker.Destination = library
                        ? .library(DeviceReceivedLibraryRepository(directory:f.root.appendingPathComponent("library")))
                        : .directory(f.root.appendingPathComponent("incoming"))
                    let sender = f.make("sender",forward:toReceiver.send)
                    let receiver = f.make("receiver",destination:destination,forward:toSender.send)
                    toReceiver.connect(receiver.client); toSender.connect(sender.client)
                    let id = UUID()
                    sender.client.submit(.outgoing(id,f.item,f.source,.macToPhone,sender.spy.callback))
                    try await chunkWait { sender.spy.callbacks == [true] && sender.spy.state(id)?.phase == .completed && receiver.spy.commits.count == 1 }
                    #expect(sender.spy.state(id)?.phase == .completed)
                    #expect(try DeviceSyncFileIntegrity.verified(receiver.spy.commits[0].1,matches:f.item))
                    #expect((receiver.spy.commits[0].2 != nil) == library)
                    #expect(receiver.spy.requests.allSatisfy { legacy ? $0.remainingChunkCount == nil : ($0.missingIndexes.count == 1 && $0.remainingChunkCount != nil) })
                    await sender.flush(); await receiver.flush()
                    #expect(receiver.spy.checkpoints.isEmpty)
                }
            }
        }
    }
}
