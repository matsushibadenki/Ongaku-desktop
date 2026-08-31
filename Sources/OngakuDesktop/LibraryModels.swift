import Foundation

enum LibrarySection: String, CaseIterable, Identifiable, Sendable {
    case songs
    case albums
    case artists
    case pinned
    case recentlyAdded
    case frequentlyPlayed
    case recentlyPlayed
    case favorites
    case ongakuMix
    case duplicates
    case needsAttention
    case effects

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .songs: "sidebar.songs"
        case .albums: "sidebar.albums"
        case .artists: "sidebar.artists"
        case .pinned: "sidebar.pinned"
        case .recentlyAdded: "sidebar.recent"
        case .frequentlyPlayed: "sidebar.frequentlyPlayed"
        case .recentlyPlayed: "sidebar.recentlyPlayed"
        case .favorites: "sidebar.favorites"
        case .ongakuMix: "sidebar.ongakuMix"
        case .duplicates: "sidebar.duplicates"
        case .needsAttention: "sidebar.attention"
        case .effects: "sidebar.effects"
        }
    }

    var systemImage: String {
        switch self {
        case .songs: "music.note.list"
        case .albums: "square.stack"
        case .artists: "music.mic"
        case .pinned: "pin.fill"
        case .recentlyAdded: "clock"
        case .frequentlyPlayed: "chart.bar.fill"
        case .recentlyPlayed: "clock.arrow.circlepath"
        case .favorites: "heart.fill"
        case .ongakuMix: "wand.and.stars"
        case .duplicates: "square.on.square"
        case .needsAttention: "exclamationmark.shield"
        case .effects: "dial.medium"
        }
    }

    var preservesResolvedOrder: Bool {
        switch self {
        case .recentlyAdded, .frequentlyPlayed, .recentlyPlayed, .ongakuMix: true
        default: false
        }
    }
}

enum FileHealth: String, Codable, CaseIterable, Sendable {
    case verified
    case unchecked
    case missing
    case changed
    case unreadable

    var titleKey: String { "health.\(rawValue)" }

    var symbol: String {
        switch self {
        case .verified: "checkmark.shield"
        case .unchecked: "questionmark.diamond"
        case .missing: "folder.badge.questionmark"
        case .changed: "exclamationmark.triangle"
        case .unreadable: "xmark.octagon"
        }
    }
}

enum LyricsSource: String, Codable, Sendable {
    case embedded
    case manual
    case lrcFile
    case lrclib
}

struct TimedLyricsLine: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var time: TimeInterval
    var text: String
}

struct TrackLyrics: Codable, Hashable, Sendable {
    var plainText: String
    var syncedLines: [TimedLyricsLine] = []
    var source: LyricsSource
    var sourceIdentifier: String?
    var updatedAt: Date = .now
    var isManuallyEdited = false

    var isSynced: Bool { !syncedLines.isEmpty }
}

enum LRCParserError: Error, Equatable {
    case noTimedLines
}

enum LRCParser {
    private static let timestampPattern = #"\[(\d{1,3}):(\d{2})(?:[\.:](\d{1,3}))?\]"#
    private static let offsetPattern = #"^\[offset:([+-]?\d+)\]$"#

    static func parse(
        _ contents: String,
        source: LyricsSource = .lrcFile,
        updatedAt: Date = .now
    ) throws -> TrackLyrics {
        let timestampExpression = try NSRegularExpression(pattern: timestampPattern)
        let offsetExpression = try NSRegularExpression(
            pattern: offsetPattern,
            options: [.caseInsensitive]
        )
        var offsetMilliseconds = 0
        var parsedLines: [TimedLyricsLine] = []

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = offsetExpression.firstMatch(in: line, range: fullRange),
               let range = Range(match.range(at: 1), in: line) {
                offsetMilliseconds = Int(line[range]) ?? 0
                continue
            }

            let matches = timestampExpression.matches(in: line, range: fullRange)
            guard !matches.isEmpty else { continue }
            let text = timestampExpression
                .stringByReplacingMatches(in: line, range: fullRange, withTemplate: "")
                .trimmingCharacters(in: .whitespaces)
            for match in matches {
                guard let minuteRange = Range(match.range(at: 1), in: line),
                      let secondRange = Range(match.range(at: 2), in: line),
                      let minutes = Double(line[minuteRange]),
                      let seconds = Double(line[secondRange]) else { continue }
                let fraction: Double
                if let fractionRange = Range(match.range(at: 3), in: line) {
                    let digits = String(line[fractionRange])
                    fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
                } else {
                    fraction = 0
                }
                parsedLines.append(TimedLyricsLine(
                    time: max(0, minutes * 60 + seconds + fraction),
                    text: text
                ))
            }
        }

        guard !parsedLines.isEmpty else { throw LRCParserError.noTimedLines }
        let offset = Double(offsetMilliseconds) / 1_000
        parsedLines = parsedLines.map {
            TimedLyricsLine(id: $0.id, time: max(0, $0.time + offset), text: $0.text)
        }
        .sorted {
            if $0.time != $1.time { return $0.time < $1.time }
            return $0.id.uuidString < $1.id.uuidString
        }
        return TrackLyrics(
            plainText: parsedLines.map(\.text).joined(separator: "\n"),
            syncedLines: parsedLines,
            source: source,
            updatedAt: updatedAt,
            isManuallyEdited: source == .manual
        )
    }

    static func serialize(_ lines: [TimedLyricsLine]) -> String {
        lines.sorted { $0.time < $1.time }.map { line in
            let hundredths = Int((max(0, line.time) * 100).rounded())
            let minutes = hundredths / 6_000
            let seconds = (hundredths / 100) % 60
            let fraction = hundredths % 100
            return String(format: "[%02d:%02d.%02d]%@", minutes, seconds, fraction, line.text)
        }
        .joined(separator: "\n")
    }
}

enum LyricsTimeline {
    static func activeLineID(
        in lines: [TimedLyricsLine],
        at time: TimeInterval
    ) -> TimedLyricsLine.ID? {
        lines.last(where: { $0.time <= max(0, time) })?.id
    }
}

struct Track: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    var artist: String
    var album: String
    var artistSortName: String = ""
    var albumSortName: String = ""
    var albumArtist: String = ""
    var albumArtistSortName: String = ""
    var composer: String = ""
    var composerSortName: String = ""
    var grouping: String = ""
    var genre: String = ""
    var participantCredits: String = ""
    var workName: String = ""
    var movementName: String = ""
    var movementNumber: Int?
    var movementCount: Int?
    var beatsPerMinute: Int?
    var copyright: String = ""
    var isrc: String = ""
    var releaseYear: Int?
    var trackNumber: Int?
    var trackCount: Int?
    var discNumber: Int?
    var discCount: Int?
    var isCompilation: Bool = false
    var playCount: Int = 0
    var syncedSkipCount: Int = 0
    var syncedLastPlayedAt: Date? = nil
    var syncedOverlayUpdatedAt: Date? = nil
    var comments: String = ""
    var lyrics: TrackLyrics? = nil
    var musicBrainzReference: MusicBrainzReference? = nil
    var duration: TimeInterval
    var fileSize: Int64
    var managedPath: String
    var sha256: String
    var addedAt: Date
    var lastVerifiedAt: Date?
    var health: FileHealth
    var artistID: UUID = UUID()
    var albumID: UUID = UUID()
    var isPinned: Bool = false
    var isFavorite: Bool = false
    var rating: Int = 0
    var isExcludedFromPlayback: Bool = false

    var fileURL: URL { URL(fileURLWithPath: managedPath) }
}

enum DuplicateMatchKind: String, Sendable {
    case exact
    case possible

    var titleKey: String { "duplicates.kind.\(rawValue)" }
}

struct DuplicateTrackGroup: Identifiable, Sendable {
    let id: String
    let kind: DuplicateMatchKind
    let tracks: [Track]
    let recommendedTrackID: Track.ID
}

struct DuplicateResolutionResult: Sendable {
    let removedCount: Int
    let trashedFileCount: Int
    let retainedFileCount: Int
    let failedFileNames: [String]
}

enum DuplicateTrackAnalyzer {
    nonisolated static func groups(in tracks: [Track]) -> [DuplicateTrackGroup] {
        guard tracks.count > 1 else { return [] }
        var sets = DuplicateTrackDisjointSet(ids: tracks.map(\.id))

        for matches in Dictionary(grouping: tracks.filter { !$0.sha256.isEmpty }, by: \.sha256)
            .values where matches.count > 1 {
            guard let first = matches.first else { continue }
            for track in matches.dropFirst() { sets.union(first.id, track.id) }
        }

        let candidates = Dictionary(grouping: tracks) { track in
            "\(normalized(track.title))\u{1f}\(normalized(track.artist))"
        }
        for (key, matches) in candidates where !key.hasPrefix("\u{1f}") && matches.count > 1 {
            let ordered = matches.sorted { $0.duration < $1.duration }
            for index in ordered.indices.dropLast() {
                let next = ordered.index(after: index)
                if ordered[next].duration - ordered[index].duration <= 3 {
                    sets.union(ordered[index].id, ordered[next].id)
                }
            }
        }

        let grouped = Dictionary(grouping: tracks) { sets.root(of: $0.id) }
        return grouped.values.compactMap { matches in
            guard matches.count > 1 else { return nil }
            let ordered = matches.sorted(by: isPreferred)
            let hashes = Set(matches.map(\.sha256).filter { !$0.isEmpty })
            let kind: DuplicateMatchKind = hashes.count == 1 && !hashes.isEmpty
                ? .exact : .possible
            let ids = matches.map { $0.id.uuidString }.sorted().joined(separator: ":")
            return DuplicateTrackGroup(
                id: ids,
                kind: kind,
                tracks: ordered,
                recommendedTrackID: ordered[0].id
            )
        }
        .sorted {
            if $0.kind != $1.kind { return $0.kind == .exact }
            let lhs = $0.tracks.first?.title ?? ""
            let rhs = $1.tracks.first?.title ?? ""
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    private nonisolated static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .unicodeScalars
        .filter { CharacterSet.alphanumerics.contains($0) }
        .map(String.init)
        .joined()
    }

    private nonisolated static func isPreferred(_ lhs: Track, _ rhs: Track) -> Bool {
        let lhsScore = preferenceScore(lhs)
        let rhsScore = preferenceScore(rhs)
        if lhsScore != rhsScore { return lhsScore > rhsScore }
        if lhs.addedAt != rhs.addedAt { return lhs.addedAt < rhs.addedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private nonisolated static func preferenceScore(_ track: Track) -> Int64 {
        let metadata = [
            track.album, track.albumArtist, track.composer, track.genre,
            track.comments, track.isrc, track.workName,
        ].count { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let verified = track.health == .verified ? 1_000_000_000 as Int64 : 0
        let bitrate = track.duration > 0
            ? min(Int64(Double(track.fileSize) / track.duration), 100_000_000) : 0
        return verified + bitrate + Int64(metadata * 1_000)
    }
}

private struct DuplicateTrackDisjointSet {
    private var parent: [Track.ID: Track.ID]

    init(ids: [Track.ID]) {
        parent = Dictionary(uniqueKeysWithValues: ids.map { ($0, $0) })
    }

    mutating func root(of id: Track.ID) -> Track.ID {
        guard let direct = parent[id], direct != id else { return id }
        let resolved = root(of: direct)
        parent[id] = resolved
        return resolved
    }

    mutating func union(_ lhs: Track.ID, _ rhs: Track.ID) {
        let lhsRoot = root(of: lhs)
        let rhsRoot = root(of: rhs)
        guard lhsRoot != rhsRoot else { return }
        if lhsRoot.uuidString < rhsRoot.uuidString { parent[rhsRoot] = lhsRoot }
        else { parent[lhsRoot] = rhsRoot }
    }
}

struct TrackMetadataValues: Equatable, Sendable {
    var title: String
    var artist: String
    var artistSortName: String
    var album: String
    var albumSortName: String
    var albumArtist: String
    var albumArtistSortName: String
    var composer: String
    var composerSortName: String
    var grouping: String
    var genre: String
    var participantCredits: String
    var workName: String
    var movementName: String
    var movementNumber: Int?
    var movementCount: Int?
    var beatsPerMinute: Int?
    var copyright: String
    var isrc: String
    var releaseYear: Int?
    var trackNumber: Int?
    var trackCount: Int?
    var discNumber: Int?
    var discCount: Int?
    var isCompilation: Bool
    var rating: Int
    var playCount: Int
    var comments: String

    init(
        title: String,
        artist: String,
        artistSortName: String,
        album: String,
        albumSortName: String,
        albumArtist: String,
        albumArtistSortName: String,
        composer: String,
        composerSortName: String,
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
        rating: Int,
        playCount: Int,
        comments: String
    ) {
        self.title = title
        self.artist = artist
        self.artistSortName = artistSortName
        self.album = album
        self.albumSortName = albumSortName
        self.albumArtist = albumArtist
        self.albumArtistSortName = albumArtistSortName
        self.composer = composer
        self.composerSortName = composerSortName
        self.grouping = grouping
        self.genre = genre
        self.participantCredits = participantCredits
        self.workName = workName
        self.movementName = movementName
        self.movementNumber = movementNumber
        self.movementCount = movementCount
        self.beatsPerMinute = beatsPerMinute
        self.copyright = copyright
        self.isrc = isrc
        self.releaseYear = releaseYear
        self.trackNumber = trackNumber
        self.trackCount = trackCount
        self.discNumber = discNumber
        self.discCount = discCount
        self.isCompilation = isCompilation
        self.rating = rating
        self.playCount = playCount
        self.comments = comments
    }

    init(track: Track) {
        title = track.title
        artist = track.artist
        artistSortName = track.artistSortName
        album = track.album
        albumSortName = track.albumSortName
        albumArtist = track.albumArtist
        albumArtistSortName = track.albumArtistSortName
        composer = track.composer
        composerSortName = track.composerSortName
        grouping = track.grouping
        genre = track.genre
        participantCredits = track.participantCredits
        workName = track.workName
        movementName = track.movementName
        movementNumber = track.movementNumber
        movementCount = track.movementCount
        beatsPerMinute = track.beatsPerMinute
        copyright = track.copyright
        isrc = track.isrc
        releaseYear = track.releaseYear
        trackNumber = track.trackNumber
        trackCount = track.trackCount
        discNumber = track.discNumber
        discCount = track.discCount
        isCompilation = track.isCompilation
        rating = track.rating
        playCount = track.playCount
        comments = track.comments
    }
}

enum TrackMetadataField: String, CaseIterable, Hashable, Sendable {
    case title
    case artist
    case artistSortName
    case album
    case albumSortName
    case albumArtist
    case albumArtistSortName
    case composer
    case composerSortName
    case grouping
    case genre
    case participantCredits
    case workName
    case movementName
    case movementNumber
    case movementCount
    case beatsPerMinute
    case copyright
    case isrc
    case releaseYear
    case trackNumber
    case trackCount
    case discNumber
    case discCount
    case isCompilation
    case rating
    case playCount
    case comments
}

struct TrackMetadataPatch: Equatable, Sendable {
    var fields: Set<TrackMetadataField>
    var values: TrackMetadataValues

    var isEmpty: Bool { fields.isEmpty }
}

enum CatalogSearch {
    static func normalize(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    static func matches(_ track: Track, query: String) -> Bool {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return true }
        return searchableText(for: track).contains(normalizedQuery)
    }

    static func searchableText(for track: Track) -> String {
        let lyrics = track.lyrics.map { value in
            ([value.plainText] + value.syncedLines.map(\.text)).joined(separator: " ")
        } ?? ""
        let musicBrainz = track.musicBrainzReference.map { reference in
            [
                reference.recordingID,
                Optional(reference.releaseID),
                reference.releaseGroupID,
                Optional(reference.artistIDs.joined(separator: " ")),
                reference.country,
                reference.mediaFormat,
            ].compactMap { $0 }.joined(separator: " ")
        } ?? ""
        let numbers = [
            track.releaseYear, track.trackNumber, track.trackCount,
            track.discNumber, track.discCount, track.movementNumber,
            track.movementCount, track.beatsPerMinute, track.rating,
            track.playCount,
        ].compactMap { $0.map(String.init) }
        return normalize(([
            track.title, track.artist, track.artistSortName,
            track.album, track.albumSortName, track.albumArtist,
            track.albumArtistSortName, track.composer, track.composerSortName,
            track.grouping, track.genre, track.participantCredits,
            track.workName, track.movementName, track.copyright,
            track.isrc, track.comments, lyrics, musicBrainz,
            track.fileURL.lastPathComponent,
        ] + numbers).joined(separator: "\u{1f}"))
    }
}

struct LibraryFilterCriteria: Equatable, Hashable, Sendable {
    var artist = ""
    var album = ""
    var composer = ""
    var genre = ""
    var minimumYear: Int?
    var maximumYear: Int?
    var minimumRating = 0
    var favoritesOnly = false
    var compilationsOnly = false
    var health: FileHealth?

    var activeCount: Int {
        [artist, album, composer, genre].count {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        + (minimumYear == nil ? 0 : 1)
        + (maximumYear == nil ? 0 : 1)
        + (minimumRating == 0 ? 0 : 1)
        + (favoritesOnly ? 1 : 0)
        + (compilationsOnly ? 1 : 0)
        + (health == nil ? 0 : 1)
    }

    func matches(_ track: Track) -> Bool {
        if !contains(track.artist, query: artist) { return false }
        if !contains(track.album, query: album) { return false }
        if !contains(track.composer, query: composer) { return false }
        if !contains(track.genre, query: genre) { return false }
        if let minimumYear, (track.releaseYear ?? Int.min) < minimumYear { return false }
        if let maximumYear, (track.releaseYear ?? Int.max) > maximumYear { return false }
        if track.rating < minimumRating { return false }
        if favoritesOnly && !track.isFavorite { return false }
        if compilationsOnly && !track.isCompilation { return false }
        if let health, track.health != health { return false }
        return true
    }

    private func contains(_ value: String, query: String) -> Bool {
        let normalizedQuery = CatalogSearch.normalize(query)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedQuery.isEmpty || CatalogSearch.normalize(value).contains(normalizedQuery)
    }
}

struct PlaylistEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var trackID: Track.ID
    var addedAt: Date

    init(id: UUID = UUID(), trackID: Track.ID, addedAt: Date = .now) {
        self.id = id
        self.trackID = trackID
        self.addedAt = addedAt
    }
}

enum SmartPlaylistMatchMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case all
    case any
    var id: String { rawValue }
}

enum SmartPlaylistField: String, Codable, CaseIterable, Identifiable, Sendable {
    case title
    case artist
    case album
    case favorite
    case rating
    case playCount
    case skipCount
    var id: String { rawValue }

    var isBoolean: Bool { self == .favorite }
    var isNumeric: Bool { [.rating, .playCount, .skipCount].contains(self) }
}

enum SmartPlaylistComparison: String, Codable, CaseIterable, Identifiable, Sendable {
    case contains
    case equals
    case notEquals
    case atLeast
    case atMost
    case isTrue
    case isFalse
    var id: String { rawValue }
}

struct SmartPlaylistRule: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var field: SmartPlaylistField = .title
    var comparison: SmartPlaylistComparison = .contains
    var value: String = ""
}

struct SmartPlaylistRuleGroup: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var mode: SmartPlaylistMatchMode = .all
    var rules: [SmartPlaylistRule] = [SmartPlaylistRule()]
    var groups: [SmartPlaylistRuleGroup] = []
}

struct SmartPlaylistDefinition: Codable, Hashable, Sendable {
    var root: SmartPlaylistRuleGroup = SmartPlaylistRuleGroup()
    var limit: Int?
}

struct Playlist: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var description: String
    var artworkPath: String?
    var folderID: PlaylistFolder.ID?
    var sortOrder: Int
    var smartDefinition: SmartPlaylistDefinition?
    var entries: [PlaylistEntry]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        description: String = "",
        artworkPath: String? = nil,
        folderID: PlaylistFolder.ID? = nil,
        sortOrder: Int = 0,
        smartDefinition: SmartPlaylistDefinition? = nil,
        entries: [PlaylistEntry] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.artworkPath = artworkPath
        self.folderID = folderID
        self.sortOrder = sortOrder
        self.smartDefinition = smartDefinition
        self.entries = entries
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, description, artworkPath, folderID, sortOrder, smartDefinition
        case entries, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        description = try values.decodeIfPresent(String.self, forKey: .description) ?? ""
        artworkPath = try values.decodeIfPresent(String.self, forKey: .artworkPath)
        folderID = try values.decodeIfPresent(PlaylistFolder.ID.self, forKey: .folderID)
        sortOrder = try values.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        smartDefinition = try values.decodeIfPresent(
            SmartPlaylistDefinition.self,
            forKey: .smartDefinition
        )
        entries = try values.decodeIfPresent([PlaylistEntry].self, forKey: .entries) ?? []
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }
}

enum SmartPlaylistResolver {
    static func tracks(
        matching definition: SmartPlaylistDefinition,
        tracks: [Track],
        statistics: [Track.ID: TrackPlaybackStatistics]
    ) -> [Track] {
        let matchedTracks = tracks.filter {
            matches(definition.root, track: $0, statistics: statistics[$0.id] ?? .init())
        }
        guard let limit = definition.limit, limit > 0 else { return matchedTracks }
        return Array(matchedTracks.prefix(limit))
    }

    private static func matches(
        _ group: SmartPlaylistRuleGroup,
        track: Track,
        statistics: TrackPlaybackStatistics
    ) -> Bool {
        let results = group.rules.map {
            matches($0, track: track, statistics: statistics)
        } + group.groups.map {
            matches($0, track: track, statistics: statistics)
        }
        guard !results.isEmpty else { return true }
        return group.mode == .all ? results.allSatisfy { $0 } : results.contains(true)
    }

    private static func matches(
        _ rule: SmartPlaylistRule,
        track: Track,
        statistics: TrackPlaybackStatistics
    ) -> Bool {
        if rule.field.isBoolean {
            let value = track.isFavorite
            return rule.comparison == .isTrue ? value : !value
        }
        if rule.field.isNumeric {
            let actual: Int = switch rule.field {
            case .rating: track.rating
            case .playCount: statistics.playCount
            case .skipCount: statistics.skipCount
            default: 0
            }
            let expected = Int(rule.value) ?? 0
            return switch rule.comparison {
            case .equals: actual == expected
            case .notEquals: actual != expected
            case .atLeast: actual >= expected
            case .atMost: actual <= expected
            default: false
            }
        }
        let actual: String = switch rule.field {
        case .title: track.title
        case .artist: track.artist
        case .album: track.album
        default: ""
        }
        let normalizedActual = CatalogSearch.normalize(actual)
        let normalizedExpected = CatalogSearch.normalize(rule.value)
        return switch rule.comparison {
        case .contains: normalizedActual.contains(normalizedExpected)
        case .equals: normalizedActual == normalizedExpected
        case .notEquals: normalizedActual != normalizedExpected
        default: false
        }
    }
}

struct PlaylistFolder: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        sortOrder: Int = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct PlaybackEvent: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case started
        case completed
        case skipped
    }

    let id: UUID
    var trackID: Track.ID
    var kind: Kind
    var occurredAt: Date
    var position: TimeInterval
    var playbackSessionID: UUID

    init(
        id: UUID = UUID(),
        trackID: Track.ID,
        kind: Kind,
        occurredAt: Date = .now,
        position: TimeInterval = 0,
        playbackSessionID: UUID = UUID()
    ) {
        self.id = id
        self.trackID = trackID
        self.kind = kind
        self.occurredAt = occurredAt
        self.position = position
        self.playbackSessionID = playbackSessionID
    }
}

extension PlaybackEvent.Kind {
    var titleKey: String { "player.history.kind.\(rawValue)" }
}

struct PlaybackHistoryItem: Identifiable, Equatable, Sendable {
    var id: UUID { event.playbackSessionID }
    let track: Track
    let event: PlaybackEvent
}

struct TrackPlaybackStatistics: Equatable, Sendable {
    var playCount = 0
    var skipCount = 0
    var lastPlayedAt: Date?
}

enum PlaybackStatisticsResolver {
    nonisolated static func statistics(
        events: [PlaybackEvent],
        tracks: [Track] = []
    ) -> [Track.ID: TrackPlaybackStatistics] {
        var result = Dictionary(uniqueKeysWithValues: tracks.map {
            ($0.id, TrackPlaybackStatistics(
                playCount: $0.playCount,
                skipCount: $0.syncedSkipCount,
                lastPlayedAt: $0.syncedLastPlayedAt
            ))
        })
        for event in events {
            var statistics = result[event.trackID] ?? TrackPlaybackStatistics()
            switch event.kind {
            case .started:
                break
            case .completed:
                statistics.playCount += 1
            case .skipped:
                statistics.skipCount += 1
            }
            if statistics.lastPlayedAt.map({ event.occurredAt > $0 }) ?? true {
                statistics.lastPlayedAt = event.occurredAt
            }
            result[event.trackID] = statistics
        }
        return result
    }
}

struct OngakuMixFeatureVector: Equatable, Sendable {
    let normalizedGenre: String
    let normalizedArtist: String
    let beatsPerMinute: Double?
    let tempoConfidence: Double
    let duration: TimeInterval
    let loudnessDBFS: Double?
    let spectralCentroidHz: Double?
    let keyPitchClass: Int?
    let musicalMode: MusicalMode?
    let keyConfidence: Double

    nonisolated init(track: Track, analysis: AudioFeatureAnalysis? = nil) {
        normalizedGenre = Self.normalize(track.genre)
        normalizedArtist = Self.normalize(track.artist)
        if let beatsPerMinute = track.beatsPerMinute {
            self.beatsPerMinute = Double(beatsPerMinute)
            tempoConfidence = 1
        } else {
            self.beatsPerMinute = analysis?.estimatedTempoBPM
            tempoConfidence = analysis?.tempoConfidence ?? 0
        }
        duration = track.duration
        loudnessDBFS = analysis?.averageLoudnessDBFS
        spectralCentroidHz = analysis?.spectralCentroidHz
        keyPitchClass = analysis?.estimatedKeyPitchClass
        musicalMode = analysis?.estimatedMode
        keyConfidence = analysis?.keyConfidence ?? 0
    }

    private nonisolated static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}

enum OngakuMixReason: String, Hashable, Sendable {
    case genre
    case tempo
    case duration
    case loudness
    case timbre
    case harmony
    case artist
    case favorite
    case rating
    case listeningHistory
    case discovery

    var titleKey: String { "ongakuMix.reason.\(rawValue)" }
}

struct OngakuMixCandidate: Identifiable, Equatable, Sendable {
    var id: Track.ID { track.id }
    let track: Track
    let score: Double
    let reasons: [OngakuMixReason]
}

enum OngakuMixHarmonicCompatibility {
    nonisolated static func score(
        firstPitchClass: Int?,
        firstMode: MusicalMode?,
        secondPitchClass: Int?,
        secondMode: MusicalMode?
    ) -> Double {
        guard let firstPitchClass, let firstMode,
              let secondPitchClass, let secondMode else { return 0 }
        let first = normalized(firstPitchClass)
        let second = normalized(secondPitchClass)
        let distance = normalized(second - first)

        if first == second && firstMode == secondMode { return 1 }
        if first == second { return 0.72 }
        if firstMode == secondMode && (distance == 5 || distance == 7) { return 0.86 }
        if firstMode == .major, secondMode == .minor, distance == 9 { return 0.94 }
        if firstMode == .minor, secondMode == .major, distance == 3 { return 0.94 }
        return 0
    }

    private nonisolated static func normalized(_ pitchClass: Int) -> Int {
        let remainder = pitchClass % 12
        return remainder >= 0 ? remainder : remainder + 12
    }
}

enum OngakuMixResolver {
    nonisolated static func seed(
        in tracks: [Track],
        events: [PlaybackEvent],
        preferredID: Track.ID? = nil
    ) -> Track? {
        let playable = tracks.filter(isPlayable)
        guard !playable.isEmpty else { return nil }
        if let preferredID, let preferred = playable.first(where: { $0.id == preferredID }) {
            return preferred
        }
        let playableIDs = Set(playable.map(\.id))
        if let recentID = events
            .filter({ playableIDs.contains($0.trackID) })
            .max(by: { $0.occurredAt < $1.occurredAt })?.trackID {
            return playable.first { $0.id == recentID }
        }
        return playable.sorted(by: seedOrder).first
    }

    nonisolated static func candidates(
        tracks: [Track],
        events: [PlaybackEvent],
        seedTrackID: Track.ID? = nil,
        audioFeatures: [Track.ID: AudioFeatureAnalysis] = [:],
        limit: Int = 30
    ) -> [OngakuMixCandidate] {
        guard limit > 0,
              let seed = seed(in: tracks, events: events, preferredID: seedTrackID) else {
            return []
        }
        let seedFeatures = OngakuMixFeatureVector(
            track: seed,
            analysis: audioFeatures[seed.id]
        )
        let statistics = PlaybackStatisticsResolver.statistics(events: events, tracks: tracks)

        return tracks.compactMap { track -> OngakuMixCandidate? in
            guard track.id != seed.id, isPlayable(track) else { return nil }
            let features = OngakuMixFeatureVector(
                track: track,
                analysis: audioFeatures[track.id]
            )
            let stats = statistics[track.id] ?? TrackPlaybackStatistics()
            var score = 0.08
            var reasons: [OngakuMixReason] = []

            if !seedFeatures.normalizedGenre.isEmpty,
               seedFeatures.normalizedGenre == features.normalizedGenre {
                score += 0.32
                reasons.append(.genre)
            }
            if !seedFeatures.normalizedArtist.isEmpty,
               seedFeatures.normalizedArtist == features.normalizedArtist {
                score += 0.08
                reasons.append(.artist)
            }
            if let seedTempo = seedFeatures.beatsPerMinute,
               let tempo = features.beatsPerMinute {
                let proximity = max(0, 1 - abs(seedTempo - tempo) / 60)
                let confidence = min(seedFeatures.tempoConfidence, features.tempoConfidence)
                score += proximity * 0.22 * confidence
                if abs(seedTempo - tempo) <= 18 { reasons.append(.tempo) }
            }
            if seedFeatures.duration > 0, features.duration > 0 {
                let difference = abs(seedFeatures.duration - features.duration)
                let scale = max(seedFeatures.duration, features.duration)
                let proximity = max(0, 1 - difference / scale)
                score += proximity * 0.12
                if proximity >= 0.8 { reasons.append(.duration) }
            }
            if let seedLoudness = seedFeatures.loudnessDBFS,
               let loudness = features.loudnessDBFS {
                let proximity = max(0, 1 - abs(seedLoudness - loudness) / 20)
                score += proximity * 0.10
                if proximity >= 0.75 { reasons.append(.loudness) }
            }
            if let seedCentroid = seedFeatures.spectralCentroidHz,
               let centroid = features.spectralCentroidHz,
               seedCentroid > 0, centroid > 0 {
                let octaveDistance = abs(log2(seedCentroid / centroid))
                let proximity = max(0, 1 - octaveDistance / 2)
                score += proximity * 0.10
                if proximity >= 0.75 { reasons.append(.timbre) }
            }
            let harmonicCompatibility = OngakuMixHarmonicCompatibility.score(
                firstPitchClass: seedFeatures.keyPitchClass,
                firstMode: seedFeatures.musicalMode,
                secondPitchClass: features.keyPitchClass,
                secondMode: features.musicalMode
            )
            if harmonicCompatibility > 0 {
                let confidence = min(seedFeatures.keyConfidence, features.keyConfidence)
                score += 0.12 * confidence * harmonicCompatibility
                if confidence >= 0.02, harmonicCompatibility >= 0.7 {
                    reasons.insert(.harmony, at: 0)
                }
            }
            if track.isFavorite {
                score += 0.08
                reasons.append(.favorite)
            }
            if track.rating > 0 {
                score += Double(min(track.rating, 5)) / 5 * 0.08
                if track.rating >= 4 { reasons.append(.rating) }
            }
            let completed = stats.playCount
            let skipped = stats.skipCount
            if completed > 0 {
                score += min(Double(completed), 10) / 10 * 0.12
                if completed > skipped { reasons.append(.listeningHistory) }
            } else if skipped == 0 {
                score += 0.06
                reasons.append(.discovery)
            }
            score -= min(Double(skipped), 5) / 5 * 0.16

            if reasons.isEmpty { reasons = [.discovery] }
            return OngakuMixCandidate(
                track: track,
                score: min(max(score, 0), 1),
                reasons: Array(reasons.prefix(3))
            )
        }
        .sorted(by: candidateOrder)
        .prefix(limit)
        .map { $0 }
    }

    private nonisolated static func isPlayable(_ track: Track) -> Bool {
        !track.isExcludedFromPlayback && track.health != .missing && track.health != .unreadable
    }

    private nonisolated static func seedOrder(_ lhs: Track, _ rhs: Track) -> Bool {
        if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
        if lhs.rating != rhs.rating { return lhs.rating > rhs.rating }
        if lhs.playCount != rhs.playCount { return lhs.playCount > rhs.playCount }
        let comparison = lhs.title.localizedStandardCompare(rhs.title)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private nonisolated static func candidateOrder(
        _ lhs: OngakuMixCandidate,
        _ rhs: OngakuMixCandidate
    ) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        let comparison = lhs.track.title.localizedStandardCompare(rhs.track.title)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

enum StandardLibraryResolver {
    nonisolated static func tracks(
        for section: LibrarySection,
        tracks: [Track],
        events: [PlaybackEvent],
        audioFeatures: [Track.ID: AudioFeatureAnalysis] = [:]
    ) -> [Track] {
        switch section {
        case .pinned:
            return tracks.filter(\.isPinned).sorted(by: titleOrder)
        case .recentlyAdded:
            return tracks.sorted {
                if $0.addedAt != $1.addedAt { return $0.addedAt > $1.addedAt }
                return titleOrder($0, $1)
            }
        case .frequentlyPlayed:
            let statistics = PlaybackStatisticsResolver.statistics(events: events, tracks: tracks)
            return tracks.filter { (statistics[$0.id]?.playCount ?? 0) > 0 }.sorted {
                let lhs = statistics[$0.id] ?? TrackPlaybackStatistics()
                let rhs = statistics[$1.id] ?? TrackPlaybackStatistics()
                if lhs.playCount != rhs.playCount { return lhs.playCount > rhs.playCount }
                if lhs.lastPlayedAt != rhs.lastPlayedAt {
                    return (lhs.lastPlayedAt ?? .distantPast) > (rhs.lastPlayedAt ?? .distantPast)
                }
                return titleOrder($0, $1)
            }
        case .recentlyPlayed:
            let statistics = PlaybackStatisticsResolver.statistics(events: events, tracks: tracks)
            return tracks.filter { statistics[$0.id]?.lastPlayedAt != nil }.sorted {
                let lhs = statistics[$0.id]?.lastPlayedAt ?? .distantPast
                let rhs = statistics[$1.id]?.lastPlayedAt ?? .distantPast
                if lhs != rhs { return lhs > rhs }
                return titleOrder($0, $1)
            }
        case .favorites:
            return tracks.filter(\.isFavorite).sorted(by: titleOrder)
        case .ongakuMix:
            return OngakuMixResolver.candidates(
                tracks: tracks,
                events: events,
                audioFeatures: audioFeatures
            ).map(\.track)
        case .needsAttention:
            return tracks.filter { $0.health != .verified }
        case .duplicates:
            let ids = Set(DuplicateTrackAnalyzer.groups(in: tracks).flatMap { $0.tracks.map(\.id) })
            return tracks.filter { ids.contains($0.id) }
        case .songs, .albums, .artists, .effects:
            return tracks
        }
    }

    private nonisolated static func titleOrder(_ lhs: Track, _ rhs: Track) -> Bool {
        let comparison = lhs.title.localizedStandardCompare(rhs.title)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

enum TrackSelectionResolver {
    nonisolated static func focusedTrackID(
        previousFocus: Track.ID?,
        previousSelection: Set<Track.ID>,
        newSelection: Set<Track.ID>
    ) -> Track.ID? {
        guard !newSelection.isEmpty else { return nil }
        let newlySelected = newSelection.subtracting(previousSelection)
        if let focusedID = newlySelected.sorted(by: stableIDOrder).first {
            return focusedID
        }
        if let previousFocus, newSelection.contains(previousFocus) {
            return previousFocus
        }
        return newSelection.sorted(by: stableIDOrder).first
    }

    private nonisolated static func stableIDOrder(_ lhs: Track.ID, _ rhs: Track.ID) -> Bool {
        lhs.uuidString < rhs.uuidString
    }
}

enum PlaybackStartResolver {
    nonisolated static func startingTrack(
        in tracks: [Track],
        selectedID: Track.ID?
    ) -> Track? {
        if let selectedID,
           let selected = tracks.first(where: { $0.id == selectedID }) {
            return selected
        }
        return tracks.first
    }

    nonisolated static func selectedTrackToStart(
        currentTrackID: Track.ID?,
        selectedTrack: Track?
    ) -> Track? {
        guard let selectedTrack,
              selectedTrack.id != currentTrackID else { return nil }
        return selectedTrack
    }
}

struct TrackSelectionState: Equatable, Sendable {
    var focusedID: Track.ID?
    var selectedIDs: Set<Track.ID>

    nonisolated init(focusedID: Track.ID? = nil, selectedIDs: Set<Track.ID> = []) {
        self.focusedID = focusedID
        self.selectedIDs = selectedIDs
    }
}

enum PlaybackHistoryResolver {
    nonisolated static func items(
        events: [PlaybackEvent],
        tracks: [Track],
        limit: Int = 100
    ) -> [PlaybackHistoryItem] {
        guard limit > 0 else { return [] }
        let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        var latestBySession: [UUID: PlaybackEvent] = [:]
        for event in events {
            guard tracksByID[event.trackID] != nil else { continue }
            if let existing = latestBySession[event.playbackSessionID] {
                if event.occurredAt > existing.occurredAt
                    || (event.occurredAt == existing.occurredAt
                        && existing.kind == .started && event.kind != .started)
                {
                    latestBySession[event.playbackSessionID] = event
                }
            } else {
                latestBySession[event.playbackSessionID] = event
            }
        }
        return latestBySession.values
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(limit)
            .compactMap { event in
                tracksByID[event.trackID].map { PlaybackHistoryItem(track: $0, event: event) }
            }
    }
}

struct PlaybackQueueState: Codable, Equatable, Sendable {
    var trackIDs: [Track.ID]
    var currentTrackID: Track.ID?
    var position: TimeInterval

    init(
        trackIDs: [Track.ID] = [],
        currentTrackID: Track.ID? = nil,
        position: TimeInterval = 0
    ) {
        self.trackIDs = trackIDs
        self.currentTrackID = currentTrackID
        self.position = position
    }
}

struct LibraryDocument: Codable, Sendable {
    static let currentSchema = 12

    var schemaVersion: Int = currentSchema
    var updatedAt: Date = .now
    var tracks: [Track] = []
    var libraryID: UUID = UUID()
    var createdAt: Date = .now
    var playlists: [Playlist] = []
    var playlistFolders: [PlaylistFolder] = []
    var playbackEvents: [PlaybackEvent] = []
    var playbackQueue: PlaybackQueueState?
}

struct LibraryLoadResult: Sendable {
    var document: LibraryDocument
    var recoveredFromBackup: Bool
    var recoveredImportCount: Int = 0
    var unresolvedImportCount: Int = 0
    var migratedFromSchemaVersion: Int?
}

extension Track {
    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case artist
        case album
        case artistSortName
        case albumSortName
        case albumArtist
        case albumArtistSortName
        case composer
        case composerSortName
        case grouping
        case genre
        case participantCredits
        case workName
        case movementName
        case movementNumber
        case movementCount
        case beatsPerMinute
        case copyright
        case isrc
        case releaseYear
        case trackNumber
        case trackCount
        case discNumber
        case discCount
        case isCompilation
        case playCount
        case syncedSkipCount
        case syncedLastPlayedAt
        case syncedOverlayUpdatedAt
        case comments
        case lyrics
        case musicBrainzReference
        case duration
        case fileSize
        case managedPath
        case sha256
        case addedAt
        case lastVerifiedAt
        case health
        case artistID
        case albumID
        case isPinned
        case isFavorite
        case rating
        case isExcludedFromPlayback
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        artist = try container.decode(String.self, forKey: .artist)
        album = try container.decode(String.self, forKey: .album)
        artistSortName = try container.decodeIfPresent(String.self, forKey: .artistSortName) ?? ""
        albumSortName = try container.decodeIfPresent(String.self, forKey: .albumSortName) ?? ""
        albumArtist = try container.decodeIfPresent(String.self, forKey: .albumArtist) ?? ""
        albumArtistSortName = try container.decodeIfPresent(
            String.self,
            forKey: .albumArtistSortName
        ) ?? ""
        composer = try container.decodeIfPresent(String.self, forKey: .composer) ?? ""
        composerSortName = try container.decodeIfPresent(String.self, forKey: .composerSortName) ?? ""
        grouping = try container.decodeIfPresent(String.self, forKey: .grouping) ?? ""
        genre = try container.decodeIfPresent(String.self, forKey: .genre) ?? ""
        participantCredits = try container.decodeIfPresent(String.self, forKey: .participantCredits) ?? ""
        workName = try container.decodeIfPresent(String.self, forKey: .workName) ?? ""
        movementName = try container.decodeIfPresent(String.self, forKey: .movementName) ?? ""
        movementNumber = try container.decodeIfPresent(Int.self, forKey: .movementNumber)
        movementCount = try container.decodeIfPresent(Int.self, forKey: .movementCount)
        beatsPerMinute = try container.decodeIfPresent(Int.self, forKey: .beatsPerMinute)
        copyright = try container.decodeIfPresent(String.self, forKey: .copyright) ?? ""
        isrc = try container.decodeIfPresent(String.self, forKey: .isrc) ?? ""
        releaseYear = try container.decodeIfPresent(Int.self, forKey: .releaseYear)
        trackNumber = try container.decodeIfPresent(Int.self, forKey: .trackNumber)
        trackCount = try container.decodeIfPresent(Int.self, forKey: .trackCount)
        discNumber = try container.decodeIfPresent(Int.self, forKey: .discNumber)
        discCount = try container.decodeIfPresent(Int.self, forKey: .discCount)
        isCompilation = try container.decodeIfPresent(Bool.self, forKey: .isCompilation) ?? false
        playCount = max(0, try container.decodeIfPresent(Int.self, forKey: .playCount) ?? 0)
        syncedSkipCount = max(0, try container.decodeIfPresent(Int.self, forKey: .syncedSkipCount) ?? 0)
        syncedLastPlayedAt = try container.decodeIfPresent(Date.self, forKey: .syncedLastPlayedAt)
        syncedOverlayUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .syncedOverlayUpdatedAt)
        comments = try container.decodeIfPresent(String.self, forKey: .comments) ?? ""
        lyrics = try container.decodeIfPresent(TrackLyrics.self, forKey: .lyrics)
        musicBrainzReference = try container.decodeIfPresent(
            MusicBrainzReference.self,
            forKey: .musicBrainzReference
        )
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        fileSize = try container.decode(Int64.self, forKey: .fileSize)
        managedPath = try container.decode(String.self, forKey: .managedPath)
        sha256 = try container.decode(String.self, forKey: .sha256)
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        lastVerifiedAt = try container.decodeIfPresent(Date.self, forKey: .lastVerifiedAt)
        health = try container.decode(FileHealth.self, forKey: .health)

        // Schema 1 and interrupted-import journals predate persistent group IDs.
        // Temporary values are normalized at the document migration boundary.
        artistID = try container.decodeIfPresent(UUID.self, forKey: .artistID) ?? UUID()
        albumID = try container.decodeIfPresent(UUID.self, forKey: .albumID) ?? UUID()
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        rating = min(max(try container.decodeIfPresent(Int.self, forKey: .rating) ?? 0, 0), 5)
        isExcludedFromPlayback = try container.decodeIfPresent(
            Bool.self,
            forKey: .isExcludedFromPlayback
        ) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(artist, forKey: .artist)
        try container.encode(album, forKey: .album)
        if !artistSortName.isEmpty { try container.encode(artistSortName, forKey: .artistSortName) }
        if !albumSortName.isEmpty { try container.encode(albumSortName, forKey: .albumSortName) }
        if !albumArtist.isEmpty { try container.encode(albumArtist, forKey: .albumArtist) }
        if !albumArtistSortName.isEmpty {
            try container.encode(albumArtistSortName, forKey: .albumArtistSortName)
        }
        if !composer.isEmpty { try container.encode(composer, forKey: .composer) }
        if !composerSortName.isEmpty { try container.encode(composerSortName, forKey: .composerSortName) }
        if !grouping.isEmpty { try container.encode(grouping, forKey: .grouping) }
        if !genre.isEmpty { try container.encode(genre, forKey: .genre) }
        if !participantCredits.isEmpty {
            try container.encode(participantCredits, forKey: .participantCredits)
        }
        if !workName.isEmpty { try container.encode(workName, forKey: .workName) }
        if !movementName.isEmpty { try container.encode(movementName, forKey: .movementName) }
        try container.encodeIfPresent(movementNumber, forKey: .movementNumber)
        try container.encodeIfPresent(movementCount, forKey: .movementCount)
        try container.encodeIfPresent(beatsPerMinute, forKey: .beatsPerMinute)
        if !copyright.isEmpty { try container.encode(copyright, forKey: .copyright) }
        if !isrc.isEmpty { try container.encode(isrc, forKey: .isrc) }
        try container.encodeIfPresent(releaseYear, forKey: .releaseYear)
        try container.encodeIfPresent(trackNumber, forKey: .trackNumber)
        try container.encodeIfPresent(trackCount, forKey: .trackCount)
        try container.encodeIfPresent(discNumber, forKey: .discNumber)
        try container.encodeIfPresent(discCount, forKey: .discCount)
        if isCompilation { try container.encode(true, forKey: .isCompilation) }
        if playCount != 0 { try container.encode(playCount, forKey: .playCount) }
        if syncedSkipCount != 0 { try container.encode(syncedSkipCount, forKey: .syncedSkipCount) }
        try container.encodeIfPresent(syncedLastPlayedAt, forKey: .syncedLastPlayedAt)
        try container.encodeIfPresent(syncedOverlayUpdatedAt, forKey: .syncedOverlayUpdatedAt)
        if !comments.isEmpty { try container.encode(comments, forKey: .comments) }
        try container.encodeIfPresent(lyrics, forKey: .lyrics)
        try container.encodeIfPresent(musicBrainzReference, forKey: .musicBrainzReference)
        try container.encode(duration, forKey: .duration)
        try container.encode(fileSize, forKey: .fileSize)
        try container.encode(managedPath, forKey: .managedPath)
        try container.encode(sha256, forKey: .sha256)
        try container.encode(addedAt, forKey: .addedAt)
        try container.encodeIfPresent(lastVerifiedAt, forKey: .lastVerifiedAt)
        try container.encode(health, forKey: .health)
        try container.encode(artistID, forKey: .artistID)
        try container.encode(albumID, forKey: .albumID)
        if isPinned { try container.encode(true, forKey: .isPinned) }
        if isFavorite { try container.encode(true, forKey: .isFavorite) }
        if rating != 0 { try container.encode(rating, forKey: .rating) }
        if isExcludedFromPlayback {
            try container.encode(true, forKey: .isExcludedFromPlayback)
        }
    }
}

struct ImportIssue: Identifiable, Sendable {
    let id = UUID()
    let fileName: String
    let message: String
}

struct ImportResult: Sendable {
    var imported: [Track]
    var issues: [ImportIssue]
}

struct AudioCDImportRequest: Sendable {
    let sourceURL: URL
    let title: String
    let artist: String
    let album: String
    var albumArtist: String? = nil
    var releaseYear: Int? = nil
    var isrc: String? = nil
    let trackNumber: Int
    let trackCount: Int
    var discNumber: Int? = nil
    var discCount: Int? = nil
    var musicBrainzReference: MusicBrainzReference? = nil
}

struct AppleMusicImportSummary: Sendable {
    var discovered: Int
    var imported: Int
    var relinked: Int
    var issues: Int
}

struct FileRelinkResult: Sendable {
    var tracks: [Track]
    var scannedFileCount: Int
    var relinkedTrackCount: Int
    var issueCount: Int
}
