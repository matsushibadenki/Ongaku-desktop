import Combine
import Foundation

#if canImport(AppKit)
import AppKit
#endif

@MainActor
final class LibraryStore: ObservableObject {
    enum SearchBackendStatus: Equatable {
        case jsonFallback
        case synchronizing
        case sqlite
    }

    enum MetadataEditError: LocalizedError {
        case trackNotFound

        var errorDescription: String? { L10n.text("metadataEditor.error.trackNotFound") }
    }

    enum Activity: Equatable {
        case idle
        case importing
        case verifying
        case notice(String)
        case failed(String)
    }

    @Published private(set) var tracks: [Track] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var playbackEvents: [PlaybackEvent] = []
    @Published private(set) var contentRevision = 0
    @Published var selectedSection: LibrarySection = .songs
    @Published var selectedTrackID: Track.ID?
    @Published var searchText = "" {
        didSet { scheduleIndexedSearch() }
    }
    @Published private(set) var activity: Activity = .idle
    @Published private(set) var lastIssues: [ImportIssue] = []
    @Published private(set) var searchBackendStatus: SearchBackendStatus = .jsonFallback
    @Published private var indexedSearchTrackIDs: Set<Track.ID>?
    @Published private(set) var indexedSearchQuery: String?

    private let repository: LibraryRepository
    private let searchIndex: SQLiteCatalogPrototype
    private var libraryID = UUID()
    private var libraryCreatedAt = Date.now
    private var searchIndexSynchronizationTask: Task<Void, Never>?
    private var indexedSearchTask: Task<Void, Never>?

    init(
        repository: LibraryRepository = LibraryRepository(),
        searchIndex: SQLiteCatalogPrototype? = nil
    ) {
        self.repository = repository
        self.searchIndex = searchIndex ?? SQLiteCatalogPrototype(rootURL: repository.rootURL)
    }

    var selectedTrack: Track? {
        tracks.first { $0.id == selectedTrackID }
    }

    var filteredTracks: [Track] {
        var result: [Track]
        switch selectedSection {
        case .songs, .albums, .artists, .effects:
            result = tracks
        case .recentlyAdded:
            result = tracks.sorted { $0.addedAt > $1.addedAt }
        case .needsAttention:
            result = tracks.filter { $0.health != .verified }
        }

        guard !searchText.isEmpty else { return result }
        let normalizedQuery = CatalogSearch.normalize(searchText)
        if indexedSearchQuery == normalizedQuery, let indexedSearchTrackIDs {
            return result.filter { indexedSearchTrackIDs.contains($0.id) }
        }
        return result.filter { CatalogSearch.matches($0, query: searchText) }
    }

    var totalBytes: Int64 { tracks.reduce(0) { $0 + $1.fileSize } }
    var attentionCount: Int { tracks.filter { $0.health != .verified }.count }

    func load() async {
        do {
            let result = try await repository.load()
            tracks = result.document.tracks
            playlists = result.document.playlists
            playbackEvents = result.document.playbackEvents
            libraryID = result.document.libraryID
            libraryCreatedAt = result.document.createdAt
            contentRevision &+= 1
            selectedTrackID = selectedTrackID ?? tracks.first?.id
            if result.unresolvedImportCount > 0 {
                activity = .failed(
                    L10n.format("status.importRecoveryIssues", result.unresolvedImportCount))
            } else if result.recoveredImportCount > 0 {
                activity = .notice(
                    L10n.format("status.recoveredImports", result.recoveredImportCount))
            } else if result.recoveredFromBackup {
                activity = .notice(L10n.text("status.recoveredManifest"))
            } else if result.migratedFromSchemaVersion != nil {
                activity = .notice(
                    L10n.format("status.libraryMigrated", LibraryDocument.currentSchema)
                )
            } else {
                activity = .idle
            }
            scheduleSearchIndexSynchronization(document: result.document)
        } catch {
            activity = .failed(error.localizedDescription)
        }
    }

    func importFiles(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        activity = .importing
        lastIssues = []
        let result = await repository.importFiles(urls, existing: tracks)
        tracks.append(contentsOf: result.imported)
        tracks.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        contentRevision &+= 1
        lastIssues = result.issues

        do {
            try await repository.save(tracks: tracks)
            selectedTrackID = result.imported.first?.id ?? selectedTrackID
            scheduleSearchIndexSynchronization(document: currentDocument())
            activity =
                result.issues.isEmpty
                ? .idle : .failed(L10n.format("import.issueCount", result.issues.count))
        } catch {
            activity = .failed(error.localizedDescription)
        }
    }

    func importAppleMusicMediaFolder(
        _ mediaFolderURL: URL,
        excluding managedDirectoryURL: URL
    ) async -> AppleMusicImportSummary {
        let legacyManagedDirectory =
            mediaFolderURL
            .appendingPathComponent("Ongaku Media", isDirectory: true)
        return await registerMediaFolderInPlace(
            mediaFolderURL,
            excluding: [managedDirectoryURL, legacyManagedDirectory],
            noFilesMessageKey: "status.appleMusicNoFiles",
            successMessageKey: "status.appleMusicImported"
        )
    }

    func registerMediaFolderInPlace(_ folderURL: URL) async -> AppleMusicImportSummary {
        await registerMediaFolderInPlace(
            folderURL,
            excluding: [],
            noFilesMessageKey: "status.folderNoFiles",
            successMessageKey: "status.folderRegistered"
        )
    }

    private func registerMediaFolderInPlace(
        _ folderURL: URL,
        excluding excludedDirectories: [URL],
        noFilesMessageKey: String,
        successMessageKey: String
    ) async -> AppleMusicImportSummary {
        activity = .importing
        lastIssues = []
        let sourceURLs = await Task.detached(priority: .userInitiated) {
            Self.discoverAudioFiles(
                in: folderURL,
                excluding: excludedDirectories
            )
        }.value
        guard !sourceURLs.isEmpty else {
            activity = .notice(L10n.text(noFilesMessageKey))
            return AppleMusicImportSummary(discovered: 0, imported: 0, relinked: 0, issues: 0)
        }

        let result = await repository.referenceFilesInPlace(
            sourceURLs,
            existing: tracks
        )
        var importedCount = 0
        var relinkedCount = 0
        for referencedTrack in result.imported {
            if let index = tracks.firstIndex(where: { $0.sha256 == referencedTrack.sha256 }) {
                if tracks[index].fileURL.standardizedFileURL
                    != referencedTrack.fileURL.standardizedFileURL
                {
                    relinkedCount += 1
                }
                tracks[index] = referencedTrack
            } else {
                tracks.append(referencedTrack)
                importedCount += 1
            }
        }
        tracks.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        contentRevision &+= 1
        lastIssues = result.issues

        do {
            try await repository.save(tracks: tracks)
            selectedTrackID = result.imported.first?.id ?? selectedTrackID
            scheduleSearchIndexSynchronization(document: currentDocument())
            activity =
                result.issues.isEmpty
                ? .notice(L10n.format(successMessageKey, importedCount, relinkedCount))
                : .failed(L10n.format("import.issueCount", result.issues.count))
        } catch {
            activity = .failed(error.localizedDescription)
        }
        return AppleMusicImportSummary(
            discovered: sourceURLs.count,
            imported: importedCount,
            relinked: relinkedCount,
            issues: result.issues.count
        )
    }

    func verifyLibrary() async {
        guard !tracks.isEmpty else { return }
        activity = .verifying
        tracks = await repository.verify(tracks)
        contentRevision &+= 1
        do {
            try await repository.save(tracks: tracks)
            scheduleSearchIndexSynchronization(document: currentDocument())
            activity = .idle
        } catch {
            activity = .failed(error.localizedDescription)
        }
    }

    func setMediaDirectory(_ url: URL) async throws {
        try await repository.setMediaDirectory(url)
        activity = .notice(L10n.text("status.storageChanged"))
    }

    func clearAllRegistrations() async throws {
        do {
            try await repository.clearAllRegistrations()
            tracks.removeAll(keepingCapacity: false)
            playlists = playlists.map { playlist in
                var emptied = playlist
                emptied.entries = []
                return emptied
            }
            playbackEvents.removeAll()
            selectedTrackID = nil
            selectedSection = .songs
            searchText = ""
            lastIssues = []
            contentRevision &+= 1
            scheduleSearchIndexSynchronization(document: currentDocument())
            activity = .notice(L10n.text("settings.storage.clearSuccess"))
        } catch {
            activity = .failed(error.localizedDescription)
            throw error
        }
    }

    func reveal(_ track: Track) {
#if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([track.fileURL])
#endif
    }

    func updateTrackMetadata(
        id: Track.ID,
        title: String,
        artist: String,
        album: String
    ) async throws {
        var updated = tracks
        guard let index = updated.firstIndex(where: { $0.id == id }) else {
            throw MetadataEditError.trackNotFound
        }
        let original = updated[index]
        updated[index].title = title
        updated[index].artist = artist
        updated[index].album = album
        if artist != original.artist || album != original.album {
            if let destination = tracks.first(where: {
                $0.id != id && $0.artist == artist && $0.album == album
            }) {
                updated[index].artistID = destination.artistID
                updated[index].albumID = destination.albumID
            } else {
                updated[index].artistID = tracks.first(where: {
                    $0.id != id && $0.artist == artist
                })?.artistID ?? UUID()
                updated[index].albumID = UUID()
            }
        }
        try await persistMetadataUpdate(updated)
    }

    func updateAlbumMetadata(
        trackIDs: [Track.ID],
        artist: String,
        album: String
    ) async throws {
        let ids = Set(trackIDs)
        var updated = tracks
        let indices = updated.indices.filter { ids.contains(updated[$0].id) }
        guard !indices.isEmpty, indices.count == ids.count else {
            throw MetadataEditError.trackNotFound
        }
        for index in indices {
            updated[index].artist = artist
            updated[index].album = album
        }
        try await persistMetadataUpdate(updated)
    }

    private func persistMetadataUpdate(_ updated: [Track]) async throws {
        do {
            try await repository.save(tracks: updated)
            tracks = updated
            contentRevision &+= 1
            scheduleSearchIndexSynchronization(document: currentDocument())
            activity = .notice(L10n.text("status.metadataSaved"))
        } catch {
            activity = .failed(error.localizedDescription)
            throw error
        }
    }

    private func currentDocument() -> LibraryDocument {
        LibraryDocument(
            updatedAt: .now,
            tracks: tracks,
            libraryID: libraryID,
            createdAt: libraryCreatedAt,
            playlists: playlists,
            playbackEvents: playbackEvents
        )
    }

    private func scheduleSearchIndexSynchronization(document: LibraryDocument) {
        searchIndexSynchronizationTask?.cancel()
        indexedSearchTask?.cancel()
        indexedSearchTrackIDs = nil
        indexedSearchQuery = nil
        searchBackendStatus = .synchronizing
        let expectedRevision = contentRevision
        let queries = parityQueries(for: document.tracks)
        let manifestURL = repository.rootURL.appendingPathComponent("library-v1.json")
        let sourceManifestURL = FileManager.default.fileExists(atPath: manifestURL.path)
            ? manifestURL : nil

        searchIndexSynchronizationTask = Task { [weak self, searchIndex] in
            do {
                _ = try await searchIndex.migrate(
                    document: document,
                    sourceManifestURL: sourceManifestURL
                )
                let parity = try await searchIndex.verifyParity(
                    document: document,
                    queries: queries
                )
                guard !Task.isCancelled, let self,
                      self.contentRevision == expectedRevision else { return }
                guard parity.isMatch else {
                    self.searchBackendStatus = .jsonFallback
                    return
                }
                self.searchBackendStatus = .sqlite
                self.scheduleIndexedSearch()
            } catch {
                guard !Task.isCancelled, let self,
                      self.contentRevision == expectedRevision else { return }
                self.searchBackendStatus = .jsonFallback
            }
        }
    }

    private func scheduleIndexedSearch() {
        indexedSearchTask?.cancel()
        let normalizedQuery = CatalogSearch.normalize(searchText)
        guard !normalizedQuery.isEmpty else {
            indexedSearchTrackIDs = nil
            indexedSearchQuery = nil
            return
        }
        guard searchBackendStatus == .sqlite else {
            indexedSearchTrackIDs = nil
            indexedSearchQuery = nil
            return
        }

        let expectedRevision = contentRevision
        let resultLimit = max(tracks.count, 1)
        let query = searchText
        indexedSearchTask = Task { [weak self, searchIndex] in
            do {
                let ids = try await searchIndex.search(query, limit: resultLimit)
                guard !Task.isCancelled, let self,
                      self.contentRevision == expectedRevision,
                      CatalogSearch.normalize(self.searchText) == normalizedQuery else { return }
                self.indexedSearchTrackIDs = Set(ids)
                self.indexedSearchQuery = normalizedQuery
            } catch {
                guard !Task.isCancelled, let self,
                      self.contentRevision == expectedRevision else { return }
                self.indexedSearchTrackIDs = nil
                self.indexedSearchQuery = nil
                self.searchBackendStatus = .jsonFallback
            }
        }
    }

    private func parityQueries(for tracks: [Track]) -> [String] {
        var queries = Set(["a", "1", "夜", "音"])
        for track in tracks.prefix(12) {
            for value in [track.title, track.artist, track.album] {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                queries.insert(String(trimmed.prefix(1)))
                queries.insert(String(trimmed.prefix(3)))
            }
        }
        return queries.sorted()
    }

    private nonisolated static func discoverAudioFiles(
        in mediaFolderURL: URL,
        excluding excludedDirectories: [URL]
    ) -> [URL] {
        let fileManager = FileManager.default
        let resourceKeys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        ]
        guard
            let enumerator = fileManager.enumerator(
                at: mediaFolderURL,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else { return [] }

        let excludedPaths = excludedDirectories.map { $0.standardizedFileURL.path }
        let supportedExtensions: Set<String> = [
            "aac", "aif", "aiff", "alac", "caf", "flac", "m4a", "mp3", "wav",
        ]
        var audioFiles: [URL] = []
        for case let url as URL in enumerator {
            let standardized = url.standardizedFileURL
            let path = standardized.path
            if excludedPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                if (try? standardized.resourceValues(forKeys: [.isDirectoryKey]).isDirectory)
                    == true
                {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard supportedExtensions.contains(standardized.pathExtension.lowercased()),
                let values = try? standardized.resourceValues(forKeys: Set(resourceKeys)),
                values.isRegularFile == true,
                values.isSymbolicLink != true
            else { continue }
            audioFiles.append(standardized)
        }
        return audioFiles.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }
}
