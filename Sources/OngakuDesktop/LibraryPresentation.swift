import Foundation

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
    private var duplicates: [DuplicateTrackGroup] = []
    private var totalBytes: Int64 = 0
    private var attentionCount = 0

    func resolve(_ request: LibraryPresentationRequest) throws -> LibraryPresentation {
        try Task.checkCancellation()
        let tracksChanged = tracksRevision != request.tracksRevision
        if tracksChanged {
            var byID: [Track.ID: Track] = [:]
            var bytes: Int64 = 0
            var attention = 0
            byID.reserveCapacity(request.tracks.count)
            for track in request.tracks {
                try Task.checkCancellation()
                byID[track.id] = track
                bytes += track.fileSize
                if track.health != .verified { attention += 1 }
            }
            let groups = DuplicateTrackAnalyzer.groups(in: request.tracks)
            try Task.checkCancellation()
            duplicates = groups
            tracksByID = byID
            totalBytes = bytes
            attentionCount = attention
        }
        if tracksChanged || eventsRevision != request.eventsRevision {
            statistics = PlaybackStatisticsResolver.statistics(
                events: request.events, tracks: request.tracks
            )
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
        if request.section == .albums {
            result.albums = AlbumGroup.makeGroups(from: visible)
            result.albumSections = AlbumSection.makeSections(from: result.albums)
        }
        try Task.checkCancellation()
        if request.section == .artists {
            result.artists = ArtistGroup.makeGroups(from: visible)
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
    let artist: String
    let tracks: [Track]

    let sortedTracks: [Track]
    let totalDuration: TimeInterval

    init(id: UUID, name: String, artist: String, tracks: [Track]) {
        self.id = id
        self.name = name
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
        let grouped = Dictionary(grouping: albums) { AlbumTitleGrouping.initial(for: $0.name) }
        return AlbumTitleGrouping.ordered(grouped.keys).compactMap { initial in
            grouped[initial].map { AlbumSection(initial: initial, albums: $0) }
        }
    }
}
