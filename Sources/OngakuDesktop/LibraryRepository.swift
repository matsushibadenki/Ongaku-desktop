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

    enum RepositoryError: LocalizedError {
        case unsupportedSchema(Int)
        case copyVerificationFailed(String)
        case sourceIsNotRegularFile(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedSchema(let version):
                "The library uses unsupported schema version \(version)."
            case .copyVerificationFailed(let file):
                "The copied data did not match \(file). The staged copy was discarded."
            case .sourceIsNotRegularFile(let file):
                "\(file) is not a regular file. Choose the original audio file instead of a link."
            }
        }
    }

    let rootURL: URL
    private let fileManager: FileManager
    private var mediaURL: URL

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
    private var importJournalURL: URL { rootURL.appendingPathComponent("import-journal-v1.json") }

    func setMediaDirectory(_ url: URL) throws {
        let standardized = url.standardizedFileURL
        try fileManager.createDirectory(at: standardized, withIntermediateDirectories: true)
        mediaURL = standardized
    }

    func load() throws -> LibraryLoadResult {
        try prepareDirectories()
        var recoveredFromBackup = false
        var document: LibraryDocument

        if fileManager.fileExists(atPath: manifestURL.path) {
            do {
                document = try decodeDocument(at: manifestURL)
            } catch {
                guard fileManager.fileExists(atPath: backupURL.path) else { throw error }
                document = try decodeDocument(at: backupURL)
                recoveredFromBackup = true
            }
        } else {
            document = LibraryDocument()
        }

        let recovery = try recoverImports(into: &document)
        if recovery.recovered > 0 {
            try save(tracks: document.tracks)
        }
        return LibraryLoadResult(
            document: document,
            recoveredFromBackup: recoveredFromBackup,
            recoveredImportCount: recovery.recovered,
            unresolvedImportCount: recovery.unresolved
        )
    }

    func save(tracks: [Track]) throws {
        try prepareDirectories()
        let document = LibraryDocument(updatedAt: .now, tracks: tracks)
        let data = try encoder.encode(document)

        // Keep the previous readable manifest before atomically replacing the primary.
        if let previous = try? Data(contentsOf: manifestURL) {
            try previous.write(to: backupURL, options: [.atomic])
        }
        try data.write(to: manifestURL, options: [.atomic])
        try reconcileImportJournal(with: tracks)
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
                    health: .verified
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
                        health: .verified
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

    private func decodeDocument(at url: URL) throws -> LibraryDocument {
        let data = try Data(contentsOf: url)
        let document = try decoder.decode(LibraryDocument.self, from: data)
        guard document.schemaVersion == LibraryDocument.currentSchema else {
            throw RepositoryError.unsupportedSchema(document.schemaVersion)
        }
        return document
    }

    private func recoverImports(into document: inout LibraryDocument) throws -> (recovered: Int, unresolved: Int) {
        guard fileManager.fileExists(atPath: importJournalURL.path) else { return (0, 0) }
        var journal = try decodeImportJournal()
        var retained: [ImportJournalEntry] = []
        var knownHashes = Set(document.tracks.map(\.sha256))
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
