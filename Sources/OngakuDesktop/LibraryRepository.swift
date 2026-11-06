import AVFoundation
import AppKit
import CryptoKit
import Darwin
import Foundation

actor LibraryRepository {
    enum OverlayJournalStep: Sendable { case journalWritten, catalogWritten, tagsWritten }
    struct OverlayJournalInterruption: Error {}
    private struct OverlayJournal: Codable {
        let version: Int
        let libraryID: UUID
        let previous: [Track]
        let updated: [Track]
        let tags: [UUID: [String]]
    }
    private var overlayJournalURL: URL { rootURL.appendingPathComponent("device-sync-overlay-journal-v1.json") }
    private var overlayTagsURL: URL { rootURL.appendingPathComponent("device-sync-tags-v1.json") }

    private enum ImportPhase: String, Codable {
        case copying
        case installing
        case installed
    }

    private struct StorageRestoreJournal: Codable {
        struct Entry: Codable {
            let name: String
            let hadOriginal: Bool
            let hadPrepared: Bool
        }
        let version: Int
        let transactionID: UUID
        let entries: [Entry]
    }
    private var storageRestoreJournalURL: URL { rootURL.appendingPathComponent("storage-restore-journal-v1.json") }
#if DEBUG
    struct StorageRestoreInterruption: Error {}
    enum StorageRestoreStep: Sendable { case afterBackup(String), afterInstall(String), beforeRollbackCopy(String) }
    var storageRestoreTestHook: (@Sendable (StorageRestoreStep) throws -> Void)?
    func setStorageRestoreTestHook(_ hook: (@Sendable (StorageRestoreStep) throws -> Void)?) { storageRestoreTestHook = hook }
#endif

    private struct CatalogWriteJournal: Codable {
        let version: Int
        let previousManifestDigest: String?
        let manifest: Data
        let manifestDigest: String?
        let backUpReadablePrimary: Bool
        let clearsRegistrations: Bool?
    }

    struct CatalogWriteRecoveryRequired: LocalizedError {
        var errorDescription: String? { L10n.text("library.error.recoveryRequiresAttention") }
    }
#if DEBUG
    enum CatalogWriteStep: Sendable { case journal, queue, events, manifest }
    var catalogWriteTestHook: (@Sendable (CatalogWriteStep) throws -> Void)?
    func setCatalogWriteTestHook(_ hook: (@Sendable (CatalogWriteStep) throws -> Void)?) { catalogWriteTestHook = hook }
#endif
    private var catalogWriteJournalURL: URL { rootURL.appendingPathComponent("catalog-write-journal-v1.json") }

    private struct SelfContainmentJournal: Codable {
        let version: Int
        let transactionID: UUID
    }
    private var selfContainmentJournalURL: URL {
        rootURL.appendingPathComponent("self-containment-journal-v1.json")
    }
    private func selfContainmentStagingURL(_ id: UUID) -> URL {
        incomingURL.appendingPathComponent("self-containment-\(id.uuidString)", isDirectory: true)
    }

    /// This journal only identifies disposable staging, never a catalog update.
    /// Quarantine an untrusted record without touching any unrecognized files.
    private func preserveUnusableSelfContainmentJournal() throws {
        let backup = rootURL.appendingPathComponent("Recovery Backups/Self-Containment-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: backup, withIntermediateDirectories: true)
        try fileManager.moveItem(at: selfContainmentJournalURL,
                                 to: backup.appendingPathComponent("self-containment-journal-v1.json"))
    }

    /// Only remove UUID-named regular staging files under the recorded directory.
    /// Installed media is deliberately retained and verified/reused on retry.
    private func recoverSelfContainmentStaging() throws {
        guard fileManager.fileExists(atPath: selfContainmentJournalURL.path) else { return }
        let bytes = try Data(contentsOf: selfContainmentJournalURL)
        guard let journal = try? decoder.decode(SelfContainmentJournal.self, from: bytes),
              journal.version == 1 else {
            try preserveUnusableSelfContainmentJournal()
            return
        }
        let directory = selfContainmentStagingURL(journal.transactionID)
        var info = stat()
        let status = directory.path.withCString { lstat($0, &info) }
        if status == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                try preserveUnusableSelfContainmentJournal()
                return
            }
            let entries = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for entry in entries {
                var item = stat()
                guard UUID(uuidString: entry.lastPathComponent) != nil,
                      entry.path.withCString({ lstat($0, &item) }) == 0,
                      (item.st_mode & S_IFMT) == S_IFREG else {
                    try preserveUnusableSelfContainmentJournal()
                    return
                }
            }
            for entry in entries { try fileManager.removeItem(at: entry) }
            try fileManager.removeItem(at: directory)
        } else if errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try fileManager.removeItem(at: selfContainmentJournalURL)
    }

    private struct ImportJournalEntry: Codable {
        let id: UUID
        let fileName: String
        let expectedSHA256: String
        let stagedPath: String
        var destinationPath: String?
        var track: Track?
        var phase: ImportPhase
        var previousManagedPath: String? = nil
    }

    private struct ImportJournal: Codable {
        static let currentSchema = 1

        var schemaVersion = currentSchema
        var updatedAt: Date = .now
        var entries: [ImportJournalEntry] = []
    }

    private struct MediaOrganizationJournalEntry: Codable {
        var sourcePath: String
        var destinationPath: String
        var expectedSHA256: String
        var moved: Bool
        var replacedDestinationBackupPath: String?
    }

    private struct MediaOrganizationJournal: Codable {
        static let currentSchema = 1
        var schemaVersion = currentSchema
        var updatedAt: Date = .now
        var entries: [MediaOrganizationJournalEntry]
    }

    private struct DecodedLibraryDocument {
        var document: LibraryDocument
        var migratedFromSchemaVersion: Int?
    }

    private struct SchemaHeader: Decodable {
        var schemaVersion: Int?
        var catalogGenerationEstablished: Bool?
    }

    /// Reuse the parser's container for the header and current document. Calling
    /// JSONDecoder twice would parse the entire track array twice, even though
    /// the header itself contains only one field.
    private struct CatalogEnvelope: Decodable {
        let header: SchemaHeader
        let document: LibraryDocument?

        init(from decoder: any Decoder) throws {
            header = try SchemaHeader(from: decoder)
            document = header.schemaVersion == LibraryDocument.currentSchema
                ? try LibraryDocument(from: decoder) : nil
        }
    }

    private struct LegacyLibraryDocument: Decodable {
        var schemaVersion: Int?
        var updatedAt: Date?
        var tracks: [Track]
    }

    private struct Schema2LibraryDocument: Decodable {
        var updatedAt: Date
        var tracks: [Track]
        var libraryID: UUID
        var createdAt: Date
    }

    private struct Schema3LibraryDocument: Decodable {
        var updatedAt: Date
        var tracks: [Track]
        var libraryID: UUID
        var createdAt: Date
        var playlists: [Playlist]
        var playbackEvents: [PlaybackEvent]
    }

    private struct Schema4LibraryDocument: Decodable {
        var updatedAt: Date
        var tracks: [Track]
        var libraryID: UUID
        var createdAt: Date
        var playlists: [Playlist]
        var playbackEvents: [PlaybackEvent]
        var playbackQueue: PlaybackQueueState?
    }

    private struct PlaybackQueueDocument: Codable {
        static let currentSchema = 1
        var schemaVersion = currentSchema
        var libraryID: UUID
        var updatedAt: Date = .now
        var queue: PlaybackQueueState?
    }

    private struct PlaybackEventsDocument: Codable {
        static let currentSchema = 1
        var schemaVersion = currentSchema
        var libraryID: UUID
        var updatedAt: Date = .now
        var events: [PlaybackEvent]
    }

    private struct Schema5LibraryDocument: Decodable {
        var updatedAt: Date
        var tracks: [Track]
        var libraryID: UUID
        var createdAt: Date
        var playlists: [Playlist]
        var playbackEvents: [PlaybackEvent]
        var playbackQueue: PlaybackQueueState?
    }

    private struct Schema6LibraryDocument: Decodable {
        var updatedAt: Date
        var tracks: [Track]
        var libraryID: UUID
        var createdAt: Date
        var playlists: [Playlist]
        var playlistFolders: [PlaylistFolder]
        var playbackEvents: [PlaybackEvent]
        var playbackQueue: PlaybackQueueState?
    }

    private typealias Schema7LibraryDocument = Schema6LibraryDocument
    private typealias Schema8LibraryDocument = Schema6LibraryDocument
    private typealias Schema9LibraryDocument = Schema6LibraryDocument
    private typealias Schema10LibraryDocument = Schema6LibraryDocument
    private typealias Schema11LibraryDocument = Schema6LibraryDocument

    private struct CatalogIdentityIndex {
        private var artistIDsByName: [String: UUID] = [:]
        private var albumIDsByArtistAndName: [String: UUID] = [:]

        init(tracks: [Track] = []) {
            for track in tracks {
                let artistKey = Self.nameKey(track.artist)
                artistIDsByName[artistKey] = artistIDsByName[artistKey] ?? track.artistID
                let albumKey = Self.albumKey(artistID: track.artistID, album: track.album)
                albumIDsByArtistAndName[albumKey] =
                    albumIDsByArtistAndName[albumKey] ?? track.albumID
            }
        }

        mutating func identities(artist: String, album: String) -> (artistID: UUID, albumID: UUID) {
            let artistKey = Self.nameKey(artist)
            let artistID = artistIDsByName[artistKey] ?? UUID()
            artistIDsByName[artistKey] = artistID

            let albumKey = Self.albumKey(artistID: artistID, album: album)
            let albumID = albumIDsByArtistAndName[albumKey] ?? UUID()
            albumIDsByArtistAndName[albumKey] = albumID
            return (artistID, albumID)
        }

        private static func nameKey(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(
                    options: [.caseInsensitive, .widthInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                )
        }

        private static func albumKey(artistID: UUID, album: String) -> String {
            "\(artistID.uuidString)\u{001F}\(nameKey(album))"
        }
    }

    enum RepositoryError: LocalizedError {
        case unsupportedSchema(Int)
        case copyVerificationFailed(String)
        case sourceIsNotRegularFile(String)
        case relinkFingerprintMismatch(String)
        case mediaOrganizationConflict(Int)
        case mediaOrganizationAmbiguousConflict(String)
        case staleOrganizedTrack
        case importInProgress
        case storageLockTimedOut
        case damagedGeneration
        case unsupportedGenerationFormat
        case damagedImportJournal
        case sourceRecoveryRequired(String)
        case multiplePreservedLibraries(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedSchema(let version):
                L10n.format("library.error.unsupportedSchema", version)
            case .copyVerificationFailed(let file):
                L10n.format("library.error.copyVerificationFailed", file)
            case .sourceIsNotRegularFile(let file):
                L10n.format("library.error.sourceIsNotRegularFile", file)
            case .relinkFingerprintMismatch(let file):
                L10n.format("library.error.relinkFingerprintMismatch", file)
            case .mediaOrganizationConflict(let count):
                L10n.format("library.error.mediaOrganizationConflict", count)
            case .mediaOrganizationAmbiguousConflict(let file):
                L10n.format("library.error.mediaOrganizationAmbiguousConflict", file)
            case .staleOrganizedTrack:
                L10n.text("library.error.staleOrganizedTrack")
            case .importInProgress:
                L10n.text("library.error.importInProgress")
            case .storageLockTimedOut:
                L10n.text("library.error.storageLockTimedOut")
            case .damagedGeneration:
                L10n.text("library.error.damagedGeneration")
            case .unsupportedGenerationFormat:
                L10n.text("library.error.unsupportedGenerationFormat")
            case .damagedImportJournal:
                L10n.text("library.error.damagedImportJournal")
            case .sourceRecoveryRequired(let path):
                L10n.format("library.error.sourceRecoveryRequired", path)
            case .multiplePreservedLibraries(let paths):
                L10n.format("settings.storage.error.multiplePreservedLibraries", paths)
            }
        }
    }

    let rootURL: URL
    private let fileManager: FileManager
    private let lockWaitTimeout: TimeInterval
    private var mediaURL: URL
    private var currentDocument: LibraryDocument?
    private struct ManifestStamp: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
    }
    private var observedManifestStamp: ManifestStamp?
    private var hasObservedManifest = false
    private var observedQueueStamp: ManifestStamp?
    private var observedEventsStamp: ManifestStamp?
    private struct GenerationToken: Equatable {
        let value: UInt64
        let epoch: UUID?
    }
    private var observedPersistentGeneration: GenerationToken?
    private var catalogLockDescriptor: Int32 = -1
    private var catalogLockDepth = 0
    private var importLockDescriptor: Int32 = -1
    private var importLockDepth = 0
    private var importInProgress = false
#if DEBUG
    enum ImportWriteStep: Sendable { case copying, installing, installed }
    var importWriteTestHook: (@Sendable (ImportWriteStep) throws -> Void)?
    func setImportWriteTestHook(_ hook: (@Sendable (ImportWriteStep) throws -> Void)?) { importWriteTestHook = hook }
    var importStagedTestGate: (@Sendable () async -> Void)?
    enum GenerationRecoveryStep: Sendable { case backup, counter }
    var generationRecoveryTestHook: (@Sendable (GenerationRecoveryStep) throws -> Void)?
    func setGenerationRecoveryTestHook(_ hook: (@Sendable (GenerationRecoveryStep) throws -> Void)?) { generationRecoveryTestHook = hook }
    var generationReservationTestHook: (@Sendable () throws -> Void)?
    func setGenerationReservationTestHook(_ hook: (@Sendable () throws -> Void)?) { generationReservationTestHook = hook }
    func setImportStagedTestGate(_ gate: (@Sendable () async -> Void)?) { importStagedTestGate = gate }
#endif

    private func acquireExclusiveLock(_ descriptor: Int32) throws {
        let started = DispatchTime.now().uptimeNanoseconds
        let limit = UInt64(lockWaitTimeout * 1_000_000_000)
        while true {
            if Task<Never, Never>.isCancelled { throw CancellationError() }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return }
            let code = errno
            guard code == EINTR || code == EWOULDBLOCK || code == EAGAIN else {
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            if DispatchTime.now().uptimeNanoseconds &- started >= limit {
                throw RepositoryError.storageLockTimedOut
            }
            if code != EINTR { usleep(10_000) }
        }
    }

    private func beginImportJournalTransaction() throws {
        if importLockDepth > 0 { importLockDepth += 1; return }
        try prepareDirectories()
        let path = rootURL.appendingPathComponent(".import-transaction-v1.lock").path
        let descriptor = path.withCString { open($0, O_CREAT | O_RDWR | O_CLOEXEC, 0o600) }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do { try acquireExclusiveLock(descriptor) }
        catch { close(descriptor); throw error }
        importLockDescriptor = descriptor
        importLockDepth = 1
    }

    /// Lock in catalog → import order, then reserve a generation before the
    /// first journal or file change. Never hold the catalog lock across await.
    private func beginImportOperation() throws {
        try beginCatalogTransaction()
        defer { endCatalogTransaction() }
        try beginImportJournalTransaction()
        do {
            guard !fileManager.fileExists(atPath: catalogWriteJournalURL.path),
                  !fileManager.fileExists(atPath: storageRestoreJournalURL.path),
                  !fileManager.fileExists(atPath: selfContainmentJournalURL.path) else {
                throw CatalogWriteRecoveryRequired()
            }
            guard !fileManager.fileExists(atPath: overlayJournalURL.path) else {
                throw OverlayRecoveryRequired()
            }
            try verifyObservedStamps()
            try reservePersistentGeneration()
            importInProgress = true
        } catch {
            endImportJournalTransaction()
            throw error
        }
    }

    private func endImportJournalTransaction() {
        precondition(importLockDepth > 0)
        importLockDepth -= 1
        guard importLockDepth == 0 else { return }
        flock(importLockDescriptor, LOCK_UN)
        close(importLockDescriptor)
        importLockDescriptor = -1
    }

    // The lock file is stable across atomic manifest replacement. All cooperating
    // processes must acquire this lock before checking or changing the catalog.
    private func beginCatalogTransaction() throws {
        // The import owns its journal lock across an await. Do not block this
        // actor on the catalog lock while another process waits for that import.
        guard !importInProgress else { throw RepositoryError.importInProgress }
        if catalogLockDepth > 0 { catalogLockDepth += 1; return }
        try prepareDirectories()
        let lockURL = rootURL.appendingPathComponent(".catalog-transaction-v1.lock")
        let descriptor = lockURL.path.withCString { open($0, O_CREAT | O_RDWR | O_CLOEXEC, 0o600) }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do { try acquireExclusiveLock(descriptor) }
        catch { close(descriptor); throw error }
        catalogLockDescriptor = descriptor
        catalogLockDepth = 1
    }

    private func endCatalogTransaction() {
        precondition(catalogLockDepth > 0)
        catalogLockDepth -= 1
        guard catalogLockDepth == 0 else { return }
        flock(catalogLockDescriptor, LOCK_UN)
        close(catalogLockDescriptor)
        catalogLockDescriptor = -1
    }

    private func fileStamp(_ url: URL) throws -> ManifestStamp? {
        var info = stat()
        let result = url.path.withCString { lstat($0, &info) }
        if result != 0 {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return ManifestStamp(device: UInt64(info.st_dev), inode: UInt64(info.st_ino),
                             size: info.st_size, modificationSeconds: Int64(info.st_mtimespec.tv_sec),
                             modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec))
    }

    private func manifestStamp() throws -> ManifestStamp? { try fileStamp(manifestURL) }

    private var generationURL: URL { rootURL.appendingPathComponent("catalog-generation-v1") }
    private var generationMarkerURL: URL { rootURL.appendingPathComponent("catalog-generation-established-v1") }

    private func ensureGenerationMarker() throws {
        guard !fileManager.fileExists(atPath: generationMarkerURL.path) else { return }
        try Data("1".utf8).write(to: generationMarkerURL, options: .atomic)
        try synchronizeOverlayFile(generationMarkerURL)
    }

    private func persistentGeneration() throws -> GenerationToken {
        guard fileManager.fileExists(atPath: generationURL.path) else {
            if fileManager.fileExists(atPath: generationMarkerURL.path)
                || fileManager.fileExists(atPath: catalogWriteJournalURL.path) {
                throw RepositoryError.damagedGeneration
            }
            // A catalog witness survives loss of both generation sidecars.
            // Old catalogs without the witness migrate through load's WAL.
            for url in [manifestURL, backupURL] where fileManager.fileExists(atPath: url.path) {
                if let header = try? decoder.decode(SchemaHeader.self, from: Data(contentsOf: url)) {
                    if let version = header.schemaVersion, version > LibraryDocument.currentSchema {
                        throw RepositoryError.unsupportedSchema(version)
                    }
                    if header.catalogGenerationEstablished == true { throw RepositoryError.damagedGeneration }
                }
            }
            return GenerationToken(value: 0, epoch: nil)
        }
        let data = try Data(contentsOf: generationURL)
        guard let text = String(data: data, encoding: .utf8) else { throw RepositoryError.damagedGeneration }
        if let value = UInt64(text), String(value) == text {
            return GenerationToken(value: value, epoch: nil)
        }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        if parts.first?.hasPrefix("v") == true && parts.first != "v2" {
            throw RepositoryError.unsupportedGenerationFormat
        }
        guard parts.count == 3, parts[0] == "v2",
              let epoch = UUID(uuidString: String(parts[1])), epoch.uuidString == parts[1],
              let value = UInt64(parts[2]), String(value) == parts[2] else {
            throw RepositoryError.damagedGeneration
        }
        return GenerationToken(value: value, epoch: epoch)
    }

    private func writeGeneration(_ token: GenerationToken) throws {
        try ensureGenerationMarker()
        let text = token.epoch.map { "v2:\($0.uuidString):\(token.value)" } ?? String(token.value)
        try Data(text.utf8).write(to: generationURL, options: .atomic)
        try synchronizeOverlayFile(generationURL)
    }

    /// Back up corrupt bytes before atomically publishing a fresh epoch and
    /// counter. Old readers reject the new format rather than reusing a counter.
    private func recoverDamagedGeneration() throws {
        do { _ = try persistentGeneration(); return }
        catch RepositoryError.damagedGeneration { }
        let backup = rootURL.appendingPathComponent("Recovery Backups/Generation-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: backup, withIntermediateDirectories: true)
        for source in [generationURL, generationMarkerURL] where fileManager.fileExists(atPath: source.path) {
            let preserved = backup.appendingPathComponent(source.lastPathComponent)
            try fileManager.copyItem(at: source, to: preserved)
            try synchronizeOverlayFile(preserved)
        }
#if DEBUG
        try generationRecoveryTestHook?(.backup)
#endif
        try writeGeneration(GenerationToken(value: 0, epoch: UUID()))
#if DEBUG
        try generationRecoveryTestHook?(.counter)
#endif
    }

    /// Reserve a new persistent generation before touching catalog data.
    /// A crash after reservation conservatively invalidates older readers.
    private func reservePersistentGeneration() throws {
        precondition(catalogLockDepth > 0)
        let current = try persistentGeneration()
        if let observedPersistentGeneration, observedPersistentGeneration != current {
            throw RepositoryError.staleOrganizedTrack
        }
        guard current.value < UInt64.max else { throw CocoaError(.fileWriteUnknown) }
        let next = GenerationToken(value: current.value + 1, epoch: current.epoch)
        try writeGeneration(next)
        observedPersistentGeneration = next
#if DEBUG
        try generationReservationTestHook?()
#endif
    }

    private func refreshObservedStamps() throws {
        observedPersistentGeneration = try persistentGeneration()
        observedManifestStamp = try manifestStamp()
        observedQueueStamp = try fileStamp(playbackQueueURL)
        observedEventsStamp = try fileStamp(playbackEventsURL)
        hasObservedManifest = true
    }

    private func verifyObservedStamps() throws {
        guard hasObservedManifest else { return }
        guard try persistentGeneration() == observedPersistentGeneration,
              try manifestStamp() == observedManifestStamp,
              try fileStamp(playbackQueueURL) == observedQueueStamp,
              try fileStamp(playbackEventsURL) == observedEventsStamp else {
            throw RepositoryError.staleOrganizedTrack
        }
    }

    // Paths moved by this repository instance; in-flight callers can still hold
    // pre-move track arrays even after the actor finishes the transaction.
    private var organizedPreviousPaths: [Track.ID: Set<String>] = [:]

    init(rootURL: URL? = nil, mediaURL: URL? = nil, fileManager: FileManager = .default,
         lockWaitTimeout: TimeInterval = 5) {
        self.fileManager = fileManager
        self.lockWaitTimeout = lockWaitTimeout.isFinite ? min(max(lockWaitTimeout, 0), 30) : 5
        let resolvedMedia: URL
        if let mediaURL {
            resolvedMedia = mediaURL
        } else if let rootURL {
            // Preserve the explicit-root initializer contract used by imports,
            // migrations, and isolated repositories.
            resolvedMedia = rootURL.appendingPathComponent("Ongaku Media", isDirectory: true)
        } else {
            resolvedMedia = fileManager.urls(for: .musicDirectory, in: .userDomainMask)
                .first?
                .appendingPathComponent("Ongaku Desktop/Ongaku Media", isDirectory: true)
                ?? fileManager.homeDirectoryForCurrentUser
                    .appendingPathComponent("Music/Ongaku Desktop/Ongaku Media", isDirectory: true)
        }
        let resolvedRoot = rootURL ?? PortableLibraryStorage(mediaURL: resolvedMedia).rootURL
        self.rootURL = resolvedRoot
        self.mediaURL = resolvedMedia
    }

    private var incomingURL: URL { rootURL.appendingPathComponent("Incoming", isDirectory: true) }
    private var manifestURL: URL { rootURL.appendingPathComponent("library-v1.json") }
    private var backupURL: URL { rootURL.appendingPathComponent("library-v1.backup.json") }
    private var storageRecoveryReceiptURL: URL { rootURL.appendingPathComponent("storage-recovery-v1.json") }
    private var playbackQueueURL: URL { rootURL.appendingPathComponent("playback-queue-v1.json") }
    private var playbackQueueBackupURL: URL {
        rootURL.appendingPathComponent("playback-queue-v1.backup.json")
    }
    private var playbackEventsURL: URL { rootURL.appendingPathComponent("playback-events-v1.json") }
    private var playbackEventsBackupURL: URL {
        rootURL.appendingPathComponent("playback-events-v1.backup.json")
    }
    private func migrationArchiveURL(for schemaVersion: Int) -> URL {
        let source = schemaVersion == 0 ? "unversioned" : "schema-\(schemaVersion)"
        return rootURL.appendingPathComponent("library-\(source).migration-backup.json")
    }
    private var importJournalURL: URL { rootURL.appendingPathComponent("import-journal-v1.json") }
    private var mediaOrganizationJournalURL: URL {
        rootURL.appendingPathComponent("media-organization-journal-v1.json")
    }
    private var playlistArtworkDirectoryURL: URL {
        rootURL.appendingPathComponent("Playlist Artwork", isDirectory: true)
    }

    func setMediaDirectory(_ url: URL) throws {
        let standardized = url.standardizedFileURL
        try fileManager.createDirectory(at: standardized, withIntermediateDirectories: true)
        mediaURL = standardized
    }

    /// A previous migration can leave an empty primary and the real catalog in
    /// Legacy Imports. Only explicit storage selection invokes this recovery.
    /// Originals and the replaced empty catalog remain available on disk.
    func restorePreservedLibraryIfEmpty() throws {
        try beginCatalogTransaction()
        defer { endCatalogTransaction() }
        guard !importInProgress else { throw RepositoryError.importInProgress }
        try beginImportJournalTransaction()
        defer { endImportJournalTransaction() }
        if fileManager.fileExists(atPath: overlayJournalURL.path)
            || fileManager.fileExists(atPath: catalogWriteJournalURL.path)
            || fileManager.fileExists(atPath: storageRestoreJournalURL.path)
            || fileManager.fileExists(atPath: importJournalURL.path) {
            _ = try load()
            return
        }
        if let current = try storageCatalog(at: rootURL) {
            guard !hasLibraryContent(current.document) else { return }
            if let receipt = try? Data(contentsOf: storageRecoveryReceiptURL),
               (try? decoder.decode(UUID.self, from: receipt)) == current.document.libraryID {
                return
            }
        }

        let nestedRoots = [
            rootURL,
            mediaURL.appendingPathComponent("Ongaku Desktop"),
            mediaURL.appendingPathComponent("Ongaku Desktop/Ongaku Library Data"),
            mediaURL.appendingPathComponent("Ongaku Desktop/Ongaku Media/Ongaku Library Data"),
            mediaURL.appendingPathComponent("Ongaku Media/Ongaku Library Data"),
            mediaURL.appendingPathComponent("Media/Ongaku Library Data"),
            mediaURL.appendingPathComponent("Catalog")
        ]
        var locations = Array(nestedRoots.dropFirst())
        for root in nestedRoots {
            let archives = root.appendingPathComponent("Legacy Imports", isDirectory: true)
            if fileManager.fileExists(atPath: archives.path) {
                locations += try fileManager.contentsOfDirectory(
                    at: archives, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                ).filter {
                    let values = try $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    return values.isDirectory == true && values.isSymbolicLink != true
                }
            }
        }
        var candidates: [(directory: URL, manifest: URL, document: LibraryDocument)] = []
        for location in locations {
            guard let catalog = try storageCatalog(at: location),
                  hasLibraryContent(catalog.document) else { continue }
            candidates.append((location, catalog.manifest, catalog.document))
        }
        guard !candidates.isEmpty else { return }
        guard candidates.count == 1, let candidate = candidates.first else {
            throw RepositoryError.multiplePreservedLibraries(
                candidates.map { $0.directory.path }.joined(separator: "\n")
            )
        }

        // These journals can contain paths rooted in the source catalog. Do
        // not transplant a stale primary or replay them under a different root.
        let sourceRecoveryJournals = ["catalog-write-journal-v1.json", "storage-restore-journal-v1.json", "import-journal-v1.json", "self-containment-journal-v1.json"]
        guard !sourceRecoveryJournals.contains(where: {
            fileManager.fileExists(atPath: candidate.directory.appendingPathComponent($0).path)
        }) else { throw RepositoryError.sourceRecoveryRequired(candidate.directory.path) }
        if fileManager.fileExists(atPath: candidate.directory.appendingPathComponent("device-sync-overlay-journal-v1.json").path),
           candidate.manifest.lastPathComponent != "library-v1.json" {
            throw OverlayRecoveryRequired()
        }
        let transactionID = UUID()
        let recovery = rootURL.appendingPathComponent("Recovery Backups/\(transactionID.uuidString)")
        let prepared = recovery.appendingPathComponent("Prepared")
        let previous = recovery.appendingPathComponent("Previous")
        try fileManager.createDirectory(at: prepared, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: previous, withIntermediateDirectories: true)
        // Derived SQLite indexes are rebuilt through the normal library-ID checks.
        var names = [
            "library-v1.backup.json", "playback-queue-v1.json", "playback-queue-v1.backup.json",
            "playback-events-v1.json", "playback-events-v1.backup.json",
            "device-sync-tags-v1.json", "device-sync-overlay-journal-v1.json", "audio-features-v1.json"
        ]
        for name in names + ["Artwork", "Playlist Artwork"] {
            let source = candidate.directory.appendingPathComponent(name)
            if fileManager.fileExists(atPath: source.path) {
                try fileManager.copyItem(at: source, to: prepared.appendingPathComponent(name))
                if !names.contains(name) { names.append(name) }
            }
        }
        try fileManager.copyItem(at: candidate.manifest, to: prepared.appendingPathComponent("library-v1.json"))
        // Validate (or recover from their backups) before touching the active files.
        let _: PlaybackQueueDocument? = try decodeSidecar(
            at: prepared.appendingPathComponent("playback-queue-v1.json"),
            backupURL: prepared.appendingPathComponent("playback-queue-v1.backup.json")
        )
        let _: PlaybackEventsDocument? = try decodeSidecar(
            at: prepared.appendingPathComponent("playback-events-v1.json"),
            backupURL: prepared.appendingPathComponent("playback-events-v1.backup.json")
        )
        try encoder.encode(candidate.document.libraryID)
            .write(to: prepared.appendingPathComponent(storageRecoveryReceiptURL.lastPathComponent), options: .atomic)
        // Invalidate stale readers before replacing any part of the catalog.
        try reservePersistentGeneration()
        names += [storageRecoveryReceiptURL.lastPathComponent, "library-v1.json"]
        let entries = names.map { name in
            StorageRestoreJournal.Entry(
                name: name,
                hadOriginal: fileManager.fileExists(atPath: rootURL.appendingPathComponent(name).path),
                hadPrepared: fileManager.fileExists(atPath: prepared.appendingPathComponent(name).path)
            )
        }
        let journal = StorageRestoreJournal(version: 1, transactionID: transactionID, entries: entries)
        try encoder.encode(journal).write(to: storageRestoreJournalURL, options: [.atomic])
        try synchronizeOverlayFile(storageRestoreJournalURL)
        do {
            for entry in entries {
                let destination = rootURL.appendingPathComponent(entry.name)
                if entry.hadOriginal {
                    try fileManager.moveItem(at: destination, to: previous.appendingPathComponent(entry.name))
#if DEBUG
                    try storageRestoreTestHook?(.afterBackup(entry.name))
#endif
                }
                if entry.hadPrepared {
                    try fileManager.moveItem(at: prepared.appendingPathComponent(entry.name), to: destination)
#if DEBUG
                    try storageRestoreTestHook?(.afterInstall(entry.name))
#endif
                }
            }
            try fileManager.removeItem(at: storageRestoreJournalURL)
        } catch {
#if DEBUG
            if error is StorageRestoreInterruption { throw error }
#endif
            do { try rollbackStorageRestore(journal) }
            catch { throw CatalogWriteRecoveryRequired() }
            throw error
        }
        currentDocument = nil
    }

    private func rollbackStorageRestore(_ journal: StorageRestoreJournal) throws {
        let allowed: Set<String> = [
            "library-v1.json", "library-v1.backup.json", "playback-queue-v1.json", "playback-queue-v1.backup.json",
            "playback-events-v1.json", "playback-events-v1.backup.json", "device-sync-tags-v1.json",
            "device-sync-overlay-journal-v1.json", "audio-features-v1.json", "Artwork", "Playlist Artwork",
            "storage-recovery-v1.json"
        ]
        guard journal.version == 1, Set(journal.entries.map(\.name)).count == journal.entries.count,
              journal.entries.allSatisfy({ allowed.contains($0.name) }) else {
            throw CatalogWriteRecoveryRequired()
        }
        let root = rootURL.appendingPathComponent("Recovery Backups/\(journal.transactionID.uuidString)")
        let previous = root.appendingPathComponent("Previous")
        let prepared = root.appendingPathComponent("Prepared")
        let preserved = root.appendingPathComponent("Interrupted")
        for entry in journal.entries.reversed() {
            let destination = rootURL.appendingPathComponent(entry.name)
            let backup = previous.appendingPathComponent(entry.name)
            let staged = prepared.appendingPathComponent(entry.name)
            let backupExists = fileManager.fileExists(atPath: backup.path)
            let destinationExists = fileManager.fileExists(atPath: destination.path)
            let stagedExists = fileManager.fileExists(atPath: staged.path)
            if entry.hadOriginal && backupExists {
                if destinationExists {
                    let holding = preserved.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try fileManager.createDirectory(at: holding, withIntermediateDirectories: true)
                    try fileManager.moveItem(at: destination, to: holding.appendingPathComponent(entry.name))
                }
                // Copy rather than move: another interruption during rollback can retry.
#if DEBUG
                try storageRestoreTestHook?(.beforeRollbackCopy(entry.name))
#endif
                try fileManager.copyItem(at: backup, to: destination)
            } else if entry.hadOriginal {
                guard destinationExists, !entry.hadPrepared || stagedExists else {
                    throw CatalogWriteRecoveryRequired()
                }
            } else if entry.hadPrepared && !stagedExists && destinationExists {
                let holding = preserved.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try fileManager.createDirectory(at: holding, withIntermediateDirectories: true)
                try fileManager.moveItem(at: destination, to: holding.appendingPathComponent(entry.name))
            }
        }
        try fileManager.removeItem(at: storageRestoreJournalURL)
        currentDocument = nil
    }

    private func recoverStorageRestoreJournal() throws {
        guard fileManager.fileExists(atPath: storageRestoreJournalURL.path) else { return }
        let data = try Data(contentsOf: storageRestoreJournalURL)
        guard let journal = try? decoder.decode(StorageRestoreJournal.self, from: data) else {
            throw CatalogWriteRecoveryRequired()
        }
        try rollbackStorageRestore(journal)
    }

    private func hasLibraryContent(_ document: LibraryDocument) -> Bool {
        !document.tracks.isEmpty || !document.playlists.isEmpty || !document.playlistFolders.isEmpty
            || !document.playbackEvents.isEmpty
    }

    private func storageCatalog(at directory: URL) throws -> (manifest: URL, document: LibraryDocument)? {
        let primary = directory.appendingPathComponent("library-v1.json")
        let backup = directory.appendingPathComponent("library-v1.backup.json")
        if fileManager.fileExists(atPath: primary.path) {
            do { return (primary, try readExternalLibraryDocument(at: primary)) }
            catch RepositoryError.unsupportedSchema(let version) { throw RepositoryError.unsupportedSchema(version) }
            catch { if !fileManager.fileExists(atPath: backup.path) { throw error } }
        }
        if fileManager.fileExists(atPath: backup.path) {
            return (backup, try readExternalLibraryDocument(at: backup))
        }
        return nil
    }

    /// Save recovery metadata without interpreting or changing damaged files.
    /// Audio and Incoming are intentionally excluded; keep the original library.
    func exportRecoverySnapshot(to parent: URL) throws -> URL {
        try beginCatalogTransaction()
        defer { endCatalogTransaction() }
        try beginImportJournalTransaction()
        defer { endImportJournalTransaction() }
        let source = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let target = parent.resolvingSymlinksInPath().standardizedFileURL
        guard !isInside(target, directory: source) else { throw CocoaError(.fileWriteNoPermission) }
        let name = "Ongaku-Recovery-\(UUID().uuidString)"
        let partial = target.appendingPathComponent(name + ".partial", isDirectory: true)
        let completed = target.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: partial, withIntermediateDirectories: false)
        let names = ["catalog-generation-v1", "catalog-generation-established-v1", "library-v1.json", "library-v1.backup.json",
                     "playback-queue-v1.json", "playback-queue-v1.backup.json",
                     "playback-events-v1.json", "playback-events-v1.backup.json",
                     "catalog-write-journal-v1.json", "storage-restore-journal-v1.json",
                     "import-journal-v1.json", "media-organization-journal-v1.json",
                     "device-sync-overlay-journal-v1.json", "device-sync-tags-v1.json",
                     "self-containment-journal-v1.json", "storage-recovery-v1.json",
                     "Recovery Backups"]
        for name in names {
            try Task.checkCancellation()
            let item = source.appendingPathComponent(name)
            if fileManager.fileExists(atPath: item.path) {
                try fileManager.copyItem(at: item, to: partial.appendingPathComponent(name))
            }
        }
        try fileManager.moveItem(at: partial, to: completed)
        return completed
    }

    /// Copy external references into this volume without changing IDs or metadata.
    /// Commit paths only after every copy has passed SHA-256 verification.
    func makeLibrarySelfContained() throws {
        try beginCatalogTransaction()
        defer { endCatalogTransaction() }
        var document = try load().document
        let journal = SelfContainmentJournal(version: 1, transactionID: UUID())
        try encoder.encode(journal).write(to: selfContainmentJournalURL, options: .atomic)
        try synchronizeOverlayFile(selfContainmentJournalURL)
        let staging = selfContainmentStagingURL(journal.transactionID)
        defer { try? recoverSelfContainmentStaging() }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        let root = mediaURL.resolvingSymlinksInPath().standardizedFileURL
        var changed = false
        for index in document.tracks.indices {
            try Task.checkCancellation()
            let source = document.tracks[index].fileURL.resolvingSymlinksInPath().standardizedFileURL
            if isInside(source, directory: root) { continue }
            let scope = source.startAccessingSecurityScopedResource()
            defer { if scope { source.stopAccessingSecurityScopedResource() } }
            let values = try source.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { throw CocoaError(.fileReadUnsupportedScheme) }
            let hash = try Self.sha256(of: source)
            let track = document.tracks[index]
            let destination = try copyIntoMedia(source, artist: track.artist, album: track.album, hash: hash, staging: staging)
            document.tracks[index].managedPath = destination.path
            changed = true
        }
        if changed {
            document.updatedAt = .now
            try persistDocument(document, backUpReadablePrimary: true)
            currentDocument = document
        }
    }

    private func copyIntoMedia(_ source: URL, artist: String, album: String, hash: String, staging: URL) throws -> URL {
        try prepareDirectories()
        let root = mediaURL.resolvingSymlinksInPath().standardizedFileURL
        let destination = try destinationURL(artist: artist, album: album,
                                             originalName: source.lastPathComponent, hash: hash)
        guard isInside(destination.resolvingSymlinksInPath(), directory: root) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: destination.path) {
            let staged = staging.appendingPathComponent(UUID().uuidString)
            defer { try? fileManager.removeItem(at: staged) }
            try fileManager.copyItem(at: source, to: staged)
            guard try Self.sha256(of: staged) == hash else {
                throw RepositoryError.copyVerificationFailed(source.lastPathComponent)
            }
            try fileManager.moveItem(at: staged, to: destination)
        }
        guard try Self.sha256(of: destination) == hash else {
            throw RepositoryError.copyVerificationFailed(source.lastPathComponent)
        }
        return destination
    }

    func load() throws -> LibraryLoadResult {
        try beginCatalogTransaction()
        defer { endCatalogTransaction() }
        guard !importInProgress else { throw RepositoryError.importInProgress }
        try beginImportJournalTransaction()
        defer { endImportJournalTransaction() }
        try prepareDirectories()
        // Loading explicitly refreshes the caller's baseline under the lock.
        try recoverDamagedGeneration()
        observedPersistentGeneration = try persistentGeneration()
        if fileManager.fileExists(atPath: generationURL.path) { try ensureGenerationMarker() }
        try recoverStorageRestoreJournal()
        try recoverCatalogWriteJournal()
        try recoverSelfContainmentStaging()
        var recoveredFromBackup = false
        var decoded: DecodedLibraryDocument
        var decodedSourceURL: URL?

        if fileManager.fileExists(atPath: manifestURL.path) {
            do {
                decoded = try decodeDocument(at: manifestURL)
                decodedSourceURL = manifestURL
            } catch RepositoryError.unsupportedSchema(let version) {
                throw RepositoryError.unsupportedSchema(version)
            } catch {
                guard fileManager.fileExists(atPath: backupURL.path) else { throw error }
                decoded = try decodeDocument(at: backupURL)
                decodedSourceURL = backupURL
                recoveredFromBackup = true
            }
        } else if fileManager.fileExists(atPath: backupURL.path) {
            decoded = try decodeDocument(at: backupURL)
            decodedSourceURL = backupURL
            recoveredFromBackup = true
        } else {
            decoded = DecodedLibraryDocument(
                document: LibraryDocument(),
                migratedFromSchemaVersion: nil
            )
        }

        try recoverOverlayJournal(using: decoded.document, recoveredFromBackup: recoveredFromBackup)
        var document = try applyingPlaybackSidecars(to: decoded.document)
        let needsGenerationWitness = document.catalogGenerationEstablished != true
        document.catalogGenerationEstablished = true
        try reconcileMediaOrganizationJournal(with: document.tracks)
        let recovery = try recoverImports(into: &document)
        let relocated = relocateFilesAfterPortableLibraryMove(in: document.tracks)
        if relocated.relinkedTrackCount > 0 {
            document.tracks = relocated.tracks
            document.updatedAt = .now
        }
        if let sourceSchemaVersion = decoded.migratedFromSchemaVersion {
            if let decodedSourceURL {
                try archivePreMigrationManifest(
                    at: decodedSourceURL,
                    sourceSchemaVersion: sourceSchemaVersion
                )
            }
            document.updatedAt = .now
            try persistDocument(document, backUpReadablePrimary: false)
            try encoder.encode(document).write(to: backupURL, options: [.atomic])
        } else if needsGenerationWitness || recovery.recovered > 0 || recoveredFromBackup || relocated.relinkedTrackCount > 0
            || !fileManager.fileExists(atPath: manifestURL.path) {
            document.updatedAt = .now
            try persistDocument(document, backUpReadablePrimary: !recoveredFromBackup)
        }
        if !fileManager.fileExists(atPath: playbackQueueURL.path)
            || !fileManager.fileExists(atPath: playbackEventsURL.path) {
            try persistPlaybackSidecars(document)
        }
        // Keep recoverable import entries until the catalog that references
        // them has been published. Retrying cleanup is safe after a crash.
        if let journal = recovery.remainingJournal { try persistImportJournal(journal) }
        currentDocument = document
        try refreshObservedStamps()
        return LibraryLoadResult(
            document: document,
            recoveredFromBackup: recoveredFromBackup,
            recoveredImportCount: recovery.recovered,
            unresolvedImportCount: recovery.unresolved,
            migratedFromSchemaVersion: decoded.migratedFromSchemaVersion
        )
    }

    /// Decodes another Ongaku catalog without preparing its directories,
    /// migrating it in place, writing backups, or changing this repository's
    /// current document.
    func readExternalLibraryDocument(at manifestURL: URL) throws -> LibraryDocument {
        let source = manifestURL.standardizedFileURL
        let values = try source.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw RepositoryError.sourceIsNotRegularFile(source.lastPathComponent)
        }
        guard values.fileSize ?? 0 <= 512 * 1_024 * 1_024 else {
            throw CocoaError(.fileReadTooLarge)
        }
        return try decodeDocument(at: source).document
    }

    func currentMediaDirectoryURL() -> URL { mediaURL }

    func requiredImportMetadata(for sourceURLs: [URL]) async -> [RequiredImportMetadataDraft] {
        var drafts: [RequiredImportMetadataDraft] = []
        for source in sourceURLs {
            let didAccess = source.startAccessingSecurityScopedResource()
            let metadata = await Self.readMetadata(
                from: source,
                fallbackName: source.deletingPathExtension().lastPathComponent
            )
            if didAccess { source.stopAccessingSecurityScopedResource() }
            guard metadata.requiresArtist || metadata.requiresAlbum else { continue }
            drafts.append(RequiredImportMetadataDraft(
                sourceURL: source,
                title: metadata.title,
                artist: metadata.requiresArtist ? "" : metadata.artist,
                album: metadata.requiresAlbum ? "" : metadata.album,
                requiresArtist: metadata.requiresArtist,
                requiresAlbum: metadata.requiresAlbum
            ))
        }
        return drafts
    }

    func planMediaOrganization(
        tracks: [Track],
        destinationRootURL: URL
    ) throws -> MediaOrganizationPreview {
        let destinationRoot = destinationRootURL.standardizedFileURL
        let sourceRoot = mediaURL.standardizedFileURL
        var reservedPaths: Set<String> = []
        let grouped = Dictionary(grouping: tracks) { $0.fileURL.standardizedFileURL.path }
        var items: [MediaOrganizationItem] = []

        for (path, matchingTracks) in grouped.sorted(by: { $0.key < $1.key }) {
            let source = URL(fileURLWithPath: path).standardizedFileURL
            guard isInside(source, directory: sourceRoot) else {
                items.append(MediaOrganizationItem(
                    trackIDs: matchingTracks.map(\.id), sourceURL: source,
                    destinationURL: source, expectedSHA256: matchingTracks[0].sha256,
                    status: .external
                ))
                continue
            }
            guard let values = try? source.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ), values.isRegularFile == true, values.isSymbolicLink != true,
                  let hash = try? Self.sha256(of: source),
                  matchingTracks.contains(where: { $0.sha256 == hash }) else {
                items.append(MediaOrganizationItem(
                    trackIDs: matchingTracks.map(\.id), sourceURL: source,
                    destinationURL: source, expectedSHA256: matchingTracks[0].sha256,
                    status: .unavailable
                ))
                continue
            }

            let representative = matchingTracks[0]
            let directory = destinationRoot
                .appendingPathComponent(Self.safePathComponent(representative.artist), isDirectory: true)
                .appendingPathComponent(Self.safePathComponent(representative.album), isDirectory: true)
            let proposed = directory.appendingPathComponent(Self.safePathComponent(source.lastPathComponent))
            let proposedPath = proposed.standardizedFileURL.path
            let sourcePath = source.standardizedFileURL.path
            let hasConflict = proposedPath != sourcePath
                && (reservedPaths.contains(proposedPath)
                    || fileManager.fileExists(atPath: proposedPath))
            reservedPaths.insert(proposedPath)
            items.append(MediaOrganizationItem(
                trackIDs: matchingTracks.map(\.id), sourceURL: source,
                destinationURL: proposed, expectedSHA256: hash,
                status: sourcePath == proposedPath ? .unchanged : (hasConflict ? .conflict : .move)
            ))
        }
        return MediaOrganizationPreview(
            sourceRootURL: sourceRoot,
            destinationRootURL: destinationRoot,
            items: items
        )
    }

    func executeMediaOrganization(
        document: LibraryDocument,
        preview: MediaOrganizationPreview,
        collisionPolicy: MediaOrganizationCollisionPolicy = .stop
    ) throws -> (document: LibraryDocument, summary: MediaOrganizationSummary) {
        try beginCatalogTransaction()
        defer { endCatalogTransaction() }
        try prepareDirectories()
        // Serialize against repository writers and retain changes made after the
        // UI captured its snapshot. A changed track list invalidates the plan.
        let latestDocument = try documentForMutation()
        guard latestDocument.libraryID == document.libraryID,
              latestDocument.tracks == document.tracks else { throw CancellationError() }
        let conflicts = preview.items.filter { $0.status == .conflict }
        if !conflicts.isEmpty, collisionPolicy == .stop {
            throw RepositoryError.mediaOrganizationConflict(conflicts.count)
        }
        var reservedPaths = Set(preview.items.filter { $0.status == .move }.map {
            $0.destinationURL.standardizedFileURL.path
        })
        var moves = preview.items.filter { $0.status == .move }
        for var item in conflicts {
            switch collisionPolicy {
            case .stop:
                break
            case .keepBoth:
                item.destinationURL = uniqueOrganizationDestination(
                    proposed: item.destinationURL,
                    source: item.sourceURL,
                    hash: item.expectedSHA256,
                    reservedPaths: &reservedPaths
                )
            case .replace:
                let path = item.destinationURL.standardizedFileURL.path
                guard !reservedPaths.contains(path) else {
                    throw RepositoryError.mediaOrganizationAmbiguousConflict(
                        item.destinationURL.lastPathComponent
                    )
                }
                reservedPaths.insert(path)
            }
            moves.append(item)
        }
        let backupRoot = rootURL.appendingPathComponent(
            "Media Organization Backups",
            isDirectory: true
        )
        var journal = MediaOrganizationJournal(entries: moves.map {
            MediaOrganizationJournalEntry(
                sourcePath: $0.sourceURL.path,
                destinationPath: $0.destinationURL.path,
                expectedSHA256: $0.expectedSHA256,
                moved: false,
                replacedDestinationBackupPath: collisionPolicy == .replace
                    && $0.status == .conflict
                    && fileManager.fileExists(atPath: $0.destinationURL.path)
                    ? backupRoot.appendingPathComponent(
                        "\(UUID().uuidString)-\($0.destinationURL.lastPathComponent)"
                    ).path
                    : nil
            )
        })
        try reservePersistentGeneration()
        try persistMediaOrganizationJournal(journal)

        var catalogCommitted = false
        do {
            for index in journal.entries.indices {
                let source = URL(fileURLWithPath: journal.entries[index].sourcePath)
                let destination = URL(fileURLWithPath: journal.entries[index].destinationPath)
                guard try Self.sha256(of: source) == journal.entries[index].expectedSHA256 else {
                    throw RepositoryError.copyVerificationFailed(source.lastPathComponent)
                }
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if let backupPath = journal.entries[index].replacedDestinationBackupPath {
                    let backup = URL(fileURLWithPath: backupPath)
                    try fileManager.createDirectory(
                        at: backup.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try fileManager.moveItem(at: destination, to: backup)
                    journal.updatedAt = .now
                    try persistMediaOrganizationJournal(journal)
                }
                try fileManager.moveItem(at: source, to: destination)
                journal.entries[index].moved = true
                guard try Self.sha256(of: destination) == journal.entries[index].expectedSHA256 else {
                    throw RepositoryError.copyVerificationFailed(destination.lastPathComponent)
                }
                journal.updatedAt = .now
                try persistMediaOrganizationJournal(journal)
            }

            let destinationByTrackID = Dictionary(
                uniqueKeysWithValues: moves.flatMap { item in
                    item.trackIDs.map { ($0, item.destinationURL.path) }
                }
            )
            var updated = latestDocument
            for index in updated.tracks.indices {
                if let path = destinationByTrackID[updated.tracks[index].id] {
                    updated.tracks[index].managedPath = path
                    updated.tracks[index].lastVerifiedAt = .now
                    updated.tracks[index].health = .verified
                }
            }
            updated.updatedAt = .now
            try persistDocument(updated, backUpReadablePrimary: true)
            currentDocument = updated
            for item in moves {
                for trackID in item.trackIDs {
                    organizedPreviousPaths[trackID, default: []].insert(item.sourceURL.standardizedFileURL.path)
                }
            }
            catalogCommitted = true
            removeMediaOrganizationBackups(journal)
            try clearMediaOrganizationJournal()
            mediaURL = preview.destinationRootURL.standardizedFileURL
            return (
                updated,
                MediaOrganizationSummary(
                    moved: moves.count,
                    updatedTracks: destinationByTrackID.count
                )
            )
        } catch {
            // After catalog publication the new locations are authoritative. Never
            // undo the files merely because journal cleanup failed.
            if !catalogCommitted {
                try rollbackMediaOrganizationJournal(journal)
                removeMediaOrganizationBackups(journal)
                try clearMediaOrganizationJournal()
            }
            throw error
        }
    }

    func save(tracks: [Track]) throws {
        try beginCatalogTransaction()
        defer { endCatalogTransaction() }
        guard !importInProgress else { throw RepositoryError.importInProgress }
        try beginImportJournalTransaction()
        defer { endImportJournalTransaction() }
        try prepareDirectories()
        var document = try documentForMutation()
        // A different repository may have committed since this actor loaded.
        // Refuse to write the caller's old full track snapshot over that catalog.
        let currentPaths = Dictionary(uniqueKeysWithValues: document.tracks.map {
            ($0.id, $0.fileURL.standardizedFileURL.path)
        })
        guard tracks.allSatisfy({ track in
            let path = track.fileURL.standardizedFileURL.path
            guard let current = currentPaths[track.id], current != path else { return true }
            return organizedPreviousPaths[track.id]?.contains(path) != true
        }) else { throw RepositoryError.staleOrganizedTrack }
        document.updatedAt = .now
        document.tracks = tracks
        try persistDocument(document, backUpReadablePrimary: true)
        currentDocument = document
        try reconcileImportJournal(with: tracks)
    }

    /// Journaled as one actor operation so ordinary repository writes cannot interleave.
    func saveSynchronizedOverlay(
        previous: [Track], updated: [Track], tags: [UUID: [String]],
        interruption: (@Sendable (OverlayJournalStep) throws -> Void)? = nil
    ) throws {
        try beginCatalogTransaction()
        defer { endCatalogTransaction() }
        guard !importInProgress else { throw RepositoryError.importInProgress }
        try beginImportJournalTransaction()
        defer { endImportJournalTransaction() }
        try prepareDirectories()
        guard !fileManager.fileExists(atPath: overlayJournalURL.path) else { throw CocoaError(.fileWriteUnknown) }
        let document = try documentForMutation()
        guard document.tracks == previous else { throw CocoaError(.fileWriteUnknown) }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: overlayTagsURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw CocoaError(.fileWriteFileExists)
        }
        try reservePersistentGeneration()
        let filtered = tags.filter { !$0.value.isEmpty }
        let tagData = try JSONEncoder().encode(filtered)
        let staged = rootURL.appendingPathComponent(".device-sync-tags-" + UUID().uuidString + ".tmp")
        defer { try? fileManager.removeItem(at: staged) }
        try tagData.write(to: staged, options: .atomic)
        let journal = OverlayJournal(version: 1, libraryID: document.libraryID,
                                     previous: previous, updated: updated, tags: filtered)
        try encoder.encode(journal).write(to: overlayJournalURL, options: .atomic)
        try synchronizeOverlayFile(overlayJournalURL)
        performingOverlayMutation = true
        defer { performingOverlayMutation = false }
        do {
            try interruption?(.journalWritten)
            try save(tracks: updated)
            try synchronizeOverlayFile(manifestURL)
            try interruption?(.catalogWritten)
            guard rename(staged.path, overlayTagsURL.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try synchronizeOverlayFile(overlayTagsURL)
            try interruption?(.tagsWritten)
            try fileManager.removeItem(at: overlayJournalURL)
        } catch is OverlayJournalInterruption {
            // Test-only interruption models process loss: preserve the on-disk journal.
            throw OverlayJournalInterruption()
        } catch {
            // After publication, keep the updated catalog and journal together for recovery.
            guard fileManager.fileExists(atPath: staged.path) else { throw OverlayRecoveryRequired() }
            do {
                guard try restoreOverlayTracksIfUnchanged(expected: updated, previous: previous) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try fileManager.removeItem(at: overlayJournalURL)
            } catch { throw OverlayRecoveryRequired() }
            throw error
        }
    }

    struct OverlayRecoveryRequired: LocalizedError {
        var errorDescription: String? { L10n.text("deviceSync.overlay.rollbackFailed") }
    }

    private func synchronizeOverlayFile(_ url: URL) throws {
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
    }

    private func recoverOverlayJournal(using document: LibraryDocument, recoveredFromBackup: Bool) throws {
        guard fileManager.fileExists(atPath: overlayJournalURL.path) else { return }
        // A backup may predate the journal and cannot establish which tag generation was published.
        guard !recoveredFromBackup else { throw OverlayRecoveryRequired() }
        let journal = try decoder.decode(OverlayJournal.self, from: Data(contentsOf: overlayJournalURL))
        guard journal.version == 1, journal.libraryID == document.libraryID else { throw OverlayRecoveryRequired() }
        if document.tracks == journal.updated {
            let data = try JSONEncoder().encode(journal.tags)
            try data.write(to: overlayTagsURL, options: .atomic)
            try synchronizeOverlayFile(overlayTagsURL)
        } else if document.tracks != journal.previous {
            throw OverlayRecoveryRequired()
        }
        try fileManager.removeItem(at: overlayJournalURL)
    }

    /// Roll back only if no other catalog writer has changed the track snapshot.
    func restoreOverlayTracksIfUnchanged(expected: [Track], previous: [Track]) throws -> Bool {
        try beginCatalogTransaction()
        defer { endCatalogTransaction() }
        let current = try documentForMutation().tracks
        if current == previous { return true }
        guard current == expected else { return false }
        try save(tracks: previous)
        return true
    }

    func save(document: LibraryDocument, expectedDocument: LibraryDocument? = nil) throws {
        try beginCatalogTransaction()
        defer { endCatalogTransaction() }
        guard !importInProgress else { throw RepositoryError.importInProgress }
        try beginImportJournalTransaction()
        defer { endImportJournalTransaction() }
        try prepareDirectories()
        // Full replacements require an observed baseline when a catalog exists.
        if !hasObservedManifest, try manifestStamp() != nil {
            throw RepositoryError.staleOrganizedTrack
        }
        try verifyObservedStamps()
        guard !fileManager.fileExists(atPath: catalogWriteJournalURL.path),
              !fileManager.fileExists(atPath: storageRestoreJournalURL.path) else { throw CatalogWriteRecoveryRequired() }
        if let expectedDocument {
            let current = try documentForMutation()
            guard current.libraryID == expectedDocument.libraryID,
                  current.tracks == expectedDocument.tracks,
                  current.playlists == expectedDocument.playlists,
                  current.playlistFolders == expectedDocument.playlistFolders,
                  current.playbackEvents == expectedDocument.playbackEvents,
                  current.playbackQueue == expectedDocument.playbackQueue else {
                throw RepositoryError.staleOrganizedTrack
            }
        }
        var updated = document
        updated.updatedAt = .now
        try persistDocument(updated, backUpReadablePrimary: true)
        currentDocument = updated
        try reconcileImportJournal(with: updated.tracks)
    }

    func trashManagedFiles(
        removedTracks: [Track],
        retainedTracks: [Track]
    ) -> (trashed: Int, retained: Int, failures: [String]) {
        trashFiles(
            removedTracks: removedTracks,
            retainedTracks: retainedTracks,
            includesExternalReferences: false
        )
    }

    func trashFiles(
        removedTracks: [Track],
        retainedTracks: [Track],
        includesExternalReferences: Bool
    ) -> (trashed: Int, retained: Int, failures: [String]) {
        let retainedPaths = Set(retainedTracks.map { $0.fileURL.standardizedFileURL.path })
        let uniqueURLs = Dictionary(
            removedTracks.map { ($0.fileURL.standardizedFileURL.path, $0.fileURL.standardizedFileURL) },
            uniquingKeysWith: { first, _ in first }
        ).values

        var trashed = 0
        var retained = 0
        var failures: [String] = []
        for url in uniqueURLs {
            guard !retainedPaths.contains(url.path) else {
                retained += 1
                continue
            }
            guard includesExternalReferences || isInside(url, directory: mediaURL) else {
                retained += 1
                continue
            }
            guard fileManager.fileExists(atPath: url.path) else { continue }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                try fileManager.trashItem(at: url, resultingItemURL: nil)
                trashed += 1
            } catch {
                failures.append(url.lastPathComponent)
            }
        }
        return (trashed, retained, failures)
    }

    func save(playlists: [Playlist]) throws {
        try beginCatalogTransaction()
        defer { endCatalogTransaction() }
        try prepareDirectories()
        var document = try documentForMutation()
        document.updatedAt = .now
        document.playlists = playlists
        try persistDocument(document, backUpReadablePrimary: true)
        currentDocument = document
    }

    func save(playlists: [Playlist], folders: [PlaylistFolder]) throws {
        try beginCatalogTransaction()
        defer { endCatalogTransaction() }
        try prepareDirectories()
        var document = try documentForMutation()
        document.playlists = playlists
        document.playlistFolders = folders
        document.updatedAt = .now
        try persistDocument(document, backUpReadablePrimary: true)
        currentDocument = document
    }

    func savePlaylistArtwork(_ data: Data, playlistID: Playlist.ID) throws -> String {
        guard data.count <= 12 * 1_024 * 1_024, NSImage(data: data) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try fileManager.createDirectory(
            at: playlistArtworkDirectoryURL,
            withIntermediateDirectories: true
        )
        let url = playlistArtworkDirectoryURL.appendingPathComponent(
            "\(playlistID.uuidString)-\(UUID().uuidString).artwork"
        )
        try data.write(to: url, options: .atomic)
        return url.path
    }

    func playlistArtworkData(at path: String) -> Data? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard isInside(url, directory: playlistArtworkDirectoryURL),
              let data = try? Data(contentsOf: url),
              data.count <= 12 * 1_024 * 1_024,
              NSImage(data: data) != nil else { return nil }
        return data
    }

    func removePlaylistArtwork(at path: String?) throws {
        guard let path else { return }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard isInside(url, directory: playlistArtworkDirectoryURL),
              fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func recordPlaybackEvent(_ event: PlaybackEvent) throws {
        try beginCatalogTransaction()
        defer { endCatalogTransaction() }
        try prepareDirectories()
        var document = try documentForMutation()
        document.updatedAt = .now
        document.playbackEvents.append(event)
        try persistPlaybackEvents(document)
        currentDocument = document
    }

    func save(playbackEvents: [PlaybackEvent]) throws {
        try beginCatalogTransaction()
        defer { endCatalogTransaction() }
        try prepareDirectories()
        var document = try documentForMutation()
        document.updatedAt = .now
        document.playbackEvents = playbackEvents
        try persistPlaybackEvents(document)
        currentDocument = document
    }

    func save(playbackQueue: PlaybackQueueState) throws {
        try beginCatalogTransaction()
        defer { endCatalogTransaction() }
        try prepareDirectories()
        var document = try documentForMutation()
        document.updatedAt = .now
        document.playbackQueue = playbackQueue
        try persistPlaybackQueue(document)
        currentDocument = document
    }

    /// Clears Ongaku's catalog records without deleting, moving, renaming, or
    /// otherwise touching any referenced or managed audio file.
    func clearAllRegistrations() throws {
        try beginCatalogTransaction()
        defer { endCatalogTransaction() }
        guard !importInProgress else { throw RepositoryError.importInProgress }
        try beginImportJournalTransaction()
        defer { endImportJournalTransaction() }
        try prepareDirectories()
        var emptyDocument = try documentForMutation()
        let removedTrackIDs = Set(emptyDocument.tracks.map(\.id))
        emptyDocument.updatedAt = .now
        emptyDocument.tracks = []
        emptyDocument.playlists = emptyDocument.playlists.map { playlist in
            var emptied = playlist
            if !emptied.entries.isEmpty {
                emptied.entries = []
                emptied.updatedAt = .now
            }
            return emptied
        }
        emptyDocument.playbackEvents.removeAll { removedTrackIDs.contains($0.trackID) }
        emptyDocument.playbackQueue = PlaybackQueueState()
        // The durable catalog journal owns the reset, including recovery
        // metadata and empty backups, until every file has been published.
        try persistDocument(emptyDocument, backUpReadablePrimary: false, clearsRegistrations: true)
        try refreshObservedStamps()
        currentDocument = emptyDocument
    }

    func importFiles(
        _ sourceURLs: [URL],
        existing: [Track],
        reportDuplicates: Bool = true,
        metadataOverrides: [String: AudioCDImportRequest] = [:],
        requiredMetadataOverrides: [String: RequiredImportMetadataDraft] = [:]
    ) async -> ImportResult {
        do {
            guard !importInProgress else { throw RepositoryError.importInProgress }
            try beginImportOperation()
        } catch {
            return ImportResult(imported: [], issues: sourceURLs.map {
                ImportIssue(fileName: $0.lastPathComponent, message: error.localizedDescription)
            })
        }

        defer {
            importInProgress = false
            endImportJournalTransaction()
        }
        var imported: [Track] = []
        var issues: [ImportIssue] = []
        var knownHashes = Set(existing.map(\.sha256))
        var identityIndex = CatalogIdentityIndex(tracks: existing)

        for source in sourceURLs {
            let didAccess = source.startAccessingSecurityScopedResource()
            defer { if didAccess { source.stopAccessingSecurityScopedResource() } }

            do {
                let sourceValues = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true else {
                    throw RepositoryError.sourceIsNotRegularFile(source.lastPathComponent)
                }
                let sourceHash = try Self.sha256(of: source)
                guard !knownHashes.contains(sourceHash) else {
                    if reportDuplicates {
                        issues.append(ImportIssue(
                            fileName: source.lastPathComponent,
                            message: L10n.text("import.duplicate")
                        ))
                    }
                    continue
                }

                let staged = incomingURL
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(source.pathExtension)
                var journalEntry = ImportJournalEntry(
                    id: UUID(),
                    fileName: source.lastPathComponent,
                    expectedSHA256: sourceHash,
                    stagedPath: staged.path,
                    destinationPath: nil,
                    track: nil,
                    phase: .copying
                )
                try upsertJournalEntry(journalEntry)
#if DEBUG
                try importWriteTestHook?(.copying)
#endif
                try fileManager.copyItem(at: source, to: staged)

                let stagedHash = try Self.sha256(of: staged)
                guard stagedHash == sourceHash else {
                    try? fileManager.removeItem(at: staged)
                    throw RepositoryError.copyVerificationFailed(source.lastPathComponent)
                }

#if DEBUG
                if let importStagedTestGate { await importStagedTestGate() }
#endif
                let metadata = await Self.readMetadata(from: staged, fallbackName: source.deletingPathExtension().lastPathComponent)
                let metadataOverride = metadataOverrides[source.standardizedFileURL.path]
                let requiredOverride = requiredMetadataOverrides[source.standardizedFileURL.path]
                let title = metadataOverride?.title ?? metadata.title
                let artist = metadataOverride?.artist ?? requiredOverride?.artist ?? metadata.artist
                let album = metadataOverride?.album ?? requiredOverride?.album ?? metadata.album
                let albumArtist = metadataOverride?.albumArtist ?? metadata.albumArtist
                let releaseYear = metadataOverride?.releaseYear ?? metadata.releaseYear
                let isrc = metadataOverride?.isrc ?? metadata.isrc
                let trackNumber = metadataOverride?.trackNumber ?? metadata.trackNumber
                let trackCount = metadataOverride?.trackCount ?? metadata.trackCount
                let discNumber = metadataOverride?.discNumber ?? metadata.discNumber
                let discCount = metadataOverride?.discCount ?? metadata.discCount
                let destination = try destinationURL(
                    artist: artist,
                    album: album,
                    originalName: source.lastPathComponent,
                    hash: sourceHash
                )
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let values = try staged.resourceValues(forKeys: [.fileSizeKey])
                let identities = identityIndex.identities(
                    artist: artist,
                    album: album
                )
                let track = Track(
                    id: UUID(),
                    title: title,
                    artist: artist,
                    album: album,
                    artistSortName: metadata.artistSortName,
                    albumSortName: metadata.albumSortName,
                    albumArtist: albumArtist,
                    composer: metadata.composer,
                    grouping: metadata.grouping,
                    genre: metadata.genre,
                    participantCredits: metadata.participantCredits,
                    workName: metadata.workName,
                    movementName: metadata.movementName,
                    movementNumber: metadata.movementNumber,
                    movementCount: metadata.movementCount,
                    beatsPerMinute: metadata.beatsPerMinute,
                    copyright: metadata.copyright,
                    isrc: isrc,
                    releaseYear: releaseYear,
                    trackNumber: trackNumber,
                    trackCount: trackCount,
                    discNumber: discNumber,
                    discCount: discCount,
                    isCompilation: metadata.isCompilation,
                    comments: metadata.comments,
                    lyrics: metadata.lyrics,
                    musicBrainzReference: metadataOverride?.musicBrainzReference,
                    duration: metadata.duration,
                    fileSize: Int64(values.fileSize ?? 0),
                    managedPath: destination.path,
                    sha256: sourceHash,
                    addedAt: .now,
                    lastVerifiedAt: .now,
                    health: .verified,
                    artistID: identities.artistID,
                    albumID: identities.albumID
                )
                journalEntry.destinationPath = destination.path
                journalEntry.track = track
                journalEntry.phase = .installing
                try upsertJournalEntry(journalEntry)
#if DEBUG
                try importWriteTestHook?(.installing)
#endif
                if fileManager.fileExists(atPath: destination.path) {
                    guard try Self.sha256(of: destination) == stagedHash else {
                        throw RepositoryError.copyVerificationFailed(source.lastPathComponent)
                    }
                    try fileManager.removeItem(at: staged)
                } else {
                    try fileManager.moveItem(at: staged, to: destination)
                }

                guard try Self.sha256(of: destination) == sourceHash else {
                    throw RepositoryError.copyVerificationFailed(source.lastPathComponent)
                }
                journalEntry.phase = .installed
                try upsertJournalEntry(journalEntry)
#if DEBUG
                try importWriteTestHook?(.installed)
#endif
                imported.append(track)
                knownHashes.insert(sourceHash)
            } catch {
                issues.append(ImportIssue(fileName: source.lastPathComponent, message: error.localizedDescription))
            }
        }

        return ImportResult(imported: imported, issues: issues)
    }

    func referenceFilesInPlace(
        _ sourceURLs: [URL],
        existing: [Track],
        copyExternalFiles: Bool = false
    ) async -> ImportResult {
        do {
            guard !importInProgress else { throw RepositoryError.importInProgress }
            try beginImportOperation()
        } catch {
            return ImportResult(imported: [], issues: sourceURLs.map {
                ImportIssue(fileName: $0.lastPathComponent, message: error.localizedDescription)
            })
        }
        defer {
            importInProgress = false
            endImportJournalTransaction()
        }
        var referenced: [Track] = []
        var issues: [ImportIssue] = []
        let existingByHash = Dictionary(
            existing.map { ($0.sha256, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var processedHashes = Set<String>()
        var identityIndex = CatalogIdentityIndex(tracks: existing)

        for source in sourceURLs {
            let didAccess = source.startAccessingSecurityScopedResource()
            defer { if didAccess { source.stopAccessingSecurityScopedResource() } }

            do {
                let values = try source.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
                )
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw RepositoryError.sourceIsNotRegularFile(source.lastPathComponent)
                }
                let hash = try Self.sha256(of: source)
                guard processedHashes.insert(hash).inserted else { continue }
                let metadata = await Self.readMetadata(
                    from: source,
                    fallbackName: source.deletingPathExtension().lastPathComponent
                )

                let mustCopy = copyExternalFiles && !isInside(
                    source.resolvingSymlinksInPath(), directory: mediaURL.resolvingSymlinksInPath()
                )
                let destination: URL
                if mustCopy {
                    let root = mediaURL.resolvingSymlinksInPath().standardizedFileURL
                    destination = try destinationURL(artist: metadata.artist, album: metadata.album,
                                                     originalName: source.lastPathComponent, hash: hash)
                    guard isInside(destination.resolvingSymlinksInPath(), directory: root) else {
                        throw CocoaError(.fileWriteNoPermission)
                    }
                } else {
                    destination = source.standardizedFileURL
                }

                let originalTrack = existingByHash[hash]
                var track: Track
                if var existingTrack = originalTrack {
                    existingTrack.managedPath = destination.path
                    existingTrack.fileSize = Int64(values.fileSize ?? 0)
                    existingTrack.lastVerifiedAt = .now
                    existingTrack.health = .verified
                    track = existingTrack
                } else {
                    let identities = identityIndex.identities(artist: metadata.artist, album: metadata.album)
                    track = Track(
                        id: UUID(),
                        title: metadata.title,
                        artist: metadata.artist,
                        album: metadata.album,
                        artistSortName: metadata.artistSortName,
                        albumSortName: metadata.albumSortName,
                        albumArtist: metadata.albumArtist,
                        composer: metadata.composer,
                        grouping: metadata.grouping,
                        genre: metadata.genre,
                        participantCredits: metadata.participantCredits,
                        workName: metadata.workName,
                        movementName: metadata.movementName,
                        movementNumber: metadata.movementNumber,
                        movementCount: metadata.movementCount,
                        beatsPerMinute: metadata.beatsPerMinute,
                        copyright: metadata.copyright,
                        isrc: metadata.isrc,
                        releaseYear: metadata.releaseYear,
                        trackNumber: metadata.trackNumber,
                        trackCount: metadata.trackCount,
                        discNumber: metadata.discNumber,
                        discCount: metadata.discCount,
                        isCompilation: metadata.isCompilation,
                        comments: metadata.comments,
                        lyrics: metadata.lyrics,
                        duration: metadata.duration,
                        fileSize: Int64(values.fileSize ?? 0),
                        managedPath: destination.path,
                        sha256: hash,
                        addedAt: .now,
                        lastVerifiedAt: .now,
                        health: .verified,
                        artistID: identities.artistID,
                        albumID: identities.albumID
                    )
                }
                if mustCopy {
                    try copyManagedReference(source, track: track, hash: hash,
                                             previousPath: originalTrack?.managedPath)
                }
                referenced.append(track)
            } catch {
                issues.append(ImportIssue(
                    fileName: source.lastPathComponent,
                    message: error.localizedDescription
                ))
            }
        }
        return ImportResult(imported: referenced, issues: issues)
    }

    private func copyManagedReference(_ source: URL, track: Track, hash: String, previousPath: String?) throws {
        let destination = track.fileURL.standardizedFileURL
        if fileManager.fileExists(atPath: destination.path) {
            guard try Self.sha256(of: destination) == hash else {
                throw RepositoryError.copyVerificationFailed(source.lastPathComponent)
            }
            return
        }
        let staged = incomingURL.appendingPathComponent(UUID().uuidString).appendingPathExtension(source.pathExtension)
        var entry = ImportJournalEntry(id: UUID(), fileName: source.lastPathComponent, expectedSHA256: hash,
                                       stagedPath: staged.path, destinationPath: nil, track: nil, phase: .copying)
        try upsertJournalEntry(entry)
#if DEBUG
        try importWriteTestHook?(.copying)
#endif
        try fileManager.copyItem(at: source, to: staged)
        guard try Self.sha256(of: staged) == hash else { throw RepositoryError.copyVerificationFailed(source.lastPathComponent) }
        entry.destinationPath = destination.path
        entry.track = track
        entry.previousManagedPath = previousPath
        entry.phase = .installing
        try upsertJournalEntry(entry)
#if DEBUG
        try importWriteTestHook?(.installing)
#endif
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            guard try Self.sha256(of: destination) == hash else { throw RepositoryError.copyVerificationFailed(source.lastPathComponent) }
            try fileManager.removeItem(at: staged)
        } else {
            try fileManager.moveItem(at: staged, to: destination)
        }
        guard try Self.sha256(of: destination) == hash else { throw RepositoryError.copyVerificationFailed(source.lastPathComponent) }
        entry.phase = .installed
        try upsertJournalEntry(entry)
#if DEBUG
        try importWriteTestHook?(.installed)
#endif
    }

    func verify(_ tracks: [Track]) -> [Track] {
        tracks.map { track in
            var checked = track
            guard fileManager.fileExists(atPath: track.managedPath) else {
                checked.health = .missing
                checked.lastVerifiedAt = .now
                return checked
            }

            do {
                let values = try track.fileURL.resourceValues(forKeys: [.fileSizeKey])
                let currentSize = Int64(values.fileSize ?? 0)
                guard currentSize == track.fileSize else {
                    checked.health = .changed
                    checked.lastVerifiedAt = .now
                    return checked
                }
                checked.health = try Self.sha256(of: track.fileURL) == track.sha256 ? .verified : .changed
            } catch {
                checked.health = .unreadable
            }
            checked.lastVerifiedAt = .now
            return checked
        }
    }

    func relink(_ track: Track, to sourceURL: URL) throws -> Track {
        let source = sourceURL.standardizedFileURL
        let didAccess = source.startAccessingSecurityScopedResource()
        defer { if didAccess { source.stopAccessingSecurityScopedResource() } }

        let values = try source.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw RepositoryError.sourceIsNotRegularFile(source.lastPathComponent)
        }
        let size = Int64(values.fileSize ?? 0)
        guard size == track.fileSize, try Self.sha256(of: source) == track.sha256 else {
            throw RepositoryError.relinkFingerprintMismatch(source.lastPathComponent)
        }

        var relinked = track
        relinked.managedPath = source.path
        relinked.fileSize = size
        relinked.lastVerifiedAt = .now
        relinked.health = .verified
        return relinked
    }

    func relinkMissingFiles(
        in tracks: [Track],
        searching searchRoots: [URL]? = nil
    ) -> FileRelinkResult {
        var updated = tracks
        let missingIndices = updated.indices.filter { updated[$0].health == .missing }
        guard !missingIndices.isEmpty else {
            return FileRelinkResult(
                tracks: updated,
                scannedFileCount: 0,
                relinkedTrackCount: 0,
                issueCount: 0
            )
        }

        var unresolvedBySize: [Int64: Set<Int>] = [:]
        for index in missingIndices {
            unresolvedBySize[updated[index].fileSize, default: []].insert(index)
        }
        var resolvedIndices = Set<Int>()
        var visitedPaths = Set<String>()
        var scannedFileCount = 0
        var issueCount = 0

        for root in (searchRoots ?? [mediaURL]) {
            let standardizedRoot = root.standardizedFileURL
            let didAccess = standardizedRoot.startAccessingSecurityScopedResource()
            defer { if didAccess { standardizedRoot.stopAccessingSecurityScopedResource() } }

            guard let enumerator = fileManager.enumerator(
                at: standardizedRoot,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else {
                issueCount += 1
                continue
            }

            for case let candidateURL as URL in enumerator {
                let candidate = candidateURL.standardizedFileURL
                guard visitedPaths.insert(candidate.path).inserted,
                      Self.isSupportedAudioFile(candidate),
                      let values = try? candidate.resourceValues(
                        forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
                      ),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true
                else { continue }

                let size = Int64(values.fileSize ?? 0)
                guard let possibleIndices = unresolvedBySize[size]?.subtracting(resolvedIndices),
                      !possibleIndices.isEmpty
                else { continue }
                scannedFileCount += 1

                do {
                    let hash = try Self.sha256(of: candidate)
                    for index in possibleIndices where updated[index].sha256 == hash {
                        updated[index].managedPath = candidate.path
                        updated[index].lastVerifiedAt = .now
                        updated[index].health = .verified
                        resolvedIndices.insert(index)
                    }
                } catch {
                    issueCount += 1
                }
                if resolvedIndices.count == missingIndices.count { break }
            }
            if resolvedIndices.count == missingIndices.count { break }
        }

        return FileRelinkResult(
            tracks: updated,
            scannedFileCount: scannedFileCount,
            relinkedTrackCount: resolvedIndices.count,
            issueCount: issueCount
        )
    }

    /// Absolute paths in older catalogs refer to the previous Mac. Once the
    /// portable folder has been copied, resolve only missing entries against
    /// the new media root and require the original size and SHA-256 before
    /// changing a path.
    private func relocateFilesAfterPortableLibraryMove(in tracks: [Track]) -> FileRelinkResult {
        var candidates = tracks
        var hasMissingPath = false
        for index in candidates.indices
            where !fileManager.fileExists(atPath: candidates[index].managedPath) {
            candidates[index].health = .missing
            hasMissingPath = true
        }
        guard hasMissingPath else {
            return FileRelinkResult(
                tracks: tracks,
                scannedFileCount: 0,
                relinkedTrackCount: 0,
                issueCount: 0
            )
        }
        return relinkMissingFiles(in: candidates, searching: [mediaURL])
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()

        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func isSupportedAudioFile(_ url: URL) -> Bool {
        let supportedExtensions: Set<String> = [
            "aac", "aif", "aiff", "alac", "caf", "flac", "m4a", "mp3", "wav",
        ]
        return supportedExtensions.contains(url.pathExtension.lowercased())
    }

    private func prepareDirectories() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: incomingURL, withIntermediateDirectories: true)
    }

    private func decodeDocument(at url: URL) throws -> DecodedLibraryDocument {
        let data = try Data(contentsOf: url)
        if let envelope = try? decoder.decode(CatalogEnvelope.self, from: data) {
            let header = envelope.header
            switch header.schemaVersion ?? 0 {
            case LibraryDocument.currentSchema:
                guard let document = envelope.document else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return DecodedLibraryDocument(
                    document: document,
                    migratedFromSchemaVersion: nil
                )
            case 11:
                let schema11 = try decoder.decode(Schema11LibraryDocument.self, from: data)
                return DecodedLibraryDocument(
                    document: LibraryDocument(
                        updatedAt: schema11.updatedAt,
                        tracks: schema11.tracks,
                        libraryID: schema11.libraryID,
                        createdAt: schema11.createdAt,
                        playlists: schema11.playlists,
                        playlistFolders: schema11.playlistFolders,
                        playbackEvents: schema11.playbackEvents,
                        playbackQueue: schema11.playbackQueue
                    ),
                    migratedFromSchemaVersion: 11
                )
            case 10:
                let schema10 = try decoder.decode(Schema10LibraryDocument.self, from: data)
                return DecodedLibraryDocument(
                    document: LibraryDocument(
                        updatedAt: schema10.updatedAt,
                        tracks: schema10.tracks,
                        libraryID: schema10.libraryID,
                        createdAt: schema10.createdAt,
                        playlists: schema10.playlists,
                        playlistFolders: schema10.playlistFolders,
                        playbackEvents: schema10.playbackEvents,
                        playbackQueue: schema10.playbackQueue
                    ),
                    migratedFromSchemaVersion: 10
                )
            case 9:
                let schema9 = try decoder.decode(Schema9LibraryDocument.self, from: data)
                return DecodedLibraryDocument(
                    document: LibraryDocument(
                        updatedAt: schema9.updatedAt,
                        tracks: schema9.tracks,
                        libraryID: schema9.libraryID,
                        createdAt: schema9.createdAt,
                        playlists: schema9.playlists,
                        playlistFolders: schema9.playlistFolders,
                        playbackEvents: schema9.playbackEvents,
                        playbackQueue: schema9.playbackQueue
                    ),
                    migratedFromSchemaVersion: 9
                )
            case 8:
                let schema8 = try decoder.decode(Schema8LibraryDocument.self, from: data)
                return DecodedLibraryDocument(
                    document: LibraryDocument(
                        updatedAt: schema8.updatedAt,
                        tracks: schema8.tracks,
                        libraryID: schema8.libraryID,
                        createdAt: schema8.createdAt,
                        playlists: schema8.playlists,
                        playlistFolders: schema8.playlistFolders,
                        playbackEvents: schema8.playbackEvents,
                        playbackQueue: schema8.playbackQueue
                    ),
                    migratedFromSchemaVersion: 8
                )
            case 7:
                let schema7 = try decoder.decode(Schema7LibraryDocument.self, from: data)
                return DecodedLibraryDocument(
                    document: LibraryDocument(
                        updatedAt: schema7.updatedAt,
                        tracks: schema7.tracks,
                        libraryID: schema7.libraryID,
                        createdAt: schema7.createdAt,
                        playlists: schema7.playlists,
                        playlistFolders: schema7.playlistFolders,
                        playbackEvents: schema7.playbackEvents,
                        playbackQueue: schema7.playbackQueue
                    ),
                    migratedFromSchemaVersion: 7
                )
            case 6:
                let schema6 = try decoder.decode(Schema6LibraryDocument.self, from: data)
                return DecodedLibraryDocument(
                    document: LibraryDocument(
                        updatedAt: schema6.updatedAt,
                        tracks: schema6.tracks,
                        libraryID: schema6.libraryID,
                        createdAt: schema6.createdAt,
                        playlists: schema6.playlists,
                        playlistFolders: schema6.playlistFolders,
                        playbackEvents: schema6.playbackEvents,
                        playbackQueue: schema6.playbackQueue
                    ),
                    migratedFromSchemaVersion: 6
                )
            case 5:
                let schema5 = try decoder.decode(Schema5LibraryDocument.self, from: data)
                var playlists = schema5.playlists
                for index in playlists.indices { playlists[index].sortOrder = index }
                return DecodedLibraryDocument(
                    document: LibraryDocument(
                        updatedAt: schema5.updatedAt,
                        tracks: schema5.tracks,
                        libraryID: schema5.libraryID,
                        createdAt: schema5.createdAt,
                        playlists: playlists,
                        playlistFolders: [],
                        playbackEvents: schema5.playbackEvents,
                        playbackQueue: schema5.playbackQueue
                    ),
                    migratedFromSchemaVersion: 5
                )
            case 4:
                let schema4 = try decoder.decode(Schema4LibraryDocument.self, from: data)
                var playlists = schema4.playlists
                for index in playlists.indices { playlists[index].sortOrder = index }
                return DecodedLibraryDocument(
                    document: LibraryDocument(
                        updatedAt: schema4.updatedAt,
                        tracks: schema4.tracks,
                        libraryID: schema4.libraryID,
                        createdAt: schema4.createdAt,
                        playlists: playlists,
                        playlistFolders: [],
                        playbackEvents: schema4.playbackEvents,
                        playbackQueue: schema4.playbackQueue
                    ),
                    migratedFromSchemaVersion: 4
                )
            case 3:
                let schema3 = try decoder.decode(Schema3LibraryDocument.self, from: data)
                var playlists = schema3.playlists
                for index in playlists.indices { playlists[index].sortOrder = index }
                return DecodedLibraryDocument(
                    document: LibraryDocument(
                        updatedAt: schema3.updatedAt,
                        tracks: schema3.tracks,
                        libraryID: schema3.libraryID,
                        createdAt: schema3.createdAt,
                        playlists: playlists,
                        playlistFolders: [],
                        playbackEvents: schema3.playbackEvents,
                        playbackQueue: nil
                    ),
                    migratedFromSchemaVersion: 3
                )
            case 2:
                let schema2 = try decoder.decode(Schema2LibraryDocument.self, from: data)
                return DecodedLibraryDocument(
                    document: LibraryDocument(
                        updatedAt: schema2.updatedAt,
                        tracks: schema2.tracks,
                        libraryID: schema2.libraryID,
                        createdAt: schema2.createdAt,
                        playlists: [],
                        playbackEvents: []
                    ),
                    migratedFromSchemaVersion: 2
                )
            case 0, 1:
                let legacy = try decoder.decode(LegacyLibraryDocument.self, from: data)
                return migrateLegacyDocument(
                    tracks: legacy.tracks,
                    updatedAt: legacy.updatedAt,
                    sourceSchemaVersion: header.schemaVersion ?? 0
                )
            default:
                throw RepositoryError.unsupportedSchema(header.schemaVersion ?? 0)
            }
        }

        // Very early development builds stored the track array without a
        // document envelope. Supporting it costs little and avoids turning an
        // otherwise valid catalog into an unrecoverable file.
        if let tracks = try? decoder.decode([Track].self, from: data) {
            return migrateLegacyDocument(
                tracks: tracks,
                updatedAt: nil,
                sourceSchemaVersion: 0
            )
        }

        // Re-run the current decoder to surface its precise corruption error.
        _ = try decoder.decode(LibraryDocument.self, from: data)
        throw CocoaError(.fileReadCorruptFile)
    }

    private func migrateLegacyDocument(
        tracks: [Track],
        updatedAt: Date?,
        sourceSchemaVersion: Int
    ) -> DecodedLibraryDocument {
        var identityIndex = CatalogIdentityIndex()
        let migratedTracks = tracks.map { track in
            var migrated = track
            let identities = identityIndex.identities(
                artist: track.artist,
                album: track.album
            )
            migrated.artistID = identities.artistID
            migrated.albumID = identities.albumID
            return migrated
        }
        let createdAt = migratedTracks.map(\.addedAt).min() ?? updatedAt ?? .now
        return DecodedLibraryDocument(
            document: LibraryDocument(
                updatedAt: updatedAt ?? .now,
                tracks: migratedTracks,
                libraryID: UUID(),
                createdAt: createdAt
            ),
            migratedFromSchemaVersion: sourceSchemaVersion
        )
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func recoverCatalogWriteJournal() throws {
        guard fileManager.fileExists(atPath: catalogWriteJournalURL.path) else { return }
        let data = try Data(contentsOf: catalogWriteJournalURL)
        guard let journal = try? decoder.decode(CatalogWriteJournal.self, from: data),
              journal.version == 1,
              let document = try? decoder.decode(LibraryDocument.self, from: journal.manifest) else {
            throw CatalogWriteRecoveryRequired()
        }
        let current: Data? = fileManager.fileExists(atPath: manifestURL.path) ? try Data(contentsOf: manifestURL) : nil
        let currentDigest = current.map(digest)
        let targetDigest = digest(journal.manifest)
        if let recordedDigest = journal.manifestDigest, recordedDigest != targetDigest {
            throw CatalogWriteRecoveryRequired()
        }
        guard currentDigest == journal.previousManifestDigest || currentDigest == targetDigest else {
            throw CatalogWriteRecoveryRequired()
        }
        if journal.clearsRegistrations == true {
            guard document.tracks.isEmpty,
                  document.playlists.allSatisfy({ $0.entries.isEmpty }) else {
                throw CatalogWriteRecoveryRequired()
            }
            try persistImportJournal(ImportJournal())
            try encoder.encode(document.libraryID).write(to: storageRecoveryReceiptURL, options: .atomic)
        }
        try persistPlaybackSidecars(document)
        if journal.clearsRegistrations == true {
            try Data(contentsOf: playbackQueueURL).write(to: playbackQueueBackupURL, options: [.atomic])
            try Data(contentsOf: playbackEventsURL).write(to: playbackEventsBackupURL, options: [.atomic])
            try journal.manifest.write(to: backupURL, options: [.atomic])
        }
        if currentDigest != targetDigest {
            if journal.backUpReadablePrimary, let current,
               (try? decodeDocument(at: manifestURL)) != nil {
                try current.write(to: backupURL, options: [.atomic])
            }
            try journal.manifest.write(to: manifestURL, options: [.atomic])
        }
        observedManifestStamp = try manifestStamp()
        try fileManager.removeItem(at: catalogWriteJournalURL)
    }

    private func persistDocument(
        _ document: LibraryDocument,
        backUpReadablePrimary: Bool,
        clearsRegistrations: Bool = false
    ) throws {
        if !performingOverlayMutation && fileManager.fileExists(atPath: overlayJournalURL.path) {
            throw OverlayRecoveryRequired()
        }
        guard !fileManager.fileExists(atPath: catalogWriteJournalURL.path) else { throw CatalogWriteRecoveryRequired() }
        try reservePersistentGeneration()
        var document = document
        document.catalogGenerationEstablished = true
        let data = try encoder.encode(document)
        let previous: Data? = fileManager.fileExists(atPath: manifestURL.path) ? try Data(contentsOf: manifestURL) : nil
        let journal = CatalogWriteJournal(version: 1, previousManifestDigest: previous.map(digest),
                                          manifest: data, manifestDigest: digest(data),
                                          backUpReadablePrimary: backUpReadablePrimary,
                                          clearsRegistrations: clearsRegistrations)
        try encoder.encode(journal).write(to: catalogWriteJournalURL, options: [.atomic])
        try synchronizeOverlayFile(catalogWriteJournalURL)
#if DEBUG
        try catalogWriteTestHook?(.journal)
#endif
        if clearsRegistrations {
            try persistImportJournal(ImportJournal())
            try encoder.encode(document.libraryID).write(to: storageRecoveryReceiptURL, options: .atomic)
        }
        try persistPlaybackQueue(document)
#if DEBUG
        try catalogWriteTestHook?(.queue)
#endif
        try persistPlaybackEvents(document)
#if DEBUG
        try catalogWriteTestHook?(.events)
#endif
        if clearsRegistrations {
            try Data(contentsOf: playbackQueueURL).write(to: playbackQueueBackupURL, options: [.atomic])
            try Data(contentsOf: playbackEventsURL).write(to: playbackEventsBackupURL, options: [.atomic])
            try data.write(to: backupURL, options: [.atomic])
        }
        if backUpReadablePrimary, let previous,
           (try? decodeDocument(at: manifestURL)) != nil {
            try previous.write(to: backupURL, options: [.atomic])
        }
        try data.write(to: manifestURL, options: [.atomic])
        observedManifestStamp = try manifestStamp()
        hasObservedManifest = true
#if DEBUG
        try catalogWriteTestHook?(.manifest)
#endif
        try fileManager.removeItem(at: catalogWriteJournalURL)
    }

    private func applyingPlaybackSidecars(to source: LibraryDocument) throws -> LibraryDocument {
        var document = source
        let trackIDs = Set(document.tracks.map(\.id))

        if let queueDocument: PlaybackQueueDocument = try decodeSidecar(
            at: playbackQueueURL,
            backupURL: playbackQueueBackupURL
        ), queueDocument.schemaVersion == PlaybackQueueDocument.currentSchema,
           queueDocument.libraryID == document.libraryID {
            if let queue = queueDocument.queue {
                let validQueueIDs = queue.trackIDs.filter(trackIDs.contains)
                let currentTrackID = queue.currentTrackID.flatMap {
                    validQueueIDs.contains($0) ? $0 : nil
                }
                document.playbackQueue = PlaybackQueueState(
                    trackIDs: validQueueIDs,
                    currentTrackID: currentTrackID,
                    position: currentTrackID == nil ? 0 : queue.position
                )
            } else {
                document.playbackQueue = nil
            }
        }

        if let eventsDocument: PlaybackEventsDocument = try decodeSidecar(
            at: playbackEventsURL,
            backupURL: playbackEventsBackupURL
        ), eventsDocument.schemaVersion == PlaybackEventsDocument.currentSchema,
           eventsDocument.libraryID == document.libraryID {
            document.playbackEvents = eventsDocument.events.filter {
                trackIDs.contains($0.trackID)
            }
        }
        return document
    }

    private func decodeSidecar<Value: Decodable>(
        at url: URL,
        backupURL: URL
    ) throws -> Value? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            return try decoder.decode(Value.self, from: Data(contentsOf: url))
        } catch {
            guard fileManager.fileExists(atPath: backupURL.path),
                  let backupData = try? Data(contentsOf: backupURL),
                  let recovered = try? decoder.decode(Value.self, from: backupData) else {
                return nil
            }
            try backupData.write(to: url, options: .atomic)
            return recovered
        }
    }

    private func persistPlaybackSidecars(_ document: LibraryDocument) throws {
        try persistPlaybackQueue(document)
        try persistPlaybackEvents(document)
    }

    private func persistPlaybackQueue(_ document: LibraryDocument) throws {
        let snapshot = PlaybackQueueDocument(
            libraryID: document.libraryID,
            updatedAt: document.updatedAt,
            queue: document.playbackQueue
        )
        let data = try encoder.encode(snapshot)
        try persistSidecar(
            data,
            at: playbackQueueURL,
            backupURL: playbackQueueBackupURL,
            validatesAs: PlaybackQueueDocument.self
        )
    }

    private func persistPlaybackEvents(_ document: LibraryDocument) throws {
        let snapshot = PlaybackEventsDocument(
            libraryID: document.libraryID,
            updatedAt: document.updatedAt,
            events: document.playbackEvents
        )
        let data = try encoder.encode(snapshot)
        try persistSidecar(
            data,
            at: playbackEventsURL,
            backupURL: playbackEventsBackupURL,
            validatesAs: PlaybackEventsDocument.self
        )
    }

    private func persistSidecar<Value: Decodable>(
        _ data: Data,
        at url: URL,
        backupURL: URL,
        validatesAs type: Value.Type
    ) throws {
        try reservePersistentGeneration()
        if fileManager.fileExists(atPath: url.path),
           let previous = try? Data(contentsOf: url),
           (try? decoder.decode(type, from: previous)) != nil {
            try previous.write(to: backupURL, options: .atomic)
        }
        try data.write(to: url, options: .atomic)
        if url == playbackQueueURL { observedQueueStamp = try fileStamp(url) }
        if url == playbackEventsURL { observedEventsStamp = try fileStamp(url) }
    }

    private func replacePlaybackSidecarsForClear(_ document: LibraryDocument) throws {
        let queueData = try encoder.encode(PlaybackQueueDocument(
            libraryID: document.libraryID,
            updatedAt: document.updatedAt,
            queue: document.playbackQueue
        ))
        let eventsData = try encoder.encode(PlaybackEventsDocument(
            libraryID: document.libraryID,
            updatedAt: document.updatedAt,
            events: document.playbackEvents
        ))
        for url in [playbackQueueBackupURL, playbackQueueURL] {
            try queueData.write(to: url, options: .atomic)
        }
        for url in [playbackEventsBackupURL, playbackEventsURL] {
            try eventsData.write(to: url, options: .atomic)
        }
    }

    private func archivePreMigrationManifest(
        at sourceURL: URL,
        sourceSchemaVersion: Int
    ) throws {
        let archiveURL = migrationArchiveURL(for: sourceSchemaVersion)
        guard !fileManager.fileExists(atPath: archiveURL.path) else { return }
        try Data(contentsOf: sourceURL).write(to: archiveURL, options: [.atomic])
    }

    private var performingOverlayMutation = false

    private func documentForMutation() throws -> LibraryDocument {
        guard !fileManager.fileExists(atPath: catalogWriteJournalURL.path),
              !fileManager.fileExists(atPath: storageRestoreJournalURL.path) else { throw CatalogWriteRecoveryRequired() }
        if !performingOverlayMutation && fileManager.fileExists(atPath: overlayJournalURL.path) {
            throw OverlayRecoveryRequired()
        }
        if let currentDocument {
            try verifyObservedStamps()
            return currentDocument
        }
        if fileManager.fileExists(atPath: manifestURL.path)
            || fileManager.fileExists(atPath: backupURL.path)
        {
            return try load().document
        }
        let document = LibraryDocument()
        currentDocument = document
        try refreshObservedStamps()
        return document
    }

    private func recoverImports(into document: inout LibraryDocument) throws -> (recovered: Int, unresolved: Int, remainingJournal: ImportJournal?) {
        guard fileManager.fileExists(atPath: importJournalURL.path) else { return (0, 0, nil) }
        var journal = try decodeImportJournal()
        var retained: [ImportJournalEntry] = []
        var knownHashes = Set(document.tracks.map(\.sha256))
        var identityIndex = CatalogIdentityIndex(tracks: document.tracks)
        var recoveredCount = 0
        var unresolvedCount = 0

        for entry in journal.entries {
            let staged = URL(fileURLWithPath: entry.stagedPath)
            guard isInside(staged, directory: incomingURL) else {
                retained.append(entry)
                unresolvedCount += 1
                continue
            }

            if entry.phase == .copying {
                if fileManager.fileExists(atPath: staged.path) {
                    try? fileManager.removeItem(at: staged)
                }
                if fileManager.fileExists(atPath: staged.path) {
                    retained.append(entry)
                    unresolvedCount += 1
                }
                continue
            }

            guard let destinationPath = entry.destinationPath,
                  let storedTrack = entry.track else {
                retained.append(entry)
                unresolvedCount += 1
                continue
            }
            let destination = URL(fileURLWithPath: destinationPath)
            guard isInside(destination, directory: mediaURL),
                  destination.standardizedFileURL.path == storedTrack.fileURL.standardizedFileURL.path,
                  storedTrack.sha256 == entry.expectedSHA256 else {
                retained.append(entry)
                unresolvedCount += 1
                continue
            }

            if !fileManager.fileExists(atPath: destination.path),
               fileManager.fileExists(atPath: staged.path),
               (try? Self.sha256(of: staged)) == entry.expectedSHA256 {
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.moveItem(at: staged, to: destination)
            }

            guard fileManager.fileExists(atPath: destination.path),
                  (try? Self.sha256(of: destination)) == entry.expectedSHA256 else {
                retained.append(entry)
                unresolvedCount += 1
                continue
            }

            if fileManager.fileExists(atPath: staged.path) {
                try? fileManager.removeItem(at: staged)
            }
            if let previousPath = entry.previousManagedPath,
               let index = document.tracks.firstIndex(where: { $0.id == storedTrack.id }) {
                let current = document.tracks[index]
                if current.fileURL.standardizedFileURL.path == destination.standardizedFileURL.path {
                    continue
                }
                guard current.fileURL.standardizedFileURL.path == URL(fileURLWithPath: previousPath).standardizedFileURL.path,
                      current.sha256 == entry.expectedSHA256 else {
                    retained.append(entry)
                    unresolvedCount += 1
                    continue
                }
                document.tracks[index].managedPath = destination.path
                document.tracks[index].fileSize = storedTrack.fileSize
                document.tracks[index].health = .verified
                document.tracks[index].lastVerifiedAt = .now
                recoveredCount += 1
                continue
            }
            if !knownHashes.contains(entry.expectedSHA256) {
                var recoveredTrack = storedTrack
                let identities = identityIndex.identities(
                    artist: recoveredTrack.artist,
                    album: recoveredTrack.album
                )
                recoveredTrack.artistID = identities.artistID
                recoveredTrack.albumID = identities.albumID
                recoveredTrack.health = .verified
                recoveredTrack.lastVerifiedAt = .now
                document.tracks.append(recoveredTrack)
                knownHashes.insert(entry.expectedSHA256)
                recoveredCount += 1
            }
        }

        journal.entries = retained
        return (recoveredCount, unresolvedCount, journal)
    }

    private func upsertJournalEntry(_ entry: ImportJournalEntry) throws {
        var journal = try decodeImportJournalIfPresent()
        if let index = journal.entries.firstIndex(where: { $0.id == entry.id }) {
            journal.entries[index] = entry
        } else {
            journal.entries.append(entry)
        }
        try persistImportJournal(journal)
    }

    private func reconcileImportJournal(with tracks: [Track]) throws {
        guard fileManager.fileExists(atPath: importJournalURL.path) else { return }
        var journal = try decodeImportJournal()
        let ids = Set(tracks.map(\.id))
        let hashes = Set(tracks.map(\.sha256))
        journal.entries.removeAll { entry in
            guard let track = entry.track,
                  ids.contains(track.id) || hashes.contains(entry.expectedSHA256) else {
                return false
            }
            if entry.previousManagedPath != nil {
                guard tracks.contains(where: {
                    $0.id == track.id && $0.fileURL.standardizedFileURL.path == track.fileURL.standardizedFileURL.path
                }) else { return false }
            }
            let staged = URL(fileURLWithPath: entry.stagedPath)
            if isInside(staged, directory: incomingURL), fileManager.fileExists(atPath: staged.path) {
                try? fileManager.removeItem(at: staged)
            }
            return true
        }
        try persistImportJournal(journal)
    }

    private func decodeImportJournalIfPresent() throws -> ImportJournal {
        guard fileManager.fileExists(atPath: importJournalURL.path) else { return ImportJournal() }
        return try decodeImportJournal()
    }

    private func decodeImportJournal() throws -> ImportJournal {
        let data = try Data(contentsOf: importJournalURL)
        let journal: ImportJournal
        do { journal = try decoder.decode(ImportJournal.self, from: data) }
        catch { throw RepositoryError.damagedImportJournal }
        guard journal.schemaVersion == ImportJournal.currentSchema else {
            throw RepositoryError.unsupportedSchema(journal.schemaVersion)
        }
        return journal
    }

    private func persistImportJournal(_ journal: ImportJournal) throws {
        guard !journal.entries.isEmpty else {
            if fileManager.fileExists(atPath: importJournalURL.path) {
                try fileManager.removeItem(at: importJournalURL)
            }
            return
        }
        var updated = journal
        updated.updatedAt = .now
        try encoder.encode(updated).write(to: importJournalURL, options: [.atomic])
        try synchronizeOverlayFile(importJournalURL)
    }

    private func isInside(_ candidate: URL, directory: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        return candidatePath == directoryPath || candidatePath.hasPrefix(directoryPath + "/")
    }

    private func destinationURL(
        artist: String,
        album: String,
        originalName: String,
        hash: String
    ) throws -> URL {
        let artistFolder = Self.safePathComponent(artist)
        let albumFolder = Self.safePathComponent(album)
        let directory = mediaURL
            .appendingPathComponent(artistFolder, isDirectory: true)
            .appendingPathComponent(albumFolder, isDirectory: true)
        let proposed = directory.appendingPathComponent(Self.safePathComponent(originalName))

        guard fileManager.fileExists(atPath: proposed.path) else { return proposed }
        if (try? Self.sha256(of: proposed)) == hash { return proposed }

        let alternate = proposed.deletingPathExtension()
            .appendingPathExtension(String(hash.prefix(8)))
            .appendingPathExtension(proposed.pathExtension)
        guard fileManager.fileExists(atPath: alternate.path) else { return alternate }
        if (try? Self.sha256(of: alternate)) == hash { return alternate }

        var counter = 2
        while true {
            let candidate = proposed.deletingPathExtension()
                .appendingPathExtension("\(hash.prefix(8))-\(counter)")
                .appendingPathExtension(proposed.pathExtension)
            if !fileManager.fileExists(atPath: candidate.path) || (try? Self.sha256(of: candidate)) == hash {
                return candidate
            }
            counter += 1
        }
    }

    private func uniqueOrganizationDestination(
        proposed: URL,
        source: URL,
        hash: String,
        reservedPaths: inout Set<String>
    ) -> URL {
        if proposed.standardizedFileURL.path == source.standardizedFileURL.path {
            reservedPaths.insert(proposed.path)
            return proposed
        }
        func isAvailable(_ candidate: URL) -> Bool {
            !reservedPaths.contains(candidate.path) && !fileManager.fileExists(atPath: candidate.path)
        }
        if isAvailable(proposed) {
            reservedPaths.insert(proposed.path)
            return proposed
        }
        var counter = 1
        while true {
            let suffix = counter == 1 ? String(hash.prefix(8)) : "\(hash.prefix(8))-\(counter)"
            let candidate = proposed.deletingPathExtension()
                .appendingPathExtension(suffix)
                .appendingPathExtension(proposed.pathExtension)
            if isAvailable(candidate) {
                reservedPaths.insert(candidate.path)
                return candidate
            }
            counter += 1
        }
    }

    private func persistMediaOrganizationJournal(
        _ journal: MediaOrganizationJournal
    ) throws {
        try encoder.encode(journal).write(to: mediaOrganizationJournalURL, options: [.atomic])
    }

    private func clearMediaOrganizationJournal() throws {
        guard fileManager.fileExists(atPath: mediaOrganizationJournalURL.path) else { return }
        try fileManager.removeItem(at: mediaOrganizationJournalURL)
    }

    private func reconcileMediaOrganizationJournal(with tracks: [Track]) throws {
        guard fileManager.fileExists(atPath: mediaOrganizationJournalURL.path) else { return }
        let data = try Data(contentsOf: mediaOrganizationJournalURL)
        let journal = try decoder.decode(MediaOrganizationJournal.self, from: data)
        guard journal.schemaVersion == MediaOrganizationJournal.currentSchema else {
            throw RepositoryError.unsupportedSchema(journal.schemaVersion)
        }
        let catalogPaths = Set(tracks.map { $0.fileURL.standardizedFileURL.path })
        let committed = !journal.entries.isEmpty && journal.entries.allSatisfy {
            catalogPaths.contains(URL(fileURLWithPath: $0.destinationPath).standardizedFileURL.path)
        }
        if committed {
            // A missing or inaccessible destination is not evidence that the
            // catalog was uncommitted. Retain the journal and replacement backups.
            for entry in journal.entries {
                let destination = URL(fileURLWithPath: entry.destinationPath)
                guard try Self.sha256(of: destination) == entry.expectedSHA256 else {
                    throw RepositoryError.copyVerificationFailed(destination.lastPathComponent)
                }
            }
        } else {
            try rollbackMediaOrganizationJournal(journal)
        }
        removeMediaOrganizationBackups(journal)
        try clearMediaOrganizationJournal()
    }

    private func rollbackMediaOrganizationJournal(_ journal: MediaOrganizationJournal) throws {
        for entry in journal.entries.reversed() {
            let source = URL(fileURLWithPath: entry.sourcePath)
            let destination = URL(fileURLWithPath: entry.destinationPath)
            let sourceExists = fileManager.fileExists(atPath: source.path)
            let destinationExists = fileManager.fileExists(atPath: destination.path)
            if !sourceExists {
                guard destinationExists,
                      try Self.sha256(of: destination) == entry.expectedSHA256 else {
                    throw RepositoryError.copyVerificationFailed(source.lastPathComponent)
                }
                try fileManager.createDirectory(
                    at: source.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try fileManager.moveItem(at: destination, to: source)
            }
            if let backupPath = entry.replacedDestinationBackupPath {
                let backup = URL(fileURLWithPath: backupPath)
                if fileManager.fileExists(atPath: backup.path) {
                    // Never delete a file that appeared at the destination while
                    // recovery was interrupted or the medium was unavailable.
                    guard !fileManager.fileExists(atPath: destination.path) else {
                        throw RepositoryError.mediaOrganizationConflict(1)
                    }
                    try fileManager.createDirectory(
                        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    try fileManager.moveItem(at: backup, to: destination)
                }
            }
        }
    }

    private func removeMediaOrganizationBackups(_ journal: MediaOrganizationJournal) {
        for entry in journal.entries {
            guard let path = entry.replacedDestinationBackupPath else { continue }
            try? fileManager.removeItem(at: URL(fileURLWithPath: path))
        }
        let directory = rootURL.appendingPathComponent(
            "Media Organization Backups",
            isDirectory: true
        )
        try? fileManager.removeItem(at: directory)
    }

    private nonisolated static func safePathComponent(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\u{0000}")
        let cleaned = value.components(separatedBy: forbidden).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return safe.isEmpty ? "Unknown" : String(safe.precomposedStringWithCanonicalMapping.prefix(180))
    }

    private nonisolated static func readMetadata(from url: URL, fallbackName: String) async -> (
        title: String,
        artist: String,
        album: String,
        artistSortName: String,
        albumSortName: String,
        albumArtist: String,
        composer: String,
        grouping: String,
        genre: String,
        participantCredits: String,
        workName: String,
        movementName: String,
        movementNumber: Int?,
        movementCount: Int?,
        beatsPerMinute: Int?,
        copyright: String,
        isrc: String,
        releaseYear: Int?,
        trackNumber: Int?,
        trackCount: Int?,
        discNumber: Int?,
        discCount: Int?,
        isCompilation: Bool,
        comments: String,
        lyrics: TrackLyrics?,
        duration: TimeInterval,
        requiresArtist: Bool,
        requiresAlbum: Bool
    ) {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
        let commonMetadata = (try? await asset.load(.commonMetadata)) ?? []
        let formatMetadata = (try? await asset.load(.metadata)) ?? []
        let metadata = commonMetadata + formatMetadata

        func string(for identifier: AVMetadataIdentifier) async -> String? {
            guard let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier).first else {
                return nil
            }
            return try? await item.load(.stringValue)
        }

        func numberedValue(
            for identifier: AVMetadataIdentifier
        ) async -> (number: Int?, total: Int?) {
            guard let value = await string(for: identifier) else { return (nil, nil) }
            let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
            return (Int(parts[0]), parts.count > 1 ? Int(parts[1]) : nil)
        }

        func firstString(for identifiers: [AVMetadataIdentifier]) async -> String? {
            for identifier in identifiers {
                if let value = await string(for: identifier), !value.isEmpty {
                    return value
                }
            }
            return nil
        }

        let parsed = parseFileName(fallbackName)
        let track = await numberedValue(for: .iTunesMetadataTrackNumber)
        let disc = await numberedValue(for: .iTunesMetadataDiscNumber)
        let releaseDate = await string(for: .iTunesMetadataReleaseDate) ?? ""
        let compilation = await string(for: .iTunesMetadataDiscCompilation) ?? ""
        let beatsPerMinute = await firstString(for: [
            .iTunesMetadataBeatsPerMin,
            .id3MetadataBeatsPerMinute
        ])
        let copyright = await firstString(for: [
            .iTunesMetadataCopyright,
            .commonIdentifierCopyrights,
            .id3MetadataCopyright
        ]) ?? ""
        let participantCredits = await firstString(for: [
            .iTunesMetadataCredits,
            .id3MetadataMusicianCreditsList,
            .id3MetadataInvolvedPeopleList_v24
        ]) ?? ""
        let movementName = await firstString(for: [
            .iTunesMetadataTrackSubTitle,
            .id3MetadataSubTitle
        ]) ?? ""
        let embeddedLyrics = (try? await asset.load(.lyrics))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let embeddedArtist = (await string(for: .commonIdentifierArtist) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let embeddedAlbum = (await string(for: .commonIdentifierAlbumName) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            await string(for: .commonIdentifierTitle) ?? parsed.title,
            embeddedArtist.isEmpty ? parsed.artist : embeddedArtist,
            embeddedAlbum.isEmpty ? L10n.text("metadata.unknownAlbum") : embeddedAlbum,
            await string(for: .id3MetadataPerformerSortOrder) ?? "",
            await string(for: .id3MetadataAlbumSortOrder) ?? "",
            await string(for: .iTunesMetadataAlbumArtist) ?? "",
            await string(for: .iTunesMetadataComposer) ?? "",
            await string(for: .iTunesMetadataGrouping) ?? "",
            await string(for: .iTunesMetadataUserGenre) ?? "",
            participantCredits,
            "",
            movementName,
            nil,
            nil,
            beatsPerMinute.flatMap(Int.init),
            copyright,
            await string(for: .id3MetadataInternationalStandardRecordingCode) ?? "",
            Int(releaseDate.prefix(4)),
            track.number,
            track.total,
            disc.number,
            disc.total,
            compilation == "1" || compilation.lowercased() == "true",
            await string(for: .iTunesMetadataUserComment) ?? "",
            embeddedLyrics.flatMap { text in
                text.isEmpty ? nil : TrackLyrics(plainText: text, source: .embedded)
            },
            duration.isFinite ? max(0, duration) : 0,
            embeddedArtist.isEmpty,
            embeddedAlbum.isEmpty
        )
    }

    private nonisolated static func parseFileName(_ value: String) -> (artist: String, title: String) {
        let parts = value.components(separatedBy: " - ")
        if parts.count >= 2 {
            return (parts[0], parts.dropFirst().joined(separator: " - "))
        }
        return (L10n.text("metadata.unknownArtist"), value)
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
