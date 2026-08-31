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
    private var isStarted = false

    override init() {
        super.init()
        session.delegate = self
        advertiser.delegate = self
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
              let peer = session.connectedPeers.first else { return }

        let transferID = UUID()
        updateTransfer(DeviceTransferState(
            id: transferID,
            item: item,
            direction: direction,
            phase: .preparing
        ))
        send(.resource(DeviceSyncResourceAnnouncement(
            transferID: transferID,
            direction: direction,
            item: item
        )))
        updateTransfer(id: transferID, phase: .transferring)
        let progress = session.sendResource(at: url, withName: transferID.uuidString, toPeer: peer) { [weak self] error in
            let terminalAction = self?.lock.withLock {
                self?.terminalTransferActions.removeValue(forKey: transferID)
            } ?? nil
            self?.removeProgress(for: transferID)
            if terminalAction == .cancel {
                self?.updateTransfer(id: transferID, phase: .cancelled)
            } else if terminalAction == .insufficientStorage {
                self?.updateTransfer(id: transferID, phase: .insufficientStorage)
            } else if let error {
                self?.updateTransfer(id: transferID, phase: .failed(error.localizedDescription))
            } else {
                self?.updateTransferProgress(id: transferID, fraction: 1, completedBytes: item.fileSize)
                self?.updateTransfer(id: transferID, phase: .completed)
            }
        }
        if let progress { observe(progress, transferID: transferID) }
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
            progress?.pause()
            updateTransfer(id: control.transferID, phase: .paused)
        case .resume:
            progress?.resume()
            updateTransfer(id: control.transferID, phase: .transferring)
        case .cancel:
            lock.withLock { terminalTransferActions[control.transferID] = .cancel }
            progress?.cancel()
            updateTransfer(id: control.transferID, phase: .cancelled)
            removeProgress(for: control.transferID)
        case .insufficientStorage:
            lock.withLock { terminalTransferActions[control.transferID] = .insufficientStorage }
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
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for index in transfers.indices where transfers[index].isActive {
                transfers[index].phase = .interrupted
            }
        }
    }

    private static func canReceive(_ item: DeviceSyncItem) -> Bool {
        guard let storage = deviceStorageInfo() else { return true }
        return DeviceTransferCapacity.canReceive(
            fileSize: item.fileSize,
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
        var candidate = tracksDirectory.appendingPathComponent(fileName)
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
