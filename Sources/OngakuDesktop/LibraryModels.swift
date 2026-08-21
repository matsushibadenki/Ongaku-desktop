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
        case .duplicates: "square.on.square"
        case .needsAttention: "exclamationmark.shield"
        case .effects: "dial.medium"
        }
    }

    var preservesResolvedOrder: Bool {
        switch self {
        case .recentlyAdded, .frequentlyPlayed, .recentlyPlayed: true
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
            ($0.id, TrackPlaybackStatistics(playCount: $0.playCount))
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

enum StandardLibraryResolver {
    nonisolated static func tracks(
        for section: LibrarySection,
        tracks: [Track],
        events: [PlaybackEvent]
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
        try container.encode(artistSortName, forKey: .artistSortName)
        try container.encode(albumSortName, forKey: .albumSortName)
        try container.encode(albumArtist, forKey: .albumArtist)
        try container.encode(albumArtistSortName, forKey: .albumArtistSortName)
        try container.encode(composer, forKey: .composer)
        try container.encode(composerSortName, forKey: .composerSortName)
        try container.encode(grouping, forKey: .grouping)
        try container.encode(genre, forKey: .genre)
        try container.encode(participantCredits, forKey: .participantCredits)
        try container.encode(workName, forKey: .workName)
        try container.encode(movementName, forKey: .movementName)
        try container.encodeIfPresent(movementNumber, forKey: .movementNumber)
        try container.encodeIfPresent(movementCount, forKey: .movementCount)
        try container.encodeIfPresent(beatsPerMinute, forKey: .beatsPerMinute)
        try container.encode(copyright, forKey: .copyright)
        try container.encode(isrc, forKey: .isrc)
        try container.encodeIfPresent(releaseYear, forKey: .releaseYear)
        try container.encodeIfPresent(trackNumber, forKey: .trackNumber)
        try container.encodeIfPresent(trackCount, forKey: .trackCount)
        try container.encodeIfPresent(discNumber, forKey: .discNumber)
        try container.encodeIfPresent(discCount, forKey: .discCount)
        try container.encode(isCompilation, forKey: .isCompilation)
        try container.encode(playCount, forKey: .playCount)
        try container.encode(comments, forKey: .comments)
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
        try container.encode(isPinned, forKey: .isPinned)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encode(rating, forKey: .rating)
        try container.encode(isExcludedFromPlayback, forKey: .isExcludedFromPlayback)
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
    let trackNumber: Int
    let trackCount: Int
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
