@preconcurrency import MultipeerConnectivity
import CryptoKit
import Foundation

struct MobilePairingRequest: Identifiable, Equatable, Sendable {
    var id: UUID
    var deviceName: String
    var pairingCode: String
}

private final class MobileInvitationHandlerBox: @unchecked Sendable {
    let value: (Bool, MCSession?) -> Void

    init(_ value: @escaping (Bool, MCSession?) -> Void) {
        self.value = value
    }
}

final class MobileSyncController: NSObject, ObservableObject, @unchecked Sendable {
    private struct LibraryImportResult: Sendable {
        var snapshot: DeviceReceivedLibrarySnapshot
        var firstErrorMessage: String?
    }

    @Published private(set) var connectionState: DeviceSyncConnectionState = .disconnected
    @Published private(set) var localItems: [DeviceSyncItem] = []
    @Published private(set) var remoteItems: [DeviceSyncItem] = []
    @Published private(set) var transfers: [DeviceTransferState] = []
    @Published private(set) var resumableTransfers: [DeviceTransferCheckpointSummary] = []
    @Published var pairingRequest: MobilePairingRequest?

    let pairingCode = String(format: "%06d", Int.random(in: 0 ... 999_999))

    private let peerID = MCPeerID(displayName: ProcessInfo.processInfo.hostName)
    private lazy var session = MCSession(
        peer: peerID,
        securityIdentity: nil,
        encryptionPreference: .required
    )
    private lazy var advertiser = MCNearbyServiceAdvertiser(
        peer: peerID,
        discoveryInfo: ["code": pairingCode],
        serviceType: DeviceSyncService.serviceType
    )
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()
    private var localURLs: [UUID: URL] = [:]
    private var pendingResources: [UUID: DeviceSyncResourceAnnouncement] = [:]
    private var transferProgresses: [UUID: Progress] = [:]
    private var transferObservations: [UUID: NSKeyValueObservation] = [:]
    private var terminalTransferActions: [UUID: DeviceTransferControlAction] = [:]
    private var invitationHandlers: [UUID: (Bool, MCSession?) -> Void] = [:]
    private var advertisingRetryWorkItem: DispatchWorkItem?
    private var chunkTransfers: DeviceChunkTransferWorker!
    private var chunkEventTask: Task<Void, Never>?

    private let libraryRepository: DeviceReceivedLibraryRepository
    private var isStarted = false

    override init() {
        let repository = DeviceReceivedLibraryRepository(directory: Self.tracksDirectory)
        libraryRepository = repository
        super.init()
        let sender = DeviceChunkSessionSender(session)
        let worker = DeviceChunkTransferWorker(checkpointDirectory: Self.checkpointDirectory,
            destination: .library(repository), send: sender.send)
        chunkTransfers = worker
        chunkEventTask = Task { @MainActor [weak self, events = worker.events] in
            for await event in events {
                guard !Task.isCancelled else { break }
                self?.applyChunkEvent(event)
            }
        }
        session.delegate = self
        advertiser.delegate = self
        refreshResumableTransfers(removingStale: true)
    }

    deinit {
        chunkEventTask?.cancel()
        chunkTransfers?.client.shutdown()
        transferProgresses.values.forEach { $0.cancel() }
        advertiser.stopAdvertisingPeer()
        session.disconnect()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        connectionState = .searching
        beginAdvertising()
    }

    func stop() {
        isStarted = false
        advertisingRetryWorkItem?.cancel()
        advertisingRetryWorkItem = nil
        advertiser.stopAdvertisingPeer()
        interruptActiveTransfers()
        session.disconnect()
        connectionState = .disconnected
        remoteItems = []
    }

    func acceptPairing(_ request: MobilePairingRequest) {
        let handler = lock.withLock { invitationHandlers.removeValue(forKey: request.id) }
        pairingRequest = nil
        handler?(true, session)
    }

    func declinePairing(_ request: MobilePairingRequest) {
        let handler = lock.withLock { invitationHandlers.removeValue(forKey: request.id) }
        pairingRequest = nil
        handler?(false, nil)
        if isStarted { beginAdvertising() }
    }

    func disconnect() {
        interruptActiveTransfers()
        session.disconnect()
        remoteItems = []
        connectionState = isStarted ? .searching : .disconnected
        if isStarted { beginAdvertising() }
    }

    func retryDiscovery() {
        guard isStarted else {
            start()
            return
        }
        connectionState = .searching
        beginAdvertising()
    }

    func loadLibrary() async {
        do {
            let repository = libraryRepository
            let loaded = try await Task.detached(priority: .utility) {
                try repository.load()
            }.value
            applyLibrarySnapshot(loaded)
        } catch {
            publishFailure(error.localizedDescription)
        }
    }

    func importFiles(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        let repository = libraryRepository
        let imported = await Task.detached(priority: .userInitiated) {
            Self.importIntoLibrary(urls, repository: repository)
        }.value
        applyLibrarySnapshot(imported.snapshot)
        sendManifestIfConnected(items: imported.snapshot.items)
        if let message = imported.firstErrorMessage {
            publishFailure(message)
        }
    }

    func uploadToMac(_ item: DeviceSyncItem) {
        sendLocalItem(item.id, direction: .phoneToMac)
    }

    func downloadFromMac(_ item: DeviceSyncItem) {
        send(.requestItem(item.id))
    }

    func pauseTransfer(_ id: UUID) {
        applyTransferControl(.init(transferID: id, action: .pause), notifyPeer: true)
    }

    func resumeTransfer(_ id: UUID) {
        applyTransferControl(.init(transferID: id, action: .resume), notifyPeer: true)
    }

    func cancelTransfer(_ id: UUID) {
        applyTransferControl(.init(transferID: id, action: .cancel), notifyPeer: true)
    }

    func discardResumableTransfers() {
        chunkTransfers.client.submit(.discardCheckpoints)
    }

    func hasLocalCopy(of item: DeviceSyncItem) -> Bool {
        localItems.contains { $0.sha256 == item.sha256 }
    }

    private func sendManifestIfConnected(items: [DeviceSyncItem]? = nil) {
        guard !session.connectedPeers.isEmpty else { return }
        send(.manifest(DeviceSyncManifest(
            deviceName: peerID.displayName,
            generatedAt: .now,
            items: items ?? localItems,
            storage: Self.deviceStorageInfo()
        )))
    }

    private static func deviceStorageInfo() -> DeviceStorageInfo? {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let values = try? documents.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]), let total = values.volumeTotalCapacity else { return nil }
        let available = values.volumeAvailableCapacityForImportantUsage
            ?? values.volumeAvailableCapacity.map(Int64.init)
            ?? 0
        return DeviceStorageInfo(totalBytes: Int64(total), availableBytes: available)
    }

    private func beginAdvertising() {
        advertisingRetryWorkItem?.cancel()
        if session.connectedPeers.isEmpty {
            connectionState = .searching
        }
        advertiser.stopAdvertisingPeer()
        advertiser.startAdvertisingPeer()
        scheduleAdvertisingRetry()
    }

    private func scheduleAdvertisingRetry() {
        advertisingRetryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  isStarted,
                  session.connectedPeers.isEmpty,
                  pairingRequest == nil else { return }
            advertiser.stopAdvertisingPeer()
            advertiser.startAdvertisingPeer()
            scheduleAdvertisingRetry()
        }
        advertisingRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: workItem)
    }

    private func send(_ message: DeviceSyncMessage) {
        guard !session.connectedPeers.isEmpty else { return }
        do {
            try session.send(
                encoder.encode(message),
                toPeers: session.connectedPeers,
                with: .reliable
            )
        } catch {
            publishFailure(error.localizedDescription)
        }
    }

    private func sendLocalItem(_ id: UUID, direction: DeviceSyncDirection, connection: UUID? = nil) {
        guard let item = localItems.first(where: { $0.id == id }),
              let url = lock.withLock({ localURLs[id] }),
              !session.connectedPeers.isEmpty else { return }

        chunkTransfers.client.submit(.outgoing(UUID(), item, url, direction, nil), connection: connection)
    }

    private func handle(_ message: DeviceSyncMessage, connection: UUID? = nil) {
        if let connection, !chunkTransfers.client.isCurrent(connection) { return }
        switch message {
        case .manifest(let manifest):
            DispatchQueue.main.async { [weak self] in
                self?.remoteItems = manifest.items
            }
        case .requestItem(let id):
            sendLocalItem(id, direction: .phoneToMac, connection: connection)
        case .resource(let announcement):
            guard Self.canReceive(announcement.item) else {
                lock.withLock {
                    terminalTransferActions[announcement.transferID] = .insufficientStorage
                }
                updateTransfer(DeviceTransferState(
                    id: announcement.transferID,
                    item: announcement.item,
                    direction: announcement.direction,
                    phase: .insufficientStorage
                ))
                send(.transferControl(.init(
                    transferID: announcement.transferID,
                    action: .insufficientStorage
                )))
                return
            }
            lock.withLock { pendingResources[announcement.transferID] = announcement }
            updateTransfer(DeviceTransferState(
                id: announcement.transferID,
                item: announcement.item,
                direction: announcement.direction,
                phase: .transferring
            ))
        case .transferControl(let control):
            applyTransferControl(control, notifyPeer: false, connection: connection)
        case .chunkOffer(let descriptor):
            chunkTransfers.client.submit(.offer(descriptor), connection: connection)
        case .chunkRequest(let request):
            chunkTransfers.client.submit(.request(request), connection: connection)
        case .chunkPayload(let payload):
            chunkTransfers.client.submit(.payload(payload), connection: connection)
        case .chunkCompletion(let completion):
            chunkTransfers.client.submit(.completion(completion), connection: connection)
        case .overlayReceipt:
            // Receipts acknowledge phone-originated overlay changes on the Mac.
            // The legacy companion target never applies them locally.
            break
        case .error(let message):
            publishFailure(message)
        }
    }

    private func finishReceivedResource(name: String, temporaryURL: URL?, error: Error?) {
        guard let transferID = UUID(uuidString: name) else { return }
        guard let announcement = lock.withLock({ pendingResources.removeValue(forKey: transferID) }) else {
            _ = lock.withLock { terminalTransferActions.removeValue(forKey: transferID) }
            removeProgress(for: transferID)
            return
        }
        if let terminalAction = lock.withLock({ terminalTransferActions.removeValue(forKey: transferID) }) {
            updateTransfer(
                id: transferID,
                phase: terminalAction == .insufficientStorage ? .insufficientStorage : .cancelled
            )
            removeProgress(for: transferID)
            return
        }
        if let error {
            updateTransfer(id: transferID, phase: .failed(error.localizedDescription))
            removeProgress(for: transferID)
            return
        }
        guard let temporaryURL else {
            updateTransfer(id: transferID, phase: .failed("Missing received file"))
            removeProgress(for: transferID)
            return
        }

        updateTransfer(id: transferID, phase: .verifying)
        do {
            guard try DeviceSyncFileIntegrity.verified(temporaryURL, matches: announcement.item) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let commit = try libraryRepository.commitVerifiedFile(
                at: temporaryURL,
                item: announcement.item
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                applyLibrarySnapshot(commit.snapshot)
                updateTransfer(id: transferID, phase: .completed)
                updateTransferProgress(id: transferID, fraction: 1, completedBytes: announcement.item.fileSize)
                removeProgress(for: transferID)
                sendManifestIfConnected(items: commit.snapshot.items)
            }
        } catch {
            updateTransfer(id: transferID, phase: .failed(error.localizedDescription))
            removeProgress(for: transferID)
            send(.error(error.localizedDescription))
        }
    }

    private func updateTransfer(_ state: DeviceTransferState) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let index = transfers.firstIndex(where: { $0.id == state.id }) {
                transfers[index] = state
            } else {
                transfers.insert(state, at: 0)
            }
        }
    }

    private func updateTransfer(id: UUID, phase: DeviceTransferState.Phase) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let index = transfers.firstIndex(where: { $0.id == id }) else { return }
            transfers[index].phase = phase
        }
    }

    private func updateTransferProgress(id: UUID, fraction: Double, completedBytes: Int64) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let index = transfers.firstIndex(where: { $0.id == id }) else { return }
            transfers[index].updateProgress(fraction: fraction, completedBytes: completedBytes)
        }
    }

    private func observe(_ progress: Progress, transferID: UUID) {
        let observation = progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] value, _ in
            Task { @MainActor [weak self] in
                self?.updateTransferProgress(
                    id: transferID,
                    fraction: value.fractionCompleted,
                    completedBytes: value.completedUnitCount
                )
            }
        }
        lock.withLock {
            transferProgresses[transferID] = progress
            transferObservations[transferID] = observation
        }
    }

    private func removeProgress(for transferID: UUID) {
        lock.withLock {
            transferObservations.removeValue(forKey: transferID)?.invalidate()
            transferProgresses.removeValue(forKey: transferID)
        }
    }

    private func applyTransferControl(_ control: DeviceTransferControl, notifyPeer: Bool, connection: UUID? = nil) {
        chunkTransfers.client.submit(.control(control, notifyPeer: notifyPeer), connection: connection)
        let value = lock.withLock {
            (transferProgresses[control.transferID], pendingResources[control.transferID] != nil)
        }
        guard value.0 != nil || value.1 else { return }
        switch control.action {
        case .pause:
            value.0?.pause(); updateTransfer(id: control.transferID, phase: .paused)
        case .resume:
            value.0?.resume(); updateTransfer(id: control.transferID, phase: .transferring)
        case .cancel, .insufficientStorage:
            lock.withLock { terminalTransferActions[control.transferID] = control.action }
            value.0?.cancel(); removeProgress(for: control.transferID)
            updateTransfer(id: control.transferID, phase: control.action == .cancel ? .cancelled : .insufficientStorage)
        }
        if notifyPeer { send(.transferControl(control)) }
    }

    private func interruptActiveTransfers(resetChunkLink: Bool = true) {
        if resetChunkLink { chunkTransfers.client.disconnect() }
        let ids = lock.withLock { Set(pendingResources.keys).union(transferProgresses.keys) }
        lock.withLock { Array(transferProgresses.values) }.forEach { $0.cancel() }
        lock.withLock {
            transferObservations.values.forEach { $0.invalidate() }
            transferObservations.removeAll(); transferProgresses.removeAll()
            pendingResources.removeAll(); terminalTransferActions.removeAll()
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for index in transfers.indices where ids.contains(transfers[index].id) && transfers[index].isActive {
                transfers[index].phase = .interrupted
            }
        }
    }

    private static func canReceive(_ item: DeviceSyncItem) -> Bool {
        canReceive(byteCount: item.fileSize)
    }

    private static func canReceive(byteCount: Int64) -> Bool {
        guard let storage = deviceStorageInfo() else { return true }
        return DeviceTransferCapacity.canReceive(
            fileSize: byteCount,
            availableBytes: storage.availableBytes
        )
    }

    private func publishFailure(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.connectionState = .failed(message)
        }
    }

    private static var tracksDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Ongaku Tracks", isDirectory: true)
    }

    private static var checkpointDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("Ongaku", isDirectory: true)
            .appendingPathComponent("TransferCheckpoints", isDirectory: true)
    }

    private func refreshResumableTransfers(removingStale: Bool = false) {
        chunkTransfers.client.submit(.refresh(removingStale: removingStale))
    }

    @MainActor private func applyChunkEvent(_ event: DeviceChunkTransferWorker.Event) {
        switch event {
        case .state(let connection, let state):
            guard chunkTransfers.client.isCurrent(connection) else { return }
            if let index = transfers.firstIndex(where: { $0.id == state.id }) { transfers[index] = state }
            else { transfers.insert(state, at: 0) }

        case .checkpoints(let values): resumableTransfers = values
        case .committed(let descriptor, let url, let snapshot):
            if let snapshot {
                applyLibrarySnapshot(snapshot)
                sendManifestIfConnected(items: snapshot.items)
            }
            _ = descriptor; _ = url
        case .storageFailure(let message): publishFailure(message)
        case .stopped: break
        case .barrier(let done): done()
        }
    }

    private func applyLibrarySnapshot(_ snapshot: DeviceReceivedLibrarySnapshot) {
        if Thread.isMainThread {
            localItems = snapshot.items
            lock.withLock { localURLs = snapshot.fileURLs }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                localItems = snapshot.items
                lock.withLock { localURLs = snapshot.fileURLs }
            }
        }
    }

    private static func importIntoLibrary(
        _ urls: [URL],
        repository: DeviceReceivedLibraryRepository
    ) -> LibraryImportResult {
        var snapshot: DeviceReceivedLibrarySnapshot
        do {
            snapshot = try repository.load()
        } catch {
            return LibraryImportResult(
                snapshot: DeviceReceivedLibrarySnapshot(items: [], fileURLs: [:]),
                firstErrorMessage: error.localizedDescription
            )
        }
        var firstErrorMessage: String?
        for source in urls {
            let accessing = source.startAccessingSecurityScopedResource()
            defer { if accessing { source.stopAccessingSecurityScopedResource() } }
            do {
                let hash = try DeviceSyncFileIntegrity.sha256(of: source)
                let values = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let item = DeviceSyncItem(
                    id: UUID(),
                    title: source.deletingPathExtension().lastPathComponent,
                    artist: "",
                    album: "",
                    fileName: source.lastPathComponent,
                    fileSize: Int64(values.fileSize ?? 0),
                    sha256: hash,
                    modifiedAt: values.contentModificationDate ?? .now
                )
                snapshot = try repository.commitVerifiedFile(at: source, item: item).snapshot
            } catch {
                firstErrorMessage = firstErrorMessage ?? error.localizedDescription
            }
        }
        return LibraryImportResult(
            snapshot: snapshot,
            firstErrorMessage: firstErrorMessage
        )
    }
}

extension MobileSyncController: MCNearbyServiceAdvertiserDelegate {
    func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        let invitation = MobileInvitationHandlerBox(invitationHandler)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let requestID = UUID()
            let receivedCode = context
                .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }?["pairingCode"]
                ?? pairingCode
            lock.withLock { invitationHandlers[requestID] = invitation.value }
            advertisingRetryWorkItem?.cancel()
            advertisingRetryWorkItem = nil
            pairingRequest = MobilePairingRequest(
                id: requestID,
                deviceName: peerID.displayName,
                pairingCode: receivedCode
            )
        }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor [weak self] in
            self?.publishFailure(error.localizedDescription)
        }
    }
}

extension MobileSyncController: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        if state == .notConnected { chunkTransfers.client.disconnect() }
        let connection = chunkTransfers.client.connection
        Task { @MainActor [weak self] in
            guard let self, chunkTransfers.client.isCurrent(connection) else { return }
            let name = peerID.displayName
            switch state {
            case .notConnected:
                guard !session.connectedPeers.contains(peerID) else { return }
                interruptActiveTransfers(resetChunkLink: false)
                connectionState = isStarted ? .searching : .disconnected
                remoteItems = []
                if isStarted { scheduleAdvertisingRetry() }
            case .connecting:
                connectionState = .connecting(name)
            case .connected:
                guard session.connectedPeers.contains(peerID) else { return }
                advertisingRetryWorkItem?.cancel()
                advertisingRetryWorkItem = nil
                connectionState = .connected(name)
                sendManifestIfConnected()
            @unknown default:
                connectionState = .failed("Unknown connection state")
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let connection = chunkTransfers.client.connection
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                handle(try decoder.decode(DeviceSyncMessage.self, from: data), connection: connection)
            } catch {
                publishFailure(error.localizedDescription)
            }
        }
    }

    func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {
        Task { @MainActor [weak self] in
            guard let self, let transferID = UUID(uuidString: resourceName) else { return }
            if lock.withLock({ terminalTransferActions[transferID] }) != nil {
                progress.cancel()
                return
            }
            observe(progress, transferID: transferID)
        }
    }

    func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: Error?
    ) {
        Task { @MainActor [weak self] in
            self?.finishReceivedResource(name: resourceName, temporaryURL: localURL, error: error)
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
