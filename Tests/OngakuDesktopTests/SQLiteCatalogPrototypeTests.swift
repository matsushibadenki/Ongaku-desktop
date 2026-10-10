import Foundation
import SQLite3
import Testing
@testable import OngakuDesktop

@Suite("SQLite catalog prototype", .serialized)
struct SQLiteCatalogPrototypeTests {
    @Test("Batched parity preserves multilingual metadata matches and reports every stale query")
    func batchedParity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ongaku-SQLite-Batched-Parity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let prototype = SQLiteCatalogPrototype(rootURL: root)
        var document = LargeLibraryFixture.makeDocument(trackCount: 200)
        document.tracks[0].title = "Àlpha Ｓong"
        document.tracks[0].lyrics = TrackLyrics(plainText: "hidden lyric", source: .manual)
        _ = try await prototype.migrate(document: document)
        let queries = ["a", "LPH", "ＳＯＮＧ", "楽", "目", "楽曲", "曲目", "hidden lyric", "missing", "a"]
        let initial = try await prototype.verifySearchParity(document: document, queries: queries)
        #expect(initial.isMatch)
        #expect(initial.checkedQueries == queries)

        document.tracks[0].title = "Renamed"
        let staleQueries = ["alpha", "renamed", "楽", "alpha"]
        let stale = try await prototype.verifySearchParity(document: document, queries: staleQueries)
        #expect(stale.mismatchedQueries == ["alpha", "renamed", "alpha"])
        _ = try await prototype.synchronizeSearchIndex(document: document)
        #expect(try await prototype.verifySearchParity(document: document, queries: staleQueries).isMatch)
        #expect(try await prototype.verifySearchParity(document: document, queries: []).isMatch)

        let finalDocument = document
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await prototype.verifySearchParity(document: finalDocument, queries: queries)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await prototype.verifySearchParity(document: document, queries: ["renamed"]).isMatch)
    }

    @Test("Cancellation interrupts SQLite before its first result and removes the handler")
    func interruptsRunningStatement() async throws {
        let task = Task.detached {
            var database: OpaquePointer?
            #expect(sqlite3_open(":memory:", &database) == SQLITE_OK)
            let db = try #require(database)
            defer { sqlite3_close(db) }
            var stepResult: Int32 = SQLITE_OK
            #expect(throws: CancellationError.self) {
                try SQLiteCatalogPrototype.withSearchCancellation(db) {
                    // Cancel after installing the handler, then execute enough
                    // VM instructions to exercise cancellation inside SQLite.
                    withUnsafeCurrentTask { $0?.cancel() }
                    stepResult = sqlite3_exec(db, """
                        WITH RECURSIVE n(x) AS (
                            VALUES(0) UNION ALL SELECT x + 1 FROM n WHERE x < 100000
                        ) SELECT sum(x) FROM n
                        """, nil, nil, nil)
                }
            }
            #expect(stepResult == SQLITE_INTERRUPT)
            // The same connection remains usable even while this task is
            // cancelled: the scoped callback must have been removed.
            #expect(sqlite3_exec(db, """
                WITH RECURSIVE n(x) AS (
                    VALUES(0) UNION ALL SELECT x + 1 FROM n WHERE x < 1000
                ) SELECT sum(x) FROM n
                """, nil, nil, nil) == SQLITE_OK)
        }
        try await task.value
    }

    @Test("Cancelled searches throw cancellation and subsequent multilingual searches work")
    func cancelledSearchRecovery() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ongaku-SQLite-Cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let prototype = SQLiteCatalogPrototype(rootURL: root)
        let document = LargeLibraryFixture.makeDocument(trackCount: 200)
        _ = try await prototype.migrate(document: document)
        for query in ["a", "楽", "目", "楽曲", "曲目", "track", "missing"] {
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await prototype.search(query)
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            let expected = Set(document.tracks.filter { CatalogSearch.matches($0, query: query) }.map(\.id))
            #expect(Set(try await prototype.search(query, limit: 200)) == expected)
        }
    }

    @Test("JSON migrates transactionally, supports indexed search, and rolls back")
    func migrationSearchAndRollback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ongaku-SQLite-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let document = makeDocument()
        let manifestURL = root.appendingPathComponent("library-v1.json")
        try encode(document).write(to: manifestURL, options: [.atomic])
        let prototype = SQLiteCatalogPrototype(rootURL: root)

        let report = try await prototype.migrate(
            document: document,
            sourceManifestURL: manifestURL
        )

        #expect(report.trackCount == 2)
        #expect(report.artistCount == 2)
        #expect(report.albumCount == 2)
        #expect(report.playlistCount == 2)
        #expect(report.playlistEntryCount == 2)
        #expect(report.playbackEventCount == 1)
        #expect(await prototype.hasInstalledDatabase())
        #expect(FileManager.default.fileExists(atPath: report.rollbackSnapshotURL.path))

        let alpha = try await prototype.search("alpha")
        #expect(alpha == [document.tracks[0].id])
        let japanese = try await prototype.search("夜")
        #expect(japanese == [document.tracks[1].id])
        let sharedAlbumSearch = try await prototype.search("Album")
        #expect(Set(sharedAlbumSearch) == Set(document.tracks.map(\.id)))
        let composerSearch = try await prototype.search("Debussy")
        #expect(composerSearch == [document.tracks[0].id])
        let lyricsSearch = try await prototype.search("hidden lyric")
        #expect(lyricsSearch == [document.tracks[0].id])
        let parity = try await prototype.verifyParity(
            document: document,
            queries: [
                "alpha", "LPH", "夜", "album", "ＳＯＮＧ", "Debussy",
                "hidden lyric", "missing",
            ]
        )
        #expect(parity.isMatch)
        #expect(parity.mismatchedQueries.isEmpty)

        // Replacing an opened WAL catalog must not carry old sidecars into the
        // newly validated database.
        _ = try await prototype.migrate(document: document, sourceManifestURL: manifestURL)
        #expect(try await prototype.search("alpha") == [document.tracks[0].id])

        try encode(LibraryDocument()).write(to: manifestURL, options: [.atomic])
        let restored = try await prototype.rollbackJSON(to: manifestURL)
        #expect(restored.libraryID == document.libraryID)
        #expect(restored.tracks.map(\.id) == document.tracks.map(\.id))
        #expect(restored.playlistFolders.map(\.id) == document.playlistFolders.map(\.id))
        #expect(restored.playlists.map(\.id) == document.playlists.map(\.id))
        #expect(restored.playbackEvents.map(\.id) == document.playbackEvents.map(\.id))
        #expect(!(await prototype.hasInstalledDatabase()))

        let diskDocument = try decode(Data(contentsOf: manifestURL))
        #expect(diskDocument.tracks.map(\.id) == document.tracks.map(\.id))
    }

    @Test("A dangling playlist reference aborts without installing SQLite")
    func rejectsDanglingPlaylistReference() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ongaku-SQLite-Invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var document = makeDocument()
        document.playlists[0].entries.append(PlaylistEntry(trackID: UUID()))
        let prototype = SQLiteCatalogPrototype(rootURL: root)

        do {
            _ = try await prototype.migrate(document: document)
            Issue.record("Migration accepted a dangling playlist reference")
        } catch {
            #expect(!(await prototype.hasInstalledDatabase()))
        }
    }

    @Test("Search metadata updates only changed SQLite rows")
    func incrementallySynchronizesSearchMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ongaku-SQLite-Diff-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let prototype = SQLiteCatalogPrototype(rootURL: root)
        var document = makeDocument()
        _ = try await prototype.migrate(document: document)

        document.tracks[0].title = "Renamed Search Target"
        document.tracks[0].lyrics = TrackLyrics(
            plainText: "new searchable phrase",
            source: .manual
        )
        let report = try await prototype.synchronizeSearchIndex(document: document)

        #expect(report.updatedTrackCount == 1)
        #expect(report.unchangedTrackCount == 1)
        #expect(try await prototype.search("renamed") == [document.tracks[0].id])
        #expect(try await prototype.search("new searchable") == [document.tracks[0].id])
        #expect(try await prototype.search("lpha song").isEmpty)

        let unchanged = try await prototype.synchronizeSearchIndex(document: document)
        #expect(unchanged.updatedTrackCount == 0)
        #expect(unchanged.unchangedTrackCount == 2)
    }

    private func makeDocument() -> LibraryDocument {
        let firstArtistID = UUID()
        let firstAlbumID = UUID()
        var first = Track(
            id: UUID(), title: "Àlpha Ｓong", artist: "First Artist", album: "Shared Album",
            duration: 180, fileSize: 1_000, managedPath: "/Music/Alpha.m4a",
            sha256: "alpha", addedAt: .now, lastVerifiedAt: .now, health: .verified,
            artistID: firstArtistID, albumID: firstAlbumID
        )
        first.composer = "Claude Debussy"
        first.participantCredits = "Piano: Alice Example"
        first.lyrics = TrackLyrics(plainText: "a hidden lyric phrase", source: .manual)
        let second = Track(
            id: UUID(), title: "夜の歌", artist: "第二歌手", album: "Second Album",
            duration: 200, fileSize: 2_000, managedPath: "/Music/Night.m4a",
            sha256: "night", addedAt: .now, lastVerifiedAt: nil, health: .unchecked,
            artistID: UUID(), albumID: UUID()
        )
        let folder = PlaylistFolder(name: "Collections", sortOrder: 0)
        let playlist = Playlist(
            name: "Mixed",
            folderID: folder.id,
            sortOrder: 0,
            entries: [PlaylistEntry(trackID: first.id), PlaylistEntry(trackID: second.id)]
        )
        let smartPlaylist = Playlist(
            name: "Favorites",
            sortOrder: 1,
            smartDefinition: SmartPlaylistDefinition(
                root: SmartPlaylistRuleGroup(
                    rules: [SmartPlaylistRule(field: .favorite, comparison: .isTrue)]
                )
            )
        )
        let event = PlaybackEvent(trackID: first.id, kind: .completed, position: first.duration)
        return LibraryDocument(
            tracks: [first, second],
            playlists: [playlist, smartPlaylist],
            playlistFolders: [folder],
            playbackEvents: [event]
        )
    }

    private func encode(_ document: LibraryDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document)
    }

    private func decode(_ data: Data) throws -> LibraryDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LibraryDocument.self, from: data)
    }
}
