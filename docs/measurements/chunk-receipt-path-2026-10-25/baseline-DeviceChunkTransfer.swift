import CryptoKit
import Foundation

struct DeviceChunkTransferDescriptor: Codable, Equatable, Sendable {
    static let maximumChunkCount = 1_000_000
    var transferID: UUID
    var direction: DeviceSyncDirection
    var item: DeviceSyncItem
    var chunkSize: Int
    var chunkHashes: [String]
    var supportsCompactRequests: Bool? = nil

    var chunkCount: Int { chunkHashes.count }

    var isValid: Bool {
        guard chunkSize >= 64 * 1_024,
              chunkSize <= 1_024 * 1_024,
              item.fileSize >= 0,
              item.sha256.isSHA256Hex else { return false }
        let size = Int64(chunkSize)
        let expectedCount64 = item.fileSize / size + (item.fileSize % size == 0 ? 0 : 1)
        guard expectedCount64 <= Int64(Self.maximumChunkCount) else { return false }
        let expectedCount = Int(expectedCount64)
        return chunkHashes.count == expectedCount
            && chunkHashes.allSatisfy(\.isSHA256Hex)
    }
}

/// An immutable, locally validated snapshot. Wire descriptors remain Codable
/// values; trust is acquired once on admission, never from a caller's flag.
struct ValidatedDeviceChunkTransferDescriptor: Sendable {
    let descriptor: DeviceChunkTransferDescriptor

    init(_ descriptor: DeviceChunkTransferDescriptor) throws {
        guard descriptor.isValid else { throw DeviceChunkTransferError.invalidDescriptor }
        self.descriptor = descriptor
    }
}

struct DeviceChunkRequest: Codable, Equatable, Sendable {
    var transferID: UUID
    var missingIndexes: [Int]
    // Advertised senders understand this count even when only one index is sent.
    var remainingChunkCount: Int? = nil
}

/// Session-local cursor over an admitted checkpoint. Received indexes only grow
/// during a session; a resumed/new connection creates a fresh cursor.
struct DeviceChunkRequestCursor: Sendable {
    private var nextIndex = 0

    mutating func request(descriptor: DeviceChunkTransferDescriptor,
                          checkpoint: DeviceTransferCheckpoint) -> DeviceChunkRequest {
        guard descriptor.supportsCompactRequests == true else {
            return .init(transferID: descriptor.transferID, missingIndexes: checkpoint.missingIndexes)
        }
        while nextIndex < descriptor.chunkCount && checkpoint.receivedIndexes.contains(nextIndex) {
            nextIndex += 1
        }
        return .init(transferID: descriptor.transferID,
                     missingIndexes: nextIndex < descriptor.chunkCount ? [nextIndex] : [],
                     remainingChunkCount: descriptor.chunkCount - checkpoint.receivedIndexes.count)
    }
}

struct DeviceChunkPayload: Codable, Equatable, Sendable {
    var transferID: UUID
    var index: Int
    var data: Data
}

struct DeviceChunkCompletion: Codable, Equatable, Sendable {
    var transferID: UUID
    var sha256: String
}

struct DeviceTransferCheckpoint: Codable, Equatable, Sendable {
    var itemSHA256: String
    var itemTitle: String? = nil
    var fileName: String? = nil
    var direction: DeviceSyncDirection? = nil
    var fileSize: Int64
    var chunkSize: Int
    var chunkHashes: [String]
    var receivedIndexes: Set<Int>
    var updatedAt: Date
    // Local checkpoint generation; absent in legacy JSON. Never sent on the wire.
    var storageGeneration: UUID? = nil

    var missingIndexes: [Int] {
        chunkHashes.indices.filter { !receivedIndexes.contains($0) }
    }

    var isComplete: Bool {
        receivedIndexes.count == chunkHashes.count && missingIndexes.isEmpty
    }

    var completedBytes: Int64 {
        receivedIndexes.reduce(into: Int64(0)) { total, index in
            let offset = Int64(index * chunkSize)
            total += min(Int64(chunkSize), max(0, fileSize - offset))
        }
    }
}

struct DeviceTransferCheckpointSummary: Identifiable, Equatable, Sendable {
    var id: String { itemSHA256 }
    var itemSHA256: String
    var title: String
    var fileSize: Int64
    var completedBytes: Int64
    var updatedAt: Date

    var fractionCompleted: Double {
        fileSize == 0 ? 1 : min(max(Double(completedBytes) / Double(fileSize), 0), 1)
    }
}

enum DeviceChunkTransferError: Error, Equatable {
    case invalidDescriptor
    case invalidChunkIndex
    case invalidChunkSize
    case chunkHashMismatch
    case checkpointMismatch
    case incompleteTransfer
    case finalHashMismatch
}

enum DeviceChunkTransfer {
    static let defaultChunkSize = 256 * 1_024

    static func descriptor(
        for item: DeviceSyncItem,
        at fileURL: URL,
        transferID: UUID = UUID(),
        direction: DeviceSyncDirection,
        chunkSize: Int = defaultChunkSize
    ) throws -> DeviceChunkTransferDescriptor {
        try validatedDescriptor(for: item, at: fileURL, transferID: transferID,
                                direction: direction, chunkSize: chunkSize).descriptor
    }

    static func validatedDescriptor(
        for item: DeviceSyncItem,
        at fileURL: URL,
        transferID: UUID = UUID(),
        direction: DeviceSyncDirection,
        chunkSize: Int = defaultChunkSize,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> ValidatedDeviceChunkTransferDescriptor {
        guard chunkSize >= 64 * 1_024, chunkSize <= 1_024 * 1_024 else {
            throw DeviceChunkTransferError.invalidDescriptor
        }
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        guard Int64(values.fileSize ?? -1) == item.fileSize else {
            throw DeviceChunkTransferError.invalidDescriptor
        }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hashes: [String] = []
        try checkCancellation()
        while let data = try handle.read(upToCount: chunkSize), !data.isEmpty {
            try checkCancellation()
            hashes.append(sha256(data))
        }
        try checkCancellation()
        let descriptor = DeviceChunkTransferDescriptor(
            transferID: transferID,
            direction: direction,
            item: item,
            chunkSize: chunkSize,
            chunkHashes: hashes,
            supportsCompactRequests: true
        )
        return try ValidatedDeviceChunkTransferDescriptor(descriptor)
    }

    static func payload(
        descriptor: DeviceChunkTransferDescriptor,
        index: Int,
        fileURL: URL
    ) throws -> DeviceChunkPayload {
        try payload(validatedDescriptor: ValidatedDeviceChunkTransferDescriptor(descriptor),
                    index: index, fileURL: fileURL)
    }

    static func payload(
        validatedDescriptor: ValidatedDeviceChunkTransferDescriptor,
        index: Int,
        fileURL: URL
    ) throws -> DeviceChunkPayload {
        let descriptor = validatedDescriptor.descriptor
        guard descriptor.chunkHashes.indices.contains(index) else {
            throw DeviceChunkTransferError.invalidChunkIndex
        }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(index * descriptor.chunkSize))
        let data = try handle.read(upToCount: descriptor.chunkSize) ?? Data()
        guard !data.isEmpty, data.count <= descriptor.chunkSize else {
            throw DeviceChunkTransferError.invalidChunkSize
        }
        guard sha256(data) == descriptor.chunkHashes[index] else {
            throw DeviceChunkTransferError.chunkHashMismatch
        }
        return DeviceChunkPayload(transferID: descriptor.transferID, index: index, data: data)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct DeviceTransferCheckpointStore: Sendable {
    let directory: URL

    func prepare(for descriptor: DeviceChunkTransferDescriptor) throws -> DeviceTransferCheckpoint {
        try prepare(validatedDescriptor: ValidatedDeviceChunkTransferDescriptor(descriptor))
    }

    func prepare(validatedDescriptor: ValidatedDeviceChunkTransferDescriptor) throws -> DeviceTransferCheckpoint {
        let descriptor = validatedDescriptor.descriptor
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let existing = try load(forSHA256: descriptor.item.sha256) {
            let partial = partialURL(forSHA256: descriptor.item.sha256)
            let partialSize = (try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            let requiredSize = existing.receivedIndexes.map { index -> Int in
                min(Int(existing.fileSize), (index + 1) * existing.chunkSize)
            }.max() ?? 0
            if existing.itemSHA256 == descriptor.item.sha256,
               existing.fileSize == descriptor.item.fileSize,
               existing.chunkSize == descriptor.chunkSize,
               existing.chunkHashes == descriptor.chunkHashes,
               existing.receivedIndexes.allSatisfy(descriptor.chunkHashes.indices.contains),
               partialSize >= requiredSize {
                // Share the already compared immutable hash array for this
                // session; resumed checkpoints otherwise own decoded copies.
                var resumed = existing
                resumed.chunkHashes = descriptor.chunkHashes
                return resumed
            } else {
                try remove(forSHA256: descriptor.item.sha256)
            }
        }
        let checkpoint = DeviceTransferCheckpoint(
            itemSHA256: descriptor.item.sha256,
            itemTitle: descriptor.item.title,
            fileName: descriptor.item.fileName,
            direction: descriptor.direction,
            fileSize: descriptor.item.fileSize,
            chunkSize: descriptor.chunkSize,
            chunkHashes: descriptor.chunkHashes,
            receivedIndexes: [],
            updatedAt: .now,
            storageGeneration: UUID()
        )
        FileManager.default.createFile(atPath: partialURL(forSHA256: descriptor.item.sha256).path, contents: nil)
        try save(checkpoint)
        return checkpoint
    }

    func accept(
        _ payload: DeviceChunkPayload,
        descriptor: DeviceChunkTransferDescriptor,
        checkpoint: inout DeviceTransferCheckpoint
    ) throws {
        guard let validated = try? ValidatedDeviceChunkTransferDescriptor(descriptor) else {
            throw DeviceChunkTransferError.checkpointMismatch
        }
        try accept(payload, validatedDescriptor: validated, checkpoint: &checkpoint)
    }

    func accept(
        _ payload: DeviceChunkPayload,
        validatedDescriptor: ValidatedDeviceChunkTransferDescriptor,
        checkpoint: inout DeviceTransferCheckpoint
    ) throws {
        let descriptor = validatedDescriptor.descriptor
        guard payload.transferID == descriptor.transferID,
              checkpoint.itemSHA256 == descriptor.item.sha256,
              checkpoint.fileSize == descriptor.item.fileSize,
              checkpoint.chunkSize == descriptor.chunkSize,
              checkpoint.chunkHashes == descriptor.chunkHashes else {
            throw DeviceChunkTransferError.checkpointMismatch
        }
        guard descriptor.chunkHashes.indices.contains(payload.index) else {
            throw DeviceChunkTransferError.invalidChunkIndex
        }
        let isLast = payload.index == descriptor.chunkCount - 1
        let expectedLastSize = descriptor.item.fileSize
            - Int64(payload.index) * Int64(descriptor.chunkSize)
        let expectedSize = isLast ? Int(expectedLastSize) : descriptor.chunkSize
        guard payload.data.count == expectedSize else {
            throw DeviceChunkTransferError.invalidChunkSize
        }
        guard DeviceChunkTransfer.sha256(payload.data) == descriptor.chunkHashes[payload.index] else {
            throw DeviceChunkTransferError.chunkHashMismatch
        }

        let partial = partialURL(forSHA256: descriptor.item.sha256)
        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(payload.index * descriptor.chunkSize))
        try handle.write(contentsOf: payload.data)
        var next = checkpoint
        next.receivedIndexes.insert(payload.index)
        next.updatedAt = .now
        // Migrate legacy metadata once, after a verified payload write. Each
        // subsequent acknowledgement only requires an atomic compact bitmap.
        if next.storageGeneration == nil {
            next.storageGeneration = UUID()
            try save(next)
        }
        try saveProgress(next)
        checkpoint = next
    }

    func finalizedFile(
        descriptor: DeviceChunkTransferDescriptor,
        checkpoint: DeviceTransferCheckpoint
    ) throws -> URL {
        try finalizedFile(descriptor: descriptor, checkpoint: checkpoint, checkCancellation: {})
    }

    func finalizedFile(
        descriptor: DeviceChunkTransferDescriptor,
        checkpoint: DeviceTransferCheckpoint,
        checkCancellation: () throws -> Void
    ) throws -> URL {
        try checkCancellation()
        guard checkpoint.isComplete else { throw DeviceChunkTransferError.incompleteTransfer }
        let partial = partialURL(forSHA256: descriptor.item.sha256)
        guard try DeviceSyncFileIntegrity.verified(partial, matches: descriptor.item, checkCancellation: checkCancellation) else {
            throw DeviceChunkTransferError.finalHashMismatch
        }
        return partial
    }

    func load(forSHA256 sha256: String) throws -> DeviceTransferCheckpoint? {
        guard sha256.isSHA256Hex else { throw DeviceChunkTransferError.invalidDescriptor }
        let url = checkpointURL(forSHA256: sha256)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var checkpoint = try JSONDecoder().decode(DeviceTransferCheckpoint.self, from: Data(contentsOf: url))
        let progressURL = progressURL(forSHA256: sha256)
        if FileManager.default.fileExists(atPath: progressURL.path) {
            let progress = try PropertyListDecoder().decode(Progress.self, from: Data(contentsOf: progressURL))
            // A stale sidecar must never mark chunks from replacement metadata
            // as received. Ignore only a well-formed, different generation.
            if let generation = checkpoint.storageGeneration, progress.generation == generation {
                guard progress.version == 1, progress.count == checkpoint.chunkHashes.count,
                      progress.count <= DeviceChunkTransferDescriptor.maximumChunkCount,
                      progress.bitmap.count == (progress.count + 7) / 8 else {
                    throw DeviceChunkTransferError.checkpointMismatch
                }
                checkpoint.receivedIndexes = Set((0..<progress.count).filter {
                    progress.bitmap[$0 / 8] & (UInt8(1) << ($0 % 8)) != 0
                })
                checkpoint.updatedAt = progress.updatedAt
            }
        }
        return checkpoint
    }

    func remove(forSHA256 sha256: String) throws {
        guard sha256.isSHA256Hex else { throw DeviceChunkTransferError.invalidDescriptor }
        for url in [progressURL(forSHA256: sha256), checkpointURL(forSHA256: sha256), partialURL(forSHA256: sha256)]
            where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func summaries() throws -> [DeviceTransferCheckpointSummary] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let checkpoint = try? load(forSHA256: url.deletingPathExtension().lastPathComponent) else { return nil }
                return DeviceTransferCheckpointSummary(
                    itemSHA256: checkpoint.itemSHA256,
                    title: checkpoint.itemTitle
                        ?? checkpoint.fileName
                        ?? String(checkpoint.itemSHA256.prefix(12)),
                    fileSize: checkpoint.fileSize,
                    completedBytes: checkpoint.completedBytes,
                    updatedAt: checkpoint.updatedAt
                )
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func removeAll() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for url in urls where url.pathExtension == "json" || url.pathExtension == "part" || url.pathExtension == "progress" {
            try FileManager.default.removeItem(at: url)
        }
    }

    @discardableResult
    func removeStale(before cutoff: Date) throws -> Int {
        let stale = try summaries().filter { $0.updatedAt < cutoff }
        for summary in stale { try remove(forSHA256: summary.itemSHA256) }
        return stale.count
    }

    private struct Progress: Codable {
        var version = 1
        var generation: UUID
        var count: Int
        var bitmap: Data
        var updatedAt: Date
    }

    private func saveProgress(_ checkpoint: DeviceTransferCheckpoint) throws {
        guard let generation = checkpoint.storageGeneration,
              checkpoint.chunkHashes.count <= DeviceChunkTransferDescriptor.maximumChunkCount else {
            throw DeviceChunkTransferError.checkpointMismatch
        }
        var bitmap = Data(repeating: 0, count: (checkpoint.chunkHashes.count + 7) / 8)
        for index in checkpoint.receivedIndexes {
            guard checkpoint.chunkHashes.indices.contains(index) else { throw DeviceChunkTransferError.invalidChunkIndex }
            bitmap[index / 8] |= UInt8(1) << (index % 8)
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(Progress(generation: generation, count: checkpoint.chunkHashes.count,
            bitmap: bitmap, updatedAt: checkpoint.updatedAt))
        try data.write(to: progressURL(forSHA256: checkpoint.itemSHA256), options: .atomic)
    }

    private func progressURL(forSHA256 sha256: String) -> URL {
        directory.appendingPathComponent("\(sha256).progress")
    }

    private func save(_ checkpoint: DeviceTransferCheckpoint) throws {
        let data = try JSONEncoder().encode(checkpoint)
        try data.write(to: checkpointURL(forSHA256: checkpoint.itemSHA256), options: .atomic)
    }

    private func checkpointURL(forSHA256 sha256: String) -> URL {
        directory.appendingPathComponent("\(sha256).json")
    }

    private func partialURL(forSHA256 sha256: String) -> URL {
        directory.appendingPathComponent("\(sha256).part")
    }
}

struct DeviceReceivedLibrarySnapshot: Equatable, Sendable {
    var items: [DeviceSyncItem]
    var fileURLs: [UUID: URL]
}

struct DeviceReceivedLibraryCommit: Equatable, Sendable {
    var snapshot: DeviceReceivedLibrarySnapshot
    var item: DeviceSyncItem
    var fileURL: URL
    var wasAlreadyStored: Bool
}

enum DeviceReceivedLibraryError: LocalizedError, Equatable {
    case corruptManifest
    case invalidFileName
    case verificationFailed

    var errorDescription: String? {
        let key = switch self {
        case .corruptManifest: "deviceReceivedLibrary.error.corruptManifest"
        case .invalidFileName: "deviceReceivedLibrary.error.invalidFileName"
        case .verificationFailed: "deviceReceivedLibrary.error.verificationFailed"
        }
        return NSLocalizedString(key, comment: "")
    }
}

/// Owns the durable commit boundary for files received by the mobile companion.
/// A transfer is complete only after the copied file and its manifest entry are durable.
final class DeviceReceivedLibraryRepository: @unchecked Sendable {
    private let directory: URL
    private let manifestURL: URL
    private let backupURL: URL
    private let fileManager: FileManager
    private let beforePersist: @Sendable () throws -> Void
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        directory: URL,
        manifestFileName: String = "ongaku-mobile-manifest.json",
        fileManager: FileManager = .default,
        beforePersist: @escaping @Sendable () throws -> Void = {}
    ) {
        self.directory = directory
        manifestURL = directory.appendingPathComponent(manifestFileName)
        backupURL = directory.appendingPathComponent("\(manifestFileName).previous")
        self.fileManager = fileManager
        self.beforePersist = beforePersist
    }

    func load() throws -> DeviceReceivedLibrarySnapshot {
        try lock.withLock {
            try prepareDirectory()
            return try loadRecoveringIfNeeded()
        }
    }

    func commitVerifiedFile(
        at sourceURL: URL,
        item proposedItem: DeviceSyncItem
    ) throws -> DeviceReceivedLibraryCommit {
        try lock.withLock {
            try prepareDirectory()
            var snapshot = try loadRecoveringIfNeeded()

            if let existing = snapshot.items.first(where: { $0.sha256 == proposedItem.sha256 }),
               let existingURL = snapshot.fileURLs[existing.id],
               try DeviceSyncFileIntegrity.verified(existingURL, matches: existing) {
                return DeviceReceivedLibraryCommit(
                    snapshot: snapshot,
                    item: existing,
                    fileURL: existingURL,
                    wasAlreadyStored: true
                )
            }

            guard proposedItem.fileName == URL(fileURLWithPath: proposedItem.fileName).lastPathComponent,
                  !proposedItem.fileName.isEmpty else {
                throw DeviceReceivedLibraryError.invalidFileName
            }
            guard try DeviceSyncFileIntegrity.verified(sourceURL, matches: proposedItem) else {
                throw DeviceReceivedLibraryError.verificationFailed
            }

            let destination = try uniqueDestination(for: proposedItem.fileName)
            do {
                try fileManager.copyItem(at: sourceURL, to: destination)
                guard try DeviceSyncFileIntegrity.verified(destination, matches: proposedItem) else {
                    throw DeviceReceivedLibraryError.verificationFailed
                }

                var storedItem = proposedItem
                storedItem.id = UUID()
                storedItem.fileName = destination.lastPathComponent
                snapshot.items.append(storedItem)
                snapshot.items.sort {
                    $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
                snapshot.fileURLs[storedItem.id] = destination
                try persist(snapshot.items)
                return DeviceReceivedLibraryCommit(
                    snapshot: snapshot,
                    item: storedItem,
                    fileURL: destination,
                    wasAlreadyStored: false
                )
            } catch {
                if fileManager.fileExists(atPath: destination.path) {
                    try? fileManager.removeItem(at: destination)
                }
                throw error
            }
        }
    }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func loadRecoveringIfNeeded() throws -> DeviceReceivedLibrarySnapshot {
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return DeviceReceivedLibrarySnapshot(items: [], fileURLs: [:])
        }
        do {
            return snapshot(for: try decode(at: manifestURL))
        } catch {
            guard fileManager.fileExists(atPath: backupURL.path),
                  let backupItems = try? decode(at: backupURL) else {
                throw DeviceReceivedLibraryError.corruptManifest
            }
            let corruptURL = directory.appendingPathComponent(
                "\(manifestURL.lastPathComponent).corrupt-\(UUID().uuidString)"
            )
            try fileManager.moveItem(at: manifestURL, to: corruptURL)
            do {
                try Data(contentsOf: backupURL).write(to: manifestURL, options: .atomic)
            } catch {
                try? fileManager.moveItem(at: corruptURL, to: manifestURL)
                throw error
            }
            return snapshot(for: backupItems)
        }
    }

    private func decode(at url: URL) throws -> [DeviceSyncItem] {
        try decoder.decode([DeviceSyncItem].self, from: Data(contentsOf: url))
    }

    private func snapshot(for decoded: [DeviceSyncItem]) -> DeviceReceivedLibrarySnapshot {
        let valid = decoded.filter { item in
            guard item.fileName == URL(fileURLWithPath: item.fileName).lastPathComponent else {
                return false
            }
            return fileManager.fileExists(
                atPath: directory.appendingPathComponent(item.fileName).path
            )
        }
        return DeviceReceivedLibrarySnapshot(
            items: valid,
            fileURLs: Dictionary(uniqueKeysWithValues: valid.map {
                ($0.id, directory.appendingPathComponent($0.fileName))
            })
        )
    }

    private func persist(_ items: [DeviceSyncItem]) throws {
        let data = try encoder.encode(items)
        if fileManager.fileExists(atPath: manifestURL.path),
           let previous = try? Data(contentsOf: manifestURL),
           (try? decoder.decode([DeviceSyncItem].self, from: previous)) != nil {
            try previous.write(to: backupURL, options: .atomic)
        }
        try beforePersist()
        try data.write(to: manifestURL, options: .atomic)
    }

    private func uniqueDestination(for fileName: String) throws -> URL {
        let source = URL(fileURLWithPath: fileName)
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var candidate = directory.appendingPathComponent(source.lastPathComponent)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(next)
            counter += 1
        }
        return candidate
    }
}

final class DeviceChunkTransferPauseCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var pausedTransferIDs: Set<UUID> = []
    private var pendingRequests: [UUID: DeviceChunkRequest] = [:]

    func pause(_ transferID: UUID) {
        _ = withLock { pausedTransferIDs.insert(transferID) }
    }

    func deferIfPaused(_ request: DeviceChunkRequest) -> Bool {
        withLock {
            guard pausedTransferIDs.contains(request.transferID) else { return false }
            pendingRequests[request.transferID] = request
            return true
        }
    }

    func resume(_ transferID: UUID) -> DeviceChunkRequest? {
        withLock {
            pausedTransferIDs.remove(transferID)
            return pendingRequests.removeValue(forKey: transferID)
        }
    }

    func remove(_ transferID: UUID) {
        withLock {
            pausedTransferIDs.remove(transferID)
            pendingRequests.removeValue(forKey: transferID)
        }
    }

    func removeAll() {
        withLock {
            pausedTransferIDs.removeAll()
            pendingRequests.removeAll()
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private extension String {
    var isSHA256Hex: Bool {
        count == 64 && allSatisfy { $0.isHexDigit }
    }
}
