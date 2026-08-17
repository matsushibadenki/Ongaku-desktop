import Foundation
import SQLite3

actor SQLiteCatalogPrototype {
    struct MigrationReport: Equatable, Sendable {
        let trackCount: Int
        let artistCount: Int
        let albumCount: Int
        let playlistCount: Int
        let playlistEntryCount: Int
        let playbackEventCount: Int
        let databaseURL: URL
        let rollbackSnapshotURL: URL
    }

    enum PrototypeError: LocalizedError {
        case sqlite(String)
        case invalidCatalog(String)
        case missingRollbackSnapshot
        case unsupportedSnapshotSchema(Int)

        var errorDescription: String? {
            switch self {
            case .sqlite(let message): message
            case .invalidCatalog(let message): message
            case .missingRollbackSnapshot: "The JSON rollback snapshot is missing."
            case .unsupportedSnapshotSchema(let version):
                "The rollback snapshot uses unsupported schema \(version)."
            }
        }
    }

    let rootURL: URL
    let databaseURL: URL
    let rollbackSnapshotURL: URL

    private let fileManager: FileManager
    private let stagingURL: URL
    private let previousDatabaseURL: URL

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        databaseURL = rootURL.appendingPathComponent("catalog-prototype-v1.sqlite")
        stagingURL = rootURL.appendingPathComponent("catalog-prototype-v1.migrating.sqlite")
        previousDatabaseURL = rootURL.appendingPathComponent("catalog-prototype-v1.previous.sqlite")
        rollbackSnapshotURL = rootURL.appendingPathComponent("catalog-json-rollback.json")
    }

    func migrate(
        document: LibraryDocument,
        sourceManifestURL: URL? = nil
    ) throws -> MigrationReport {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try writeRollbackSnapshot(document: document, sourceManifestURL: sourceManifestURL)
        try removeDatabaseFiles(at: stagingURL)

        let identities = try catalogIdentities(from: document.tracks)
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            stagingURL.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "Unable to open the SQLite catalog."
            if let database { sqlite3_close(database) }
            throw PrototypeError.sqlite("Unable to open staged catalog at \(stagingURL.path): \(message)")
        }
        var databaseIsOpen = true
        var shouldRemoveStagingDatabase = true
        defer {
            if databaseIsOpen { sqlite3_close(database) }
            if shouldRemoveStagingDatabase { try? removeDatabaseFiles(at: stagingURL) }
        }

        do {
            try execute(database, sql: "PRAGMA foreign_keys = ON")
            try execute(database, sql: "PRAGMA journal_mode = WAL")
            try execute(database, sql: "PRAGMA synchronous = FULL")
            try createSchema(in: database)
            try execute(database, sql: "BEGIN IMMEDIATE")
            try insert(document: document, identities: identities, into: database)
            try validate(document: document, identities: identities, in: database)
            try execute(database, sql: "COMMIT")
            try execute(database, sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        } catch {
            try? execute(database, sql: "ROLLBACK")
            throw error
        }

        guard sqlite3_close(database) == SQLITE_OK else {
            throw PrototypeError.sqlite("Unable to close the staged SQLite catalog.")
        }
        databaseIsOpen = false
        try installStagedDatabase()
        shouldRemoveStagingDatabase = false

        return MigrationReport(
            trackCount: document.tracks.count,
            artistCount: identities.artists.count,
            albumCount: identities.albums.count,
            playlistCount: document.playlists.count,
            playlistEntryCount: document.playlists.reduce(0) { $0 + $1.entries.count },
            playbackEventCount: document.playbackEvents.count,
            databaseURL: databaseURL,
            rollbackSnapshotURL: rollbackSnapshotURL
        )
    }

    func search(_ query: String, limit: Int = 200) throws -> [Track.ID] {
        let match = matchExpression(for: query)
        guard !match.isEmpty, limit > 0 else { return [] }
        // WAL databases may need to recreate their shared-memory sidecar after
        // the staged file is installed under its final name.
        return try withOpenDatabase(readOnly: false) { database in
            try withStatement(
                database,
                sql: """
                    SELECT track_id
                    FROM track_search
                    WHERE track_search MATCH ?
                    ORDER BY bm25(track_search), title COLLATE NOCASE
                    LIMIT ?
                    """
            ) { statement in
                try bind(match, to: 1, in: statement, database: database)
                try bind(Int64(limit), to: 2, in: statement, database: database)
                var ids: [Track.ID] = []
                while true {
                    let result = sqlite3_step(statement)
                    if result == SQLITE_DONE { break }
                    guard result == SQLITE_ROW else { throw sqliteError(database) }
                    guard let text = sqlite3_column_text(statement, 0),
                          let id = UUID(uuidString: String(cString: text)) else {
                        throw PrototypeError.invalidCatalog("SQLite returned an invalid track UUID.")
                    }
                    ids.append(id)
                }
                return ids
            }
        }
    }

    @discardableResult
    func rollbackJSON(to manifestURL: URL) throws -> LibraryDocument {
        guard fileManager.fileExists(atPath: rollbackSnapshotURL.path) else {
            throw PrototypeError.missingRollbackSnapshot
        }
        let data = try Data(contentsOf: rollbackSnapshotURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(LibraryDocument.self, from: data)
        guard document.schemaVersion == LibraryDocument.currentSchema else {
            throw PrototypeError.unsupportedSnapshotSchema(document.schemaVersion)
        }
        try data.write(to: manifestURL, options: [.atomic])
        try removeDatabaseFiles(at: databaseURL)
        try removeDatabaseFiles(at: previousDatabaseURL)
        try removeDatabaseFiles(at: stagingURL)
        return document
    }

    func hasInstalledDatabase() -> Bool {
        fileManager.fileExists(atPath: databaseURL.path)
    }

    private struct CatalogIdentities {
        var artists: [UUID: String]
        var albums: [UUID: (artistID: UUID, name: String)]
    }

    private func catalogIdentities(from tracks: [Track]) throws -> CatalogIdentities {
        var artists: [UUID: String] = [:]
        var albums: [UUID: (artistID: UUID, name: String)] = [:]
        for track in tracks {
            if let existing = artists[track.artistID], existing != track.artist {
                throw PrototypeError.invalidCatalog(
                    "Artist \(track.artistID) has conflicting names."
                )
            }
            artists[track.artistID] = track.artist
            if let existing = albums[track.albumID],
               existing.artistID != track.artistID || existing.name != track.album {
                throw PrototypeError.invalidCatalog(
                    "Album \(track.albumID) has conflicting metadata."
                )
            }
            albums[track.albumID] = (track.artistID, track.album)
        }
        return CatalogIdentities(artists: artists, albums: albums)
    }

    private func createSchema(in database: OpaquePointer) throws {
        try execute(
            database,
            sql: """
                CREATE TABLE library (
                    id TEXT PRIMARY KEY NOT NULL,
                    schema_version INTEGER NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE artist (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL
                );
                CREATE TABLE album (
                    id TEXT PRIMARY KEY NOT NULL,
                    artist_id TEXT NOT NULL REFERENCES artist(id),
                    name TEXT NOT NULL
                );
                CREATE TABLE track (
                    rowid INTEGER PRIMARY KEY,
                    id TEXT UNIQUE NOT NULL,
                    title TEXT NOT NULL,
                    artist_id TEXT NOT NULL REFERENCES artist(id),
                    album_id TEXT NOT NULL REFERENCES album(id),
                    duration REAL NOT NULL,
                    file_size INTEGER NOT NULL,
                    managed_path TEXT NOT NULL,
                    sha256 TEXT NOT NULL,
                    added_at REAL NOT NULL,
                    last_verified_at REAL,
                    health TEXT NOT NULL
                );
                CREATE INDEX track_artist_id_idx ON track(artist_id);
                CREATE INDEX track_album_id_idx ON track(album_id);
                CREATE INDEX track_added_at_idx ON track(added_at DESC);
                CREATE TABLE playlist (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    description TEXT NOT NULL,
                    artwork_path TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE playlist_entry (
                    id TEXT PRIMARY KEY NOT NULL,
                    playlist_id TEXT NOT NULL REFERENCES playlist(id) ON DELETE CASCADE,
                    track_id TEXT NOT NULL REFERENCES track(id) ON DELETE CASCADE,
                    position INTEGER NOT NULL,
                    added_at REAL NOT NULL,
                    UNIQUE(playlist_id, position)
                );
                CREATE INDEX playlist_entry_track_idx ON playlist_entry(track_id);
                CREATE TABLE playback_event (
                    id TEXT PRIMARY KEY NOT NULL,
                    track_id TEXT NOT NULL REFERENCES track(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    occurred_at REAL NOT NULL,
                    position REAL NOT NULL,
                    playback_session_id TEXT NOT NULL
                );
                CREATE INDEX playback_event_track_time_idx
                    ON playback_event(track_id, occurred_at DESC);
                CREATE VIRTUAL TABLE track_search USING fts5(
                    track_id UNINDEXED,
                    title,
                    artist,
                    album,
                    tokenize = 'unicode61 remove_diacritics 2'
                );
                """
        )
    }

    private func insert(
        document: LibraryDocument,
        identities: CatalogIdentities,
        into database: OpaquePointer
    ) throws {
        try withStatement(
            database,
            sql: "INSERT INTO library VALUES (?, ?, ?, ?)"
        ) { statement in
            try bind(document.libraryID.uuidString, to: 1, in: statement, database: database)
            try bind(Int64(document.schemaVersion), to: 2, in: statement, database: database)
            try bind(document.createdAt.timeIntervalSince1970, to: 3, in: statement, database: database)
            try bind(document.updatedAt.timeIntervalSince1970, to: 4, in: statement, database: database)
            try stepDone(statement, database: database)
        }

        try withStatement(database, sql: "INSERT INTO artist VALUES (?, ?)") { statement in
            for (id, name) in identities.artists.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                try reset(statement, database: database)
                try bind(id.uuidString, to: 1, in: statement, database: database)
                try bind(name, to: 2, in: statement, database: database)
                try stepDone(statement, database: database)
            }
        }

        try withStatement(database, sql: "INSERT INTO album VALUES (?, ?, ?)") { statement in
            for (id, album) in identities.albums.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                try reset(statement, database: database)
                try bind(id.uuidString, to: 1, in: statement, database: database)
                try bind(album.artistID.uuidString, to: 2, in: statement, database: database)
                try bind(album.name, to: 3, in: statement, database: database)
                try stepDone(statement, database: database)
            }
        }

        try withStatement(
            database,
            sql: """
                INSERT INTO track(
                    id, title, artist_id, album_id, duration, file_size, managed_path,
                    sha256, added_at, last_verified_at, health
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
        ) { trackStatement in
            try withStatement(
                database,
                sql: "INSERT INTO track_search(track_id, title, artist, album) VALUES (?, ?, ?, ?)"
            ) { searchStatement in
                for track in document.tracks {
                    try reset(trackStatement, database: database)
                    try bind(track.id.uuidString, to: 1, in: trackStatement, database: database)
                    try bind(track.title, to: 2, in: trackStatement, database: database)
                    try bind(track.artistID.uuidString, to: 3, in: trackStatement, database: database)
                    try bind(track.albumID.uuidString, to: 4, in: trackStatement, database: database)
                    try bind(track.duration, to: 5, in: trackStatement, database: database)
                    try bind(track.fileSize, to: 6, in: trackStatement, database: database)
                    try bind(track.managedPath, to: 7, in: trackStatement, database: database)
                    try bind(track.sha256, to: 8, in: trackStatement, database: database)
                    try bind(track.addedAt.timeIntervalSince1970, to: 9, in: trackStatement, database: database)
                    if let lastVerifiedAt = track.lastVerifiedAt {
                        try bind(lastVerifiedAt.timeIntervalSince1970, to: 10, in: trackStatement, database: database)
                    } else {
                        try bindNull(to: 10, in: trackStatement, database: database)
                    }
                    try bind(track.health.rawValue, to: 11, in: trackStatement, database: database)
                    try stepDone(trackStatement, database: database)

                    try reset(searchStatement, database: database)
                    try bind(track.id.uuidString, to: 1, in: searchStatement, database: database)
                    try bind(track.title, to: 2, in: searchStatement, database: database)
                    try bind(track.artist, to: 3, in: searchStatement, database: database)
                    try bind(track.album, to: 4, in: searchStatement, database: database)
                    try stepDone(searchStatement, database: database)
                }
            }
        }

        try withStatement(
            database,
            sql: "INSERT INTO playlist VALUES (?, ?, ?, ?, ?, ?)"
        ) { playlistStatement in
            try withStatement(
                database,
                sql: "INSERT INTO playlist_entry VALUES (?, ?, ?, ?, ?)"
            ) { entryStatement in
                for playlist in document.playlists {
                    try reset(playlistStatement, database: database)
                    try bind(playlist.id.uuidString, to: 1, in: playlistStatement, database: database)
                    try bind(playlist.name, to: 2, in: playlistStatement, database: database)
                    try bind(playlist.description, to: 3, in: playlistStatement, database: database)
                    if let artworkPath = playlist.artworkPath {
                        try bind(artworkPath, to: 4, in: playlistStatement, database: database)
                    } else {
                        try bindNull(to: 4, in: playlistStatement, database: database)
                    }
                    try bind(playlist.createdAt.timeIntervalSince1970, to: 5, in: playlistStatement, database: database)
                    try bind(playlist.updatedAt.timeIntervalSince1970, to: 6, in: playlistStatement, database: database)
                    try stepDone(playlistStatement, database: database)

                    for (position, entry) in playlist.entries.enumerated() {
                        try reset(entryStatement, database: database)
                        try bind(entry.id.uuidString, to: 1, in: entryStatement, database: database)
                        try bind(playlist.id.uuidString, to: 2, in: entryStatement, database: database)
                        try bind(entry.trackID.uuidString, to: 3, in: entryStatement, database: database)
                        try bind(Int64(position), to: 4, in: entryStatement, database: database)
                        try bind(entry.addedAt.timeIntervalSince1970, to: 5, in: entryStatement, database: database)
                        try stepDone(entryStatement, database: database)
                    }
                }
            }
        }

        try withStatement(
            database,
            sql: "INSERT INTO playback_event VALUES (?, ?, ?, ?, ?, ?)"
        ) { statement in
            for event in document.playbackEvents {
                try reset(statement, database: database)
                try bind(event.id.uuidString, to: 1, in: statement, database: database)
                try bind(event.trackID.uuidString, to: 2, in: statement, database: database)
                try bind(event.kind.rawValue, to: 3, in: statement, database: database)
                try bind(event.occurredAt.timeIntervalSince1970, to: 4, in: statement, database: database)
                try bind(event.position, to: 5, in: statement, database: database)
                try bind(event.playbackSessionID.uuidString, to: 6, in: statement, database: database)
                try stepDone(statement, database: database)
            }
        }
    }

    private func validate(
        document: LibraryDocument,
        identities: CatalogIdentities,
        in database: OpaquePointer
    ) throws {
        let expectedCounts = [
            "library": 1,
            "artist": identities.artists.count,
            "album": identities.albums.count,
            "track": document.tracks.count,
            "track_search": document.tracks.count,
            "playlist": document.playlists.count,
            "playlist_entry": document.playlists.reduce(0) { $0 + $1.entries.count },
            "playback_event": document.playbackEvents.count,
        ]
        for (table, expected) in expectedCounts {
            let actual = try integer(database, sql: "SELECT count(*) FROM \(table)")
            guard actual == expected else {
                throw PrototypeError.invalidCatalog(
                    "SQLite validation failed for \(table): expected \(expected), found \(actual)."
                )
            }
        }

        let expectedIDSets: [(table: String, expected: Set<String>)] = [
            ("artist", Set(identities.artists.keys.map(\.uuidString))),
            ("album", Set(identities.albums.keys.map(\.uuidString))),
            ("track", Set(document.tracks.map { $0.id.uuidString })),
            ("playlist", Set(document.playlists.map { $0.id.uuidString })),
            ("playlist_entry", Set(document.playlists.flatMap { $0.entries }.map { $0.id.uuidString })),
            ("playback_event", Set(document.playbackEvents.map { $0.id.uuidString })),
        ]
        for (table, expected) in expectedIDSets {
            let actual = try stringSet(database, sql: "SELECT id FROM \(table)")
            guard actual == expected else {
                throw PrototypeError.invalidCatalog("Stable UUID validation failed for \(table).")
            }
        }

        let expectedEntryOrder = document.playlists.flatMap { playlist in
            playlist.entries.enumerated().map {
                "\(playlist.id.uuidString):\($0.offset):\($0.element.id.uuidString)"
            }
        }
        var actualEntryOrder: [String] = []
        try withStatement(
            database,
            sql: "SELECT playlist_id, position, id FROM playlist_entry ORDER BY playlist_id, position"
        ) { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let playlist = sqlite3_column_text(statement, 0),
                      let entry = sqlite3_column_text(statement, 2) else {
                    throw PrototypeError.invalidCatalog("Playlist order validation failed.")
                }
                actualEntryOrder.append(
                    "\(String(cString: playlist)):\(sqlite3_column_int64(statement, 1)):\(String(cString: entry))"
                )
            }
        }
        guard actualEntryOrder.sorted() == expectedEntryOrder.sorted() else {
            throw PrototypeError.invalidCatalog("Playlist entry order validation failed.")
        }

        let foreignKeyViolations = try integer(
            database,
            sql: "SELECT count(*) FROM pragma_foreign_key_check"
        )
        guard foreignKeyViolations == 0 else {
            throw PrototypeError.invalidCatalog("SQLite foreign-key validation failed.")
        }
    }

    private func writeRollbackSnapshot(
        document: LibraryDocument,
        sourceManifestURL: URL?
    ) throws {
        let data: Data
        if let sourceManifestURL {
            data = try Data(contentsOf: sourceManifestURL)
        } else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            data = try encoder.encode(document)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(LibraryDocument.self, from: data)
        guard snapshot.schemaVersion == LibraryDocument.currentSchema else {
            throw PrototypeError.unsupportedSnapshotSchema(snapshot.schemaVersion)
        }
        let snapshotReferences = (
            tracks: Set(snapshot.tracks.map(\.id)),
            playlists: Set(snapshot.playlists.map(\.id)),
            entries: Set(snapshot.playlists.flatMap(\.entries).map(\.id)),
            events: Set(snapshot.playbackEvents.map(\.id))
        )
        let documentReferences = (
            tracks: Set(document.tracks.map(\.id)),
            playlists: Set(document.playlists.map(\.id)),
            entries: Set(document.playlists.flatMap(\.entries).map(\.id)),
            events: Set(document.playbackEvents.map(\.id))
        )
        guard snapshot.libraryID == document.libraryID,
              snapshotReferences.tracks == documentReferences.tracks,
              snapshotReferences.playlists == documentReferences.playlists,
              snapshotReferences.entries == documentReferences.entries,
              snapshotReferences.events == documentReferences.events else {
            throw PrototypeError.invalidCatalog(
                "The source JSON does not match the document selected for migration."
            )
        }
        try data.write(to: rollbackSnapshotURL, options: [.atomic])
    }

    private func installStagedDatabase() throws {
        try removeDatabaseFiles(at: previousDatabaseURL)
        if fileManager.fileExists(atPath: databaseURL.path) {
            try checkpointDatabase(at: databaseURL)
            try removeDatabaseSidecars(at: databaseURL)
            try fileManager.moveItem(at: databaseURL, to: previousDatabaseURL)
        }
        do {
            try fileManager.moveItem(at: stagingURL, to: databaseURL)
        } catch {
            if fileManager.fileExists(atPath: previousDatabaseURL.path),
               !fileManager.fileExists(atPath: databaseURL.path) {
                try? fileManager.moveItem(at: previousDatabaseURL, to: databaseURL)
            }
            throw error
        }
        try removeDatabaseFiles(at: previousDatabaseURL)
    }

    private func checkpointDatabase(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "Unable to checkpoint the installed SQLite catalog."
            if let database { sqlite3_close(database) }
            throw PrototypeError.sqlite(message)
        }
        defer { sqlite3_close(database) }
        try execute(database, sql: "PRAGMA wal_checkpoint(TRUNCATE)")
    }

    private func removeDatabaseFiles(at url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try removeDatabaseSidecars(at: url)
    }

    private func removeDatabaseSidecars(at url: URL) throws {
        for candidate in [URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")] {
            if fileManager.fileExists(atPath: candidate.path) {
                try fileManager.removeItem(at: candidate)
            }
        }
    }

    private func matchExpression(for query: String) -> String {
        query.split(whereSeparator: \.isWhitespace).map { component in
            let escaped = component.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\"*"
        }
        .joined(separator: " AND ")
    }

    private func withOpenDatabase<T>(
        readOnly: Bool,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        var database: OpaquePointer?
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "Unable to open the installed SQLite catalog."
            if let database { sqlite3_close(database) }
            throw PrototypeError.sqlite("Unable to open installed catalog at \(databaseURL.path): \(message)")
        }
        defer { sqlite3_close(database) }
        return try body(database)
    }

    private func execute(_ database: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            let operation = sql.split(whereSeparator: \.isWhitespace).prefix(4).joined(separator: " ")
            throw PrototypeError.sqlite("\(operation): \(message)")
        }
    }

    private func withStatement<T>(
        _ database: OpaquePointer,
        sql: String,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw sqliteError(database) }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func reset(_ statement: OpaquePointer, database: OpaquePointer) throws {
        guard sqlite3_reset(statement) == SQLITE_OK,
              sqlite3_clear_bindings(statement) == SQLITE_OK else {
            throw sqliteError(database)
        }
    }

    private func bind(
        _ value: String,
        to index: Int32,
        in statement: OpaquePointer,
        database: OpaquePointer
    ) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, index, value, -1, transient) == SQLITE_OK else {
            throw sqliteError(database)
        }
    }

    private func bind(
        _ value: Int64,
        to index: Int32,
        in statement: OpaquePointer,
        database: OpaquePointer
    ) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
            throw sqliteError(database)
        }
    }

    private func bind(
        _ value: Double,
        to index: Int32,
        in statement: OpaquePointer,
        database: OpaquePointer
    ) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
            throw sqliteError(database)
        }
    }

    private func bindNull(
        to index: Int32,
        in statement: OpaquePointer,
        database: OpaquePointer
    ) throws {
        guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
            throw sqliteError(database)
        }
    }

    private func stepDone(_ statement: OpaquePointer, database: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(database) }
    }

    private func integer(_ database: OpaquePointer, sql: String) throws -> Int {
        try withStatement(database, sql: sql) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError(database) }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    private func stringSet(_ database: OpaquePointer, sql: String) throws -> Set<String> {
        try withStatement(database, sql: sql) { statement in
            var result = Set<String>()
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
                    throw sqliteError(database)
                }
                result.insert(String(cString: text))
            }
            return result
        }
    }

    private func sqliteError(_ database: OpaquePointer) -> PrototypeError {
        .sqlite(String(cString: sqlite3_errmsg(database)))
    }
}
