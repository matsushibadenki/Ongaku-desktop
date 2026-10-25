import Foundation
@preconcurrency import MultipeerConnectivity

/// Transport-only adapter. It owns no UI or transfer dictionaries. MCSession
/// sends were already performed off-main; each send gets a private encoder.
final class DeviceChunkSessionSender: @unchecked Sendable {
    private let session: MCSession
    init(_ session: MCSession) { self.session = session }
    func send(_ message: DeviceSyncMessage) throws {
        let peers = session.connectedPeers
        guard !peers.isEmpty else { throw URLError(.networkConnectionLost) }
        try session.send(JSONEncoder().encode(message), toPeers: peers, with: .reliable)
    }
}

/// A connection mailbox, not transfer state. Synchronous submission stamps the
/// physical connection before a delegate/UI task can be delayed or reordered.
final class DeviceChunkTransferClient: @unchecked Sendable {
    private let lock = NSLock()
    private var context: UUID
    private var closed = false
    private let input: AsyncStream<DeviceChunkTransferWorker.Message>.Continuation
    fileprivate init(context: UUID, input: AsyncStream<DeviceChunkTransferWorker.Message>.Continuation) {
        self.context = context; self.input = input
    }
    var connection: UUID { lock.lock(); defer { lock.unlock() }; return context }
    func isCurrent(_ value: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }; return !closed && value == context
    }
    func submit(_ command: DeviceChunkTransferWorker.Command, connection expected: UUID? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, expected == nil || expected == context else { return }
        input.yield(.command(context, command))
    }
    func disconnect() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        let previous = context; context = UUID()
        input.yield(.disconnect(previous, context))
    }
    func shutdown() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        input.yield(.shutdown)
    }
}

private final class ChunkCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

actor DeviceChunkTransferWorker {
    enum Destination: Sendable {
        case directory(URL)
        case library(DeviceReceivedLibraryRepository)
    }
    enum Point: Equatable, Sendable { case descriptor, read, accept, stage, commit, descriptorResult, acceptResult, stageResult }
    enum Command: Sendable {
        case outgoing(UUID, DeviceSyncItem, URL, DeviceSyncDirection, (@Sendable (Error?) -> Void)?)
        case offer(DeviceChunkTransferDescriptor)
        case request(DeviceChunkRequest)
        case payload(DeviceChunkPayload)
        case completion(DeviceChunkCompletion)
        case control(DeviceTransferControl, notifyPeer: Bool)
        case refresh(removingStale: Bool)
        case discardCheckpoints
        case barrier(@Sendable () -> Void)
        case flush(@Sendable () -> Void)
    }
    enum Event: Sendable {
        case state(UUID, DeviceTransferState)
        case checkpoints([DeviceTransferCheckpointSummary])
        case committed(DeviceChunkTransferDescriptor, URL, DeviceReceivedLibrarySnapshot?)
        case storageFailure(String)
        case stopped
        case barrier(@Sendable () -> Void)
    }
    fileprivate struct Ticket: Hashable, Sendable {
        let context: UUID
        let id: UUID
        let token: UUID
    }
    fileprivate enum Reply: Sendable {
        case outgoing(Ticket, Result<ValidatedDeviceChunkTransferDescriptor, Error>)
        case prepared(Ticket, Result<DeviceTransferCheckpoint, Error>)
        case read(Ticket, DeviceChunkRequest, Result<DeviceChunkPayload, Error>)
        case accepted(Ticket, Result<DeviceTransferCheckpoint, Error>)
        case staged(Ticket, Result<URL, Error>)
        case committed(Ticket, Result<DiskCommit, Error>)
        case released(String?, Bool, Result<Void, Error>)
        case refreshed(Result<[DeviceTransferCheckpointSummary], Error>)
        case stopped
    }
    fileprivate enum Message: Sendable {
        case command(UUID, Command)
        case disconnect(UUID, UUID)
        case reply(Reply)
        case shutdown
    }
    fileprivate struct DiskCommit: Sendable {
        let url: URL
        let snapshot: DeviceReceivedLibrarySnapshot?
    }
    private struct Entry {
        let ticket: Ticket
        let cancellation: ChunkCancellation
        var state: DeviceTransferState
        let receiving: Bool
        var descriptor: DeviceChunkTransferDescriptor?
        var checkpoint: DeviceTransferCheckpoint?
        var pendingRequest: DeviceChunkRequest?
        var awaitingIndex: Int?
        var staged: URL?
        var busy = true
        var paused = false
        var offered = false
        var committing = false
        var completion: (@Sendable (Error?) -> Void)?
    }
    nonisolated let client: DeviceChunkTransferClient
    nonisolated let events: AsyncStream<Event>
    private let input: AsyncStream<Message>.Continuation
    private let output: AsyncStream<Event>.Continuation
    private let disk: DeviceChunkTransferDisk
    private let send: @Sendable (DeviceSyncMessage) throws -> Void
    private var context: UUID
    private var entries: [UUID: Entry] = [:]
    private var closedIDs: Set<UUID> = []
    private var summaries: [String: DeviceTransferCheckpointSummary] = [:]
    private var removing: Set<String> = []
    private var closing = false
    private var pendingDisk = 0
    private var flushWaiters: [@Sendable () -> Void] = []

    init(checkpointDirectory: URL, destination: Destination,
         canReceive: @escaping @Sendable (Int64) -> Bool = DeviceChunkTransferWorker.capacityAvailable,
         beforeIO: @escaping @Sendable (Point) -> Void = { _ in },
         send: @escaping @Sendable (DeviceSyncMessage) throws -> Void) {
        let commands = AsyncStream<Message>.makeStream()
        let updates = AsyncStream<Event>.makeStream()
        let context = UUID()
        self.context = context; self.send = send
        input = commands.continuation; output = updates.continuation; events = updates.stream
        client = DeviceChunkTransferClient(context: context, input: commands.continuation)
        disk = DeviceChunkTransferDisk(directory: checkpointDirectory, destination: destination,
            canReceive: canReceive, beforeIO: beforeIO, output: commands.continuation)
        Task { await self.run(commands.stream) }
    }
    nonisolated static func capacityAvailable(_ bytes: Int64) -> Bool {
        let url = FileManager.default.temporaryDirectory
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]),
              let available = values.volumeAvailableCapacityForImportantUsage
                ?? values.volumeAvailableCapacity.map(Int64.init) else { return true }
        return DeviceTransferCapacity.canReceive(fileSize: bytes, availableBytes: available)
    }
    private func run(_ stream: AsyncStream<Message>) async {
        for await message in stream {
            switch message {
            case .command(let connection, let command):
                guard !closing, connection == context else { continue }
                handle(command)
            case .disconnect(let previous, let next):
                guard !closing, previous == context else { continue }
                context = next
                interrupt()
            case .reply(let reply):
                pendingDisk = max(0, pendingDisk - 1)
                finish(reply)
                if pendingDisk == 0 {
                    let waiters = flushWaiters; flushWaiters.removeAll()
                    waiters.forEach { output.yield(.barrier($0)) }
                }
            case .shutdown:
                closing = true; interrupt(); submitDisk(.shutdown)
            }
        }
    }
    private func submitDisk(_ job: DeviceChunkTransferDisk.Job) {
        if disk.submit(job) { pendingDisk += 1 }
    }
    private func state(_ entry: Entry) {
        // Confirmed terminal history remains publishable across a physical
        // disconnect; old active progress is fenced by its connection context.
        output.yield(.state(entry.state.isActive ? context : client.connection, entry.state))
    }
    private func checkpoints() {
        output.yield(.checkpoints(summaries.values.filter { !removing.contains($0.itemSHA256) }.sorted { $0.updatedAt > $1.updatedAt }))
    }
    private func checkpoint(_ value: DeviceTransferCheckpoint, descriptor: DeviceChunkTransferDescriptor) {
        guard !removing.contains(value.itemSHA256) else { return }
        summaries[value.itemSHA256] = .init(itemSHA256: value.itemSHA256,
            title: value.itemTitle ?? descriptor.item.title, fileSize: value.fileSize,
            completedBytes: value.completedBytes, updatedAt: value.updatedAt)
        checkpoints()
    }
    private func wire(_ message: DeviceSyncMessage, id: UUID) {
        guard !closing, client.isCurrent(context) else { return }
        do { try send(message) } catch { fail(id, error: error) }
    }
    private func handle(_ command: Command) {
        switch command {
        case let .outgoing(id, item, url, direction, completion):
            guard entries[id] == nil, !closedIDs.contains(id) else { return }
            let entry = Entry(ticket: .init(context: context, id: id, token: UUID()), cancellation: ChunkCancellation(),
                state: .init(id: id, item: item, direction: direction, phase: .preparing), receiving: false, completion: completion)
            entries[id] = entry; state(entry)
            submitDisk(.outgoing(entry.ticket, entry.cancellation, item, url, direction))
        case .offer(let descriptor):
            guard entries[descriptor.transferID] == nil, !closedIDs.contains(descriptor.transferID) else { return }
            let conflict = entries.values.contains {
                $0.receiving && ($0.state.isActive || $0.committing) && $0.state.item.sha256 == descriptor.item.sha256
            }
            let entry = Entry(ticket: .init(context: context, id: descriptor.transferID, token: UUID()), cancellation: ChunkCancellation(),
                state: .init(id: descriptor.transferID, item: descriptor.item, direction: descriptor.direction, phase: .preparing),
                receiving: true, descriptor: descriptor)
            entries[descriptor.transferID] = entry; state(entry)
            if conflict { fail(descriptor.transferID, error: DeviceChunkTransferError.checkpointMismatch); return }
            submitDisk(.prepare(entry.ticket, entry.cancellation, descriptor))
        case .request(let request):
            guard var entry = entries[request.transferID], entry.state.isActive, !entry.receiving else { return }
            entry.pendingRequest = request; entries[request.transferID] = entry
            advance(request.transferID)
        case .payload(let payload):
            guard var entry = entries[payload.transferID], entry.state.isActive, entry.receiving,
                  !entry.busy, !entry.committing, entry.checkpoint != nil,
                  entry.awaitingIndex == payload.index else { return }
            // At most one chunk is requested at a time. Extra/duplicate in-flight
            // packets are safely re-requested from the authoritative checkpoint.
            entry.awaitingIndex = nil
            entry.busy = true; entries[payload.transferID] = entry
            submitDisk(.accept(entry.ticket, entry.cancellation, payload))
        case .completion(let completion):
            guard let entry = entries[completion.transferID], entry.state.isActive, !entry.receiving else { return }
            guard entry.descriptor?.item.sha256 == completion.sha256 else {
                fail(completion.transferID, error: DeviceChunkTransferError.finalHashMismatch); return
            }
            terminal(completion.transferID, phase: .completed, error: nil, discard: false)
        case .control(let control, let notify):
            guard var entry = entries[control.transferID], entry.state.isActive, !entry.committing else { return }
            switch control.action {
            case .pause:
                entry.paused = true; entry.state.phase = .paused; entries[control.transferID] = entry; state(entry)
            case .resume:
                entry.paused = false; entry.state.phase = entry.busy && entry.descriptor == nil ? .preparing : .transferring
                entries[control.transferID] = entry; state(entry); advance(control.transferID)
            case .cancel:
                terminal(control.transferID, phase: .cancelled, error: CocoaError(.userCancelled), discard: true)
            case .insufficientStorage:
                terminal(control.transferID, phase: .insufficientStorage, error: CocoaError(.fileWriteOutOfSpace), discard: false)
            }
            if notify && client.isCurrent(context) { try? send(.transferControl(control)) }
        case .refresh(let stale): submitDisk(.refresh(stale))
        case .discardCheckpoints:
            guard !entries.values.contains(where: { $0.state.isActive || $0.committing }) else { return }
            submitDisk(.discard)
        case .barrier(let done): output.yield(.barrier(done))
        case .flush(let done):
            if pendingDisk == 0 { output.yield(.barrier(done)) } else { flushWaiters.append(done) }
        }
    }
    private func advance(_ id: UUID) {
        guard client.isCurrent(context), var entry = entries[id], entry.state.isActive,
              !entry.paused, !entry.busy, !entry.committing else { return }
        if !entry.receiving {
            guard let descriptor = entry.descriptor else { return }
            if !entry.offered {
                entry.offered = true; entries[id] = entry
                wire(.chunkOffer(descriptor), id: id)
                guard entries[id]?.state.isActive == true else { return }
            }
            if let request = entry.pendingRequest {
                guard let index = request.missingIndexes.first, descriptor.chunkHashes.indices.contains(index) else { return }
                entry.pendingRequest = nil; entry.busy = true; entries[id] = entry
                submitDisk(.read(entry.ticket, entry.cancellation, request))
            }
        } else if let checkpoint = entry.checkpoint {
            if checkpoint.isComplete {
                entry.busy = true; entry.state.phase = .verifying
                if entry.staged != nil {
                    // Durable commit wins after this claim. Later cancel/pause
                    // cannot roll back a verified library transaction.
                    entry.committing = true; entries[id] = entry; state(entry)
                    submitDisk(.commit(entry.ticket))
                } else {
                    entries[id] = entry; state(entry)
                    submitDisk(.stage(entry.ticket, entry.cancellation))
                }
            } else {
                let missing = checkpoint.missingIndexes
                entry.awaitingIndex = missing.first; entries[id] = entry
                wire(.chunkRequest(.init(transferID: id, missingIndexes: missing)), id: id)
            }
        }
    }
    private func terminal(_ id: UUID, phase: DeviceTransferState.Phase, error: Error?, discard: Bool) {
        guard var entry = entries[id], entry.state.isActive, !entry.committing else { return }
        entry.cancellation.cancel()
        entry.state.phase = phase
        if phase == .completed { entry.state.updateProgress(fraction: 1, completedBytes: entry.state.item.fileSize) }
        let completion = entry.completion; entry.completion = nil
        if discard && entry.receiving { removing.insert(entry.state.item.sha256); summaries.removeValue(forKey: entry.state.item.sha256); checkpoints() }
        submitDisk(.release(entry.ticket, entry.receiving ? entry.state.item.sha256 : nil, discard))
        entry.descriptor = nil; entry.checkpoint = nil; entry.pendingRequest = nil; entry.staged = nil; entry.busy = false
        entries.removeValue(forKey: id); closedIDs.insert(id)
        state(entry); completion?(error)
    }
    private func fail(_ id: UUID, error: Error) {
        guard let entry = entries[id], entry.state.isActive else { return }
        let connection = entry.ticket.context
        let receiving = entry.receiving
        let phase: DeviceTransferState.Phase = (error as? CocoaError)?.code == .fileWriteOutOfSpace
            ? .insufficientStorage : .failed(error.localizedDescription)
        terminal(id, phase: phase, error: error, discard: false)
        if receiving { submitDisk(.refresh(false)) }
        if !closing && connection == context && client.isCurrent(connection) {
            try? send(.transferControl(.init(transferID: id, action: phase == .insufficientStorage ? .insufficientStorage : .cancel)))
        }
    }
    private func interrupt() {
        for id in Array(entries.keys) where entries[id]?.state.isActive == true && entries[id]?.committing != true {
            terminal(id, phase: .interrupted, error: URLError(.networkConnectionLost), discard: false)
        }
        closedIDs.removeAll()
        submitDisk(.refresh(false))
    }
    private func finish(_ reply: Reply) {
        switch reply {
        case .released(let sha, let removed, let result):
            if let sha { removing.remove(sha); if removed { summaries.removeValue(forKey: sha) }; checkpoints() }
            if case .failure(let error) = result { output.yield(.storageFailure(error.localizedDescription)) }
        case .refreshed(let result):
            switch result {
            case .success(let values):
                summaries = Dictionary(values.map { ($0.itemSHA256, $0) }, uniquingKeysWith: {
                    $0.updatedAt >= $1.updatedAt ? $0 : $1
                }); checkpoints()
            case .failure(let error): output.yield(.storageFailure(error.localizedDescription))
            }
        case .stopped:
            pendingDisk = 0
            flushWaiters.forEach { output.yield(.barrier($0)) }; flushWaiters.removeAll()
            output.yield(.stopped); output.finish(); input.finish()
        default: finishTransfer(reply)
        }
    }
    private func finishTransfer(_ reply: Reply) {
        let ticket: Ticket
        switch reply {
        case .outgoing(let t, _), .prepared(let t, _), .read(let t, _, _), .accepted(let t, _), .staged(let t, _), .committed(let t, _): ticket = t
        default: return
        }
        guard var entry = entries[ticket.id], entry.ticket == ticket else { return }
        // A claimed commit may finish durably after disconnect. Its local
        // publication is retained, but no acknowledgement enters a new link.
        if case .committed(let t, let result) = reply, entry.committing {
            entry.committing = false; entries[t.id] = entry
            switch result {
            case .success(let commit):
                if let descriptor = entry.descriptor {
                    summaries.removeValue(forKey: descriptor.item.sha256); checkpoints()
                    output.yield(.committed(descriptor, commit.url, commit.snapshot))
                    if !closing && t.context == context && client.isCurrent(t.context) { try? send(.chunkCompletion(.init(transferID: t.id, sha256: descriptor.item.sha256))) }
                }
                terminal(t.id, phase: .completed, error: nil, discard: false)
            case .failure(let error): fail(t.id, error: error)
            }
            return
        }
        guard !closing, ticket.context == context, client.isCurrent(ticket.context), entry.state.isActive else { return }
        entry.busy = false
        do {
            switch reply {
            case .outgoing(_, let result): entry.descriptor = try result.get().descriptor
            case .prepared(_, let result):
                let value = try result.get(); entry.checkpoint = value
                entry.state.resumedFromCheckpoint = value.completedBytes > 0
                entry.state.updateProgress(fraction: value.fileSize == 0 ? 1 : Double(value.completedBytes)/Double(value.fileSize), completedBytes: value.completedBytes)
                checkpoint(value, descriptor: entry.descriptor!)
            case .accepted(_, let result):
                let value = try result.get(); entry.checkpoint = value
                entry.state.updateProgress(fraction: value.fileSize == 0 ? 1 : Double(value.completedBytes)/Double(value.fileSize), completedBytes: value.completedBytes)
                checkpoint(value, descriptor: entry.descriptor!)
            case .read(_, let request, let result):
                let payload = try result.get()
                if entry.paused { if entry.pendingRequest == nil { entry.pendingRequest = request } }
                else {
                    let descriptor = entry.descriptor!
                    let completed = descriptor.chunkCount - request.missingIndexes.count + 1
                    entry.state.updateProgress(fraction: Double(completed)/Double(max(1,descriptor.chunkCount)),
                        completedBytes: min(descriptor.item.fileSize, Int64(completed * descriptor.chunkSize)))
                    // Publish state before sending; a synchronous send error can
                    // then terminate this same actor-owned session exactly once.
                    entries[ticket.id] = entry
                    wire(.chunkPayload(payload), id: ticket.id)
                    guard entries[ticket.id]?.state.isActive == true else { return }
                }
            case .staged(_, let result): entry.staged = try result.get()
            default: return
            }
            entry.state.phase = entry.paused ? .paused
                : (entry.receiving && entry.checkpoint?.isComplete == true ? .verifying : .transferring)
            entries[ticket.id] = entry; state(entry); advance(ticket.id)
        } catch { entries[ticket.id] = entry; fail(ticket.id, error: error) }
    }
}

/// Private serial I/O lane. A FIFO mailbox (rather than reentrant awaited jobs)
/// orders accept/delete/reopen operations; only this actor mutates checkpoints.
private actor DeviceChunkTransferDisk {
    typealias Ticket = DeviceChunkTransferWorker.Ticket
    enum Job: Sendable {
        case outgoing(Ticket, ChunkCancellation, DeviceSyncItem, URL, DeviceSyncDirection)
        case prepare(Ticket, ChunkCancellation, DeviceChunkTransferDescriptor)
        case read(Ticket, ChunkCancellation, DeviceChunkRequest)
        case accept(Ticket, ChunkCancellation, DeviceChunkPayload)
        case stage(Ticket, ChunkCancellation)
        case commit(Ticket)
        case release(Ticket, String?, Bool)
        case refresh(Bool)
        case discard
        case shutdown
    }
    private struct Incoming {
        let descriptor: ValidatedDeviceChunkTransferDescriptor
        var checkpoint: DeviceTransferCheckpoint
    }
    nonisolated private let input: AsyncStream<Job>.Continuation
    private let output: AsyncStream<DeviceChunkTransferWorker.Message>.Continuation
    private let store: DeviceTransferCheckpointStore
    private let destination: DeviceChunkTransferWorker.Destination
    private let canReceive: @Sendable (Int64) -> Bool
    private let beforeIO: @Sendable (DeviceChunkTransferWorker.Point) -> Void
    private var outgoing: [Ticket: (ValidatedDeviceChunkTransferDescriptor, URL)] = [:]
    private var incoming: [Ticket: Incoming] = [:]
    private var owners: [String: Ticket] = [:]
    private var staged: [Ticket: URL] = [:]

    init(directory: URL, destination: DeviceChunkTransferWorker.Destination,
         canReceive: @escaping @Sendable (Int64) -> Bool,
         beforeIO: @escaping @Sendable (DeviceChunkTransferWorker.Point) -> Void,
         output: AsyncStream<DeviceChunkTransferWorker.Message>.Continuation) {
        let commands = AsyncStream<Job>.makeStream(); input = commands.continuation
        store = DeviceTransferCheckpointStore(directory: directory)
        self.destination = destination; self.canReceive = canReceive; self.beforeIO = beforeIO; self.output = output
        Task { await self.run(commands.stream) }
    }
    nonisolated func submit(_ job: Job) -> Bool {
        if case .enqueued = input.yield(job) { return true }
        return false
    }
    private func run(_ stream: AsyncStream<Job>) async {
        for await job in stream {
            perform(job)
            if case .shutdown = job { break }
        }
    }
    private func emit(_ reply: DeviceChunkTransferWorker.Reply) {
        // Test barriers can hold a successful result after disk mutation but
        // before lifecycle publication, exercising truly stale success replies.
        switch reply {
        case .outgoing: beforeIO(.descriptorResult)
        case .accepted: beforeIO(.acceptResult)
        case .staged: beforeIO(.stageResult)
        default: break
        }
        output.yield(.reply(reply))
    }
    private func perform(_ job: Job) {
        switch job {
        case let .outgoing(ticket, cancellation, item, url, direction):
            emit(.outgoing(ticket, Result {
                beforeIO(.descriptor); try cancellation.check()
                let value = try DeviceChunkTransfer.validatedDescriptor(for: item, at: url, transferID: ticket.id,
                    direction: direction, checkCancellation: cancellation.check)
                try cancellation.check(); outgoing[ticket] = (value, url); return value
            }))
        case let .prepare(ticket, cancellation, descriptor):
            emit(.prepared(ticket, Result {
                try cancellation.check()
                let value = try ValidatedDeviceChunkTransferDescriptor(descriptor)
                let checkpoint = try store.prepare(validatedDescriptor: value)
                // Record ownership before capacity failure so later cancellation
                // can clean only this session's own checkpoint.
                owners[descriptor.item.sha256] = ticket
                incoming[ticket] = Incoming(descriptor: value, checkpoint: checkpoint)
                guard canReceive(max(0,descriptor.item.fileSize-checkpoint.completedBytes)) else { throw CocoaError(.fileWriteOutOfSpace) }
                try cancellation.check(); return checkpoint
            }))
        case let .read(ticket, cancellation, request):
            emit(.read(ticket, request, Result {
                beforeIO(.read); try cancellation.check()
                guard let value = outgoing[ticket], let index = request.missingIndexes.first else { throw DeviceChunkTransferError.checkpointMismatch }
                let payload = try DeviceChunkTransfer.payload(validatedDescriptor: value.0, index: index, fileURL: value.1)
                try cancellation.check(); return payload
            }))
        case let .accept(ticket, cancellation, payload):
            emit(.accepted(ticket, Result {
                beforeIO(.accept); try cancellation.check()
                guard var value = incoming[ticket], owners[value.descriptor.descriptor.item.sha256] == ticket else { throw DeviceChunkTransferError.checkpointMismatch }
                try store.accept(payload, validatedDescriptor: value.descriptor, checkpoint: &value.checkpoint)
                incoming[ticket] = value; try cancellation.check(); return value.checkpoint
            }))
        case let .stage(ticket, cancellation):
            emit(.staged(ticket, Result {
                beforeIO(.stage); try cancellation.check()
                guard let value = incoming[ticket] else { throw DeviceChunkTransferError.checkpointMismatch }
                let partial = try store.finalizedFile(descriptor: value.descriptor.descriptor, checkpoint: value.checkpoint, checkCancellation: cancellation.check)
                try cancellation.check()
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OngakuChunkStage", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent(ticket.token.uuidString)
                do {
                    try FileManager.default.copyItem(at: partial, to: url)
                    try cancellation.check(); staged[ticket] = url; return url
                } catch { try? FileManager.default.removeItem(at: url); throw error }
            }))
        case .commit(let ticket):
            emit(.committed(ticket, Result {
                beforeIO(.commit)
                guard let value = incoming[ticket], let source = staged[ticket] else { throw DeviceChunkTransferError.checkpointMismatch }
                let descriptor = value.descriptor.descriptor
                let result: DeviceChunkTransferWorker.DiskCommit
                switch destination {
                case .library(let repository):
                    let commit = try repository.commitVerifiedFile(at: source, item: descriptor.item)
                    result = .init(url: commit.fileURL, snapshot: commit.snapshot)
                case .directory(let directory):
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let name = URL(fileURLWithPath: descriptor.item.fileName).lastPathComponent
                    let url = directory.appendingPathComponent("\(ticket.token.uuidString)-\(name)")
                    do {
                        try FileManager.default.copyItem(at: source, to: url)
                        guard try DeviceSyncFileIntegrity.verified(url, matches: descriptor.item) else { throw DeviceChunkTransferError.finalHashMismatch }
                    } catch { try? FileManager.default.removeItem(at: url); throw error }
                    result = .init(url: url, snapshot: nil)
                }
                // A cleanup failure must not turn an already durable library
                // commit into a failed transfer or publish it a second time.
                if owners[descriptor.item.sha256] == ticket {
                    try? store.remove(forSHA256: descriptor.item.sha256); owners.removeValue(forKey: descriptor.item.sha256)
                }
                try? FileManager.default.removeItem(at: source); staged.removeValue(forKey: ticket)
                return result
            }))
        case let .release(ticket, sha, discard):
            let result: Result<Void, Error> = Result {
                outgoing.removeValue(forKey: ticket)
                incoming.removeValue(forKey: ticket)
                if let url = staged.removeValue(forKey: ticket) { try? FileManager.default.removeItem(at: url) }
                if let sha, owners[sha] == ticket {
                    if discard { try store.remove(forSHA256: sha) }
                    owners.removeValue(forKey: sha)
                }
            }
            emit(.released(sha, discard && (try? result.get()) != nil, result))
        case .refresh(let stale):
            emit(.refreshed(Result {
                if stale && incoming.isEmpty && outgoing.isEmpty { _ = try store.removeStale(before: Date().addingTimeInterval(-30*24*60*60)) }
                return try store.summaries()
            }))
        case .discard:
            emit(.refreshed(Result { try store.removeAll(); return try store.summaries() }))
        case .shutdown:
            for url in staged.values { try? FileManager.default.removeItem(at: url) }
            staged.removeAll(); outgoing.removeAll(); incoming.removeAll(); owners.removeAll()
            emit(.stopped); input.finish()
        }
    }
}
