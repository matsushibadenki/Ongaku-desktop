import Foundation

enum LibrarySection: String, CaseIterable, Identifiable, Sendable {
    case songs
    case albums
    case artists
    case recentlyAdded
    case needsAttention
    case effects

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .songs: "sidebar.songs"
        case .albums: "sidebar.albums"
        case .artists: "sidebar.artists"
        case .recentlyAdded: "sidebar.recent"
        case .needsAttention: "sidebar.attention"
        case .effects: "sidebar.effects"
        }
    }

    var systemImage: String {
        switch self {
        case .songs: "music.note.list"
        case .albums: "square.stack"
        case .artists: "music.mic"
        case .recentlyAdded: "clock"
        case .needsAttention: "exclamationmark.shield"
        case .effects: "dial.medium"
        }
    }
}

enum FileHealth: String, Codable, Sendable {
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

struct Track: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var fileSize: Int64
    var managedPath: String
    var sha256: String
    var addedAt: Date
    var lastVerifiedAt: Date?
    var health: FileHealth
    var artistID: UUID = UUID()
    var albumID: UUID = UUID()

    var fileURL: URL { URL(fileURLWithPath: managedPath) }
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
        return normalize(track.title).contains(normalizedQuery)
            || normalize(track.artist).contains(normalizedQuery)
            || normalize(track.album).contains(normalizedQuery)
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

struct Playlist: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var description: String
    var artworkPath: String?
    var entries: [PlaylistEntry]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        description: String = "",
        artworkPath: String? = nil,
        entries: [PlaylistEntry] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.artworkPath = artworkPath
        self.entries = entries
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

struct LibraryDocument: Codable, Sendable {
    static let currentSchema = 3

    var schemaVersion: Int = currentSchema
    var updatedAt: Date = .now
    var tracks: [Track] = []
    var libraryID: UUID = UUID()
    var createdAt: Date = .now
    var playlists: [Playlist] = []
    var playbackEvents: [PlaybackEvent] = []
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
        case duration
        case fileSize
        case managedPath
        case sha256
        case addedAt
        case lastVerifiedAt
        case health
        case artistID
        case albumID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        artist = try container.decode(String.self, forKey: .artist)
        album = try container.decode(String.self, forKey: .album)
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
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(artist, forKey: .artist)
        try container.encode(album, forKey: .album)
        try container.encode(duration, forKey: .duration)
        try container.encode(fileSize, forKey: .fileSize)
        try container.encode(managedPath, forKey: .managedPath)
        try container.encode(sha256, forKey: .sha256)
        try container.encode(addedAt, forKey: .addedAt)
        try container.encodeIfPresent(lastVerifiedAt, forKey: .lastVerifiedAt)
        try container.encode(health, forKey: .health)
        try container.encode(artistID, forKey: .artistID)
        try container.encode(albumID, forKey: .albumID)
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

struct AppleMusicImportSummary: Sendable {
    var discovered: Int
    var imported: Int
    var relinked: Int
    var issues: Int
}
