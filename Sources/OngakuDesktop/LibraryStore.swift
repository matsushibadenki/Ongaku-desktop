import Combine
import Foundation

#if canImport(AppKit)
import AppKit
#endif

struct AudioFeatureAnalysisProgress: Equatable, Sendable {
    let total: Int
    var completed: Int = 0
    var failed: Int = 0
}

enum AudioFeatureAnalysisPauseReason: Equatable, Sendable {
    case user
    case lowPowerMode
    case thermalPressure
}

enum AudioFeatureAnalysisPowerPolicy {
    nonisolated static func automaticPauseReason(
        isLowPowerModeEnabled: Bool,
        thermalState: ProcessInfo.ThermalState
    ) -> AudioFeatureAnalysisPauseReason? {
        if thermalState == .serious || thermalState == .critical {
            return .thermalPressure
        }
        if isLowPowerModeEnabled {
            return .lowPowerMode
        }
        return nil
    }
}

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

    enum DuplicateResolutionError: LocalizedError {
        case invalidSelection

        var errorDescription: String? { L10n.text("duplicates.error.invalidSelection") }
    }

    enum Activity: Equatable {
        case idle
        case importing
        case verifying
        case relinking
        case notice(String)
        case failed(String)
    }

    @Published private(set) var tracks: [Track] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var playlistFolders: [PlaylistFolder] = []
    @Published private(set) var playbackEvents: [PlaybackEvent] = []
    @Published private(set) var playbackQueue: PlaybackQueueState?
    @Published private(set) var syncedDisplayTags: [Track.ID: [String]] = [:]
    @Published private(set) var contentRevision = 0
    @Published private(set) var audioFeatures: [Track.ID: AudioFeatureAnalysis] = [:]
    @Published private(set) var isAnalyzingAudioFeatures = false
    @Published private(set) var isAudioFeatureAnalysisPaused = false
    @Published private(set) var audioFeatureAnalysisPauseReason: AudioFeatureAnalysisPauseReason?
    @Published private(set) var audioFeatureRevision = 0
    @Published private(set) var audioFeatureAnalysisProgress: AudioFeatureAnalysisProgress?
    @Published var selectedSection: LibrarySection = .songs
    @Published var selectedPlaylistID: Playlist.ID?
    @Published private var trackSelection = TrackSelectionState()
    var selectedTrackID: Track.ID? {
        get { trackSelection.focusedID }
        set {
            let selectedIDs: Set<Track.ID>
            if let newValue {
                selectedIDs = trackSelection.selectedIDs.contains(newValue)
                    ? trackSelection.selectedIDs
                    : [newValue]
            } else {
                selectedIDs = []
            }
            let next = TrackSelectionState(focusedID: newValue, selectedIDs: selectedIDs)
            guard trackSelection != next else { return }
            trackSelection = next
        }
    }
    var selectedTrackIDs: Set<Track.ID> {
        get { trackSelection.selectedIDs }
        set {
            let focusedID = TrackSelectionResolver.focusedTrackID(
                previousFocus: trackSelection.focusedID,
                previousSelection: newValue,
                newSelection: newValue
            )
            let next = TrackSelectionState(focusedID: focusedID, selectedIDs: newValue)
            guard trackSelection != next else { return }
            trackSelection = next
        }
    }
    @Published var searchText = "" {
        didSet { scheduleIndexedSearch() }
    }
    @Published var filterCriteria = LibraryFilterCriteria()
    @Published private(set) var activity: Activity = .idle
    @Published private(set) var lastIssues: [ImportIssue] = []
    @Published private(set) var searchBackendStatus: SearchBackendStatus = .jsonFallback
    @Published private var indexedSearchTrackIDs: Set<Track.ID>?
    @Published private(set) var indexedSearchQuery: String?

    private var repository: LibraryRepository
    private let deviceSyncTagsURL: URL
    private var audioFeatureCache: AudioFeatureCache
    private var searchIndex: SQLiteCatalogPrototype
    private var libraryID = UUID()
    private var libraryCreatedAt = Date.now
    private var searchIndexSynchronizationTask: Task<Void, Never>?
    private var indexedSearchTask: Task<Void, Never>?
    private var playbackQueueSaveTask: Task<Void, Never>?
    private var audioFeatureAnalysisTask: Task<Void, Never>?
    private var audioFeatureAnalysisGeneration = UUID()
    private var isAudioFeatureAnalysisUserPaused = false
    private var duplicateGroupCacheRevision = -1
    private var duplicateGroupCache: [DuplicateTrackGroup] = []
    weak var undoManager: UndoManager?

    init(
        repository: LibraryRepository = LibraryRepository(),
        searchIndex: SQLiteCatalogPrototype? = nil
    ) {
        self.repository = repository
        deviceSyncTagsURL = repository.rootURL.appendingPathComponent("device-sync-tags-v1.json")
        audioFeatureCache = AudioFeatureCache(rootURL: repository.rootURL)
        self.searchIndex = searchIndex ?? SQLiteCatalogPrototype(rootURL: repository.rootURL)
    }

    var selectedTrack: Track? {
        tracks.first { $0.id == selectedTrackID }
    }

    func updateTrackSelection(_ selectedIDs: Set<Track.ID>, focusedID: Track.ID?) {
        let validFocus = focusedID.flatMap { selectedIDs.contains($0) ? $0 : nil }
        let next = TrackSelectionState(focusedID: validFocus, selectedIDs: selectedIDs)
        guard trackSelection != next else { return }
        trackSelection = next
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
            result = StandardLibraryResolver.tracks(
                for: selectedSection,
                tracks: tracks,
                events: playbackEvents,
                audioFeatures: audioFeatures
            )
        }

        if filterCriteria.activeCount > 0 {
            result = result.filter(filterCriteria.matches)
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

    var duplicateGroups: [DuplicateTrackGroup] {
        if duplicateGroupCacheRevision != contentRevision {
            duplicateGroupCache = DuplicateTrackAnalyzer.groups(in: tracks)
            duplicateGroupCacheRevision = contentRevision
        }
        return duplicateGroupCache
    }

    var filteredDuplicateGroups: [DuplicateTrackGroup] {
        return duplicateGroups.filter { group in
            group.tracks.contains { track in
                filterCriteria.matches(track)
                    && (searchText.isEmpty || CatalogSearch.matches(track, query: searchText))
            }
        }
    }

    func playbackStatistics(for trackID: Track.ID) -> TrackPlaybackStatistics {
        PlaybackStatisticsResolver.statistics(events: playbackEvents, tracks: tracks)[trackID]
            ?? TrackPlaybackStatistics()
    }

    func setFavorite(_ isFavorite: Bool, for trackID: Track.ID) async {
        await updatePlaybackAttributes(for: trackID) {
            $0.isFavorite = isFavorite
            $0.syncedOverlayUpdatedAt = .now
        }
    }

    func setPinned(_ isPinned: Bool, for trackID: Track.ID) async {
        await updatePlaybackAttributes(for: trackID) { $0.isPinned = isPinned }
    }

    func setRating(_ rating: Int, for trackID: Track.ID) async {
        await updatePlaybackAttributes(for: trackID) {
            $0.rating = min(max(rating, 0), 5)
            $0.syncedOverlayUpdatedAt = .now
        }
    }

    func setExcludedFromPlayback(_ isExcluded: Bool, for trackID: Track.ID) async {
        await updatePlaybackAttributes(for: trackID) {
            $0.isExcludedFromPlayback = isExcluded
        }
    }

    @discardableResult
    func applySyncedTrackOverlays(
        _ applications: [DeviceSyncOverlayApplication]
    ) async -> Int {
        guard !applications.isEmpty else { return 0 }
        let previous = tracks
        let previousTags = syncedDisplayTags
        let statistics = PlaybackStatisticsResolver.statistics(
            events: playbackEvents,
            tracks: tracks
        )
        var appliedCount = 0

        for application in applications {
            guard let index = tracks.firstIndex(where: { $0.id == application.trackID }) else {
                continue
            }
            let remote = application.overlay
            let current = statistics[application.trackID] ?? TrackPlaybackStatistics()

            if application.fields.contains(.favorite) {
                tracks[index].isFavorite = remote.isFavorite
            }
            if application.fields.contains(.rating) {
                tracks[index].rating = min(max(remote.rating, 0), 5)
            }
            if !application.fields.isDisjoint(with: [.favorite, .rating]) {
                tracks[index].syncedOverlayUpdatedAt = max(
                    tracks[index].syncedOverlayUpdatedAt ?? .distantPast,
                    remote.updatedAt
                )
            }
            if application.fields.contains(.playCount), remote.playCount > current.playCount {
                tracks[index].playCount += remote.playCount - current.playCount
            }
            if application.fields.contains(.skipCount), remote.skipCount > current.skipCount {
                tracks[index].syncedSkipCount += remote.skipCount - current.skipCount
            }
            if application.fields.contains(.lastPlayedAt),
               let remoteLastPlayedAt = remote.lastPlayedAt,
               tracks[index].syncedLastPlayedAt.map({ remoteLastPlayedAt > $0 }) ?? true {
                tracks[index].syncedLastPlayedAt = remoteLastPlayedAt
            }
            if application.fields.contains(.displayTags), let tags = remote.displayTags {
                syncedDisplayTags[application.trackID] = Self.normalizedDisplayTags(tags)
            }
            appliedCount += 1
        }

        guard appliedCount > 0 else { return 0 }
        contentRevision &+= 1
        do {
            try await repository.save(tracks: tracks)
            try saveDeviceSyncTags()
            activity = .notice(L10n.text("deviceSync.overlay.applied"))
            return appliedCount
        } catch {
            tracks = previous
            syncedDisplayTags = previousTags
            contentRevision &+= 1
            activity = .failed(error.localizedDescription)
            return 0
        }
    }

    @discardableResult
    func undoSyncedTrackOverlays(
        _ changes: [DeviceSyncAuditChange]
    ) async -> DeviceSyncOverlayUndoResult {
        guard !changes.isEmpty else {
            return DeviceSyncOverlayUndoResult(restoredFieldCount: 0, conflictFieldCount: 0)
        }
        let previous = tracks
        let previousTags = syncedDisplayTags
        let statistics = PlaybackStatisticsResolver.statistics(
            events: playbackEvents,
            tracks: tracks
        )
        var restoredFieldCount = 0
        var conflictFieldCount = 0

        for change in changes {
            guard let index = tracks.firstIndex(where: { $0.id == change.trackID }) else {
                conflictFieldCount += change.fields.count
                continue
            }
            let current = statistics[change.trackID] ?? TrackPlaybackStatistics()
            for field in change.fields {
                switch field {
                case .favorite where tracks[index].isFavorite == change.after.isFavorite:
                    tracks[index].isFavorite = change.before.isFavorite
                    tracks[index].syncedOverlayUpdatedAt = .now
                    restoredFieldCount += 1
                case .rating where tracks[index].rating == change.after.rating:
                    tracks[index].rating = change.before.rating
                    tracks[index].syncedOverlayUpdatedAt = .now
                    restoredFieldCount += 1
                case .playCount where current.playCount == change.after.playCount:
                    let delta = max(0, change.after.playCount - change.before.playCount)
                    tracks[index].playCount = max(0, tracks[index].playCount - delta)
                    restoredFieldCount += 1
                case .skipCount where current.skipCount == change.after.skipCount:
                    let delta = max(0, change.after.skipCount - change.before.skipCount)
                    tracks[index].syncedSkipCount = max(0, tracks[index].syncedSkipCount - delta)
                    restoredFieldCount += 1
                case .lastPlayedAt where current.lastPlayedAt == change.after.lastPlayedAt:
                    tracks[index].syncedLastPlayedAt = change.before.lastPlayedAt
                    restoredFieldCount += 1
                case .displayTags:
                    let currentTags = syncedDisplayTags[change.trackID] ?? []
                    if currentTags == (change.after.displayTags ?? []) {
                        syncedDisplayTags[change.trackID] = Self.normalizedDisplayTags(
                            change.before.displayTags ?? []
                        )
                        restoredFieldCount += 1
                    } else {
                        conflictFieldCount += 1
                    }
                default:
                    conflictFieldCount += 1
                }
            }
        }

        guard restoredFieldCount > 0 else {
            return DeviceSyncOverlayUndoResult(
                restoredFieldCount: 0,
                conflictFieldCount: conflictFieldCount
            )
        }
        contentRevision &+= 1
        do {
            try await repository.save(tracks: tracks)
            try saveDeviceSyncTags()
            activity = .notice(L10n.text("deviceSync.audit.undoCompleted"))
            return DeviceSyncOverlayUndoResult(
                restoredFieldCount: restoredFieldCount,
                conflictFieldCount: conflictFieldCount
            )
        } catch {
            tracks = previous
            syncedDisplayTags = previousTags
            contentRevision &+= 1
            activity = .failed(error.localizedDescription)
            return DeviceSyncOverlayUndoResult(
                restoredFieldCount: 0,
                conflictFieldCount: changes.reduce(0) { $0 + $1.fields.count }
            )
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

    @discardableResult
    func createPlaylistFromAppleMusic(
        name rawName: String,
        trackIDs: [Track.ID]
    ) async throws -> Playlist.ID {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PlaylistTransferError.emptyName }
        let validTrackIDs = Set(tracks.map(\.id))
        var seen: Set<Track.ID> = []
        let orderedTrackIDs = trackIDs.filter {
            validTrackIDs.contains($0) && seen.insert($0).inserted
        }
        let nextOrder = playlists.filter { $0.folderID == nil }
            .map(\.sortOrder).max().map { $0 + 1 } ?? 0
        let playlist = Playlist(
            name: name,
            description: L10n.text("appleMusic.conversion.playlistDescription"),
            sortOrder: nextOrder,
            entries: orderedTrackIDs.map { PlaylistEntry(trackID: $0) }
        )
        try await persistPlaylists(
            playlists + [playlist],
            undoActionName: L10n.text("undo.playlist.create")
        )
        selectedPlaylistID = playlist.id
        return playlist.id
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

    func deleteTracks(
        _ trackIDs: Set<Track.ID>,
        moveFilesToTrash: Bool
    ) async throws -> TrackDeletionResult {
        guard !trackIDs.isEmpty else {
            return TrackDeletionResult(
                removedCount: 0,
                trashedFileCount: 0,
                retainedFileCount: 0,
                failedFileNames: []
            )
        }
        let removedTracks = tracks.filter { trackIDs.contains($0.id) }
        guard !removedTracks.isEmpty else {
            return TrackDeletionResult(
                removedCount: 0,
                trashedFileCount: 0,
                retainedFileCount: 0,
                failedFileNames: []
            )
        }
        let removedIDs = Set(removedTracks.map(\.id))
        let updatedTracks = tracks.filter { !removedIDs.contains($0.id) }
        let updatedPlaylists = playlists.map { playlist in
            guard playlist.smartDefinition == nil else { return playlist }
            var updated = playlist
            let previousCount = updated.entries.count
            updated.entries.removeAll { removedIDs.contains($0.trackID) }
            if updated.entries.count != previousCount { updated.updatedAt = .now }
            return updated
        }
        let updatedEvents = playbackEvents.filter { !removedIDs.contains($0.trackID) }
        var updatedQueue = playbackQueue
        if var queue = updatedQueue {
            queue.trackIDs.removeAll { removedIDs.contains($0) }
            if let currentTrackID = queue.currentTrackID, removedIDs.contains(currentTrackID) {
                queue.currentTrackID = nil
                queue.position = 0
            }
            updatedQueue = queue
        }

        playbackQueueSaveTask?.cancel()
        cancelAudioFeatureAnalysis()
        let document = LibraryDocument(
            updatedAt: .now,
            tracks: updatedTracks,
            libraryID: libraryID,
            createdAt: libraryCreatedAt,
            playlists: updatedPlaylists,
            playlistFolders: playlistFolders,
            playbackEvents: updatedEvents,
            playbackQueue: updatedQueue
        )
        do {
            try await repository.save(document: document)
            tracks = updatedTracks
            playlists = updatedPlaylists
            playbackEvents = updatedEvents
            playbackQueue = updatedQueue
            selectedTrackIDs.subtract(removedIDs)
            if let selectedTrackID, removedIDs.contains(selectedTrackID) {
                self.selectedTrackID = self.selectedTrackIDs.first
            }
            audioFeatures = audioFeatures.filter { !removedIDs.contains($0.key) }
            syncedDisplayTags = syncedDisplayTags.filter { !removedIDs.contains($0.key) }
            try? await audioFeatureCache.save(audioFeatures)
            try? saveDeviceSyncTags()
            contentRevision &+= 1
            audioFeatureRevision &+= 1
            scheduleSearchIndexSynchronization(document: document)

            var trashResult = (trashed: 0, retained: removedTracks.count, failures: [String]())
            if moveFilesToTrash {
                trashResult = await repository.trashFiles(
                    removedTracks: removedTracks,
                    retainedTracks: updatedTracks,
                    includesExternalReferences: true
                )
            }
            let result = TrackDeletionResult(
                removedCount: removedTracks.count,
                trashedFileCount: trashResult.trashed,
                retainedFileCount: trashResult.retained,
                failedFileNames: trashResult.failures
            )
            activity = trashResult.failures.isEmpty
                ? .notice(L10n.format("libraryDeletion.status.removed", result.removedCount))
                : .failed(L10n.format(
                    "libraryDeletion.status.trashFailed",
                    trashResult.failures.count
                ))
            return result
        } catch {
            activity = .failed(error.localizedDescription)
            throw error
        }
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

    func applySyncedPlaylistOverlays(
        _ applications: [DeviceSyncPlaylistApplication]
    ) async throws -> [DeviceSyncPlaylistAuditChange] {
        guard !applications.isEmpty else { return [] }
        var updated = playlists
        var changes: [DeviceSyncPlaylistAuditChange] = []
        var nextSortOrder = (updated.map(\.sortOrder).max() ?? -1) + 1

        for application in applications {
            let entries = application.trackIDs.map {
                PlaylistEntry(trackID: $0, addedAt: application.remote.updatedAt)
            }
            if let index = updated.firstIndex(where: { $0.id == application.remote.id }) {
                guard updated[index].smartDefinition == nil else { continue }
                let before = updated[index]
                updated[index].name = application.remote.name
                updated[index].entries = entries
                updated[index].updatedAt = application.remote.updatedAt
                changes.append(DeviceSyncPlaylistAuditChange(
                    before: before,
                    after: updated[index]
                ))
            } else {
                let playlist = Playlist(
                    id: application.remote.id,
                    name: application.remote.name,
                    sortOrder: nextSortOrder,
                    entries: entries,
                    createdAt: application.remote.createdAt,
                    updatedAt: application.remote.updatedAt
                )
                nextSortOrder += 1
                updated.append(playlist)
                changes.append(DeviceSyncPlaylistAuditChange(before: nil, after: playlist))
            }
        }

        guard !changes.isEmpty else { return [] }
        try await persistPlaylists(updated, registersUndo: false)
        return changes
    }

    func undoSyncedPlaylistChanges(
        _ changes: [DeviceSyncPlaylistAuditChange]
    ) async -> DeviceSyncOverlayUndoResult {
        guard !changes.isEmpty else {
            return DeviceSyncOverlayUndoResult(restoredFieldCount: 0, conflictFieldCount: 0)
        }
        var updated = playlists
        var restoredCount = 0
        var conflictCount = 0

        for change in changes {
            guard let index = updated.firstIndex(where: { $0.id == change.after.id }),
                  updated[index] == change.after else {
                conflictCount += 1
                continue
            }
            if let before = change.before {
                updated[index] = before
            } else {
                updated.remove(at: index)
            }
            restoredCount += 1
        }

        guard restoredCount > 0 else {
            return DeviceSyncOverlayUndoResult(
                restoredFieldCount: 0,
                conflictFieldCount: conflictCount
            )
        }
        do {
            try await persistPlaylists(updated, registersUndo: false)
            activity = .notice(L10n.text("deviceSync.audit.undoCompleted"))
            return DeviceSyncOverlayUndoResult(
                restoredFieldCount: restoredCount,
                conflictFieldCount: conflictCount
            )
        } catch {
            return DeviceSyncOverlayUndoResult(
                restoredFieldCount: 0,
                conflictFieldCount: changes.count
            )
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
            loadDeviceSyncTags()
            audioFeatures = (try? await audioFeatureCache.load(validTracks: tracks)) ?? [:]
            audioFeatureRevision &+= 1
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

    private func loadDeviceSyncTags() {
        guard let data = try? Data(contentsOf: deviceSyncTagsURL),
              let decoded = try? JSONDecoder().decode([UUID: [String]].self, from: data) else {
            syncedDisplayTags = [:]
            return
        }
        let validIDs = Set(tracks.map(\.id))
        syncedDisplayTags = decoded.reduce(into: [:]) { result, pair in
            guard validIDs.contains(pair.key) else { return }
            let tags = Self.normalizedDisplayTags(pair.value)
            if !tags.isEmpty { result[pair.key] = tags }
        }
    }

    private func saveDeviceSyncTags() throws {
        let nonEmpty = syncedDisplayTags.filter { !$0.value.isEmpty }
        let data = try JSONEncoder().encode(nonEmpty)
        try FileManager.default.createDirectory(
            at: deviceSyncTagsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: deviceSyncTagsURL, options: .atomic)
    }

    private nonisolated static func normalizedDisplayTags(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return Array(values.compactMap { value in
            let tag = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
            guard !tag.isEmpty else { return nil }
            let key = tag.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            return seen.insert(key).inserted ? tag : nil
        }.prefix(12))
    }

    func switchLibrary(catalogURL: URL, mediaURL: URL) async {
        searchIndexSynchronizationTask?.cancel()
        indexedSearchTask?.cancel()
        playbackQueueSaveTask?.cancel()
        audioFeatureAnalysisTask?.cancel()
        audioFeatureAnalysisTask = nil
        audioFeatureAnalysisGeneration = UUID()
        repository = LibraryRepository(rootURL: catalogURL, mediaURL: mediaURL)
        audioFeatureCache = AudioFeatureCache(rootURL: catalogURL)
        searchIndex = SQLiteCatalogPrototype(rootURL: catalogURL)
        tracks = []
        playlists = []
        playlistFolders = []
        playbackEvents = []
        playbackQueue = nil
        audioFeatures = [:]
        isAnalyzingAudioFeatures = false
        isAudioFeatureAnalysisPaused = false
        audioFeatureAnalysisPauseReason = nil
        isAudioFeatureAnalysisUserPaused = false
        audioFeatureAnalysisProgress = nil
        audioFeatureRevision &+= 1
        selectedPlaylistID = nil
        selectedTrackID = nil
        selectedTrackIDs = []
        selectedSection = .songs
        searchText = ""
        filterCriteria = LibraryFilterCriteria()
        indexedSearchTrackIDs = nil
        indexedSearchQuery = nil
        searchBackendStatus = .jsonFallback
        lastIssues = []
        contentRevision &+= 1
        await load()
    }

    func startOngakuMixFeatureAnalysis() {
        let seed = OngakuMixResolver.seed(in: tracks, events: playbackEvents)
        let candidates = OngakuMixResolver.candidates(
            tracks: tracks,
            events: playbackEvents,
            audioFeatures: audioFeatures,
            limit: 12
        )
        let targets = ([seed].compactMap { $0 } + candidates.map(\.track)).filter { track in
            !(audioFeatures[track.id]?.isCurrent(for: track) ?? false)
        }
        startAudioFeatureAnalysis(targets: targets)
    }

    func startLibraryAudioFeatureAnalysis() {
        let targets = tracks.filter { track in
            !track.isExcludedFromPlayback
                && track.health != .missing
                && track.health != .unreadable
                && !(audioFeatures[track.id]?.isCurrent(for: track) ?? false)
        }
        startAudioFeatureAnalysis(targets: targets)
    }

    func cancelAudioFeatureAnalysis() {
        audioFeatureAnalysisTask?.cancel()
    }

    func pauseAudioFeatureAnalysis() {
        guard isAnalyzingAudioFeatures else { return }
        isAudioFeatureAnalysisUserPaused = true
        updateAudioFeatureAnalysisPauseState(.user)
    }

    func resumeAudioFeatureAnalysis() {
        guard isAnalyzingAudioFeatures else { return }
        isAudioFeatureAnalysisUserPaused = false
        updateAudioFeatureAnalysisPauseState(currentAutomaticAudioFeaturePauseReason())
    }

    private func startAudioFeatureAnalysis(targets: [Track]) {
        guard audioFeatureAnalysisTask == nil, !targets.isEmpty else { return }
        let generation = UUID()
        audioFeatureAnalysisGeneration = generation
        let cache = audioFeatureCache
        isAudioFeatureAnalysisUserPaused = false
        isAnalyzingAudioFeatures = true
        updateAudioFeatureAnalysisPauseState(currentAutomaticAudioFeaturePauseReason())
        audioFeatureAnalysisProgress = AudioFeatureAnalysisProgress(total: targets.count)
        audioFeatureAnalysisTask = Task { [weak self] in
            await self?.runAudioFeatureAnalysis(
                targets: targets,
                generation: generation,
                cache: cache
            )
        }
    }

    private func runAudioFeatureAnalysis(
        targets: [Track],
        generation: UUID,
        cache: AudioFeatureCache
    ) async {
        var updated = audioFeatures
        var completed = 0
        var failed = 0
        for track in targets {
            guard await waitUntilAudioFeatureAnalysisCanContinue(generation: generation) else {
                break
            }
            let analysis = await Task.detached(priority: .utility) {
                try? AudioFeatureAnalyzer.analyze(track: track)
            }.value
            guard generation == audioFeatureAnalysisGeneration else { return }
            if let analysis {
                updated[track.id] = analysis
                completed += 1
            } else {
                failed += 1
            }
            audioFeatureAnalysisProgress = AudioFeatureAnalysisProgress(
                total: targets.count,
                completed: completed,
                failed: failed
            )
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard generation == audioFeatureAnalysisGeneration else { return }
        try? await cache.save(updated)
        await Task.yield()
        if updated != audioFeatures {
            audioFeatures = updated
            audioFeatureRevision &+= 1
        }
        audioFeatureAnalysisProgress = AudioFeatureAnalysisProgress(
            total: targets.count,
            completed: completed,
            failed: failed
        )
        isAudioFeatureAnalysisUserPaused = false
        updateAudioFeatureAnalysisPauseState(nil)
        isAnalyzingAudioFeatures = false
        audioFeatureAnalysisTask = nil
    }

    private func waitUntilAudioFeatureAnalysisCanContinue(generation: UUID) async -> Bool {
        while !Task.isCancelled && generation == audioFeatureAnalysisGeneration {
            let reason = isAudioFeatureAnalysisUserPaused
                ? AudioFeatureAnalysisPauseReason.user
                : currentAutomaticAudioFeaturePauseReason()
            updateAudioFeatureAnalysisPauseState(reason)
            guard reason != nil else { return true }
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return false
            }
        }
        return false
    }

    private func currentAutomaticAudioFeaturePauseReason() -> AudioFeatureAnalysisPauseReason? {
        AudioFeatureAnalysisPowerPolicy.automaticPauseReason(
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState
        )
    }

    private func updateAudioFeatureAnalysisPauseState(
        _ reason: AudioFeatureAnalysisPauseReason?
    ) {
        let paused = reason != nil
        if audioFeatureAnalysisPauseReason != reason {
            audioFeatureAnalysisPauseReason = reason
        }
        if isAudioFeatureAnalysisPaused != paused {
            isAudioFeatureAnalysisPaused = paused
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

    @discardableResult
    func importAudioCD(_ requests: [AudioCDImportRequest]) async -> Int {
        guard !requests.isEmpty else { return 0 }
        activity = .importing
        lastIssues = []
        let overrides = Dictionary(
            uniqueKeysWithValues: requests.map {
                ($0.sourceURL.standardizedFileURL.path, $0)
            }
        )
        let result = await repository.importFiles(
            requests.map(\.sourceURL),
            existing: tracks,
            metadataOverrides: overrides
        )
        tracks.append(contentsOf: result.imported)
        tracks.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        contentRevision &+= 1
        lastIssues = result.issues

        do {
            try await repository.save(tracks: tracks)
            selectedTrackID = result.imported.first?.id ?? selectedTrackID
            scheduleSearchIndexSynchronization(document: currentDocument())
            if result.imported.isEmpty, !result.issues.isEmpty {
                activity = .failed(L10n.format("import.issueCount", result.issues.count))
            } else {
                activity = .notice(L10n.format("status.cdImported", result.imported.count))
            }
            return result.imported.count
        } catch {
            activity = .failed(error.localizedDescription)
            return 0
        }
    }

    @discardableResult
    func importLegacyLibrary(
        _ preview: LegacyLibraryMigrationPreview
    ) async throws -> LegacyLibraryMigrationSummary {
        activity = .importing
        lastIssues = []

        let readyTracks = preview.tracks.filter {
            $0.status == .ready && $0.location != nil
        }
        let hashResults = await Task.detached(priority: .userInitiated) {
            readyTracks.map { source -> (Int, URL, Result<String, Error>) in
                let url = source.location!
                do { return (source.id, url, .success(try LibraryRepository.sha256(of: url))) }
                catch { return (source.id, url, .failure(error)) }
            }
        }.value

        var hashByLegacyID: [Int: String] = [:]
        var sourceIssues: [ImportIssue] = []
        for (legacyID, url, result) in hashResults {
            switch result {
            case .success(let hash): hashByLegacyID[legacyID] = hash
            case .failure(let error):
                sourceIssues.append(ImportIssue(
                    fileName: url.lastPathComponent,
                    message: error.localizedDescription
                ))
            }
        }

        let hashableReadyTracks = readyTracks.filter { hashByLegacyID[$0.id] != nil }
        let overridePairs: [(String, AudioCDImportRequest)] = hashableReadyTracks.compactMap {
            source in
                guard let location = source.location else { return nil }
                return (
                    location.standardizedFileURL.path,
                    AudioCDImportRequest(
                        sourceURL: location,
                        title: source.title,
                        artist: source.artist,
                        album: source.album,
                        albumArtist: source.albumArtist.isEmpty ? nil : source.albumArtist,
                        releaseYear: source.releaseYear,
                        trackNumber: source.trackNumber ?? 0,
                        trackCount: source.trackCount ?? 0,
                        discNumber: source.discNumber,
                        discCount: source.discCount
                    )
                )
            }
        let overrides: [String: AudioCDImportRequest] = Dictionary(
            overridePairs,
            uniquingKeysWith: { first, _ in first }
        )
        let importResult = await repository.importFiles(
            hashableReadyTracks.compactMap(\.location),
            existing: tracks,
            reportDuplicates: false,
            metadataOverrides: overrides
        )

        var updatedTracks = tracks + importResult.imported
        let importedIDs: Set<Track.ID> = Set(importResult.imported.map(\.id))
        let sourceByHash = Dictionary(
            hashableReadyTracks.compactMap { source -> (String, LegacyLibraryTrack)? in
                guard let hash = hashByLegacyID[source.id] else { return nil }
                return (hash, source)
            },
            uniquingKeysWith: { first, _ in first }
        )
        for index in updatedTracks.indices where importedIDs.contains(updatedTracks[index].id) {
            guard let source = sourceByHash[updatedTracks[index].sha256] else { continue }
            Self.applyLegacyMetadata(source, to: &updatedTracks[index])
        }

        var trackIDByLegacyID: [Int: Track.ID] = [:]
        let tracksByPath: [String: Track.ID] = Dictionary(
            updatedTracks.map { ($0.fileURL.standardizedFileURL.path, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        let tracksByHash: [String: Track.ID] = Dictionary(
            updatedTracks.map { ($0.sha256, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        for source in preview.tracks {
            if let location = source.location,
               let trackID = tracksByPath[location.standardizedFileURL.path] {
                trackIDByLegacyID[source.id] = trackID
            } else if let hash = hashByLegacyID[source.id], let trackID = tracksByHash[hash] {
                trackIDByLegacyID[source.id] = trackID
            }
        }

        var updatedPlaylists = playlists
        var importedPlaylistCount = 0
        for source in preview.playlists {
            var seen: Set<Track.ID> = []
            let trackIDs = source.trackIDs.compactMap { trackIDByLegacyID[$0] }
                .filter { seen.insert($0).inserted }
            let alreadyExists = updatedPlaylists.contains {
                $0.name == source.name && $0.entries.map(\.trackID) == trackIDs
            }
            guard !alreadyExists else { continue }
            let nextOrder = updatedPlaylists.filter { $0.folderID == nil }
                .map(\.sortOrder).max().map { $0 + 1 } ?? 0
            updatedPlaylists.append(Playlist(
                name: source.name,
                description: source.description,
                sortOrder: nextOrder,
                entries: trackIDs.map { PlaylistEntry(trackID: $0) }
            ))
            importedPlaylistCount += 1
        }

        updatedTracks.sort {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }

        let document = LibraryDocument(
            updatedAt: .now,
            tracks: updatedTracks,
            libraryID: libraryID,
            createdAt: libraryCreatedAt,
            playlists: updatedPlaylists,
            playlistFolders: playlistFolders,
            playbackEvents: playbackEvents,
            playbackQueue: playbackQueue
        )
        do {
            try await repository.save(document: document)
            tracks = updatedTracks
            playlists = updatedPlaylists
            lastIssues = sourceIssues + importResult.issues
            selectedTrackID = importResult.imported.first?.id ?? selectedTrackID
            contentRevision &+= 1
            scheduleSearchIndexSynchronization(document: document)
            let mappedExistingCount = Set(trackIDByLegacyID.values)
                .subtracting(importedIDs).count
            let summary = LegacyLibraryMigrationSummary(
                imported: importResult.imported.count,
                linkedExisting: mappedExistingCount,
                playlists: importedPlaylistCount,
                issues: lastIssues.count + preview.missingCount + preview.unsupportedCount
            )
            activity = .notice(L10n.format(
                "status.libraryMigrationImported",
                summary.imported,
                summary.playlists,
                summary.issues
            ))
            return summary
        } catch {
            activity = .failed(error.localizedDescription)
            throw error
        }
    }

    func previewOngakuLibrary(at selectedURL: URL) async throws -> OngakuLibraryMigrationPreview {
        let selected = selectedURL.standardizedFileURL
        let selectedValues = try? selected.resourceValues(forKeys: [.isDirectoryKey])
        let isDirectory = selectedValues?.isDirectory == true
        let manifestURL = isDirectory
            ? selected.appendingPathComponent("library-v1.json")
            : selected
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw OngakuLibraryMigrationError.manifestNotFound
        }
        let document = try await repository.readExternalLibraryDocument(at: manifestURL)
        guard document.libraryID != libraryID else {
            throw OngakuLibraryMigrationError.sameLibrary
        }
        guard !document.tracks.isEmpty else {
            throw OngakuLibraryMigrationError.noTracks
        }
        let existingHashes = Set(tracks.map(\.sha256).filter { !$0.isEmpty })
        let existingPaths = Set(tracks.map { $0.fileURL.standardizedFileURL.path })
        let rows = document.tracks.map { track -> OngakuLibraryMigrationRow in
            let fileURL = track.fileURL.standardizedFileURL
            let status: LegacyLibraryTrackStatus
            if (!track.sha256.isEmpty && existingHashes.contains(track.sha256))
                || existingPaths.contains(fileURL.path) {
                status = .alreadyRegistered
            } else if !Self.isSupportedAudioFile(fileURL) {
                status = .unsupported
            } else if Self.isReadableRegularAudioFile(fileURL) {
                status = .ready
            } else {
                status = .missing
            }
            return OngakuLibraryMigrationRow(track: track, status: status)
        }
        return OngakuLibraryMigrationPreview(
            manifestURL: manifestURL,
            document: document,
            rows: rows
        )
    }

    @discardableResult
    func importOngakuLibrary(
        _ preview: OngakuLibraryMigrationPreview
    ) async throws -> OngakuLibraryMigrationSummary {
        activity = .importing
        lastIssues = []
        let readySources = preview.rows.filter { $0.status == .ready }.map(\.track)
        let hashResults = await Task.detached(priority: .userInitiated) {
            readySources.map { source -> (Track, Result<String, Error>) in
                do { return (source, .success(try LibraryRepository.sha256(of: source.fileURL))) }
                catch { return (source, .failure(error)) }
            }
        }.value

        var actualHashBySourceID: [Track.ID: String] = [:]
        var sourceIssues: [ImportIssue] = []
        for (source, result) in hashResults {
            switch result {
            case .success(let hash): actualHashBySourceID[source.id] = hash
            case .failure(let error):
                sourceIssues.append(ImportIssue(
                    fileName: source.fileURL.lastPathComponent,
                    message: error.localizedDescription
                ))
            }
        }
        let hashableSources = readySources.filter { actualHashBySourceID[$0.id] != nil }
        let overridePairs: [(String, AudioCDImportRequest)] = hashableSources.map { source in
            (
                source.fileURL.standardizedFileURL.path,
                AudioCDImportRequest(
                    sourceURL: source.fileURL,
                    title: source.title,
                    artist: source.artist,
                    album: source.album,
                    albumArtist: source.albumArtist.isEmpty ? nil : source.albumArtist,
                    releaseYear: source.releaseYear,
                    isrc: source.isrc.isEmpty ? nil : source.isrc,
                    trackNumber: source.trackNumber ?? 0,
                    trackCount: source.trackCount ?? 0,
                    discNumber: source.discNumber,
                    discCount: source.discCount,
                    musicBrainzReference: source.musicBrainzReference
                )
            )
        }
        let overrides = Dictionary(
            overridePairs,
            uniquingKeysWith: { first, _ in first }
        )
        let importResult = await repository.importFiles(
            hashableSources.map(\.fileURL),
            existing: tracks,
            reportDuplicates: false,
            metadataOverrides: overrides
        )

        var updatedTracks = tracks + importResult.imported
        let importedIDs: Set<Track.ID> = Set(importResult.imported.map(\.id))
        let sourceByHash = Dictionary(
            hashableSources.compactMap { source -> (String, Track)? in
                guard let hash = actualHashBySourceID[source.id] else { return nil }
                return (hash, source)
            },
            uniquingKeysWith: { first, _ in first }
        )
        for index in updatedTracks.indices where importedIDs.contains(updatedTracks[index].id) {
            guard let source = sourceByHash[updatedTracks[index].sha256] else { continue }
            Self.applyOngakuMetadata(source, to: &updatedTracks[index])
        }

        let tracksByHash: [String: Track.ID] = Dictionary(
            updatedTracks.filter { !$0.sha256.isEmpty }.map { ($0.sha256, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        let tracksByPath: [String: Track.ID] = Dictionary(
            updatedTracks.map { ($0.fileURL.standardizedFileURL.path, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        var trackIDMap: [Track.ID: Track.ID] = [:]
        for row in preview.rows {
            let source = row.track
            if let actualHash = actualHashBySourceID[source.id],
               let destinationID = tracksByHash[actualHash] {
                trackIDMap[source.id] = destinationID
            } else if !source.sha256.isEmpty, let destinationID = tracksByHash[source.sha256] {
                trackIDMap[source.id] = destinationID
            } else if let destinationID = tracksByPath[source.fileURL.standardizedFileURL.path] {
                trackIDMap[source.id] = destinationID
            }
        }

        var updatedFolders = playlistFolders
        var folderIDMap: [PlaylistFolder.ID: PlaylistFolder.ID] = [:]
        var importedFolderCount = 0
        for source in preview.document.playlistFolders.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            if let existing = updatedFolders.first(where: { $0.name == source.name }) {
                folderIDMap[source.id] = existing.id
                continue
            }
            let destination = PlaylistFolder(
                name: source.name,
                sortOrder: updatedFolders.map(\.sortOrder).max().map { $0 + 1 } ?? 0,
                createdAt: source.createdAt,
                updatedAt: source.updatedAt
            )
            updatedFolders.append(destination)
            folderIDMap[source.id] = destination.id
            importedFolderCount += 1
        }

        var updatedPlaylists = playlists
        var importedPlaylistCount = 0
        for source in preview.document.playlists.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            var seen: Set<Track.ID> = []
            let entries = source.entries.compactMap { entry -> PlaylistEntry? in
                guard let destinationID = trackIDMap[entry.trackID],
                      seen.insert(destinationID).inserted else { return nil }
                return PlaylistEntry(trackID: destinationID, addedAt: entry.addedAt)
            }
            let destinationFolderID = source.folderID.flatMap { folderIDMap[$0] }
            let alreadyExists = updatedPlaylists.contains {
                $0.name == source.name
                    && $0.folderID == destinationFolderID
                    && $0.smartDefinition == source.smartDefinition
                    && $0.entries.map(\.trackID) == entries.map(\.trackID)
            }
            guard !alreadyExists else { continue }
            updatedPlaylists.append(Playlist(
                name: source.name,
                description: source.description,
                folderID: destinationFolderID,
                sortOrder: updatedPlaylists.filter { $0.folderID == destinationFolderID }
                    .map(\.sortOrder).max().map { $0 + 1 } ?? 0,
                smartDefinition: source.smartDefinition,
                entries: source.smartDefinition == nil ? entries : [],
                createdAt: source.createdAt,
                updatedAt: source.updatedAt
            ))
            importedPlaylistCount += 1
        }
        updatedTracks.sort {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }

        let destinationDocument = LibraryDocument(
            updatedAt: .now,
            tracks: updatedTracks,
            libraryID: libraryID,
            createdAt: libraryCreatedAt,
            playlists: updatedPlaylists,
            playlistFolders: updatedFolders,
            playbackEvents: playbackEvents,
            playbackQueue: playbackQueue
        )
        do {
            try await repository.save(document: destinationDocument)
            tracks = updatedTracks
            playlists = updatedPlaylists
            playlistFolders = updatedFolders
            lastIssues = sourceIssues + importResult.issues
            selectedTrackID = importResult.imported.first?.id ?? selectedTrackID
            contentRevision &+= 1
            scheduleSearchIndexSynchronization(document: destinationDocument)
            let summary = OngakuLibraryMigrationSummary(
                imported: importResult.imported.count,
                linkedExisting: Set(trackIDMap.values).subtracting(importedIDs).count,
                playlists: importedPlaylistCount,
                folders: importedFolderCount,
                issues: lastIssues.count + preview.missingCount + preview.unsupportedCount
            )
            activity = .notice(L10n.format(
                "status.ongakuLibraryMigrationImported",
                summary.imported,
                summary.playlists,
                summary.folders,
                summary.issues
            ))
            return summary
        } catch {
            activity = .failed(error.localizedDescription)
            throw error
        }
    }

    func previewSharedFolder(at folderURL: URL) async throws -> SharedFolderMigrationPreview {
        let root = folderURL.standardizedFileURL
        let existingHashes = Set(tracks.map(\.sha256).filter { !$0.isEmpty })
        let files = await Task.detached(priority: .userInitiated) {
            Self.resolveDroppedAudioFiles([root])
        }.value
        guard !files.isEmpty else { throw SharedFolderMigrationError.noAudioFiles }

        let hashResults = await Task.detached(priority: .userInitiated) {
            files.map { file -> (URL, Result<String, Error>) in
                do { return (file, .success(try LibraryRepository.sha256(of: file))) }
                catch { return (file, .failure(error)) }
            }
        }.value
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let rows = hashResults.map { file, result -> SharedFolderMigrationRow in
            let relativePath = file.path.hasPrefix(rootPrefix)
                ? String(file.path.dropFirst(rootPrefix.count))
                : file.lastPathComponent
            switch result {
            case .success(let hash):
                return SharedFolderMigrationRow(
                    sourceURL: file,
                    relativePath: relativePath,
                    sha256: hash,
                    status: existingHashes.contains(hash) ? .alreadyRegistered : .ready
                )
            case .failure:
                return SharedFolderMigrationRow(
                    sourceURL: file,
                    relativePath: relativePath,
                    sha256: nil,
                    status: .missing
                )
            }
        }
        return SharedFolderMigrationPreview(rootURL: root, rows: rows)
    }

    @discardableResult
    func importSharedFolder(
        _ preview: SharedFolderMigrationPreview
    ) async throws -> SharedFolderMigrationSummary {
        activity = .importing
        lastIssues = []
        let sources = preview.rows.filter { $0.status == .ready }.map(\.sourceURL)
        let result = await repository.importFiles(
            sources,
            existing: tracks,
            reportDuplicates: false
        )
        var updatedTracks = tracks + result.imported
        updatedTracks.sort {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        do {
            try await repository.save(tracks: updatedTracks)
            tracks = updatedTracks
            lastIssues = result.issues
            selectedTrackID = result.imported.first?.id ?? selectedTrackID
            contentRevision &+= 1
            scheduleSearchIndexSynchronization(document: currentDocument())
            let summary = SharedFolderMigrationSummary(
                imported: result.imported.count,
                linkedExisting: preview.registeredCount,
                issues: result.issues.count + preview.unavailableCount
            )
            activity = .notice(L10n.format(
                "status.sharedFolderMigrationImported",
                summary.imported,
                summary.linkedExisting,
                summary.issues
            ))
            return summary
        } catch {
            activity = .failed(error.localizedDescription)
            throw error
        }
    }

    func mediaDirectoryURL() async -> URL {
        await repository.currentMediaDirectoryURL()
    }

    func previewMediaOrganization(
        destination: URL
    ) async throws -> MediaOrganizationPreview {
        try await repository.planMediaOrganization(
            tracks: tracks,
            destinationRootURL: destination
        )
    }

    @discardableResult
    func organizeManagedMediaAfterMetadataChange(
        trackIDs: Set<Track.ID>
    ) async throws -> MediaOrganizationSummary {
        let destination = await repository.currentMediaDirectoryURL()
        let preview = try await repository.planMediaOrganization(
            tracks: tracks,
            destinationRootURL: destination
        ).restricted(to: trackIDs)
        guard preview.moveCount > 0 else {
            return MediaOrganizationSummary(moved: 0, updatedTracks: 0)
        }
        return try await executeMediaOrganization(preview)
    }

    @discardableResult
    func executeMediaOrganization(
        _ preview: MediaOrganizationPreview
    ) async throws -> MediaOrganizationSummary {
        activity = .importing
        do {
            let result = try await repository.executeMediaOrganization(
                document: currentDocument(),
                preview: preview
            )
            tracks = result.document.tracks
            contentRevision &+= 1
            scheduleSearchIndexSynchronization(document: result.document)
            activity = .notice(L10n.format(
                "status.mediaOrganizationComplete",
                result.summary.moved,
                result.summary.updatedTracks
            ))
            return result.summary
        } catch {
            activity = .failed(error.localizedDescription)
            throw error
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
        let relinkResult = await repository.relinkMissingFiles(in: tracks)
        tracks = relinkResult.tracks
        contentRevision &+= 1
        do {
            try await repository.save(tracks: tracks)
            scheduleSearchIndexSynchronization(document: currentDocument())
            activity = relinkResult.relinkedTrackCount > 0
                ? .notice(L10n.format(
                    "status.relinkAutomaticComplete",
                    relinkResult.relinkedTrackCount
                ))
                : .idle
        } catch {
            activity = .failed(error.localizedDescription)
        }
    }

    func relinkMissingFiles(searching roots: [URL]) async {
        guard !roots.isEmpty, tracks.contains(where: { $0.health == .missing }) else { return }
        activity = .relinking
        let result = await repository.relinkMissingFiles(in: tracks, searching: roots)
        do {
            if result.relinkedTrackCount > 0 {
                try await persistRelinkedTracks(result.tracks)
            }
            activity = .notice(L10n.format(
                "status.relinkSearchComplete",
                result.relinkedTrackCount,
                result.scannedFileCount
            ))
        } catch {
            activity = .failed(error.localizedDescription)
        }
    }

    func relinkTrack(id: Track.ID, to url: URL) async {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else {
            activity = .failed(MetadataEditError.trackNotFound.localizedDescription)
            return
        }
        activity = .relinking
        do {
            var updated = tracks
            updated[index] = try await repository.relink(updated[index], to: url)
            try await persistRelinkedTracks(updated)
            activity = .notice(L10n.text("status.relinkManualComplete"))
        } catch {
            activity = .failed(error.localizedDescription)
        }
    }

    private func persistRelinkedTracks(_ updated: [Track]) async throws {
        try await repository.save(tracks: updated)
        tracks = updated
        contentRevision &+= 1
        scheduleSearchIndexSynchronization(document: currentDocument())
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

    func resolveDuplicateGroup(
        _ groupID: DuplicateTrackGroup.ID,
        keeping keepID: Track.ID,
        moveManagedFilesToTrash: Bool
    ) async throws -> DuplicateResolutionResult {
        guard let group = duplicateGroups.first(where: { $0.id == groupID }),
              group.tracks.contains(where: { $0.id == keepID }) else {
            throw DuplicateResolutionError.invalidSelection
        }
        let removedIDs = Set(group.tracks.map(\.id)).subtracting([keepID])
        guard !removedIDs.isEmpty else { throw DuplicateResolutionError.invalidSelection }
        let removedTracks = tracks.filter { removedIDs.contains($0.id) }
        let updatedTracks = tracks.filter { !removedIDs.contains($0.id) }

        var updatedPlaylists = playlists
        for index in updatedPlaylists.indices where updatedPlaylists[index].smartDefinition == nil {
            var seen: Set<Track.ID> = []
            updatedPlaylists[index].entries = updatedPlaylists[index].entries.compactMap { entry in
                var updated = entry
                if removedIDs.contains(updated.trackID) { updated.trackID = keepID }
                return seen.insert(updated.trackID).inserted ? updated : nil
            }
            updatedPlaylists[index].updatedAt = .now
        }
        let updatedEvents = playbackEvents.map { event in
            guard removedIDs.contains(event.trackID) else { return event }
            var updated = event
            updated.trackID = keepID
            return updated
        }
        var updatedQueue = playbackQueue
        if var queue = updatedQueue {
            var seen: Set<Track.ID> = []
            queue.trackIDs = queue.trackIDs.compactMap { id in
                let updated = removedIDs.contains(id) ? keepID : id
                return seen.insert(updated).inserted ? updated : nil
            }
            if let current = queue.currentTrackID, removedIDs.contains(current) {
                queue.currentTrackID = keepID
            }
            updatedQueue = queue
        }

        playbackQueueSaveTask?.cancel()
        let document = LibraryDocument(
            updatedAt: .now,
            tracks: updatedTracks,
            libraryID: libraryID,
            createdAt: libraryCreatedAt,
            playlists: updatedPlaylists,
            playlistFolders: playlistFolders,
            playbackEvents: updatedEvents,
            playbackQueue: updatedQueue
        )
        do {
            try await repository.save(document: document)
            tracks = updatedTracks
            playlists = updatedPlaylists
            playbackEvents = updatedEvents
            playbackQueue = updatedQueue
            if let selectedTrackID, removedIDs.contains(selectedTrackID) {
                self.selectedTrackID = keepID
            }
            selectedTrackIDs.subtract(removedIDs)
            selectedTrackIDs.insert(keepID)
            contentRevision &+= 1
            scheduleSearchIndexSynchronization(document: document)

            var trashResult = (trashed: 0, retained: removedTracks.count, failures: [String]())
            if moveManagedFilesToTrash {
                trashResult = await repository.trashManagedFiles(
                    removedTracks: removedTracks,
                    retainedTracks: updatedTracks
                )
            }
            let result = DuplicateResolutionResult(
                removedCount: removedTracks.count,
                trashedFileCount: trashResult.trashed,
                retainedFileCount: trashResult.retained,
                failedFileNames: trashResult.failures
            )
            activity = trashResult.failures.isEmpty
                ? .notice(L10n.format("duplicates.status.resolved", result.removedCount))
                : .failed(L10n.format(
                    "duplicates.status.trashFailed",
                    trashResult.failures.count
                ))
            return result
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
        artwork: AudioArtworkChange = .unchanged,
        musicBrainzReference: MusicBrainzReference? = nil
    ) async throws {
        var updated = tracks
        guard let index = updated.firstIndex(where: { $0.id == id }) else {
            throw MetadataEditError.trackNotFound
        }
        let original = updated[index]
        updated[index].apply(metadata, includesTrackSpecificValues: true)
        if let musicBrainzReference {
            updated[index].musicBrainzReference = musicBrainzReference
        }
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
        artwork: AudioArtworkChange = .unchanged,
        musicBrainzReference: MusicBrainzReference? = nil
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
            if let musicBrainzReference {
                updated[index].musicBrainzReference = musicBrainzReference.albumReference
            }
            if metadata.artist != originalArtist {
                updated[index].artistID = destinationArtistID
            }
        }
        try await persistMetadataUpdate(updated, changedTrackIDs: ids, artwork: artwork)
    }

    func updateTracksMetadata(
        trackIDs: [Track.ID],
        patch: TrackMetadataPatch
    ) async throws {
        guard !patch.isEmpty else { return }
        let ids = Set(trackIDs)
        var updated = tracks
        let indices = updated.indices.filter { ids.contains(updated[$0].id) }
        guard !indices.isEmpty, indices.count == ids.count else {
            throw MetadataEditError.trackNotFound
        }

        for index in indices {
            updated[index].apply(patch)
        }
        reconcileMetadataIdentity(
            in: &updated,
            changedTrackIDs: ids,
            fields: patch.fields
        )
        try await persistMetadataUpdate(updated, changedTrackIDs: ids)
    }

    func updateTrackLyrics(id: Track.ID, lyrics: TrackLyrics?) async throws {
        var updated = tracks
        guard let index = updated.firstIndex(where: { $0.id == id }) else {
            throw MetadataEditError.trackNotFound
        }
        updated[index].lyrics = lyrics
        try await persistMetadataUpdate(
            updated,
            changedTrackIDs: [id],
            lyrics: .set(lyrics?.plainText ?? "")
        )
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
        artwork: AudioArtworkChange = .unchanged,
        lyrics: AudioLyricsChange = .unchanged
    ) async throws {
        var updated = proposed
        for index in updated.indices where changedTrackIDs.contains(updated[index].id) {
            let track = updated[index]
            let fingerprint = await AudioFileMetadataWriter.shared.embed(
                AudioMetadataUpdate(
                    metadata: TrackMetadataValues(track: track),
                    artwork: artwork,
                    lyrics: lyrics
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

    private func reconcileMetadataIdentity(
        in proposed: inout [Track],
        changedTrackIDs: Set<Track.ID>,
        fields: Set<TrackMetadataField>
    ) {
        let changesArtist = fields.contains(.artist)
        let changesAlbum = fields.contains(.album)
        guard changesArtist || changesAlbum else { return }

        var artistIDs: [String: UUID] = [:]
        let originalsByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        for track in proposed where !changedTrackIDs.contains(track.id) {
            let artistKey = metadataIdentityKey(track.artist)
            artistIDs[artistKey, default: track.artistID] = track.artistID
        }
        for track in proposed where changedTrackIDs.contains(track.id) {
            guard let original = originalsByID[track.id],
                  metadataIdentityKey(track.artist) == metadataIdentityKey(original.artist)
            else { continue }
            artistIDs[metadataIdentityKey(track.artist), default: original.artistID] = original.artistID
        }

        for index in proposed.indices where changedTrackIDs.contains(proposed[index].id) {
            if changesArtist {
                let key = metadataIdentityKey(proposed[index].artist)
                let artistID = artistIDs[key] ?? UUID()
                artistIDs[key] = artistID
                proposed[index].artistID = artistID
            }
        }

        if !changesAlbum {
            var remappedAlbumIDs: [String: UUID] = [:]
            for index in proposed.indices where changedTrackIDs.contains(proposed[index].id) {
                guard let original = originalsByID[proposed[index].id] else { continue }
                if proposed[index].artistID == original.artistID {
                    proposed[index].albumID = original.albumID
                    continue
                }
                let movesEntireAlbum = tracks
                    .filter { $0.albumID == original.albumID }
                    .allSatisfy { changedTrackIDs.contains($0.id) }
                let key = "\(original.albumID.uuidString):\(proposed[index].artistID.uuidString)"
                let albumID = remappedAlbumIDs[key]
                    ?? (movesEntireAlbum ? original.albumID : UUID())
                remappedAlbumIDs[key] = albumID
                proposed[index].albumID = albumID
            }
            return
        }

        var albumIDs: [String: UUID] = [:]
        for track in proposed where !changedTrackIDs.contains(track.id) {
            albumIDs[metadataAlbumIdentityKey(artistID: track.artistID, album: track.album),
                     default: track.albumID] = track.albumID
        }
        for track in proposed where changedTrackIDs.contains(track.id) {
            guard let original = originalsByID[track.id],
                  track.artistID == original.artistID,
                  metadataIdentityKey(track.album) == metadataIdentityKey(original.album)
            else { continue }
            let key = metadataAlbumIdentityKey(artistID: track.artistID, album: track.album)
            albumIDs[key, default: original.albumID] = original.albumID
        }

        for index in proposed.indices where changedTrackIDs.contains(proposed[index].id) {
            let albumKey = metadataAlbumIdentityKey(
                artistID: proposed[index].artistID,
                album: proposed[index].album
            )
            let albumID = albumIDs[albumKey] ?? UUID()
            albumIDs[albumKey] = albumID
            proposed[index].albumID = albumID
        }
    }

    private func metadataIdentityKey(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func metadataAlbumIdentityKey(artistID: UUID, album: String) -> String {
        "\(artistID.uuidString):\(metadataIdentityKey(album))"
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
            for value in [
                track.title, track.artist, track.album, track.albumArtist,
                track.composer, track.genre, track.grouping, track.comments,
                track.participantCredits, track.workName, track.movementName,
                track.isrc, track.lyrics?.plainText ?? "",
            ] {
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

    private nonisolated static func isReadableRegularAudioFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isReadableKey]
        ) else { return false }
        return values.isRegularFile == true
            && values.isSymbolicLink != true
            && values.isReadable == true
    }

    private nonisolated static func applyLegacyMetadata(
        _ source: LegacyLibraryTrack,
        to track: inout Track
    ) {
        track.title = source.title
        track.artist = source.artist
        track.artistSortName = source.artistSortName
        track.album = source.album
        track.albumSortName = source.albumSortName
        track.albumArtist = source.albumArtist
        track.albumArtistSortName = source.albumArtistSortName
        track.composer = source.composer
        track.composerSortName = source.composerSortName
        track.grouping = source.grouping
        track.genre = source.genre
        track.beatsPerMinute = source.beatsPerMinute
        track.copyright = source.copyright
        track.releaseYear = source.releaseYear
        track.trackNumber = source.trackNumber
        track.trackCount = source.trackCount
        track.discNumber = source.discNumber
        track.discCount = source.discCount
        track.isCompilation = source.isCompilation
        track.rating = source.rating
        track.playCount = source.playCount
        track.comments = source.comments
        track.isFavorite = source.isFavorite
        track.isExcludedFromPlayback = source.isExcludedFromPlayback
        track.addedAt = source.addedAt ?? track.addedAt
    }

    private nonisolated static func applyOngakuMetadata(
        _ source: Track,
        to track: inout Track
    ) {
        track.apply(TrackMetadataValues(track: source), includesTrackSpecificValues: true)
        track.lyrics = source.lyrics
        track.musicBrainzReference = source.musicBrainzReference
        track.addedAt = source.addedAt
        track.isPinned = source.isPinned
        track.isFavorite = source.isFavorite
        track.isExcludedFromPlayback = source.isExcludedFromPlayback
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
        participantCredits = metadata.participantCredits
        workName = metadata.workName
        copyright = metadata.copyright
        releaseYear = metadata.releaseYear
        discNumber = metadata.discNumber
        discCount = metadata.discCount
        isCompilation = metadata.isCompilation
        rating = min(max(metadata.rating, 0), 5)
        playCount = max(0, metadata.playCount)
        comments = metadata.comments
        if includesTrackSpecificValues {
            movementName = metadata.movementName
            movementNumber = metadata.movementNumber
            movementCount = metadata.movementCount
            beatsPerMinute = metadata.beatsPerMinute
            isrc = metadata.isrc
        }
    }

    mutating func apply(_ patch: TrackMetadataPatch) {
        let fields = patch.fields
        let metadata = patch.values
        if fields.contains(.title) { title = metadata.title }
        if fields.contains(.artist) { artist = metadata.artist }
        if fields.contains(.artistSortName) { artistSortName = metadata.artistSortName }
        if fields.contains(.album) { album = metadata.album }
        if fields.contains(.albumSortName) { albumSortName = metadata.albumSortName }
        if fields.contains(.albumArtist) { albumArtist = metadata.albumArtist }
        if fields.contains(.albumArtistSortName) {
            albumArtistSortName = metadata.albumArtistSortName
        }
        if fields.contains(.composer) { composer = metadata.composer }
        if fields.contains(.composerSortName) { composerSortName = metadata.composerSortName }
        if fields.contains(.grouping) { grouping = metadata.grouping }
        if fields.contains(.genre) { genre = metadata.genre }
        if fields.contains(.participantCredits) { participantCredits = metadata.participantCredits }
        if fields.contains(.workName) { workName = metadata.workName }
        if fields.contains(.movementName) { movementName = metadata.movementName }
        if fields.contains(.movementNumber) { movementNumber = metadata.movementNumber }
        if fields.contains(.movementCount) { movementCount = metadata.movementCount }
        if fields.contains(.beatsPerMinute) { beatsPerMinute = metadata.beatsPerMinute }
        if fields.contains(.copyright) { copyright = metadata.copyright }
        if fields.contains(.isrc) { isrc = metadata.isrc }
        if fields.contains(.releaseYear) { releaseYear = metadata.releaseYear }
        if fields.contains(.trackNumber) { trackNumber = metadata.trackNumber }
        if fields.contains(.trackCount) { trackCount = metadata.trackCount }
        if fields.contains(.discNumber) { discNumber = metadata.discNumber }
        if fields.contains(.discCount) { discCount = metadata.discCount }
        if fields.contains(.isCompilation) { isCompilation = metadata.isCompilation }
        if fields.contains(.rating) { rating = min(max(metadata.rating, 0), 5) }
        if fields.contains(.playCount) { playCount = max(0, metadata.playCount) }
        if fields.contains(.comments) { comments = metadata.comments }
    }
}
