import AVFoundation
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

        var errorDescription: String? {
            switch self {
            case .unsupportedSchema(let version):
                L10n.format("library.error.unsupportedSchema", version)
            case .copyVerificationFailed(let file):
                L10n.format("library.error.copyVerificationFailed", file)
            case .sourceIsNotRegularFile(let file):
                L10n.format("library.error.sourceIsNotRegularFile", file)
            }
        }
    }

    let rootURL: URL
    private let fileManager: FileManager
    private var mediaURL: URL
    private var libraryIdentity: (id: UUID, createdAt: Date)?

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
    private var migrationArchiveURL: URL {
        rootURL.appendingPathComponent("library-schema-1.migration-backup.json")
    }
    private var importJournalURL: URL { rootURL.appendingPathComponent("import-journal-v1.json") }

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
        libraryIdentity = (document.libraryID, document.createdAt)
        let recovery = try recoverImports(into: &document)
        if decoded.migratedFromSchemaVersion != nil {
            if let decodedSourceURL {
                try archivePreMigrationManifest(at: decodedSourceURL)
            }
            document.updatedAt = .now
            try persistDocument(document, backUpReadablePrimary: false)
            try encoder.encode(document).write(to: backupURL, options: [.atomic])
        } else if recovery.recovered > 0 || recoveredFromBackup {
            document.updatedAt = .now
            try persistDocument(document, backUpReadablePrimary: !recoveredFromBackup)
        }
        return LibraryLoadResult(
            document: document,
            recoveredFromBackup: recoveredFromBackup,
            recoveredImportCount: recovery.recovered,
            unresolvedImportCount: recovery.unresolved,
            migratedFromSchemaVersion: decoded.migratedFromSchemaVersion
        )
    }

    func save(tracks: [Track]) throws {
        try prepareDirectories()
        let identity = libraryIdentity ?? (UUID(), .now)
        let document = LibraryDocument(
            updatedAt: .now,
            tracks: tracks,
            libraryID: identity.0,
            createdAt: identity.1
        )
        try persistDocument(document, backUpReadablePrimary: true)
        libraryIdentity = (document.libraryID, document.createdAt)
        try reconcileImportJournal(with: tracks)
    }

    /// Clears Ongaku's catalog records without deleting, moving, renaming, or
    /// otherwise touching any referenced or managed audio file.
    func clearAllRegistrations() throws {
        try prepareDirectories()
        let identity = libraryIdentity ?? (UUID(), .now)
        let emptyDocument = LibraryDocument(
            updatedAt: .now,
            tracks: [],
            libraryID: identity.0,
            createdAt: identity.1
        )
        let data = try encoder.encode(emptyDocument)

        // Clear recovery metadata first. If the operation is interrupted before
        // the primary manifest is replaced, the previous catalog remains valid.
        // Once the primary becomes empty, neither recovery path can re-register
        // tracks. Incoming audio files themselves are deliberately left untouched.
        try persistImportJournal(ImportJournal())
        try data.write(to: backupURL, options: [.atomic])
        try data.write(to: manifestURL, options: [.atomic])
        libraryIdentity = (emptyDocument.libraryID, emptyDocument.createdAt)
    }

    func importFiles(
        _ sourceURLs: [URL],
        existing: [Track],
        reportDuplicates: Bool = true
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
                let destination = try destinationURL(
                    artist: metadata.artist,
                    album: metadata.album,
                    originalName: source.lastPathComponent,
                    hash: sourceHash
                )
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let values = try staged.resourceValues(forKeys: [.fileSizeKey])
                let identities = identityIndex.identities(
                    artist: metadata.artist,
                    album: metadata.album
                )
                let track = Track(
                    id: UUID(),
                    title: metadata.title,
                    artist: metadata.artist,
                    album: metadata.album,
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

    private func archivePreMigrationManifest(at sourceURL: URL) throws {
        guard !fileManager.fileExists(atPath: migrationArchiveURL.path) else { return }
        try Data(contentsOf: sourceURL).write(to: migrationArchiveURL, options: [.atomic])
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
        duration: TimeInterval
    ) {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
        let metadata = (try? await asset.load(.commonMetadata)) ?? []

        func string(for identifier: AVMetadataIdentifier) async -> String? {
            guard let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier).first else {
                return nil
            }
            return try? await item.load(.stringValue)
        }

        let parsed = parseFileName(fallbackName)
        return (
            await string(for: .commonIdentifierTitle) ?? parsed.title,
            await string(for: .commonIdentifierArtist) ?? parsed.artist,
            await string(for: .commonIdentifierAlbumName) ?? L10n.text("metadata.unknownAlbum"),
            duration.isFinite ? max(0, duration) : 0
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
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
