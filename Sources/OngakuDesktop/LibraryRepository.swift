import AVFoundation
import AppKit
import CryptoKit
import Foundation

actor LibraryRepository {
    private enum ImportPhase: String, Codable {
        case copying
        case installing
        case installed
    }

    private struct ImportJournalEntry: Codable {
        let id: UUID
        let fileName: String
        let expectedSHA256: String
        let stagedPath: String
        var destinationPath: String?
        var track: Track?
        var phase: ImportPhase
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
            }
        }
    }

    let rootURL: URL
    private let fileManager: FileManager
    private var mediaURL: URL
    private var currentDocument: LibraryDocument?

    init(rootURL: URL? = nil, mediaURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let resolvedRoot: URL
        if let rootURL {
            resolvedRoot = rootURL
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            resolvedRoot = support.appendingPathComponent("Ongaku Desktop", isDirectory: true)
        }
        self.rootURL = resolvedRoot
        self.mediaURL = mediaURL ?? resolvedRoot.appendingPathComponent("Ongaku Media", isDirectory: true)
    }

    private var incomingURL: URL { rootURL.appendingPathComponent("Incoming", isDirectory: true) }
    private var manifestURL: URL { rootURL.appendingPathComponent("library-v1.json") }
    private var backupURL: URL { rootURL.appendingPathComponent("library-v1.backup.json") }
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

    func load() throws -> LibraryLoadResult {
        try prepareDirectories()
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
        } else {
            decoded = DecodedLibraryDocument(
                document: LibraryDocument(),
                migratedFromSchemaVersion: nil
            )
        }

        var document = decoded.document
        try reconcileMediaOrganizationJournal(with: document.tracks)
        let recovery = try recoverImports(into: &document)
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
        } else if recovery.recovered > 0 || recoveredFromBackup {
            document.updatedAt = .now
            try persistDocument(document, backUpReadablePrimary: !recoveredFromBackup)
        }
        currentDocument = document
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
            let destination = uniqueOrganizationDestination(
                proposed: proposed,
                source: source,
                hash: hash,
                reservedPaths: &reservedPaths
            )
            items.append(MediaOrganizationItem(
                trackIDs: matchingTracks.map(\.id), sourceURL: source,
                destinationURL: destination, expectedSHA256: hash,
                status: source.path == destination.path ? .unchanged : .move
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
        preview: MediaOrganizationPreview
    ) throws -> (document: LibraryDocument, summary: MediaOrganizationSummary) {
        try prepareDirectories()
        let moves = preview.items.filter { $0.status == .move }
        var journal = MediaOrganizationJournal(entries: moves.map {
            MediaOrganizationJournalEntry(
                sourcePath: $0.sourceURL.path,
                destinationPath: $0.destinationURL.path,
                expectedSHA256: $0.expectedSHA256,
                moved: false
            )
        })
        try persistMediaOrganizationJournal(journal)

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
            var updated = document
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
            rollbackMediaOrganizationJournal(journal)
            try? clearMediaOrganizationJournal()
            throw error
        }
    }

    func save(tracks: [Track]) throws {
        try prepareDirectories()
        var document = try documentForMutation()
        document.updatedAt = .now
        document.tracks = tracks
        try persistDocument(document, backUpReadablePrimary: true)
        currentDocument = document
        try reconcileImportJournal(with: tracks)
    }

    func save(document: LibraryDocument) throws {
        try prepareDirectories()
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
        try prepareDirectories()
        var document = try documentForMutation()
        document.updatedAt = .now
        document.playlists = playlists
        try persistDocument(document, backUpReadablePrimary: true)
        currentDocument = document
    }

    func save(playlists: [Playlist], folders: [PlaylistFolder]) throws {
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
        try prepareDirectories()
        var document = try documentForMutation()
        document.updatedAt = .now
        document.playbackEvents.append(event)
        try persistDocument(document, backUpReadablePrimary: true)
        currentDocument = document
    }

    func save(playbackEvents: [PlaybackEvent]) throws {
        try prepareDirectories()
        var document = try documentForMutation()
        document.updatedAt = .now
        document.playbackEvents = playbackEvents
        try persistDocument(document, backUpReadablePrimary: true)
        currentDocument = document
    }

    func save(playbackQueue: PlaybackQueueState) throws {
        try prepareDirectories()
        var document = try documentForMutation()
        document.updatedAt = .now
        document.playbackQueue = playbackQueue
        try persistDocument(document, backUpReadablePrimary: true)
        currentDocument = document
    }

    /// Clears Ongaku's catalog records without deleting, moving, renaming, or
    /// otherwise touching any referenced or managed audio file.
    func clearAllRegistrations() throws {
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
        let data = try encoder.encode(emptyDocument)

        // Clear recovery metadata first. If the operation is interrupted before
        // the primary manifest is replaced, the previous catalog remains valid.
        // Once the primary becomes empty, neither recovery path can re-register
        // tracks. Incoming audio files themselves are deliberately left untouched.
        try persistImportJournal(ImportJournal())
        try data.write(to: backupURL, options: [.atomic])
        try data.write(to: manifestURL, options: [.atomic])
        currentDocument = emptyDocument
    }

    func importFiles(
        _ sourceURLs: [URL],
        existing: [Track],
        reportDuplicates: Bool = true,
        metadataOverrides: [String: AudioCDImportRequest] = [:],
        requiredMetadataOverrides: [String: RequiredImportMetadataDraft] = [:]
    ) async -> ImportResult {
        do { try prepareDirectories() } catch {
            return ImportResult(imported: [], issues: sourceURLs.map {
                ImportIssue(fileName: $0.lastPathComponent, message: error.localizedDescription)
            })
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
                try fileManager.copyItem(at: source, to: staged)

                let stagedHash = try Self.sha256(of: staged)
                guard stagedHash == sourceHash else {
                    try? fileManager.removeItem(at: staged)
                    throw RepositoryError.copyVerificationFailed(source.lastPathComponent)
                }

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
        existing: [Track]
    ) async -> ImportResult {
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

                if var track = existingByHash[hash] {
                    track.managedPath = source.standardizedFileURL.path
                    track.fileSize = Int64(values.fileSize ?? 0)
                    track.lastVerifiedAt = .now
                    track.health = .verified
                    referenced.append(track)
                } else {
                    let identities = identityIndex.identities(
                        artist: metadata.artist,
                        album: metadata.album
                    )
                    referenced.append(Track(
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
                        managedPath: source.standardizedFileURL.path,
                        sha256: hash,
                        addedAt: .now,
                        lastVerifiedAt: .now,
                        health: .verified,
                        artistID: identities.artistID,
                        albumID: identities.albumID
                    ))
                }
            } catch {
                issues.append(ImportIssue(
                    fileName: source.lastPathComponent,
                    message: error.localizedDescription
                ))
            }
        }
        return ImportResult(imported: referenced, issues: issues)
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
        if let header = try? decoder.decode(SchemaHeader.self, from: data) {
            switch header.schemaVersion ?? 0 {
            case LibraryDocument.currentSchema:
                let document = try decoder.decode(LibraryDocument.self, from: data)
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

    private func persistDocument(
        _ document: LibraryDocument,
        backUpReadablePrimary: Bool
    ) throws {
        let data = try encoder.encode(document)
        if backUpReadablePrimary,
           let previous = try? Data(contentsOf: manifestURL),
           (try? decodeDocument(at: manifestURL)) != nil {
            try previous.write(to: backupURL, options: [.atomic])
        }
        try data.write(to: manifestURL, options: [.atomic])
    }

    private func archivePreMigrationManifest(
        at sourceURL: URL,
        sourceSchemaVersion: Int
    ) throws {
        let archiveURL = migrationArchiveURL(for: sourceSchemaVersion)
        guard !fileManager.fileExists(atPath: archiveURL.path) else { return }
        try Data(contentsOf: sourceURL).write(to: archiveURL, options: [.atomic])
    }

    private func documentForMutation() throws -> LibraryDocument {
        if let currentDocument { return currentDocument }
        if fileManager.fileExists(atPath: manifestURL.path)
            || fileManager.fileExists(atPath: backupURL.path)
        {
            return try load().document
        }
        let document = LibraryDocument()
        currentDocument = document
        return document
    }

    private func recoverImports(into document: inout LibraryDocument) throws -> (recovered: Int, unresolved: Int) {
        guard fileManager.fileExists(atPath: importJournalURL.path) else { return (0, 0) }
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
        try persistImportJournal(journal)
        return (recoveredCount, unresolvedCount)
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
        let journal = try decoder.decode(ImportJournal.self, from: data)
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
            let destination = URL(fileURLWithPath: $0.destinationPath).standardizedFileURL
            return catalogPaths.contains(destination.path)
                && fileManager.fileExists(atPath: destination.path)
                && (try? Self.sha256(of: destination)) == $0.expectedSHA256
        }
        if !committed { rollbackMediaOrganizationJournal(journal) }
        try clearMediaOrganizationJournal()
    }

    private func rollbackMediaOrganizationJournal(_ journal: MediaOrganizationJournal) {
        for entry in journal.entries.reversed() {
            let source = URL(fileURLWithPath: entry.sourcePath)
            let destination = URL(fileURLWithPath: entry.destinationPath)
            guard !fileManager.fileExists(atPath: source.path),
                  fileManager.fileExists(atPath: destination.path),
                  (try? Self.sha256(of: destination)) == entry.expectedSHA256 else { continue }
            try? fileManager.createDirectory(
                at: source.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? fileManager.moveItem(at: destination, to: source)
        }
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
