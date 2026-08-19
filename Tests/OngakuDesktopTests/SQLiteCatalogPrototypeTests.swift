import Foundation
import Testing
@testable import OngakuDesktop

@Suite("SQLite catalog prototype", .serialized)
struct SQLiteCatalogPrototypeTests {
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
        let parity = try await prototype.verifyParity(
            document: document,
            queries: ["alpha", "LPH", "夜", "album", "ＳＯＮＧ", "missing"]
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

    private func makeDocument() -> LibraryDocument {
        let firstArtistID = UUID()
        let firstAlbumID = UUID()
        let first = Track(
            id: UUID(), title: "Àlpha Ｓong", artist: "First Artist", album: "Shared Album",
            duration: 180, fileSize: 1_000, managedPath: "/Music/Alpha.m4a",
            sha256: "alpha", addedAt: .now, lastVerifiedAt: .now, health: .verified,
            artistID: firstArtistID, albumID: firstAlbumID
        )
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
