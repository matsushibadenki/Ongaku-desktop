@preconcurrency import MultipeerConnectivity
import CryptoKit
import Foundation

struct MobilePairingRequest: Identifiable, Equatable, Sendable {
    var id: UUID
    var deviceName: String
    var pairingCode: String
}

final class MobileSyncController: NSObject, ObservableObject, @unchecked Sendable {
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
    private var outgoingChunkTransfers: [UUID: (DeviceChunkTransferDescriptor, URL)] = [:]
    private var incomingChunkTransfers: [UUID: (DeviceChunkTransferDescriptor, DeviceTransferCheckpoint)] = [:]
    private var pendingChunkRequests: [UUID: DeviceChunkRequest] = [:]
    private var pausedChunkTransferIDs: Set<UUID> = []
    private var invitationHandlers: [UUID: (Bool, MCSession?) -> Void] = [:]
    private var advertisingRetryWorkItem: DispatchWorkItem?
    private let chunkTransferQueue = DispatchQueue(
        label: "com.matsushibadenki.OngakuMobile.chunk-transfer",
        qos: .utility
    )
    private lazy var checkpointStore = DeviceTransferCheckpointStore(
        directory: Self.checkpointDirectory
    )
    private var isStarted = false

    override init() {
        super.init()
        session.delegate = self
        advertiser.delegate = self
        refreshResumableTransfers(removingStale: true)
    }

    deinit {
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
        let loaded = await Task.detached(priority: .utility) {
            Self.loadStoredLibrary()
        }.value
        localItems = loaded.items
        lock.withLock { localURLs = loaded.urls }
    }

    func importFiles(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        let existing = localItems
        let imported = await Task.detached(priority: .userInitiated) {
            Self.copyIntoLibrary(urls, existing: existing)
        }.value

        localItems = imported.items.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        lock.withLock { localURLs = imported.urls }
        Self.saveManifest(localItems)
        sendManifestIfConnected()
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
        guard !transfers.contains(where: \.isActive) else { return }
        chunkTransferQueue.async { [weak self] in
            guard let self else { return }
            try? checkpointStore.removeAll()
            refreshResumableTransfers()
        }
    }

    func hasLocalCopy(of item: DeviceSyncItem) -> Bool {
        localItems.contains { $0.sha256 == item.sha256 }
    }

    private func sendManifestIfConnected() {
        guard !session.connectedPeers.isEmpty else { return }
        send(.manifest(DeviceSyncManifest(
            deviceName: peerID.displayName,
            generatedAt: .now,
            items: localItems,
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

    private func sendLocalItem(_ id: UUID, direction: DeviceSyncDirection) {
        guard let item = localItems.first(where: { $0.id == id }),
              let url = lock.withLock({ localURLs[id] }),
              !session.connectedPeers.isEmpty else { return }

        let transferID = UUID()
        updateTransfer(DeviceTransferState(
            id: transferID,
            item: item,
            direction: direction,
            phase: .preparing
        ))
        chunkTransferQueue.async { [weak self] in
            guard let self else { return }
            do {
                let descriptor = try DeviceChunkTransfer.descriptor(
                    for: item,
                    at: url,
                    transferID: transferID,
                    direction: direction
                )
                lock.withLock { outgoingChunkTransfers[transferID] = (descriptor, url) }
                updateTransfer(id: transferID, phase: .transferring)
                send(.chunkOffer(descriptor))
            } catch {
                updateTransfer(id: transferID, phase: .failed(error.localizedDescription))
            }
        }
    }

    private func handle(_ message: DeviceSyncMessage) {
        switch message {
        case .manifest(let manifest):
            DispatchQueue.main.async { [weak self] in
                self?.remoteItems = manifest.items
            }
        case .requestItem(let id):
            sendLocalItem(id, direction: .phoneToMac)
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
            applyTransferControl(control, notifyPeer: false)
        case .chunkOffer(let descriptor):
            receiveChunkOffer(descriptor)
        case .chunkRequest(let request):
            sendRequestedChunk(request)
        case .chunkPayload(let payload):
            receiveChunk(payload)
        case .chunkCompletion(let completion):
            finishOutgoingChunkTransfer(completion)
        case .overlayReceipt:
            // Receipts acknowledge phone-originated overlay changes on the Mac.
            // The legacy companion target never applies them locally.
            break
        case .error(let message):
            publishFailure(message)
        }
    }

    private func receiveChunkOffer(_ descriptor: DeviceChunkTransferDescriptor) {
        chunkTransferQueue.async { [weak self] in
            guard let self else { return }
            do {
                let checkpoint = try checkpointStore.prepare(for: descriptor)
                let remainingBytes = max(0, descriptor.item.fileSize - checkpoint.completedBytes)
                guard Self.canReceive(byteCount: remainingBytes) else {
                    updateTransfer(DeviceTransferState(
                        id: descriptor.transferID,
                        item: descriptor.item,
                        direction: descriptor.direction,
                        phase: .insufficientStorage
                    ))
                    send(.transferControl(.init(
                        transferID: descriptor.transferID,
                        action: .insufficientStorage
                    )))
                    return
                }
                lock.withLock {
                    incomingChunkTransfers[descriptor.transferID] = (descriptor, checkpoint)
                }
                publishCheckpoint(descriptor: descriptor, checkpoint: checkpoint)
                updateTransfer(DeviceTransferState(
                    id: descriptor.transferID,
                    item: descriptor.item,
                    direction: descriptor.direction,
                    phase: checkpoint.isComplete ? .verifying : .transferring,
                    fractionCompleted: descriptor.item.fileSize == 0
                        ? 1
                        : Double(checkpoint.completedBytes) / Double(descriptor.item.fileSize),
                    bytesTransferred: checkpoint.completedBytes,
                    resumedFromCheckpoint: checkpoint.completedBytes > 0
                ))
                if checkpoint.isComplete {
                    finishIncomingChunkTransfer(descriptor: descriptor, checkpoint: checkpoint)
                } else {
                    requestMissingChunks(descriptor: descriptor, checkpoint: checkpoint)
                }
            } catch {
                updateTransfer(DeviceTransferState(
                    id: descriptor.transferID,
                    item: descriptor.item,
                    direction: descriptor.direction,
                    phase: .failed(error.localizedDescription)
                ))
            }
        }
    }

    private func requestMissingChunks(
        descriptor: DeviceChunkTransferDescriptor,
        checkpoint: DeviceTransferCheckpoint
    ) {
        send(.chunkRequest(.init(
            transferID: descriptor.transferID,
            missingIndexes: checkpoint.missingIndexes
        )))
    }

    private func sendRequestedChunk(_ request: DeviceChunkRequest) {
        chunkTransferQueue.async { [weak self] in
            guard let self else { return }
            let value = lock.withLock { outgoingChunkTransfers[request.transferID] }
            guard let (descriptor, fileURL) = value,
                  let index = request.missingIndexes.first,
                  descriptor.chunkHashes.indices.contains(index) else { return }
            if lock.withLock({ pausedChunkTransferIDs.contains(request.transferID) }) {
                lock.withLock { pendingChunkRequests[request.transferID] = request }
                return
            }
            do {
                let payload = try DeviceChunkTransfer.payload(
                    descriptor: descriptor,
                    index: index,
                    fileURL: fileURL
                )
                send(.chunkPayload(payload))
                let completedCount = descriptor.chunkCount - request.missingIndexes.count + 1
                updateTransferProgress(
                    id: request.transferID,
                    fraction: descriptor.chunkCount == 0
                        ? 1
                        : Double(completedCount) / Double(descriptor.chunkCount),
                    completedBytes: min(
                        descriptor.item.fileSize,
                        Int64(completedCount * descriptor.chunkSize)
                    )
                )
            } catch {
                failChunkTransfer(request.transferID, error: error)
            }
        }
    }

    private func receiveChunk(_ payload: DeviceChunkPayload) {
        chunkTransferQueue.async { [weak self] in
            guard let self else { return }
            do {
                guard var value = lock.withLock({ incomingChunkTransfers[payload.transferID] }) else {
                    throw DeviceChunkTransferError.checkpointMismatch
                }
                try checkpointStore.accept(
                    payload,
                    descriptor: value.0,
                    checkpoint: &value.1
                )
                publishCheckpoint(descriptor: value.0, checkpoint: value.1)
                lock.withLock { incomingChunkTransfers[payload.transferID] = value }
                updateTransferProgress(
                    id: payload.transferID,
                    fraction: value.0.item.fileSize == 0
                        ? 1
                        : Double(value.1.completedBytes) / Double(value.0.item.fileSize),
                    completedBytes: value.1.completedBytes
                )
                if value.1.isComplete {
                    finishIncomingChunkTransfer(descriptor: value.0, checkpoint: value.1)
                } else {
                    requestMissingChunks(descriptor: value.0, checkpoint: value.1)
                }
            } catch {
                failChunkTransfer(payload.transferID, error: error)
            }
        }
    }

    private func finishIncomingChunkTransfer(
        descriptor: DeviceChunkTransferDescriptor,
        checkpoint: DeviceTransferCheckpoint
    ) {
        updateTransfer(id: descriptor.transferID, phase: .verifying)
        do {
            let partial = try checkpointStore.finalizedFile(
                descriptor: descriptor,
                checkpoint: checkpoint
            )
            let alreadyStored = DispatchQueue.main.sync {
                localItems.contains { $0.sha256 == descriptor.item.sha256 }
            }
            var storedItem: DeviceSyncItem?
            var destination: URL?
            if !alreadyStored {
                let target = try Self.uniqueDestination(for: descriptor.item.fileName)
                try FileManager.default.copyItem(at: partial, to: target)
                var item = descriptor.item
                item.id = UUID()
                item.fileName = target.lastPathComponent
                storedItem = item
                destination = target
            }
            try checkpointStore.remove(forSHA256: descriptor.item.sha256)
            refreshResumableTransfers()
            _ = lock.withLock { incomingChunkTransfers.removeValue(forKey: descriptor.transferID) }
            updateTransferProgress(
                id: descriptor.transferID,
                fraction: 1,
                completedBytes: descriptor.item.fileSize
            )
            updateTransfer(id: descriptor.transferID, phase: .completed)
            send(.chunkCompletion(.init(
                transferID: descriptor.transferID,
                sha256: descriptor.item.sha256
            )))
            if let storedItem, let destination {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    localItems.append(storedItem)
                    localItems.sort {
                        $0.title.localizedStandardCompare($1.title) == .orderedAscending
                    }
                    lock.withLock { localURLs[storedItem.id] = destination }
                    Self.saveManifest(localItems)
                    sendManifestIfConnected()
                }
            }
        } catch {
            failChunkTransfer(descriptor.transferID, error: error)
        }
    }

    private func finishOutgoingChunkTransfer(_ completion: DeviceChunkCompletion) {
        let outgoing = lock.withLock { () -> (DeviceChunkTransferDescriptor, URL)? in
            pendingChunkRequests.removeValue(forKey: completion.transferID)
            pausedChunkTransferIDs.remove(completion.transferID)
            return outgoingChunkTransfers.removeValue(forKey: completion.transferID)
        }
        guard let descriptor = outgoing?.0,
              completion.sha256 == descriptor.item.sha256 else {
            updateTransfer(
                id: completion.transferID,
                phase: .failed(DeviceChunkTransferError.finalHashMismatch.localizedDescription)
            )
            return
        }
        updateTransferProgress(
            id: completion.transferID,
            fraction: 1,
            completedBytes: descriptor.item.fileSize
        )
        updateTransfer(id: completion.transferID, phase: .completed)
    }

    private func failChunkTransfer(_ transferID: UUID, error: Error) {
        lock.withLock {
            outgoingChunkTransfers.removeValue(forKey: transferID)
            incomingChunkTransfers.removeValue(forKey: transferID)
            pendingChunkRequests.removeValue(forKey: transferID)
            pausedChunkTransferIDs.remove(transferID)
        }
        updateTransfer(id: transferID, phase: .failed(error.localizedDescription))
        send(.transferControl(.init(transferID: transferID, action: .cancel)))
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
            let destination = try Self.uniqueDestination(for: announcement.item.fileName)
            try FileManager.default.copyItem(at: temporaryURL, to: destination)
            var storedItem = announcement.item
            storedItem.id = UUID()
            storedItem.fileName = destination.lastPathComponent
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                localItems.append(storedItem)
                localItems.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                lock.withLock { localURLs[storedItem.id] = destination }
                Self.saveManifest(localItems)
                updateTransfer(id: transferID, phase: .completed)
                updateTransferProgress(id: transferID, fraction: 1, completedBytes: announcement.item.fileSize)
                removeProgress(for: transferID)
                sendManifestIfConnected()
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
            self?.updateTransferProgress(
                id: transferID,
                fraction: value.fractionCompleted,
                completedBytes: value.completedUnitCount
            )
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

    private func applyTransferControl(_ control: DeviceTransferControl, notifyPeer: Bool) {
        let progress = lock.withLock { transferProgresses[control.transferID] }
        switch control.action {
        case .pause:
            _ = lock.withLock { pausedChunkTransferIDs.insert(control.transferID) }
            progress?.pause()
            updateTransfer(id: control.transferID, phase: .paused)
        case .resume:
            let pending = lock.withLock { () -> DeviceChunkRequest? in
                pausedChunkTransferIDs.remove(control.transferID)
                return pendingChunkRequests.removeValue(forKey: control.transferID)
            }
            progress?.resume()
            updateTransfer(id: control.transferID, phase: .transferring)
            if let pending { sendRequestedChunk(pending) }
        case .cancel:
            let incoming = lock.withLock { () -> (DeviceChunkTransferDescriptor, DeviceTransferCheckpoint)? in
                terminalTransferActions[control.transferID] = .cancel
                pausedChunkTransferIDs.remove(control.transferID)
                pendingChunkRequests.removeValue(forKey: control.transferID)
                outgoingChunkTransfers.removeValue(forKey: control.transferID)
                return incomingChunkTransfers.removeValue(forKey: control.transferID)
            }
            progress?.cancel()
            updateTransfer(id: control.transferID, phase: .cancelled)
            removeProgress(for: control.transferID)
            if let descriptor = incoming?.0 {
                try? checkpointStore.remove(forSHA256: descriptor.item.sha256)
                refreshResumableTransfers()
            }
        case .insufficientStorage:
            lock.withLock {
                terminalTransferActions[control.transferID] = .insufficientStorage
                pausedChunkTransferIDs.remove(control.transferID)
                pendingChunkRequests.removeValue(forKey: control.transferID)
                outgoingChunkTransfers.removeValue(forKey: control.transferID)
            }
            progress?.cancel()
            updateTransfer(id: control.transferID, phase: .insufficientStorage)
            removeProgress(for: control.transferID)
        }
        if notifyPeer { send(.transferControl(control)) }
    }

    private func interruptActiveTransfers() {
        lock.withLock { Array(transferProgresses.values) }.forEach { $0.cancel() }
        lock.withLock {
            transferObservations.values.forEach { $0.invalidate() }
            transferObservations.removeAll()
            transferProgresses.removeAll()
            pendingResources.removeAll()
            terminalTransferActions.removeAll()
            outgoingChunkTransfers.removeAll()
            incomingChunkTransfers.removeAll()
            pendingChunkRequests.removeAll()
            pausedChunkTransferIDs.removeAll()
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for index in transfers.indices where transfers[index].isActive {
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
        chunkTransferQueue.async { [weak self] in
            guard let self else { return }
            if removingStale {
                _ = try? checkpointStore.removeStale(
                    before: Date().addingTimeInterval(-30 * 24 * 60 * 60)
                )
            }
            let summaries = (try? checkpointStore.summaries()) ?? []
            DispatchQueue.main.async { [weak self] in
                self?.resumableTransfers = summaries
            }
        }
    }

    private func publishCheckpoint(
        descriptor: DeviceChunkTransferDescriptor,
        checkpoint: DeviceTransferCheckpoint
    ) {
        let summary = DeviceTransferCheckpointSummary(
            itemSHA256: checkpoint.itemSHA256,
            title: checkpoint.itemTitle ?? descriptor.item.title,
            fileSize: checkpoint.fileSize,
            completedBytes: checkpoint.completedBytes,
            updatedAt: checkpoint.updatedAt
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            resumableTransfers.removeAll { $0.id == summary.id }
            resumableTransfers.append(summary)
            resumableTransfers.sort { $0.updatedAt > $1.updatedAt }
        }
    }

    private static var manifestURL: URL {
        tracksDirectory.appendingPathComponent("ongaku-mobile-manifest.json")
    }

    private static func loadStoredLibrary() -> (items: [DeviceSyncItem], urls: [UUID: URL]) {
        try? FileManager.default.createDirectory(at: tracksDirectory, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode([DeviceSyncItem].self, from: data) else {
            return ([], [:])
        }
        let valid = decoded.filter {
            FileManager.default.fileExists(atPath: tracksDirectory.appendingPathComponent($0.fileName).path)
        }
        return (valid, Dictionary(uniqueKeysWithValues: valid.map {
            ($0.id, tracksDirectory.appendingPathComponent($0.fileName))
        }))
    }

    private static func saveManifest(_ items: [DeviceSyncItem]) {
        try? FileManager.default.createDirectory(at: tracksDirectory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    private static func copyIntoLibrary(
        _ urls: [URL],
        existing: [DeviceSyncItem]
    ) -> (items: [DeviceSyncItem], urls: [UUID: URL]) {
        try? FileManager.default.createDirectory(at: tracksDirectory, withIntermediateDirectories: true)
        var items = existing
        var outputURLs = Dictionary(uniqueKeysWithValues: existing.map {
            ($0.id, tracksDirectory.appendingPathComponent($0.fileName))
        })
        var knownHashes = Set(existing.map(\.sha256))

        for source in urls {
            let accessing = source.startAccessingSecurityScopedResource()
            defer { if accessing { source.stopAccessingSecurityScopedResource() } }
            do {
                let hash = try DeviceSyncFileIntegrity.sha256(of: source)
                guard knownHashes.insert(hash).inserted else { continue }
                let values = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let destination = try uniqueDestination(for: source.lastPathComponent)
                try FileManager.default.copyItem(at: source, to: destination)
                let item = DeviceSyncItem(
                    id: UUID(),
                    title: source.deletingPathExtension().lastPathComponent,
                    artist: "",
                    album: "",
                    fileName: destination.lastPathComponent,
                    fileSize: Int64(values.fileSize ?? 0),
                    sha256: hash,
                    modifiedAt: values.contentModificationDate ?? .now
                )
                items.append(item)
                outputURLs[item.id] = destination
            } catch {
                continue
            }
        }
        return (items, outputURLs)
    }

    private static func uniqueDestination(for fileName: String) throws -> URL {
        try FileManager.default.createDirectory(at: tracksDirectory, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: fileName)
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var candidate = tracksDirectory.appendingPathComponent(source.lastPathComponent)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            candidate = tracksDirectory.appendingPathComponent(next)
            counter += 1
        }
        return candidate
    }
}

extension MobileSyncController: MCNearbyServiceAdvertiserDelegate {
    func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        let requestID = UUID()
        let receivedCode = context
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }?["pairingCode"]
            ?? pairingCode
        lock.withLock { invitationHandlers[requestID] = invitationHandler }
        DispatchQueue.main.async { [weak self] in
            self?.advertisingRetryWorkItem?.cancel()
            self?.advertisingRetryWorkItem = nil
            self?.pairingRequest = MobilePairingRequest(
                id: requestID,
                deviceName: peerID.displayName,
                pairingCode: receivedCode
            )
        }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        publishFailure(error.localizedDescription)
    }
}

extension MobileSyncController: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let name = peerID.displayName
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch state {
            case .notConnected:
                interruptActiveTransfers()
                connectionState = isStarted ? .searching : .disconnected
                remoteItems = []
                if isStarted { scheduleAdvertisingRetry() }
            case .connecting:
                connectionState = .connecting(name)
            case .connected:
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
        do {
            handle(try decoder.decode(DeviceSyncMessage.self, from: data))
        } catch {
            publishFailure(error.localizedDescription)
        }
    }

    func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {
        guard let transferID = UUID(uuidString: resourceName) else { return }
        if lock.withLock({ terminalTransferActions[transferID] }) != nil {
            progress.cancel()
            return
        }
        observe(progress, transferID: transferID)
    }

    func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: Error?
    ) {
        finishReceivedResource(name: resourceName, temporaryURL: localURL, error: error)
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
