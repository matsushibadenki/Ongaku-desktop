import Foundation

/// Owns fallback text preparation away from MainActor. Edits retain the text of
/// unchanged rows; changing the query only scans the prepared text. A cancelled
/// preparation cannot publish a partially updated catalog.
actor CatalogFallbackSearchWorker {
    private let maximumTextBytes: Int
    private(set) var cachedTextBytes = 0
    var cachedTrackCount: Int { cachedTracks.count }
    private var libraryID: UUID?
    private var revision = -1
    private var cachedTracks: [Track] = []
    private var cachedText: [String] = []

    init(maximumTextBytes: Int = 64 * 1_024 * 1_024) {
        self.maximumTextBytes = max(0, maximumTextBytes)
    }

    func discardOtherLibrary(_ libraryID: UUID) {
        guard !Task.isCancelled, self.libraryID != libraryID else { return }
        clear()
    }

    /// SQLite has passed parity for this snapshot. Release derived text and
    /// retained Track storage only for the library/revision that it supersedes.
    /// A late or cancelled synchronization must not evict a newer fallback.
    func releaseCache(libraryID: UUID, throughRevision: Int) {
        guard !Task.isCancelled, self.libraryID == libraryID,
              revision <= throughRevision else { return }
        clear()
    }

    private func clear() {
        libraryID = nil
        revision = -1
        cachedTracks = []
        cachedText = []
        cachedTextBytes = 0
    }

    func search(
        tracks: [Track], libraryID: UUID, revision: Int, query: String
    ) throws -> Set<Track.ID> {
        try Task.checkCancellation()
        let normalizedQuery = CatalogSearch.normalize(query)
        var result = Set<Track.ID>()
        if self.libraryID != libraryID || self.revision != revision {
            var preparedText: [String]? = []
            preparedText?.reserveCapacity(tracks.count)
            var textBytes = 0
            for index in tracks.indices {
                try Task.checkCancellation()
                let text: String
                if self.libraryID == libraryID, cachedTracks.indices.contains(index),
                   cachedTracks[index] == tracks[index] {
                    text = cachedText[index]
                } else {
                    text = CatalogSearch.searchableText(for: tracks[index])
                }
                if normalizedQuery.isEmpty || text.contains(normalizedQuery) {
                    result.insert(tracks[index].id)
                }
                if preparedText != nil {
                    let bytes = text.utf8.count
                    if bytes <= maximumTextBytes - textBytes {
                        textBytes += bytes
                        preparedText?.append(text)
                    } else {
                        // Oversized catalogs still search correctly, but their
                        // derived text is streamed rather than kept in memory.
                        preparedText = nil
                    }
                }
            }
            try Task.checkCancellation()
            if let preparedText {
                cachedTracks = tracks
                cachedText = preparedText
                cachedTextBytes = textBytes
                self.libraryID = libraryID
                self.revision = revision
            } else {
                clear()
            }
            return result
        }
        for index in cachedTracks.indices {
            try Task.checkCancellation()
            if normalizedQuery.isEmpty || cachedText[index].contains(normalizedQuery) {
                result.insert(cachedTracks[index].id)
            }
        }
        return result
    }
}

/// Immutable input captured on MainActor. The worker owns all full-catalog
/// derivation; publishing a result never reads mutable UI state off actor.
struct LibraryPresentationRequest: Sendable {
    let tracks: [Track]
    let events: [PlaybackEvent]
    let tracksRevision: Int
    let eventsRevision: Int
    let section: LibrarySection
    let playlist: Playlist?
    let filter: LibraryFilterCriteria
    let searchIDs: Set<Track.ID>?
    let audioFeatures: [Track.ID: AudioFeatureAnalysis]
}

struct LibraryPresentation: Sendable {
    var tracks: [Track] = []
    var mixCandidates: [OngakuMixCandidate] = []
    var mixSeed: Track?
    var albums: [AlbumGroup] = []
    var artists: [ArtistGroup] = []
    var albumSections: [AlbumSection] = []
    var duplicates: [DuplicateTrackGroup] = []
    var allDuplicates: [DuplicateTrackGroup] = []
    var statistics: [Track.ID: TrackPlaybackStatistics] = [:]
    var tracksByID: [Track.ID: Track] = [:]
    var totalBytes: Int64 = 0
    var attentionCount = 0
}

/// Serial ownership avoids overlapping large allocations when users quickly
/// change sections. Cancelled requests cannot replace the published snapshot.
actor LibraryPresentationWorker {
    private var tracksRevision = -1
    private var eventsRevision = -1
    private var tracksByID: [Track.ID: Track] = [:]
    private var statistics: [Track.ID: TrackPlaybackStatistics] = [:]
    private var historyStatistics: [Track.ID: TrackPlaybackStatistics] = [:]
    private var duplicates: [DuplicateTrackGroup] = []
    private var duplicateCandidateKeys: [Track.ID: String] = [:]
    private let maximumDuplicateKeyBytes: Int
    private(set) var cachedDuplicateKeyBytes = 0

    init(maximumDuplicateKeyBytes: Int = 16 * 1_024 * 1_024) {
        self.maximumDuplicateKeyBytes = max(0, maximumDuplicateKeyBytes)
    }

    private var totalBytes: Int64 = 0
    private var attentionCount = 0
    private var cachedAlbums: [AlbumGroup]?
    private var cachedAlbumSections: [AlbumSection]?
    private var cachedArtists: [ArtistGroup]?

    func resolve(_ request: LibraryPresentationRequest) throws -> LibraryPresentation {
        try Task.checkCancellation()
        let tracksChanged = tracksRevision != request.tracksRevision
        if tracksChanged {
            cachedAlbums = nil
            cachedAlbumSections = nil
            cachedArtists = nil
            var byID: [Track.ID: Track] = [:]
            var candidateKeys: [Track.ID: String] = [:]
            candidateKeys.reserveCapacity(min(request.tracks.count, maximumDuplicateKeyBytes))
            var candidateKeyBytes = 0
            var bytes: Int64 = 0
            var attention = 0
            var membershipChanged = tracksByID.count != request.tracks.count
            byID.reserveCapacity(request.tracks.count)
            for track in request.tracks {
                try Task.checkCancellation()
                if let previous = tracksByID[track.id] {
                    if previous.title != track.title || previous.artist != track.artist
                        || previous.duration != track.duration || previous.sha256 != track.sha256 {
                        membershipChanged = true
                    }
                } else {
                    membershipChanged = true
                }
                if candidateKeyBytes < maximumDuplicateKeyBytes {
                    let key: String
                    if let previous = tracksByID[track.id],
                        previous.title == track.title, previous.artist == track.artist,
                        let cached = duplicateCandidateKeys[track.id] {
                        key = cached
                    } else {
                        key = DuplicateTrackAnalyzer.candidateKey(for: track)
                    }
                    let keyBytes = key.utf8.count
                    if keyBytes <= maximumDuplicateKeyBytes - candidateKeyBytes {
                        candidateKeys[track.id] = key
                        candidateKeyBytes += keyBytes
                    }
                    // The analyzer computes uncached keys when needed; reaching
                    // the retention budget never drops tracks from analysis.
                }
                byID[track.id] = track
                bytes += track.fileSize
                if track.health != .verified { attention += 1 }
            }
            let groups = membershipChanged
                ? DuplicateTrackAnalyzer.groups(in: request.tracks, candidateKeys: candidateKeys)
                : DuplicateTrackAnalyzer.refreshedGroups(duplicates, tracksByID: byID)
            try Task.checkCancellation()
            duplicateCandidateKeys = candidateKeys
            cachedDuplicateKeyBytes = candidateKeyBytes
            duplicates = groups
            tracksByID = byID
            totalBytes = bytes
            attentionCount = attention
        }
        if tracksChanged || eventsRevision != request.eventsRevision {
            let history = eventsRevision == request.eventsRevision
                ? historyStatistics
                : PlaybackStatisticsResolver.statistics(events: request.events)
            try Task.checkCancellation()
            var combined = history
            for track in request.tracks {
                try Task.checkCancellation()
                var value = history[track.id] ?? TrackPlaybackStatistics()
                value.playCount += track.playCount
                value.skipCount += track.syncedSkipCount
                if let syncedDate = track.syncedLastPlayedAt,
                   value.lastPlayedAt.map({ syncedDate > $0 }) ?? true {
                    value.lastPlayedAt = syncedDate
                }
                combined[track.id] = value
            }
            try Task.checkCancellation()
            historyStatistics = history
            statistics = combined
            // Commit the cache keys only after every dependent cache is ready.
            tracksRevision = request.tracksRevision
            eventsRevision = request.eventsRevision
        }
        try Task.checkCancellation()
        var visible: [Track]
        var mixCandidates: [OngakuMixCandidate] = []
        var mixSeed: Track?
        if let playlist = request.playlist {
            if let definition = playlist.smartDefinition {
                visible = SmartPlaylistResolver.tracks(
                    matching: definition, tracks: request.tracks, statistics: statistics
                )
            } else {
                visible = playlist.entries.compactMap { tracksByID[$0.trackID] }
            }
        } else if request.section == .ongakuMix {
            mixSeed = OngakuMixResolver.seed(in: request.tracks, events: request.events)
            mixCandidates = OngakuMixResolver.candidates(
                tracks: request.tracks, events: request.events,
                seedTrackID: mixSeed?.id, audioFeatures: request.audioFeatures
            )
            visible = mixCandidates.map(\.track)
        } else if request.section == .duplicates {
            let ids = Set(duplicates.flatMap { $0.tracks.map(\.id) })
            visible = request.tracks.filter { ids.contains($0.id) }
        } else {
            visible = StandardLibraryResolver.tracks(
                for: request.section, tracks: request.tracks, events: request.events,
                audioFeatures: request.audioFeatures, statistics: statistics
            )
        }
        try Task.checkCancellation()
        if request.filter.activeCount > 0 || request.searchIDs != nil {
            visible = try visible.filter { track in
                try Task.checkCancellation()
                return request.filter.matches(track)
                    && (request.searchIDs?.contains(track.id) ?? true)
            }
        }
        var result = LibraryPresentation(
            tracks: visible, mixCandidates: mixCandidates, mixSeed: mixSeed, allDuplicates: duplicates, statistics: statistics, tracksByID: tracksByID,
            totalBytes: totalBytes, attentionCount: attentionCount
        )
        let canReuseGroups = request.playlist == nil
            && request.filter.activeCount == 0 && request.searchIDs == nil
        if request.section == .albums {
            if canReuseGroups, let cachedAlbums, let cachedAlbumSections {
                result.albums = cachedAlbums
                result.albumSections = cachedAlbumSections
            } else {
                result.albums = AlbumGroup.makeGroups(from: visible)
                result.albumSections = AlbumSection.makeSections(from: result.albums)
                try Task.checkCancellation()
                if canReuseGroups {
                    cachedAlbums = result.albums
                    cachedAlbumSections = result.albumSections
                }
            }
        }
        try Task.checkCancellation()
        if request.section == .artists {
            if canReuseGroups, let cachedArtists {
                result.artists = cachedArtists
            } else {
                result.artists = ArtistGroup.makeGroups(from: visible)
                try Task.checkCancellation()
                if canReuseGroups { cachedArtists = result.artists }
            }
        }
        if request.section == .duplicates {
            // Analyze the complete catalog first so filters do not hide a
            // matching group's other copies from the resolution workflow.
            let visibleIDs = Set(visible.map(\.id))
            result.duplicates = duplicates.filter {
                $0.tracks.contains { visibleIDs.contains($0.id) }
            }
        }
        try Task.checkCancellation()
        return result
    }
}

struct AlbumGroup: Identifiable, Sendable {
    let id: UUID
    let name: String
    let sortName: String
    let artist: String
    let tracks: [Track]

    let sortedTracks: [Track]
    let totalDuration: TimeInterval

    init(id: UUID, name: String, sortName: String = "", artist: String, tracks: [Track]) {
        self.id = id
        self.name = name
        self.sortName = sortName
        self.artist = artist
        self.tracks = tracks
        sortedTracks = tracks.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        totalDuration = tracks.reduce(0) { $0 + $1.duration }
    }

    static func makeGroups(from tracks: [Track]) -> [AlbumGroup] {
        let groups = Dictionary(grouping: tracks, by: \.albumID)
        return groups.values.compactMap { group in
            guard let first = group.first else { return nil }
            return AlbumGroup(
                id: first.albumID,
                name: first.album,
                sortName: first.albumSortName,
                artist: first.artist,
                tracks: group
            )
        }
        .sorted {
            AlbumDisplayOrdering.areInIncreasingOrder(
                lhsName: $0.name,
                lhsArtist: $0.artist,
                lhsID: $0.id,
                rhsName: $1.name,
                rhsArtist: $1.artist,
                rhsID: $1.id
            )
        }
    }
}

struct ArtistGroup: Identifiable, Sendable {
    let id: UUID
    let name: String
    let tracks: [Track]
    let albumCount: Int
    let sortedTracks: [Track]
    let albums: [AlbumGroup]

    init(id: UUID, name: String, tracks: [Track]) {
        self.id = id
        self.name = name
        self.tracks = tracks
        albums = AlbumGroup.makeGroups(from: tracks)
        albumCount = albums.count
        sortedTracks = tracks.sorted {
            let albumComparison = $0.album.localizedStandardCompare($1.album)
            if albumComparison != .orderedSame { return albumComparison == .orderedAscending }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    static func makeGroups(from tracks: [Track]) -> [ArtistGroup] {
        Dictionary(grouping: tracks, by: \.artistID).compactMap { artistID, songs in
            guard let artist = songs.first?.artist else { return nil }
            return ArtistGroup(id: artistID, name: artist, tracks: songs)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

enum AlbumTitleGrouping {
    static let miscellaneousInitial = "#"

    static func initial(for title: String, locale: Locale = .current) -> String {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: locale
            )
        guard let firstCharacter = normalized.first else { return miscellaneousInitial }
        let initial = String(firstCharacter)
        guard initial.unicodeScalars.contains(where: CharacterSet.letters.contains) else {
            return miscellaneousInitial
        }
        return initial.uppercased(with: locale)
    }

    static func initial(
        for title: String,
        preferredReading: String,
        locale: Locale = .current
    ) -> String {
        let reading = preferredReading.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reading.isEmpty, containsJapaneseTitleCharacters(title) else {
            return initial(for: title, locale: locale)
        }
        return initial(for: reading, locale: locale)
    }

    private static func containsJapaneseTitleCharacters(_ title: String) -> Bool {
        title.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040 ... 0x30FF, // Hiragana and Katakana
                 0x3400 ... 0x4DBF, // CJK Extension A
                 0x4E00 ... 0x9FFF: // CJK Unified Ideographs
                true
            default:
                false
            }
        }
    }

    static func ordered(_ initials: some Sequence<String>, locale: Locale = .current) -> [String] {
        initials.sorted { lhs, rhs in
            if lhs == miscellaneousInitial { return false }
            if rhs == miscellaneousInitial { return true }
            return lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
                == .orderedAscending
        }
    }
}

enum AlbumDisplayOrdering {
    static func areInIncreasingOrder(
        lhsName: String,
        lhsArtist: String,
        lhsID: UUID,
        rhsName: String,
        rhsArtist: String,
        rhsID: UUID
    ) -> Bool {
        let nameComparison = lhsName.localizedStandardCompare(rhsName)
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }

        let artistComparison = lhsArtist.localizedStandardCompare(rhsArtist)
        if artistComparison != .orderedSame {
            return artistComparison == .orderedAscending
        }

        return lhsID.uuidString < rhsID.uuidString
    }
}

struct AlbumSection: Identifiable, Sendable {
    let initial: String
    let albums: [AlbumGroup]
    var id: String { initial }

    static func makeSections(from albums: [AlbumGroup]) -> [AlbumSection] {
        let grouped = Dictionary(grouping: albums) {
            AlbumTitleGrouping.initial(for: $0.name, preferredReading: $0.sortName)
        }
        return AlbumTitleGrouping.ordered(grouped.keys).compactMap { initial in
            grouped[initial].map { AlbumSection(initial: initial, albums: $0) }
        }
    }
}
