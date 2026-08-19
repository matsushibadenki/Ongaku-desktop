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
    @Published private(set) var playlistFolders: [PlaylistFolder] = []
    @Published private(set) var playbackEvents: [PlaybackEvent] = []
    @Published private(set) var playbackQueue: PlaybackQueueState?
    @Published private(set) var contentRevision = 0
    @Published var selectedSection: LibrarySection = .songs
    @Published var selectedPlaylistID: Playlist.ID?
    @Published var selectedTrackID: Track.ID?
    @Published var selectedTrackIDs: Set<Track.ID> = []
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
    private var playbackQueueSaveTask: Task<Void, Never>?
    weak var undoManager: UndoManager?

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

    var selectedPlaylist: Playlist? {
        guard let selectedPlaylistID else { return nil }
        return playlists.first { $0.id == selectedPlaylistID }
    }

    var filteredTracks: [Track] {
        var result: [Track]
        if let selectedPlaylist {
            if let definition = selectedPlaylist.smartDefinition {
                result = SmartPlaylistResolver.tracks(
                    matching: definition,
                    tracks: tracks,
                    statistics: PlaybackStatisticsResolver.statistics(
                        events: playbackEvents,
                        tracks: tracks
                    )
                )
            } else {
                let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
                result = selectedPlaylist.entries.compactMap { tracksByID[$0.trackID] }
            }
        } else {
            switch selectedSection {
            case .songs, .albums, .artists, .effects:
                result = tracks
            case .recentlyAdded:
                result = tracks.sorted { $0.addedAt > $1.addedAt }
            case .needsAttention:
                result = tracks.filter { $0.health != .verified }
            }
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

    func playbackStatistics(for trackID: Track.ID) -> TrackPlaybackStatistics {
        PlaybackStatisticsResolver.statistics(events: playbackEvents, tracks: tracks)[trackID]
            ?? TrackPlaybackStatistics()
    }

    func setFavorite(_ isFavorite: Bool, for trackID: Track.ID) async {
        await updatePlaybackAttributes(for: trackID) { $0.isFavorite = isFavorite }
    }

    func setRating(_ rating: Int, for trackID: Track.ID) async {
        await updatePlaybackAttributes(for: trackID) {
            $0.rating = min(max(rating, 0), 5)
        }
    }

    func setExcludedFromPlayback(_ isExcluded: Bool, for trackID: Track.ID) async {
        await updatePlaybackAttributes(for: trackID) {
            $0.isExcludedFromPlayback = isExcluded
        }
    }

    private func updatePlaybackAttributes(
        for trackID: Track.ID,
        mutation: (inout Track) -> Void
    ) async {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        let previous = tracks
        mutation(&tracks[index])
        contentRevision &+= 1
        do {
            try await repository.save(tracks: tracks)
            activity = .notice(L10n.text("status.playbackAttributesSaved"))
        } catch {
            tracks = previous
            contentRevision &+= 1
            activity = .failed(error.localizedDescription)
        }
    }

    @discardableResult
    func createPlaylist(
        name: String,
        description: String,
        artworkData: Data?
    ) async throws -> Playlist.ID {
        let nextOrder = playlists.filter { $0.folderID == nil }
            .map(\.sortOrder).max().map { $0 + 1 } ?? 0
        var playlist = Playlist(
            name: name,
            description: description,
            sortOrder: nextOrder
        )
        if let artworkData {
            playlist.artworkPath = try await repository.savePlaylistArtwork(
                artworkData,
                playlistID: playlist.id
            )
        }
        do {
            try await persistPlaylists(
                playlists + [playlist],
                undoActionName: L10n.text("undo.playlist.create")
            )
            selectedPlaylistID = playlist.id
            return playlist.id
        } catch {
            try? await repository.removePlaylistArtwork(at: playlist.artworkPath)
            throw error
        }
    }

    func updatePlaylist(
        id: Playlist.ID,
        name: String,
        description: String,
        artworkData: Data?,
        removesArtwork: Bool
    ) async throws {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let previousArtworkPath = playlists[index].artworkPath
        var updated = playlists
        updated[index].name = name
        updated[index].description = description
        updated[index].updatedAt = .now
        var newlyWrittenPath: String?
        if let artworkData {
            newlyWrittenPath = try await repository.savePlaylistArtwork(
                artworkData,
                playlistID: id
            )
            updated[index].artworkPath = newlyWrittenPath
        } else if removesArtwork {
            updated[index].artworkPath = nil
        }
        do {
            try await persistPlaylists(
                updated,
                undoActionName: L10n.text("undo.playlist.edit")
            )
            if updated[index].artworkPath != previousArtworkPath {
                if undoManager == nil {
                    try? await repository.removePlaylistArtwork(at: previousArtworkPath)
                }
            }
        } catch {
            try? await repository.removePlaylistArtwork(at: newlyWrittenPath)
            throw error
        }
    }

    @discardableResult
    func createSmartPlaylist(
        name: String,
        definition: SmartPlaylistDefinition
    ) async throws -> Playlist.ID {
        let nextOrder = playlists.filter { $0.folderID == nil }
            .map(\.sortOrder).max().map { $0 + 1 } ?? 0
        let playlist = Playlist(
            name: name,
            sortOrder: nextOrder,
            smartDefinition: definition
        )
        try await persistPlaylists(
            playlists + [playlist],
            undoActionName: L10n.text("undo.smartPlaylist.create")
        )
        selectedPlaylistID = playlist.id
        return playlist.id
    }

    func updateSmartPlaylist(
        id: Playlist.ID,
        name: String,
        definition: SmartPlaylistDefinition
    ) async throws {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        var updated = playlists
        updated[index].name = name
        updated[index].smartDefinition = definition
        updated[index].entries = []
        updated[index].updatedAt = .now
        try await persistPlaylists(
            updated,
            undoActionName: L10n.text("undo.smartPlaylist.edit")
        )
    }

    @discardableResult
    func duplicatePlaylist(_ id: Playlist.ID) async throws -> Playlist.ID? {
        guard let source = playlists.first(where: { $0.id == id }) else { return nil }
        let artworkData: Data? = if let path = source.artworkPath {
            await repository.playlistArtworkData(at: path)
        } else {
            nil
        }
        var duplicate = Playlist(
            name: L10n.format("playlist.copyName", source.name),
            description: source.description,
            folderID: source.folderID,
            sortOrder: playlists.filter { $0.folderID == source.folderID }
                .map(\.sortOrder).max().map { $0 + 1 } ?? 0,
            smartDefinition: source.smartDefinition,
            entries: source.entries.map { PlaylistEntry(trackID: $0.trackID) }
        )
        if let artworkData {
            duplicate.artworkPath = try await repository.savePlaylistArtwork(
                artworkData,
                playlistID: duplicate.id
            )
        }
        do {
            try await persistPlaylists(
                playlists + [duplicate],
                undoActionName: L10n.text("undo.playlist.duplicate")
            )
            selectedPlaylistID = duplicate.id
            return duplicate.id
        } catch {
            try? await repository.removePlaylistArtwork(at: duplicate.artworkPath)
            throw error
        }
    }

    func deletePlaylist(_ id: Playlist.ID) async throws {
        guard let playlist = playlists.first(where: { $0.id == id }) else { return }
        try await persistPlaylists(
            playlists.filter { $0.id != id },
            undoActionName: L10n.text("undo.playlist.delete")
        )
        if selectedPlaylistID == id {
            selectedPlaylistID = nil
            selectedSection = .songs
        }
        if undoManager == nil {
            try? await repository.removePlaylistArtwork(at: playlist.artworkPath)
        }
    }

    @discardableResult
    func addTracks(_ trackIDs: [Track.ID], to playlistID: Playlist.ID) async throws -> Int {
        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }) else {
            return 0
        }
        guard playlists[playlistIndex].smartDefinition == nil else { return 0 }
        let validTrackIDs = Set(tracks.map(\.id))
        var existingTrackIDs = Set(playlists[playlistIndex].entries.map(\.trackID))
        var entriesToAdd: [PlaylistEntry] = []
        for trackID in trackIDs where validTrackIDs.contains(trackID) {
            // A track may only occur once in a regular playlist. Repeated drops are safe.
            guard existingTrackIDs.insert(trackID).inserted else { continue }
            entriesToAdd.append(PlaylistEntry(trackID: trackID))
        }
        guard !entriesToAdd.isEmpty else {
            activity = .notice(L10n.text("status.playlistNoNewTracks"))
            return 0
        }

        var updated = playlists
        updated[playlistIndex].entries.append(contentsOf: entriesToAdd)
        updated[playlistIndex].updatedAt = .now
        try await persistPlaylists(
            updated,
            undoActionName: L10n.text("undo.playlist.addTracks")
        )
        activity = .notice(L10n.format("status.playlistTracksAdded", entriesToAdd.count))
        return entriesToAdd.count
    }

    @discardableResult
    func removeTracks(_ trackIDs: Set<Track.ID>, from playlistID: Playlist.ID) async throws -> Int {
        guard !trackIDs.isEmpty,
              let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }),
              playlists[playlistIndex].smartDefinition == nil else {
            return 0
        }
        var updated = playlists
        let previousCount = updated[playlistIndex].entries.count
        updated[playlistIndex].entries.removeAll { trackIDs.contains($0.trackID) }
        let removedCount = previousCount - updated[playlistIndex].entries.count
        guard removedCount > 0 else { return 0 }
        updated[playlistIndex].updatedAt = .now
        try await persistPlaylists(
            updated,
            undoActionName: L10n.text("undo.playlist.removeTracks")
        )
        selectedTrackIDs.subtract(trackIDs)
        if let selectedTrackID, trackIDs.contains(selectedTrackID) {
            self.selectedTrackID = selectedTrackIDs.first
        }
        activity = .notice(L10n.format("status.playlistTracksRemoved", removedCount))
        return removedCount
    }

    func playlistsContaining(trackIDs: Set<Track.ID>) -> [Playlist] {
        guard !trackIDs.isEmpty else { return [] }
        let statistics = PlaybackStatisticsResolver.statistics(events: playbackEvents, tracks: tracks)
        return playlists.filter { playlist in
            let memberIDs: Set<Track.ID>
            if let definition = playlist.smartDefinition {
                memberIDs = Set(SmartPlaylistResolver.tracks(
                    matching: definition,
                    tracks: tracks,
                    statistics: statistics
                ).map(\.id))
            } else {
                memberIDs = Set(playlist.entries.map(\.trackID))
            }
            return trackIDs.isSubset(of: memberIDs)
        }
    }

    func tracks(in playlist: Playlist) -> [Track] {
        if let definition = playlist.smartDefinition {
            return SmartPlaylistResolver.tracks(
                matching: definition,
                tracks: tracks,
                statistics: PlaybackStatisticsResolver.statistics(
                    events: playbackEvents,
                    tracks: tracks
                )
            )
        }
        let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        return playlist.entries.compactMap { tracksByID[$0.trackID] }
    }

    @discardableResult
    func importPlaylist(
        name: String,
        description: String,
        trackIDs: [Track.ID]
    ) async throws -> Playlist.ID {
        let knownTrackIDs = Set(tracks.map(\.id))
        var seen: Set<Track.ID> = []
        let entries = trackIDs
            .filter { knownTrackIDs.contains($0) && seen.insert($0).inserted }
            .map { PlaylistEntry(trackID: $0) }
        let nextOrder = playlists.filter { $0.folderID == nil }
            .map(\.sortOrder).max().map { $0 + 1 } ?? 0
        let playlist = Playlist(
            name: name,
            description: description,
            sortOrder: nextOrder,
            entries: entries
        )
        try await persistPlaylists(
            playlists + [playlist],
            undoActionName: L10n.text("undo.playlist.import")
        )
        selectedPlaylistID = playlist.id
        selectedTrackID = entries.first?.trackID
        selectedTrackIDs = Set(entries.prefix(1).map(\.trackID))
        return playlist.id
    }

    var sortedPlaylistFolders: [PlaylistFolder] {
        playlistFolders.sorted {
            $0.sortOrder == $1.sortOrder
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : $0.sortOrder < $1.sortOrder
        }
    }

    func playlists(in folderID: PlaylistFolder.ID?) -> [Playlist] {
        playlists.filter { $0.folderID == folderID }.sorted {
            $0.sortOrder == $1.sortOrder
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : $0.sortOrder < $1.sortOrder
        }
    }

    @discardableResult
    func createPlaylistFolder(name: String) async throws -> PlaylistFolder.ID {
        let order = playlistFolders.map(\.sortOrder).max().map { $0 + 1 } ?? 0
        let folder = PlaylistFolder(name: name, sortOrder: order)
        try await persistPlaylists(
            playlists,
            folders: playlistFolders + [folder],
            undoActionName: L10n.text("undo.playlistFolder.create")
        )
        return folder.id
    }

    func renamePlaylistFolder(_ id: PlaylistFolder.ID, name: String) async throws {
        guard let index = playlistFolders.firstIndex(where: { $0.id == id }) else { return }
        var folders = playlistFolders
        folders[index].name = name
        folders[index].updatedAt = .now
        try await persistPlaylists(
            playlists,
            folders: folders,
            undoActionName: L10n.text("undo.playlistFolder.rename")
        )
    }

    func deletePlaylistFolder(_ id: PlaylistFolder.ID) async throws {
        guard playlistFolders.contains(where: { $0.id == id }) else { return }
        var updated = playlists
        var nextOrder = updated.filter { $0.folderID == nil }
            .map(\.sortOrder).max().map { $0 + 1 } ?? 0
        for index in updated.indices where updated[index].folderID == id {
            updated[index].folderID = nil
            updated[index].sortOrder = nextOrder
            updated[index].updatedAt = .now
            nextOrder += 1
        }
        try await persistPlaylists(
            updated,
            folders: playlistFolders.filter { $0.id != id },
            undoActionName: L10n.text("undo.playlistFolder.delete")
        )
    }

    func movePlaylist(
        _ playlistID: Playlist.ID,
        to folderID: PlaylistFolder.ID?,
        before targetPlaylistID: Playlist.ID? = nil
    ) async throws {
        guard let sourceIndex = playlists.firstIndex(where: { $0.id == playlistID }),
              folderID == nil || playlistFolders.contains(where: { $0.id == folderID }) else {
            return
        }
        let oldFolderID = playlists[sourceIndex].folderID
        var updated = playlists
        updated[sourceIndex].folderID = folderID
        updated[sourceIndex].updatedAt = .now
        normalizePlaylistOrder(&updated, in: oldFolderID, excluding: playlistID)
        var targetIDs = updated
            .filter { $0.folderID == folderID && $0.id != playlistID }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(\.id)
        let insertionIndex = targetPlaylistID.flatMap { targetIDs.firstIndex(of: $0) }
            ?? targetIDs.endIndex
        targetIDs.insert(playlistID, at: insertionIndex)
        assignPlaylistOrder(&updated, ids: targetIDs)
        try await persistPlaylists(
            updated,
            undoActionName: L10n.text("undo.playlist.move")
        )
    }

    func movePlaylistFolder(
        _ folderID: PlaylistFolder.ID,
        before targetFolderID: PlaylistFolder.ID?
    ) async throws {
        var ids = sortedPlaylistFolders.map(\.id)
        guard let sourceIndex = ids.firstIndex(of: folderID) else { return }
        ids.remove(at: sourceIndex)
        let insertionIndex = targetFolderID.flatMap { ids.firstIndex(of: $0) } ?? ids.endIndex
        ids.insert(folderID, at: insertionIndex)
        var folders = playlistFolders
        for (order, id) in ids.enumerated() {
            if let index = folders.firstIndex(where: { $0.id == id }) {
                folders[index].sortOrder = order
                folders[index].updatedAt = .now
            }
        }
        try await persistPlaylists(
            playlists,
            folders: folders,
            undoActionName: L10n.text("undo.playlistFolder.reorder")
        )
    }

    private func normalizePlaylistOrder(
        _ playlists: inout [Playlist],
        in folderID: PlaylistFolder.ID?,
        excluding excludedID: Playlist.ID
    ) {
        let ids = playlists.filter { $0.folderID == folderID && $0.id != excludedID }
            .sorted { $0.sortOrder < $1.sortOrder }.map(\.id)
        assignPlaylistOrder(&playlists, ids: ids)
    }

    private func assignPlaylistOrder(_ playlists: inout [Playlist], ids: [Playlist.ID]) {
        for (order, id) in ids.enumerated() {
            if let index = playlists.firstIndex(where: { $0.id == id }) {
                playlists[index].sortOrder = order
            }
        }
    }

    @discardableResult
    func moveTracks(
        _ trackIDs: [Track.ID],
        before targetTrackID: Track.ID?,
        in playlistID: Playlist.ID
    ) async throws -> Bool {
        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }) else {
            return false
        }
        guard playlists[playlistIndex].smartDefinition == nil else { return false }
        let movingIDs = Set(trackIDs)
        guard !movingIDs.isEmpty,
              targetTrackID.map({ movingIDs.contains($0) }) != true else {
            return false
        }

        let originalEntries = playlists[playlistIndex].entries
        let movingEntries = originalEntries.filter { movingIDs.contains($0.trackID) }
        guard !movingEntries.isEmpty else { return false }
        var remainingEntries = originalEntries.filter { !movingIDs.contains($0.trackID) }
        let insertionIndex: Int
        if let targetTrackID,
           let targetIndex = remainingEntries.firstIndex(where: { $0.trackID == targetTrackID }) {
            insertionIndex = targetIndex
        } else {
            insertionIndex = remainingEntries.endIndex
        }
        remainingEntries.insert(contentsOf: movingEntries, at: insertionIndex)
        guard remainingEntries != originalEntries else { return false }

        var updated = playlists
        updated[playlistIndex].entries = remainingEntries
        updated[playlistIndex].updatedAt = .now
        try await persistPlaylists(
            updated,
            undoActionName: L10n.text("undo.playlist.reorder")
        )
        activity = .notice(L10n.text("status.playlistTracksReordered"))
        return true
    }

    private func persistPlaylists(
        _ updated: [Playlist],
        folders updatedFolders: [PlaylistFolder]? = nil,
        undoActionName: String? = nil,
        registersUndo: Bool = true
    ) async throws {
        let previous = PlaylistOrganizationSnapshot(
            playlists: playlists,
            folders: playlistFolders
        )
        let folders = updatedFolders ?? playlistFolders
        do {
            try await repository.save(playlists: updated, folders: folders)
            playlists = updated
            playlistFolders = folders
            contentRevision &+= 1
            scheduleSearchIndexSynchronization(document: currentDocument())
            activity = .notice(L10n.text("status.playlistSaved"))
            if registersUndo,
               previous.playlists != updated || previous.folders != folders,
               let undoActionName,
               let undoManager {
                registerPlaylistUndo(
                    restoring: previous,
                    inverse: PlaylistOrganizationSnapshot(
                        playlists: updated,
                        folders: folders
                    ),
                    actionName: undoActionName,
                    with: undoManager
                )
            }
        } catch {
            activity = .failed(error.localizedDescription)
            throw error
        }
    }

    private func registerPlaylistUndo(
        restoring snapshot: PlaylistOrganizationSnapshot,
        inverse: PlaylistOrganizationSnapshot,
        actionName: String,
        with undoManager: UndoManager
    ) {
        undoManager.registerUndo(withTarget: self) { target in
            target.registerPlaylistUndo(
                restoring: inverse,
                inverse: snapshot,
                actionName: actionName,
                with: undoManager
            )
            Task { @MainActor in
                do {
                    try await target.persistPlaylists(
                        snapshot.playlists,
                        folders: snapshot.folders,
                        registersUndo: false
                    )
                    target.reconcileSelectionAfterPlaylistRestore()
                } catch {
                    target.activity = .failed(error.localizedDescription)
                }
            }
        }
        undoManager.setActionName(actionName)
    }

    private struct PlaylistOrganizationSnapshot: Equatable {
        var playlists: [Playlist]
        var folders: [PlaylistFolder]
    }

    private func reconcileSelectionAfterPlaylistRestore() {
        if let selectedPlaylistID,
           !playlists.contains(where: { $0.id == selectedPlaylistID }) {
            self.selectedPlaylistID = nil
            selectedSection = .songs
        }
    }

    func load() async {
        do {
            let result = try await repository.load()
            tracks = result.document.tracks
            playlists = result.document.playlists
            playlistFolders = result.document.playlistFolders
            playbackEvents = result.document.playbackEvents
            playbackQueue = result.document.playbackQueue
            libraryID = result.document.libraryID
            libraryCreatedAt = result.document.createdAt
            contentRevision &+= 1
            selectedTrackID = selectedTrackID ?? tracks.first?.id
            if selectedTrackIDs.isEmpty, let selectedTrackID {
                selectedTrackIDs = [selectedTrackID]
            }
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

    func importDroppedItems(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        activity = .importing
        lastIssues = []

        let accessedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer {
            for url in accessedURLs {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let sourceURLs = await Task.detached(priority: .userInitiated) {
            Self.resolveDroppedAudioFiles(urls)
        }.value
        guard !sourceURLs.isEmpty else {
            activity = .notice(L10n.text("status.dropNoAudioFiles"))
            return
        }

        await importFiles(sourceURLs)
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
            playbackQueue = PlaybackQueueState()
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

    func noteArtworkChanged() {
        contentRevision &+= 1
    }

    func updateTrackMetadata(
        id: Track.ID,
        title: String,
        artist: String,
        album: String,
        artwork: AudioArtworkChange = .unchanged
    ) async throws {
        guard let track = tracks.first(where: { $0.id == id }) else {
            throw MetadataEditError.trackNotFound
        }
        var metadata = TrackMetadataValues(track: track)
        metadata.title = title
        metadata.artist = artist
        metadata.album = album
        try await updateTrackMetadata(id: id, metadata: metadata, artwork: artwork)
    }

    func updateTrackMetadata(
        id: Track.ID,
        metadata: TrackMetadataValues,
        artwork: AudioArtworkChange = .unchanged
    ) async throws {
        var updated = tracks
        guard let index = updated.firstIndex(where: { $0.id == id }) else {
            throw MetadataEditError.trackNotFound
        }
        let original = updated[index]
        updated[index].apply(metadata, includesTrackSpecificValues: true)
        if metadata.artist != original.artist || metadata.album != original.album {
            if let destination = tracks.first(where: {
                $0.id != id && $0.artist == metadata.artist && $0.album == metadata.album
            }) {
                updated[index].artistID = destination.artistID
                updated[index].albumID = destination.albumID
            } else {
                updated[index].artistID = tracks.first(where: {
                    $0.id != id && $0.artist == metadata.artist
                })?.artistID ?? UUID()
                updated[index].albumID = UUID()
            }
        }
        try await persistMetadataUpdate(updated, changedTrackIDs: Set([id]), artwork: artwork)
    }

    func updateAlbumMetadata(
        trackIDs: [Track.ID],
        artist: String,
        album: String,
        artwork: AudioArtworkChange = .unchanged
    ) async throws {
        guard let track = tracks.first(where: { trackIDs.contains($0.id) }) else {
            throw MetadataEditError.trackNotFound
        }
        var metadata = TrackMetadataValues(track: track)
        metadata.artist = artist
        metadata.album = album
        try await updateAlbumMetadata(
            trackIDs: trackIDs,
            metadata: metadata,
            artwork: artwork
        )
    }

    func updateAlbumMetadata(
        trackIDs: [Track.ID],
        metadata: TrackMetadataValues,
        artwork: AudioArtworkChange = .unchanged
    ) async throws {
        let ids = Set(trackIDs)
        var updated = tracks
        let indices = updated.indices.filter { ids.contains(updated[$0].id) }
        guard !indices.isEmpty, indices.count == ids.count else {
            throw MetadataEditError.trackNotFound
        }
        let originalArtist = updated[indices[0]].artist
        let destinationArtistID = tracks.first(where: {
            !ids.contains($0.id) && $0.artist == metadata.artist
        })?.artistID ?? UUID()
        for index in indices {
            updated[index].apply(metadata, includesTrackSpecificValues: false)
            if metadata.artist != originalArtist {
                updated[index].artistID = destinationArtistID
            }
        }
        try await persistMetadataUpdate(updated, changedTrackIDs: ids, artwork: artwork)
    }

    func updateArtistMetadata(
        trackIDs: [Track.ID],
        artist: String
    ) async throws {
        let ids = Set(trackIDs)
        var updated = tracks
        let indices = updated.indices.filter { ids.contains(updated[$0].id) }
        guard !indices.isEmpty, indices.count == ids.count else {
            throw MetadataEditError.trackNotFound
        }
        for index in indices {
            updated[index].artist = artist
        }
        try await persistMetadataUpdate(updated, changedTrackIDs: ids)
    }

    private func persistMetadataUpdate(
        _ proposed: [Track],
        changedTrackIDs: Set<Track.ID>,
        artwork: AudioArtworkChange = .unchanged
    ) async throws {
        var updated = proposed
        for index in updated.indices where changedTrackIDs.contains(updated[index].id) {
            let track = updated[index]
            let fingerprint = await AudioFileMetadataWriter.shared.embed(
                AudioMetadataUpdate(
                    metadata: TrackMetadataValues(track: track),
                    artwork: artwork
                ),
                in: track.fileURL
            )
            if let fingerprint {
                updated[index].fileSize = fingerprint.fileSize
                updated[index].sha256 = fingerprint.sha256
                updated[index].health = .verified
                updated[index].lastVerifiedAt = .now
                if case .set = artwork {
                    await EmbeddedArtworkCache.shared.invalidate([track.fileURL])
                }
            }
        }
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
            playlistFolders: playlistFolders,
            playbackEvents: playbackEvents,
            playbackQueue: playbackQueue
        )
    }

    func schedulePlaybackQueueSave(_ state: PlaybackQueueState) {
        guard playbackQueue != state else { return }
        playbackQueue = state
        playbackQueueSaveTask?.cancel()
        playbackQueueSaveTask = Task { [weak self, repository] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled, let self, self.playbackQueue == state else { return }
            do {
                try await repository.save(playbackQueue: state)
            } catch {
                guard !Task.isCancelled else { return }
                self.activity = .failed(error.localizedDescription)
            }
        }
    }

    func recordPlaybackEvent(_ event: PlaybackEvent) async {
        playbackEvents.append(event)
        do {
            try await repository.recordPlaybackEvent(event)
        } catch {
            playbackEvents.removeAll { $0.id == event.id }
            activity = .failed(error.localizedDescription)
        }
    }

    func clearPlaybackHistory() async {
        let previous = playbackEvents
        playbackEvents.removeAll()
        do {
            try await repository.save(playbackEvents: [])
        } catch {
            playbackEvents = previous
            activity = .failed(error.localizedDescription)
        }
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

    nonisolated static func resolveDroppedAudioFiles(_ droppedURLs: [URL]) -> [URL] {
        var filesByPath: [String: URL] = [:]
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        ]

        for droppedURL in droppedURLs {
            let standardized = droppedURL.standardizedFileURL
            guard let values = try? standardized.resourceValues(forKeys: resourceKeys),
                  values.isSymbolicLink != true else { continue }

            if values.isDirectory == true {
                for fileURL in discoverAudioFiles(in: standardized, excluding: []) {
                    filesByPath[fileURL.path] = fileURL
                }
            } else if values.isRegularFile == true, isSupportedAudioFile(standardized) {
                filesByPath[standardized.path] = standardized
            }
        }

        return filesByPath.values.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
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
            guard isSupportedAudioFile(standardized),
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

    private nonisolated static func isSupportedAudioFile(_ url: URL) -> Bool {
        let supportedExtensions: Set<String> = [
            "aac", "aif", "aiff", "alac", "caf", "flac", "m4a", "mp3", "wav",
        ]
        return supportedExtensions.contains(url.pathExtension.lowercased())
    }
}

private extension Track {
    mutating func apply(
        _ metadata: TrackMetadataValues,
        includesTrackSpecificValues: Bool
    ) {
        if includesTrackSpecificValues {
            title = metadata.title
            trackNumber = metadata.trackNumber
            trackCount = metadata.trackCount
        }
        artist = metadata.artist
        artistSortName = metadata.artistSortName
        album = metadata.album
        albumSortName = metadata.albumSortName
        albumArtist = metadata.albumArtist
        albumArtistSortName = metadata.albumArtistSortName
        composer = metadata.composer
        composerSortName = metadata.composerSortName
        grouping = metadata.grouping
        genre = metadata.genre
        releaseYear = metadata.releaseYear
        discNumber = metadata.discNumber
        discCount = metadata.discCount
        isCompilation = metadata.isCompilation
        rating = min(max(metadata.rating, 0), 5)
        playCount = max(0, metadata.playCount)
        comments = metadata.comments
    }
}
