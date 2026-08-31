@preconcurrency import MultipeerConnectivity
import AppKit
import Foundation
import IOKit

struct DiscoveredPhone: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var pairingCode: String
}

struct USBMobileDevice: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
}

final class PhoneSyncController: NSObject, ObservableObject, @unchecked Sendable {
    nonisolated static let auditHistoryDefaultsKey = "deviceSync.overlayAudit.v1"
    @Published private(set) var connectionState: DeviceSyncConnectionState = .disconnected
    @Published private(set) var discoveredPhones: [DiscoveredPhone] = []
    @Published private(set) var usbMobileDevices: [USBMobileDevice] = []
    @Published private(set) var remoteItems: [DeviceSyncItem] = []
    @Published private(set) var remoteStorageInfo: DeviceStorageInfo?
    @Published private(set) var remoteOverlays: [DeviceSyncTrackOverlay] = []
    @Published private(set) var remotePlaylistOverlays: [DeviceSyncPlaylistOverlay] = []
    @Published private(set) var latestOverlayReceipt: DeviceSyncOverlayReceipt?
    @Published private(set) var overlayAuditHistory: [DeviceSyncAuditEntry] = []
    @Published private(set) var transfers: [DeviceTransferState] = []
    @Published private(set) var isBulkSyncing = false
    @Published private(set) var bulkSyncTotalCount = 0
    @Published private(set) var bulkSyncCompletedCount = 0
    @Published private(set) var bulkSyncFailedCount = 0
    @Published private(set) var bulkSyncCurrentTitle: String?

    var onVerifiedIncomingFile: ((URL) -> Void)?
    var onReceivedOverlays: (([DeviceSyncTrackOverlay]) -> Void)?

    private let peerID = MCPeerID(displayName: Host.current().localizedName ?? "Mac")
    private lazy var session = MCSession(
        peer: peerID,
        securityIdentity: nil,
        encryptionPreference: .required
    )
    private lazy var browser = MCNearbyServiceBrowser(
        peer: peerID,
        serviceType: DeviceSyncService.serviceType
    )
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var peersByID: [String: MCPeerID] = [:]
    private var localItems: [UUID: DeviceSyncItem] = [:]
    private var localURLs: [UUID: URL] = [:]
    private var localOverlays: [DeviceSyncTrackOverlay] = []
    private var localPlaylistOverlays: [DeviceSyncPlaylistOverlay] = []
    private var pendingResources: [UUID: DeviceSyncResourceAnnouncement] = [:]
    private var transferProgresses: [UUID: Progress] = [:]
    private var transferObservations: [UUID: NSKeyValueObservation] = [:]
    private var terminalTransferActions: [UUID: DeviceTransferControlAction] = [:]
    private var bulkUploadQueue: [UUID] = []
    private var bulkDownloadQueue: [UUID] = []
    private var bulkDownloadAwaitingSHA256: String?
    private var bulkOperationTimeoutWorkItem: DispatchWorkItem?
    private var discoveryRetryWorkItem: DispatchWorkItem?
    private var connectionAttemptTimeoutWorkItem: DispatchWorkItem?
    private var usbDetectionTimer: DispatchSourceTimer?
    private let usbDetectionQueue = DispatchQueue(
        label: "com.matsushibadenki.OngakuDesktop.usb-device-detection",
        qos: .utility
    )
    private var automaticInvitationCooldowns: [String: Date] = [:]
    private var isStarted = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        session.delegate = self
        browser.delegate = self
        if let data = defaults.data(forKey: Self.auditHistoryDefaultsKey),
           let history = try? decoder.decode([DeviceSyncAuditEntry].self, from: data) {
            overlayAuditHistory = history
        }
    }

    deinit {
        bulkOperationTimeoutWorkItem?.cancel()
        connectionAttemptTimeoutWorkItem?.cancel()
        usbDetectionTimer?.cancel()
        transferProgresses.values.forEach { $0.cancel() }
        browser.stopBrowsingForPeers()
        session.disconnect()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        connectionState = .searching
        startUSBDetection()
        beginBrowsing()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        discoveryRetryWorkItem?.cancel()
        discoveryRetryWorkItem = nil
        connectionAttemptTimeoutWorkItem?.cancel()
        connectionAttemptTimeoutWorkItem = nil
        browser.stopBrowsingForPeers()
        session.disconnect()
        connectionState = .disconnected
        discoveredPhones = []
        remoteItems = []
        remoteStorageInfo = nil
        stopUSBDetection()
        resetBulkSync()
    }

    func updateLocalTracks(
        _ tracks: [Track],
        playbackEvents: [PlaybackEvent] = [],
        playlists: [Playlist] = [],
        displayTags: [Track.ID: [String]] = [:]
    ) {
        var items: [UUID: DeviceSyncItem] = [:]
        var urls: [UUID: URL] = [:]
        let statistics = PlaybackStatisticsResolver.statistics(
            events: playbackEvents,
            tracks: tracks
        )
        for track in tracks where track.health == .verified {
            let item = DeviceSyncItem(
                id: track.id,
                title: track.title,
                artist: track.artist,
                album: track.album,
                fileName: track.fileURL.lastPathComponent,
                fileSize: track.fileSize,
                sha256: track.sha256,
                modifiedAt: track.lastVerifiedAt ?? track.addedAt
            )
            items[item.id] = item
            urls[item.id] = track.fileURL
        }
        let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        let playlistOverlays = playlists.filter { $0.smartDefinition == nil }.map { playlist in
            DeviceSyncPlaylistOverlay(
                id: playlist.id,
                name: playlist.name,
                tracks: playlist.entries.compactMap { entry in
                    guard let track = tracksByID[entry.trackID] else { return nil }
                    return DeviceSyncTrackReference(
                        sourceKey: "ongakuManaged:\(track.id.uuidString)",
                        title: track.title,
                        artist: track.artist,
                        album: track.album,
                        duration: track.duration
                    )
                },
                createdAt: playlist.createdAt,
                updatedAt: playlist.updatedAt
            )
        }
        lock.withLock {
            localItems = items
            localURLs = urls
            localOverlays = tracks.map { track in
                let trackStatistics = statistics[track.id] ?? TrackPlaybackStatistics()
                return DeviceSyncTrackOverlay(
                    sourceKey: "ongakuManaged:\(track.id.uuidString)",
                    title: track.title,
                    artist: track.artist,
                    album: track.album,
                    duration: track.duration,
                    isFavorite: track.isFavorite,
                    rating: track.rating,
                    playCount: trackStatistics.playCount,
                    skipCount: trackStatistics.skipCount,
                    lastPlayedAt: trackStatistics.lastPlayedAt,
                    displayTags: displayTags[track.id] ?? [],
                    updatedAt: max(
                        track.syncedOverlayUpdatedAt ?? .distantPast,
                        trackStatistics.lastPlayedAt ?? track.addedAt
                    )
                )
            }
            localPlaylistOverlays = playlistOverlays
        }
        sendManifestIfConnected()
    }

    var overlayPreviews: [DeviceSyncOverlayPreview] {
        let locals = lock.withLock { localOverlays }
        return remoteOverlays.map { remote in
            let matches = locals.filter { remote.matchesIdentity(of: $0) }
            guard matches.count == 1, let local = matches.first else {
                return DeviceSyncOverlayPreview(
                    remote: remote,
                    local: nil,
                    localTrackID: nil,
                    status: matches.isEmpty ? .unmatched : .ambiguous
                )
            }
            let trackID = UUID(uuidString: local.sourceKey.split(separator: ":").last.map(String.init) ?? "")
            return DeviceSyncOverlayPreview(
                remote: remote,
                local: local,
                localTrackID: trackID,
                status: remote.hasSameValues(as: local) ? .identical : .different
            )
        }.sorted {
            $0.remote.title.localizedStandardCompare($1.remote.title) == .orderedAscending
        }
    }

    func playlistPreviews(
        tracks: [Track],
        playlists: [Playlist]
    ) -> [DeviceSyncPlaylistPreview] {
        let localOverlays = tracks.map { track in
            DeviceSyncTrackOverlay(
                sourceKey: "ongakuManaged:\(track.id.uuidString)",
                title: track.title,
                artist: track.artist,
                album: track.album,
                duration: track.duration,
                isFavorite: track.isFavorite,
                rating: track.rating,
                playCount: 0,
                skipCount: 0,
                lastPlayedAt: nil,
                updatedAt: track.syncedOverlayUpdatedAt ?? track.addedAt
            )
        }
        let trackIDsBySourceKey = Dictionary(uniqueKeysWithValues: zip(
            localOverlays.map(\.sourceKey), tracks.map(\.id)
        ))

        return remotePlaylistOverlays.map { remote in
            var matchedTrackIDs: [Track.ID] = []
            var unmatchedTrackCount = 0
            var ambiguousTrackCount = 0
            for reference in remote.tracks {
                let matches = localOverlays.filter { reference.matchesIdentity(of: $0) }
                if matches.isEmpty {
                    unmatchedTrackCount += 1
                } else if matches.count > 1 {
                    ambiguousTrackCount += 1
                } else if let sourceKey = matches.first?.sourceKey,
                          let trackID = trackIDsBySourceKey[sourceKey] {
                    matchedTrackIDs.append(trackID)
                }
            }

            let local = playlists.first(where: { $0.id == remote.id })
            let hasTrackConflict = unmatchedTrackCount > 0 || ambiguousTrackCount > 0
            let status: DeviceSyncPlaylistMatchStatus
            if hasTrackConflict || local?.smartDefinition != nil {
                status = .conflicted
            } else if let local {
                let localTrackIDs = local.entries.map(\.trackID)
                status = local.name == remote.name && localTrackIDs == matchedTrackIDs
                    ? .identical
                    : .different
            } else {
                status = .new
            }
            return DeviceSyncPlaylistPreview(
                remote: remote,
                local: local,
                matchedTrackIDs: matchedTrackIDs,
                unmatchedTrackCount: unmatchedTrackCount,
                ambiguousTrackCount: ambiguousTrackCount,
                status: status
            )
        }.sorted {
            $0.remote.name.localizedStandardCompare($1.remote.name) == .orderedAscending
        }
    }

    func connect(to phone: DiscoveredPhone) {
        invite(phone, automatically: false)
    }

    func openFinderForUSBFileSharing() {
        let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        NSWorkspace.shared.openApplication(
            at: finderURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    func sendOverlayReceipt(_ receipt: DeviceSyncOverlayReceipt) {
        latestOverlayReceipt = receipt
        send(.overlayReceipt(receipt))
    }

    func recordOverlayAudit(_ entry: DeviceSyncAuditEntry) {
        overlayAuditHistory.insert(entry, at: 0)
        overlayAuditHistory = Array(overlayAuditHistory.prefix(50))
        persistOverlayAuditHistory()
    }

    func markOverlayAuditUndone(_ id: UUID) {
        guard let index = overlayAuditHistory.firstIndex(where: { $0.id == id }) else { return }
        overlayAuditHistory[index].isUndone = true
        persistOverlayAuditHistory()
    }

    private func persistOverlayAuditHistory() {
        guard let data = try? encoder.encode(overlayAuditHistory) else { return }
        defaults.set(data, forKey: Self.auditHistoryDefaultsKey)
    }

    private func invite(_ phone: DiscoveredPhone, automatically: Bool) {
        guard let peer = lock.withLock({ peersByID[phone.id] }) else { return }
        guard session.connectedPeers.isEmpty else { return }
        if automatically {
            guard automaticInvitationCooldowns[phone.id, default: .distantPast] <= .now else {
                return
            }
            automaticInvitationCooldowns[phone.id] = .now.addingTimeInterval(5 * 60)
        }
        connectionAttemptTimeoutWorkItem?.cancel()
        connectionState = .connecting(phone.name)
        let context = try? encoder.encode(["pairingCode": phone.pairingCode])
        browser.invitePeer(peer, to: session, withContext: context, timeout: 30)

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            guard let self,
                  case .connecting = connectionState,
                  session.connectedPeers.isEmpty else { return }
            connectionState = .failed(L10n.text("deviceSync.connect.timeout"))
            connectionAttemptTimeoutWorkItem = nil
        }
        connectionAttemptTimeoutWorkItem = timeoutWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeoutWorkItem)
    }

    private func attemptAutomaticConnection(to phone: DiscoveredPhone) {
        guard case .searching = connectionState else { return }
        invite(phone, automatically: true)
    }

    private func startUSBDetection() {
        guard usbDetectionTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: usbDetectionQueue)
        timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(300))
        timer.setEventHandler { [weak self] in
            let devices = Self.detectUSBMobileDevices()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let newlyConnected = usbMobileDevices.isEmpty && !devices.isEmpty
                usbMobileDevices = devices
                if newlyConnected, isStarted, session.connectedPeers.isEmpty {
                    beginBrowsing()
                }
            }
        }
        usbDetectionTimer = timer
        timer.resume()
    }

    private func stopUSBDetection() {
        usbDetectionTimer?.cancel()
        usbDetectionTimer = nil
        usbMobileDevices = []
    }

    nonisolated private static func detectUSBMobileDevices() -> [USBMobileDevice] {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var devices: [USBMobileDevice] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            let vendor = usbProperty("idVendor", from: service) as? NSNumber
            let supportsIPhoneOS = usbProperty("SupportsIPhoneOS", from: service) as? NSNumber
            guard vendor?.intValue == 0x05AC, supportsIPhoneOS?.boolValue == true else { continue }

            let name = (usbProperty("USB Product Name", from: service) as? String)
                ?? (usbProperty("kUSBProductString", from: service) as? String)
                ?? "iPhone"
            let serial = (usbProperty("USB Serial Number", from: service) as? String)
                ?? (usbProperty("kUSBSerialNumberString", from: service) as? String)
            var registryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &registryID)
            devices.append(USBMobileDevice(
                id: serial ?? String(registryID),
                name: name
            ))
        }
        return devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    nonisolated private static func usbProperty(
        _ key: String,
        from service: io_registry_entry_t
    ) -> Any? {
        IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
    }

    func disconnect() {
        session.disconnect()
        connectionState = isStarted ? .searching : .disconnected
        remoteItems = []
        remoteStorageInfo = nil
        connectionAttemptTimeoutWorkItem?.cancel()
        connectionAttemptTimeoutWorkItem = nil
        resetBulkSync()
        if isStarted { beginBrowsing() }
    }

    func retryDiscovery() {
        guard isStarted else {
            start()
            return
        }
        discoveredPhones = []
        connectionState = .searching
        beginBrowsing()
    }

    func uploadToPhone(_ item: DeviceSyncItem) {
        sendLocalItem(item.id, direction: .macToPhone)
    }

    func syncToPhone(_ items: [DeviceSyncItem]) {
        guard !isBulkSyncing, !session.connectedPeers.isEmpty else { return }

        var seenHashes: Set<String> = []
        let pending = items.filter { item in
            !hasRemoteCopy(of: item) && seenHashes.insert(item.sha256).inserted
        }
        guard !pending.isEmpty else { return }

        bulkUploadQueue = pending.map(\.id)
        bulkDownloadQueue = []
        bulkDownloadAwaitingSHA256 = nil
        bulkSyncTotalCount = pending.count
        bulkSyncCompletedCount = 0
        bulkSyncFailedCount = 0
        bulkSyncCurrentTitle = nil
        isBulkSyncing = true
        sendNextBulkItem()
    }

    func synchronizeBidirectionally(
        uploadItems: [DeviceSyncItem],
        downloadItems: [DeviceSyncItem]
    ) {
        guard !isBulkSyncing, !session.connectedPeers.isEmpty else { return }

        var uploadHashes: Set<String> = []
        let uploads = uploadItems.filter {
            !hasRemoteCopy(of: $0) && uploadHashes.insert($0.sha256).inserted
        }
        var downloadHashes: Set<String> = []
        let downloads = downloadItems.filter {
            !hasLocalCopy(of: $0) && downloadHashes.insert($0.sha256).inserted
        }
        guard !uploads.isEmpty || !downloads.isEmpty else { return }

        bulkUploadQueue = uploads.map(\.id)
        bulkDownloadQueue = downloads.map(\.id)
        bulkDownloadAwaitingSHA256 = nil
        bulkSyncTotalCount = uploads.count + downloads.count
        bulkSyncCompletedCount = 0
        bulkSyncFailedCount = 0
        bulkSyncCurrentTitle = nil
        isBulkSyncing = true
        sendNextBulkItem()
    }

    func downloadFromPhone(_ item: DeviceSyncItem) {
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
        lock.withLock { localItems.values.contains(where: { $0.sha256 == item.sha256 }) }
    }

    func hasRemoteCopy(of item: DeviceSyncItem) -> Bool {
        remoteItems.contains { $0.sha256 == item.sha256 }
    }

    private func resetBulkSync() {
        bulkOperationTimeoutWorkItem?.cancel()
        bulkOperationTimeoutWorkItem = nil
        bulkUploadQueue = []
        bulkDownloadQueue = []
        bulkDownloadAwaitingSHA256 = nil
        isBulkSyncing = false
        bulkSyncTotalCount = 0
        bulkSyncCompletedCount = 0
        bulkSyncFailedCount = 0
        bulkSyncCurrentTitle = nil
    }

    private func sendNextBulkItem() {
        guard isBulkSyncing else { return }

        if bulkDownloadAwaitingSHA256 != nil { return }
        if !bulkDownloadQueue.isEmpty {
            let itemID = bulkDownloadQueue.removeFirst()
            guard let item = remoteItems.first(where: { $0.id == itemID }) else {
                bulkSyncFailedCount += 1
                sendNextBulkItem()
                return
            }
            bulkSyncCurrentTitle = item.title
            bulkDownloadAwaitingSHA256 = item.sha256
            send(.requestItem(item.id))
            scheduleBulkDownloadTimeout(for: item.sha256)
            return
        }

        guard !bulkUploadQueue.isEmpty else {
            isBulkSyncing = false
            bulkSyncCurrentTitle = nil
            return
        }

        let itemID = bulkUploadQueue.removeFirst()
        bulkSyncCurrentTitle = lock.withLock { localItems[itemID]?.title }
        sendLocalItem(itemID, direction: .macToPhone) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.isBulkSyncing else { return }
                if error == nil {
                    self.bulkSyncCompletedCount += 1
                } else {
                    self.bulkSyncFailedCount += 1
                }
                self.sendNextBulkItem()
            }
        }
    }

    private func scheduleBulkDownloadTimeout(for sha256: String) {
        bulkOperationTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  isBulkSyncing,
                  bulkDownloadAwaitingSHA256 == sha256 else { return }
            bulkDownloadAwaitingSHA256 = nil
            bulkSyncFailedCount += 1
            bulkOperationTimeoutWorkItem = nil
            sendNextBulkItem()
        }
        bulkOperationTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: workItem)
    }

    private func completeBulkDownloadIfNeeded(
        _ announcement: DeviceSyncResourceAnnouncement,
        error: Error?
    ) {
        guard announcement.direction == .phoneToMac else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  isBulkSyncing,
                  bulkDownloadAwaitingSHA256 == announcement.item.sha256 else { return }
            bulkOperationTimeoutWorkItem?.cancel()
            bulkOperationTimeoutWorkItem = nil
            bulkDownloadAwaitingSHA256 = nil
            if error == nil {
                bulkSyncCompletedCount += 1
            } else {
                bulkSyncFailedCount += 1
            }
            sendNextBulkItem()
        }
    }

    private func sendManifestIfConnected() {
        guard !session.connectedPeers.isEmpty else { return }
        let values = lock.withLock {
            (Array(localItems.values), localOverlays, localPlaylistOverlays)
        }
        send(.manifest(DeviceSyncManifest(
            deviceName: peerID.displayName,
            generatedAt: .now,
            items: values.0.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending },
            overlays: values.1,
            playlistOverlays: values.2
        )))
    }

    private func beginBrowsing() {
        discoveryRetryWorkItem?.cancel()
        if session.connectedPeers.isEmpty {
            connectionState = .searching
        }
        browser.stopBrowsingForPeers()
        browser.startBrowsingForPeers()
        scheduleDiscoveryRetry()
    }

    private func scheduleDiscoveryRetry() {
        discoveryRetryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  isStarted,
                  session.connectedPeers.isEmpty,
                  discoveredPhones.isEmpty else { return }
            browser.stopBrowsingForPeers()
            browser.startBrowsingForPeers()
            scheduleDiscoveryRetry()
        }
        discoveryRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: workItem)
    }

    private func send(_ message: DeviceSyncMessage) {
        guard !session.connectedPeers.isEmpty else { return }
        do {
            let data = try encoder.encode(message)
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
        } catch {
            publishFailure(error.localizedDescription)
        }
    }

    private func sendLocalItem(
        _ id: UUID,
        direction: DeviceSyncDirection,
        completion: ((Error?) -> Void)? = nil
    ) {
        let value = lock.withLock { () -> (DeviceSyncItem, URL)? in
            guard let item = localItems[id], let url = localURLs[id] else { return nil }
            return (item, url)
        }
        guard let (item, url) = value, let peer = session.connectedPeers.first else {
            completion?(CocoaError(.fileNoSuchFile))
            return
        }

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
            completion?(error)
        }
        if let progress { observe(progress, transferID: transferID) }
    }

    private func handle(_ message: DeviceSyncMessage) {
        switch message {
        case .manifest(let manifest):
            DispatchQueue.main.async { [weak self] in
                self?.remoteItems = manifest.items
                self?.remoteStorageInfo = manifest.storage
                self?.remoteOverlays = manifest.overlays ?? []
                self?.remotePlaylistOverlays = manifest.playlistOverlays ?? []
                if let overlays = manifest.overlays, !overlays.isEmpty {
                    self?.onReceivedOverlays?(overlays)
                }
            }
        case .requestItem(let id):
            sendLocalItem(id, direction: .macToPhone)
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
        case .overlayReceipt(let receipt):
            DispatchQueue.main.async { [weak self] in
                self?.latestOverlayReceipt = receipt
            }
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
            completeBulkDownloadIfNeeded(announcement, error: error)
            return
        }
        guard let temporaryURL else {
            let error = CocoaError(.fileNoSuchFile)
            updateTransfer(id: transferID, phase: .failed(error.localizedDescription))
            removeProgress(for: transferID)
            completeBulkDownloadIfNeeded(announcement, error: error)
            return
        }

        updateTransfer(id: transferID, phase: .verifying)
        do {
            guard try DeviceSyncFileIntegrity.verified(temporaryURL, matches: announcement.item) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let incomingDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("OngakuIncoming", isDirectory: true)
            try FileManager.default.createDirectory(
                at: incomingDirectory,
                withIntermediateDirectories: true
            )
            let destination = incomingDirectory.appendingPathComponent(
                "\(transferID.uuidString)-\(announcement.item.fileName)"
            )
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: temporaryURL, to: destination)
            updateTransfer(id: transferID, phase: .completed)
            updateTransferProgress(id: transferID, fraction: 1, completedBytes: announcement.item.fileSize)
            removeProgress(for: transferID)
            DispatchQueue.main.async { [weak self] in
                self?.onVerifiedIncomingFile?(destination)
            }
            completeBulkDownloadIfNeeded(announcement, error: nil)
        } catch {
            updateTransfer(id: transferID, phase: .failed(error.localizedDescription))
            removeProgress(for: transferID)
            completeBulkDownloadIfNeeded(announcement, error: error)
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
        let temporary = FileManager.default.temporaryDirectory
        guard let values = try? temporary.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]) else { return true }
        let available = values.volumeAvailableCapacityForImportantUsage
            ?? values.volumeAvailableCapacity.map(Int64.init)
        guard let available else { return true }
        return DeviceTransferCapacity.canReceive(fileSize: item.fileSize, availableBytes: available)
    }

    private func publishFailure(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.connectionState = .failed(message)
        }
    }
}

extension PhoneSyncController: MCNearbyServiceBrowserDelegate {
    func browser(
        _ browser: MCNearbyServiceBrowser,
        foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String: String]?
    ) {
        let id = peerID.displayName
        lock.withLock { peersByID[id] = peerID }
        let phone = DiscoveredPhone(
            id: id,
            name: peerID.displayName,
            pairingCode: info?["code"] ?? "------"
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            discoveryRetryWorkItem?.cancel()
            discoveryRetryWorkItem = nil
            if let index = discoveredPhones.firstIndex(where: { $0.id == id }) {
                discoveredPhones[index] = phone
            } else {
                discoveredPhones.append(phone)
            }
            attemptAutomaticConnection(to: phone)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        let id = peerID.displayName
        _ = lock.withLock { peersByID.removeValue(forKey: id) }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            discoveredPhones.removeAll { $0.id == id }
            if discoveredPhones.isEmpty, isStarted {
                scheduleDiscoveryRetry()
            }
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        publishFailure(error.localizedDescription)
    }
}

extension PhoneSyncController: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let name = peerID.displayName
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch state {
            case .notConnected:
                interruptActiveTransfers()
                connectionAttemptTimeoutWorkItem?.cancel()
                connectionAttemptTimeoutWorkItem = nil
                connectionState = isStarted ? .searching : .disconnected
                remoteItems = []
                remoteStorageInfo = nil
                resetBulkSync()
                if isStarted { scheduleDiscoveryRetry() }
            case .connecting:
                connectionState = .connecting(name)
            case .connected:
                connectionAttemptTimeoutWorkItem?.cancel()
                connectionAttemptTimeoutWorkItem = nil
                discoveryRetryWorkItem?.cancel()
                discoveryRetryWorkItem = nil
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
