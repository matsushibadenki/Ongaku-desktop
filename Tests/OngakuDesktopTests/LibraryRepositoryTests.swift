import AppKit
import AVFoundation
import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Library repository integrity")
struct LibraryRepositoryTests {
    private func fixtureURL(_ name: String) -> URL {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "Fixtures"
        ) else {
            fatalError("Missing test fixture: \(name)")
        }
        return url
    }

    @Test("Resolving duplicates transfers catalog references without deleting files")
    @MainActor
    func resolvesDuplicateRegistrations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let keep = Track(
            id: UUID(), title: "Song", artist: "Artist", album: "Album",
            duration: 120, fileSize: 10, managedPath: root.appendingPathComponent("keep.wav").path,
            sha256: "identical", addedAt: .distantPast, health: .verified
        )
        let remove = Track(
            id: UUID(), title: "Song Copy", artist: "Artist", album: "Album",
            duration: 120, fileSize: 10, managedPath: root.appendingPathComponent("remove.wav").path,
            sha256: "identical", addedAt: .now, health: .verified
        )
        let playlist = Playlist(
            name: "Both",
            entries: [PlaylistEntry(trackID: remove.id), PlaylistEntry(trackID: keep.id)]
        )
        let event = PlaybackEvent(trackID: remove.id, kind: .completed)
        let queue = PlaybackQueueState(
            trackIDs: [remove.id, keep.id],
            currentTrackID: remove.id,
            position: 42
        )
        let repository = LibraryRepository(rootURL: root)
        try await repository.save(document: LibraryDocument(
            tracks: [keep, remove],
            playlists: [playlist],
            playbackEvents: [event],
            playbackQueue: queue
        ))
        let store = LibraryStore(repository: repository)
        await store.load()
        let group = try #require(store.duplicateGroups.first)

        let result = try await store.resolveDuplicateGroup(
            group.id,
            keeping: keep.id,
            moveManagedFilesToTrash: false
        )

        #expect(result.removedCount == 1)
        #expect(result.trashedFileCount == 0)
        #expect(store.tracks.map(\.id) == [keep.id])
        #expect(store.playlists[0].entries.map(\.trackID) == [keep.id])
        #expect(store.playbackEvents.map(\.trackID) == [keep.id])
        #expect(store.playbackQueue?.trackIDs == [keep.id])
        #expect(store.playbackQueue?.currentTrackID == keep.id)

        let restored = try await LibraryRepository(rootURL: root).load().document
        #expect(restored.tracks.map(\.id) == [keep.id])
        #expect(restored.playlists[0].entries.map(\.trackID) == [keep.id])
        #expect(restored.playbackEvents.map(\.trackID) == [keep.id])
    }

    @Test("Playlist create, edit, artwork, duplicate, delete, and restart are transactional")
    @MainActor
    func managesPlaylists() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        let store = LibraryStore(repository: repository)
        await store.load()

        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 4, height: 4)).fill()
        image.unlockFocus()
        let artworkData = try #require(image.tiffRepresentation)

        let originalID = try await store.createPlaylist(
            name: "Road Trip",
            description: "Long drives",
            artworkData: artworkData
        )
        let original = try #require(store.playlists.first { $0.id == originalID })
        let originalArtworkPath = try #require(original.artworkPath)
        #expect(FileManager.default.fileExists(atPath: originalArtworkPath))
        #expect(store.selectedPlaylistID == originalID)

        let duplicatedID = try await store.duplicatePlaylist(originalID)
        let duplicateID = try #require(duplicatedID)
        let duplicate = try #require(store.playlists.first { $0.id == duplicateID })
        let duplicateArtworkPath = try #require(duplicate.artworkPath)
        #expect(duplicate.name == L10n.format("playlist.copyName", original.name))
        #expect(duplicateArtworkPath != originalArtworkPath)
        #expect(FileManager.default.fileExists(atPath: duplicateArtworkPath))

        try await store.updatePlaylist(
            id: originalID,
            name: "Highway",
            description: "Night driving",
            artworkData: nil,
            removesArtwork: true
        )
        let updated = try #require(store.playlists.first { $0.id == originalID })
        #expect(updated.name == "Highway")
        #expect(updated.description == "Night driving")
        #expect(updated.artworkPath == nil)
        #expect(!FileManager.default.fileExists(atPath: originalArtworkPath))

        try await store.deletePlaylist(duplicateID)
        #expect(!FileManager.default.fileExists(atPath: duplicateArtworkPath))
        #expect(store.playlists.map(\.id) == [originalID])

        let restored = try await LibraryRepository(rootURL: root).load().document
        #expect(restored.playlists.map(\.id) == [originalID])
        #expect(restored.playlists[0].name == "Highway")

        try await store.deletePlaylist(originalID)
        #expect(store.playlists.isEmpty)
        #expect(store.selectedPlaylistID == nil)
    }

    @Test("Playlist membership preserves order, ignores duplicates, removes, and persists")
    @MainActor
    func managesPlaylistMembership() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        let first = Track(
            id: UUID(), title: "First", artist: "Artist", album: "Album",
            duration: 10, fileSize: 1, managedPath: root.appendingPathComponent("1.wav").path,
            sha256: "1", addedAt: .now, lastVerifiedAt: .now, health: .verified
        )
        let second = Track(
            id: UUID(), title: "Second", artist: "Artist", album: "Album",
            duration: 20, fileSize: 1, managedPath: root.appendingPathComponent("2.wav").path,
            sha256: "2", addedAt: .now, lastVerifiedAt: .now, health: .verified
        )
        try await repository.save(tracks: [first, second])
        let store = LibraryStore(repository: repository)
        await store.load()
        let playlistID = try await store.createPlaylist(
            name: "Selection", description: "", artworkData: nil
        )

        let added = try await store.addTracks(
            [second.id, first.id, second.id], to: playlistID
        )
        #expect(added == 2)
        #expect(store.selectedPlaylist?.entries.map(\.trackID) == [second.id, first.id])
        #expect(store.playlistsContaining(trackIDs: [first.id]).map(\.id) == [playlistID])

        let duplicateCount = try await store.addTracks([first.id], to: playlistID)
        #expect(duplicateCount == 0)
        #expect(store.selectedPlaylist?.entries.count == 2)

        let removed = try await store.removeTracks([second.id], from: playlistID)
        #expect(removed == 1)
        #expect(store.selectedPlaylist?.entries.map(\.trackID) == [first.id])

        let restored = try await LibraryRepository(rootURL: root).load().document
        #expect(restored.playlists.first?.entries.map(\.trackID) == [first.id])
    }

    @Test("Playlist order can be changed and restored with Undo and Redo")
    @MainActor
    func reordersPlaylistWithUndo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        let tracks = (1...3).map { index in
            Track(
                id: UUID(), title: "Track \(index)", artist: "Artist", album: "Album",
                duration: 10, fileSize: 1,
                managedPath: root.appendingPathComponent("\(index).wav").path,
                sha256: "\(index)", addedAt: .now, lastVerifiedAt: .now,
                health: .verified
            )
        }
        try await repository.save(tracks: tracks)
        let store = LibraryStore(repository: repository)
        await store.load()
        let playlistID = try await store.createPlaylist(
            name: "Ordered", description: "", artworkData: nil
        )
        _ = try await store.addTracks(tracks.map(\.id), to: playlistID)

        let undoManager = UndoManager()
        store.undoManager = undoManager
        let moved = try await store.moveTracks(
            [tracks[2].id], before: tracks[0].id, in: playlistID
        )
        #expect(moved)
        #expect(store.selectedPlaylist?.entries.map(\.trackID) == [
            tracks[2].id, tracks[0].id, tracks[1].id
        ])

        undoManager.undo()
        try await waitUntil {
            store.selectedPlaylist?.entries.map(\.trackID) == tracks.map(\.id)
        }
        #expect(undoManager.canRedo)

        undoManager.redo()
        try await waitUntil {
            store.selectedPlaylist?.entries.map(\.trackID) == [
                tracks[2].id, tracks[0].id, tracks[1].id
            ]
        }
        let restored = try await LibraryRepository(rootURL: root).load().document
        #expect(restored.playlists.first?.entries.map(\.trackID) == [
            tracks[2].id, tracks[0].id, tracks[1].id
        ])
    }

    @Test("Playlist folders preserve membership and sidebar order")
    @MainActor
    func managesPlaylistFolders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(repository: LibraryRepository(rootURL: root))
        await store.load()
        let first = try await store.createPlaylist(name: "First", description: "", artworkData: nil)
        let second = try await store.createPlaylist(name: "Second", description: "", artworkData: nil)
        let third = try await store.createPlaylist(name: "Third", description: "", artworkData: nil)
        let favorites = try await store.createPlaylistFolder(name: "Favorites")
        let seasons = try await store.createPlaylistFolder(name: "Seasons")

        try await store.movePlaylist(first, to: favorites)
        try await store.movePlaylist(second, to: favorites, before: first)
        try await store.movePlaylist(third, to: seasons)
        #expect(store.playlists(in: favorites).map(\.id) == [second, first])

        try await store.movePlaylistFolder(seasons, before: favorites)
        #expect(store.sortedPlaylistFolders.map(\.id) == [seasons, favorites])

        let undoManager = UndoManager()
        store.undoManager = undoManager
        try await store.deletePlaylistFolder(favorites)
        #expect(store.playlistFolders.map(\.id) == [seasons])
        #expect(Set(store.playlists(in: nil).map(\.id)) == [first, second])

        undoManager.undo()
        try await waitUntil {
            store.playlistFolders.contains(where: { $0.id == favorites })
        }
        #expect(store.playlists(in: favorites).map(\.id) == [second, first])

        let restored = try await LibraryRepository(rootURL: root).load().document
        #expect(restored.playlistFolders.sorted { $0.sortOrder < $1.sortOrder }.map(\.id) == [
            seasons, favorites
        ])
        #expect(restored.playlists.filter { $0.folderID == favorites }
            .sorted { $0.sortOrder < $1.sortOrder }.map(\.id) == [second, first])
    }

    @MainActor
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for the asynchronous playlist operation")
    }

    @Test("Manifest round-trips atomically")
    func manifestRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = LibraryRepository(rootURL: root)
        var track = Track(
            id: UUID(),
            title: "Test",
            artist: "Artist",
            album: "Album",
            duration: 42,
            fileSize: 3,
            managedPath: root.appendingPathComponent("test.wav").path,
            sha256: "abc",
            addedAt: .now,
            lastVerifiedAt: .now,
            health: .verified
        )
        track.isPinned = true
        track.isFavorite = true
        track.rating = 4
        track.isExcludedFromPlayback = true

        try await repository.save(tracks: [track])
        let loaded = try await repository.load()
        #expect(loaded.document.tracks.count == 1)
        #expect(loaded.document.tracks[0].id == track.id)
        #expect(loaded.document.tracks[0].title == track.title)
        #expect(loaded.document.tracks[0].sha256 == track.sha256)
        #expect(loaded.document.tracks[0].health == .verified)
        #expect(loaded.document.tracks[0].isPinned)
        #expect(loaded.document.tracks[0].isFavorite)
        #expect(loaded.document.tracks[0].rating == 4)
        #expect(loaded.document.tracks[0].isExcludedFromPlayback)
        try? FileManager.default.removeItem(at: root)
    }

    @Test("Schema 1 migrates once with stable library, artist, and album IDs")
    func migratesSchemaOneCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(contentsOf: fixtureURL("library-schema-1.json"))
            .write(to: root.appendingPathComponent("library-v1.json"))

        let repository = LibraryRepository(rootURL: root)
        let migrated = try await repository.load()

        #expect(migrated.migratedFromSchemaVersion == 1)
        #expect(migrated.document.schemaVersion == LibraryDocument.currentSchema)
        #expect(migrated.document.tracks.count == 3)
        #expect(migrated.document.createdAt == migrated.document.tracks[0].addedAt)
        #expect(migrated.document.tracks[0].artistID == migrated.document.tracks[1].artistID)
        #expect(migrated.document.tracks[1].artistID == migrated.document.tracks[2].artistID)
        #expect(migrated.document.tracks[0].albumID == migrated.document.tracks[1].albumID)
        #expect(migrated.document.tracks[1].albumID != migrated.document.tracks[2].albumID)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("library-schema-1.migration-backup.json").path
        ))

        let firstLibraryID = migrated.document.libraryID
        let firstArtistID = migrated.document.tracks[0].artistID
        let firstAlbumID = migrated.document.tracks[0].albumID
        let reloaded = try await repository.load()
        #expect(reloaded.migratedFromSchemaVersion == nil)
        #expect(reloaded.document.libraryID == firstLibraryID)
        #expect(reloaded.document.tracks[0].artistID == firstArtistID)
        #expect(reloaded.document.tracks[0].albumID == firstAlbumID)

        try Data(contentsOf: fixtureURL("library-corrupt.json")).write(
            to: root.appendingPathComponent("library-v1.json"),
            options: .atomic
        )
        let savedAgain = try await LibraryRepository(rootURL: root).load()
        #expect(savedAgain.recoveredFromBackup)
        #expect(savedAgain.document.libraryID == firstLibraryID)
        #expect(savedAgain.document.tracks[0].artistID == firstArtistID)
        #expect(savedAgain.document.tracks[0].albumID == firstAlbumID)
    }

    @Test("An unversioned track-array fixture migrates to the current schema")
    func migratesUnversionedCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(contentsOf: fixtureURL("library-unversioned.json"))
            .write(to: root.appendingPathComponent("library-v1.json"))

        let loaded = try await LibraryRepository(rootURL: root).load()
        #expect(loaded.migratedFromSchemaVersion == 0)
        #expect(loaded.document.schemaVersion == LibraryDocument.currentSchema)
        #expect(loaded.document.tracks.map(\.title) == ["Early Track"])
    }

    @Test("Schema 2 preserves stable identities while adding playlists and playback events")
    func migratesSchemaTwoCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(contentsOf: fixtureURL("library-schema-2.json"))
            .write(to: root.appendingPathComponent("library-v1.json"))

        let loaded = try await LibraryRepository(rootURL: root).load()

        #expect(loaded.migratedFromSchemaVersion == 2)
        #expect(loaded.document.schemaVersion == LibraryDocument.currentSchema)
        #expect(loaded.document.libraryID.uuidString == "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        #expect(loaded.document.tracks[0].artistID.uuidString == "11111111-1111-1111-1111-111111111111")
        #expect(loaded.document.tracks[0].albumID.uuidString == "22222222-2222-2222-2222-222222222222")
        #expect(loaded.document.playlists.isEmpty)
        #expect(loaded.document.playbackEvents.isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("library-schema-2.migration-backup.json").path
        ))
    }

    @Test("Playlist entries and playback events survive track-only saves and restart")
    func persistsPlaylistAndPlaybackModels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        let track = Track(
            id: UUID(), title: "History", artist: "Artist", album: "Album", duration: 30,
            fileSize: 100, managedPath: "/tmp/history.m4a", sha256: "history",
            addedAt: .now, lastVerifiedAt: nil, health: .unchecked
        )
        try await repository.save(tracks: [track])

        let entry = PlaylistEntry(trackID: track.id)
        let playlist = Playlist(name: "Road Trip", entries: [entry])
        let sessionID = UUID()
        let event = PlaybackEvent(
            trackID: track.id,
            kind: .completed,
            position: track.duration,
            playbackSessionID: sessionID
        )
        try await repository.save(playlists: [playlist])
        try await repository.recordPlaybackEvent(event)

        var renamed = track
        renamed.title = "History Edited"
        try await repository.save(tracks: [renamed])

        let reloaded = try await LibraryRepository(rootURL: root).load().document
        #expect(reloaded.playlists.map(\.id) == [playlist.id])
        #expect(reloaded.playlists[0].entries.map(\.id) == [entry.id])
        #expect(reloaded.playlists[0].entries.map(\.trackID) == [track.id])
        #expect(reloaded.playbackEvents.map(\.id) == [event.id])
        #expect(reloaded.playbackEvents[0].trackID == track.id)
        #expect(reloaded.playbackEvents[0].kind == .completed)
        #expect(reloaded.playbackEvents[0].playbackSessionID == sessionID)
        #expect(reloaded.tracks[0].title == "History Edited")
    }

    @Test("Schema 3 migrates to a queue-capable catalog without inventing queue state")
    func migratesSchemaThreeCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = """
        {
          "schemaVersion": 3,
          "updatedAt": "2026-08-17T00:00:00Z",
          "tracks": [],
          "libraryID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
          "createdAt": "2026-08-16T00:00:00Z",
          "playlists": [],
          "playbackEvents": []
        }
        """
        try Data(manifest.utf8).write(to: root.appendingPathComponent("library-v1.json"))

        let loaded = try await LibraryRepository(rootURL: root).load()
        #expect(loaded.migratedFromSchemaVersion == 3)
        #expect(loaded.document.schemaVersion == LibraryDocument.currentSchema)
        #expect(loaded.document.playbackQueue == nil)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("library-schema-3.migration-backup.json").path
        ))
    }

    @Test("Schema 4 migrates playback attributes with safe defaults and preserves the queue")
    func migratesSchemaFourCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = """
        {
          "schemaVersion": 4,
          "updatedAt": "2026-08-18T00:00:00Z",
          "tracks": [],
          "libraryID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
          "createdAt": "2026-08-16T00:00:00Z",
          "playlists": [],
          "playbackEvents": [],
          "playbackQueue": { "trackIDs": [], "position": 12.5 }
        }
        """
        try Data(manifest.utf8).write(to: root.appendingPathComponent("library-v1.json"))

        let loaded = try await LibraryRepository(rootURL: root).load()
        #expect(loaded.migratedFromSchemaVersion == 4)
        #expect(loaded.document.schemaVersion == LibraryDocument.currentSchema)
        #expect(loaded.document.playbackQueue?.position == 12.5)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("library-schema-4.migration-backup.json").path
        ))
    }

    @Test("Schema 5 preserves playlist order while adding folders")
    func migratesSchemaFivePlaylistOrganization() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let firstID = UUID()
        let secondID = UUID()
        let libraryID = UUID()
        let json = """
        {
          "schemaVersion": 5,
          "updatedAt": "2026-08-19T00:00:00Z",
          "tracks": [],
          "libraryID": "\(libraryID.uuidString)",
          "createdAt": "2026-08-19T00:00:00Z",
          "playlists": [
            {"id":"\(firstID.uuidString)","name":"First","description":"","entries":[],"createdAt":"2026-08-19T00:00:00Z","updatedAt":"2026-08-19T00:00:00Z"},
            {"id":"\(secondID.uuidString)","name":"Second","description":"","entries":[],"createdAt":"2026-08-19T00:00:00Z","updatedAt":"2026-08-19T00:00:00Z"}
          ],
          "playbackEvents": []
        }
        """
        try Data(json.utf8).write(to: root.appendingPathComponent("library-v1.json"))

        let loaded = try await LibraryRepository(rootURL: root).load()
        #expect(loaded.migratedFromSchemaVersion == 5)
        #expect(loaded.document.schemaVersion == LibraryDocument.currentSchema)
        #expect(loaded.document.playlistFolders.isEmpty)
        #expect(loaded.document.playlists.map(\.id) == [firstID, secondID])
        #expect(loaded.document.playlists.map(\.sortOrder) == [0, 1])
    }

    @Test("Playback queue order, current track, and position survive restart")
    func persistsPlaybackQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Track(
            id: UUID(), title: "First", artist: "Artist", album: "Album", duration: 60,
            fileSize: 1, managedPath: "/tmp/first.m4a", sha256: "first",
            addedAt: .now, lastVerifiedAt: nil, health: .unchecked
        )
        let second = Track(
            id: UUID(), title: "Second", artist: "Artist", album: "Album", duration: 90,
            fileSize: 1, managedPath: "/tmp/second.m4a", sha256: "second",
            addedAt: .now, lastVerifiedAt: nil, health: .unchecked,
            artistID: first.artistID, albumID: first.albumID
        )
        let repository = LibraryRepository(rootURL: root)
        try await repository.save(tracks: [first, second])
        let state = PlaybackQueueState(
            trackIDs: [second.id, first.id],
            currentTrackID: second.id,
            position: 37.5
        )
        try await repository.save(playbackQueue: state)

        var renamed = first
        renamed.title = "First Edited"
        try await repository.save(tracks: [renamed, second])

        let reloaded = try await LibraryRepository(rootURL: root).load().document
        #expect(reloaded.playbackQueue == state)
        #expect(reloaded.tracks[0].title == "First Edited")
    }

    @Test("A future schema is never replaced with an older backup")
    func rejectsFutureSchemaWithoutDowngrade() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        try await repository.save(tracks: [])
        try await repository.save(tracks: [])
        try Data("{\"schemaVersion\":999,\"tracks\":[]}".utf8)
            .write(to: root.appendingPathComponent("library-v1.json"), options: .atomic)

        do {
            _ = try await LibraryRepository(rootURL: root).load()
            Issue.record("A catalog from a future schema was accepted")
        } catch LibraryRepository.RepositoryError.unsupportedSchema(let version) {
            #expect(version == 999)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Clearing registrations leaves every audio file untouched")
    func clearsRegistrationsWithoutTouchingAudioFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let catalog = root.appendingPathComponent("Catalog", isDirectory: true)
        let audioDirectory = root.appendingPathComponent("Media/Artist/Album", isDirectory: true)
        let audioFile = audioDirectory.appendingPathComponent("Track.m4a")
        try FileManager.default.createDirectory(
            at: audioDirectory, withIntermediateDirectories: true)
        let originalAudio = Data([0, 0, 0, 20, 21, 22, 23, 24])
        try originalAudio.write(to: audioFile)

        let track = Track(
            id: UUID(),
            title: "Track",
            artist: "Artist",
            album: "Album",
            duration: 12,
            fileSize: Int64(originalAudio.count),
            managedPath: audioFile.path,
            sha256: try LibraryRepository.sha256(of: audioFile),
            addedAt: .now,
            lastVerifiedAt: .now,
            health: .verified
        )
        let repository = LibraryRepository(
            rootURL: catalog,
            mediaURL: root.appendingPathComponent("Media")
        )
        try await repository.save(tracks: [track])
        let playlist = Playlist(
            name: "Temporary references",
            entries: [PlaylistEntry(trackID: track.id)]
        )
        let playbackEvent = PlaybackEvent(trackID: track.id, kind: .started)
        try await repository.save(playlists: [playlist])
        try await repository.recordPlaybackEvent(playbackEvent)

        try await repository.clearAllRegistrations()

        let cleared = try await repository.load()
        #expect(cleared.document.tracks.isEmpty)
        #expect(cleared.document.playlists.map(\.id) == [playlist.id])
        #expect(cleared.document.playlists[0].entries.isEmpty)
        #expect(cleared.document.playbackEvents.isEmpty)
        #expect(cleared.document.playbackQueue == PlaybackQueueState())
        #expect(FileManager.default.fileExists(atPath: audioFile.path))
        #expect(try Data(contentsOf: audioFile) == originalAudio)

        // Backup recovery must preserve the intentionally empty catalog too.
        try Data(contentsOf: fixtureURL("library-corrupt.json")).write(
            to: catalog.appendingPathComponent("library-v1.json")
        )
        let recovered = try await repository.load()
        #expect(recovered.recoveredFromBackup)
        #expect(recovered.document.tracks.isEmpty)
        #expect(recovered.document.playlists[0].entries.isEmpty)
        #expect(recovered.document.playbackEvents.isEmpty)
        #expect(recovered.document.playbackQueue == PlaybackQueueState())
        #expect(FileManager.default.fileExists(atPath: audioFile.path))
        #expect(try Data(contentsOf: audioFile) == originalAudio)

        // Recovery rewrites the primary without replacing the known-good backup.
        let healthyReload = try await repository.load()
        #expect(!healthyReload.recoveredFromBackup)
        #expect(healthyReload.document.tracks.isEmpty)
        try? FileManager.default.removeItem(at: root)
    }

    @Test("Verification detects changed content")
    func detectsChangedContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("sample.bin")
        try Data([1, 2, 3]).write(to: file)
        let hash = try LibraryRepository.sha256(of: file)
        var track = Track(
            id: UUID(), title: "Sample", artist: "A", album: "B", duration: 0,
            fileSize: 3, managedPath: file.path, sha256: hash, addedAt: .now,
            lastVerifiedAt: nil, health: .unchecked
        )
        let repository = LibraryRepository(rootURL: root.appendingPathComponent("Library"))
        let first = await repository.verify([track])
        #expect(first[0].health == .verified)

        try Data([9, 9, 9]).write(to: file)
        track.health = .unchecked
        let second = await repository.verify([track])
        #expect(second[0].health == .changed)
        try? FileManager.default.removeItem(at: root)
    }

    @Test("Missing files are automatically and manually relinked only by checksum")
    func safelyRelinksMissingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let searchRoot = root.appendingPathComponent("Search", isDirectory: true)
        let nested = searchRoot.appendingPathComponent("Artist/Album", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let recovered = nested.appendingPathComponent("Recovered.mp3")
        let originalData = Data([0x49, 0x44, 0x33, 1, 2, 3, 4, 5])
        try originalData.write(to: recovered)
        let hash = try LibraryRepository.sha256(of: recovered)
        let track = Track(
            id: UUID(), title: "Missing", artist: "Artist", album: "Album", duration: 1,
            fileSize: Int64(originalData.count),
            managedPath: root.appendingPathComponent("Old/Missing.mp3").path,
            sha256: hash, addedAt: .now, lastVerifiedAt: .now, health: .missing
        )
        let repository = LibraryRepository(rootURL: root.appendingPathComponent("Catalog"))

        let automatic = await repository.relinkMissingFiles(
            in: [track],
            searching: [searchRoot]
        )
        #expect(automatic.relinkedTrackCount == 1)
        #expect(automatic.scannedFileCount == 1)
        #expect(automatic.tracks[0].managedPath == recovered.standardizedFileURL.path)
        #expect(automatic.tracks[0].health == .verified)

        let wrong = root.appendingPathComponent("Wrong.mp3")
        try Data(repeating: 0xFF, count: originalData.count).write(to: wrong)
        do {
            _ = try await repository.relink(track, to: wrong)
            Issue.record("A mismatching checksum must not be relinked")
        } catch LibraryRepository.RepositoryError.relinkFingerprintMismatch {
            // Expected: the catalog path remains unchanged.
        }
        let manual = try await repository.relink(track, to: recovered)
        #expect(manual.managedPath == recovered.standardizedFileURL.path)
        #expect(manual.health == .verified)
    }

    @Test("Import copies data and rejects duplicate content")
    func importAndDeduplicate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("Artist - Track.mp3")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0x49, 0x44, 0x33, 1, 2, 3, 4]).write(to: source)
        let repository = LibraryRepository(rootURL: root.appendingPathComponent("Managed"))

        let first = await repository.importFiles([source], existing: [])
        #expect(first.imported.count == 1)
        #expect(first.issues.isEmpty)
        #expect(FileManager.default.fileExists(atPath: first.imported[0].managedPath))
        #expect(first.imported[0].sha256 == (try LibraryRepository.sha256(of: source)))

        let duplicate = await repository.importFiles([source], existing: first.imported)
        #expect(duplicate.imported.isEmpty)
        #expect(duplicate.issues.count == 1)
        try? FileManager.default.removeItem(at: root)
    }

    @Test("CD import metadata organizes verified copies by artist and album")
    func importsCDMetadataOverrides() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disc = root.appendingPathComponent("Audio CD")
        let source = disc.appendingPathComponent("1 Audio Track.aiff")
        try FileManager.default.createDirectory(at: disc, withIntermediateDirectories: true)
        try Data([0x46, 0x4F, 0x52, 0x4D, 1, 2, 3, 4]).write(to: source)
        let media = root.appendingPathComponent("Media")
        let repository = LibraryRepository(
            rootURL: root.appendingPathComponent("Catalog"),
            mediaURL: media
        )
        let request = AudioCDImportRequest(
            sourceURL: source,
            title: "Opening",
            artist: "Disc Artist",
            album: "Disc Album",
            albumArtist: "Album Artist",
            releaseYear: 2026,
            isrc: "JPAAA2600001",
            trackNumber: 1,
            trackCount: 12,
            discNumber: 1,
            discCount: 2,
            musicBrainzReference: MusicBrainzReference(
                recordingID: "recording-id",
                releaseID: "release-id",
                releaseGroupID: "release-group-id",
                artistIDs: ["artist-id"],
                isrc: "JPAAA2600001",
                country: "JP",
                mediaFormat: "CD",
                coverArtID: nil,
                coverArtTypes: [],
                fetchedAt: .now
            )
        )

        let result = await repository.importFiles(
            [source],
            existing: [],
            metadataOverrides: [source.standardizedFileURL.path: request]
        )
        let track = try #require(result.imported.first)

        #expect(result.issues.isEmpty)
        #expect(track.title == "Opening")
        #expect(track.artist == "Disc Artist")
        #expect(track.album == "Disc Album")
        #expect(track.trackNumber == 1)
        #expect(track.trackCount == 12)
        #expect(track.albumArtist == "Album Artist")
        #expect(track.releaseYear == 2026)
        #expect(track.isrc == "JPAAA2600001")
        #expect(track.discNumber == 1)
        #expect(track.discCount == 2)
        #expect(track.musicBrainzReference?.releaseID == "release-id")
        #expect(track.managedPath.hasPrefix(
            media.appendingPathComponent("Disc Artist/Disc Album").path + "/"
        ))
        #expect(try LibraryRepository.sha256(of: track.fileURL) == LibraryRepository.sha256(of: source))
    }

    @Test("MusicBrainz Disc ID and lookup URLs follow the CD TOC specification")
    func musicBrainzDiscID() {
        let toc = MusicBrainzDiscTOC(
            firstTrack: 1,
            lastTrack: 3,
            leadoutOffset: 45_000,
            trackOffsets: [150, 15_000, 30_000]
        )

        #expect(toc.discID == "ohhlX44vA82K1SAvWfO52oJ_ZxQ-")
        #expect(toc.queryValue == "1 3 45000 150 15000 30000")
        #expect(MusicBrainzService.discLookupURL(for: toc).path.hasSuffix("/discid/\(toc.discID)"))
        #expect(
            URLComponents(
                url: MusicBrainzService.tocLookupURL(for: toc),
                resolvingAgainstBaseURL: false
            )?.queryItems?.first(where: { $0.name == "toc" })?.value == toc.queryValue
        )
    }

    @Test("Secure CD reads require two consecutive matching checksums")
    func secureCDReadVerification() throws {
        var stableSequence = ["first", "second", "second"]
        let stable = try AudioCDRipper.verifiedSourceHash(
            URL(fileURLWithPath: "/tmp/test-track.aiff")
        ) { _ in stableSequence.removeFirst() }
        #expect(stable == "second")

        var unstableSequence = ["first", "second", "third"]
        #expect(throws: AudioCDRipError.unstableRead) {
            try AudioCDRipper.verifiedSourceHash(
                URL(fileURLWithPath: "/tmp/test-track.aiff")
            ) { _ in unstableSequence.removeFirst() }
        }
    }

    @Test("CD ripper creates verified AIFF, WAV, ALAC, and AAC files")
    func convertsCDImportFormats() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.aiff")
        let format = AVAudioFormat(
            standardFormatWithSampleRate: 44_100,
            channels: 2
        )!
        do {
            let sourceFile = try AVAudioFile(
                forWriting: source,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: true,
                ]
            )
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410)!
            buffer.frameLength = 4_410
            for channel in 0..<2 {
                let samples = buffer.floatChannelData![channel]
                for frame in 0..<4_410 {
                    samples[frame] = Float(
                        sin(2 * Double.pi * 440 * Double(frame) / 44_100) * 0.2
                    )
                }
            }
            try sourceFile.write(from: buffer)
        }

        for outputFormat in AudioCDImportFormat.allCases {
            let output = root.appendingPathComponent("output-\(outputFormat.rawValue)")
                .appendingPathExtension(outputFormat.pathExtension)
            try AudioCDRipper.rip(
                sourceURL: source,
                destinationURL: output,
                format: outputFormat,
                aacQuality: .high
            )
            let decoded = try AVAudioFile(forReading: output)
            let outputHash = try LibraryRepository.sha256(of: output)
            #expect(decoded.length > 0)
            #expect(!outputHash.isEmpty)
        }
    }

    @Test("An installed file is recovered when import was interrupted before catalog save")
    func recoversInterruptedImport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("Artist - Recovered.mp3")
        let managedRoot = root.appendingPathComponent("Managed")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0x49, 0x44, 0x33, 9, 8, 7, 6]).write(to: source)

        let importingRepository = LibraryRepository(rootURL: managedRoot)
        let imported = await importingRepository.importFiles([source], existing: [])
        #expect(imported.imported.count == 1)
        #expect(imported.issues.isEmpty)

        // Simulate termination after the managed file was installed but before Store.save().
        let restartedRepository = LibraryRepository(rootURL: managedRoot)
        let recovered = try await restartedRepository.load()
        #expect(recovered.recoveredImportCount == 1)
        #expect(recovered.unresolvedImportCount == 0)
        #expect(recovered.document.tracks.count == 1)
        #expect(recovered.document.tracks[0].sha256 == imported.imported[0].sha256)
        #expect(FileManager.default.fileExists(atPath: recovered.document.tracks[0].managedPath))

        let secondLoad = try await restartedRepository.load()
        #expect(secondLoad.recoveredImportCount == 0)
        #expect(secondLoad.document.tracks.count == 1)
        try? FileManager.default.removeItem(at: root)
    }

    @Test("A configured media directory receives new managed files")
    func importsIntoConfiguredMediaDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("Artist - Custom.mp3")
        let catalog = root.appendingPathComponent("Catalog")
        let media = root.appendingPathComponent("Selected/Ongaku Media")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0x49, 0x44, 0x33, 4, 5, 6]).write(to: source)

        let repository = LibraryRepository(rootURL: catalog, mediaURL: media)
        let imported = await repository.importFiles([source], existing: [])

        #expect(imported.imported.count == 1)
        #expect(imported.imported[0].fileURL.path.hasPrefix(media.path + "/"))
        #expect(FileManager.default.fileExists(atPath: imported.imported[0].managedPath))
        try? FileManager.default.removeItem(at: root)
    }

    @Test("Dropping files and folders imports supported audio into artist and album folders")
    @MainActor
    func importsDroppedFilesAndFoldersIntoManagedHierarchy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let droppedFolder = root.appendingPathComponent("Dropped Music", isDirectory: true)
        let nestedFolder = droppedFolder.appendingPathComponent("Nested", isDirectory: true)
        let first = droppedFolder.appendingPathComponent("Artist - First.mp3")
        let second = nestedFolder.appendingPathComponent("Artist - Second.flac")
        let ignored = nestedFolder.appendingPathComponent("Notes.txt")
        let media = root.appendingPathComponent("Managed Music", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedFolder, withIntermediateDirectories: true)
        try Data([0x49, 0x44, 0x33, 41, 42, 43]).write(to: first)
        try Data([0x66, 0x4C, 0x61, 0x43, 51, 52, 53]).write(to: second)
        try Data("not audio".utf8).write(to: ignored)
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = LibraryRepository(
            rootURL: root.appendingPathComponent("Catalog", isDirectory: true),
            mediaURL: media
        )
        let store = LibraryStore(repository: repository)

        // The direct file overlaps with the folder and must still be imported only once.
        await store.importDroppedItems([droppedFolder, first, ignored])

        #expect(store.tracks.count == 2)
        #expect(Set(store.tracks.map(\.title)) == Set(["First", "Second"]))
        for track in store.tracks {
            #expect(track.fileURL.path.hasPrefix(media.path + "/"))
            #expect(track.fileURL.deletingLastPathComponent().lastPathComponent == track.album)
            #expect(
                track.fileURL.deletingLastPathComponent().deletingLastPathComponent()
                    .lastPathComponent == track.artist)
            #expect(FileManager.default.fileExists(atPath: track.managedPath))
        }
        #expect(try Data(contentsOf: ignored) == Data("not audio".utf8))
    }

    @Test("The automatic Ongaku Media directory is created only by a managed import")
    func createsAutomaticMediaDirectoryOnFirstImport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let catalog = root.appendingPathComponent("Catalog", isDirectory: true)
        let automaticMedia = catalog.appendingPathComponent("Ongaku Media", isDirectory: true)
        let source = root.appendingPathComponent("First Track.mp3")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0x49, 0x44, 0x33, 31, 32, 33]).write(to: source)

        let repository = LibraryRepository(rootURL: catalog)
        _ = try await repository.load()
        #expect(!FileManager.default.fileExists(atPath: automaticMedia.path))

        let imported = await repository.importFiles([source], existing: [])
        #expect(imported.imported.count == 1)
        #expect(FileManager.default.fileExists(atPath: automaticMedia.path))
        #expect(imported.imported[0].fileURL.path.hasPrefix(automaticMedia.path + "/"))
        try? FileManager.default.removeItem(at: root)
    }

    @Test("Changing the media directory redirects the next import immediately")
    func changesMediaDirectoryAtRuntime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("Artist - Redirected.mp3")
        let catalog = root.appendingPathComponent("Catalog")
        let originalMedia = root.appendingPathComponent("Original/Ongaku Media")
        let changedMedia = root.appendingPathComponent("Changed/Ongaku Media")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0x49, 0x44, 0x33, 7, 8, 9]).write(to: source)

        let repository = LibraryRepository(rootURL: catalog, mediaURL: originalMedia)
        try await repository.setMediaDirectory(changedMedia)
        let imported = await repository.importFiles([source], existing: [])

        #expect(imported.imported.count == 1)
        #expect(imported.imported[0].fileURL.path.hasPrefix(changedMedia.path + "/"))
        #expect(!imported.imported[0].fileURL.path.hasPrefix(originalMedia.path + "/"))
        try? FileManager.default.removeItem(at: root)
    }

    @Test("Selecting an Apple Music library references originals and relinks old managed copies")
    @MainActor
    func importsAppleMusicMediaFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let media = root.appendingPathComponent("Media.localized", isDirectory: true)
        let managed = media.appendingPathComponent("Ongaku Media", isDirectory: true)
        let sourceDirectory = media.appendingPathComponent("Music/Artist/Album", isDirectory: true)
        let source = sourceDirectory.appendingPathComponent("Track.mp3")
        let secondSource = sourceDirectory.appendingPathComponent("Second Track.m4a")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try Data([0x49, 0x44, 0x33, 10, 11, 12]).write(to: source)
        try Data([0, 0, 0, 20, 21, 22]).write(to: secondSource)

        let repository = LibraryRepository(
            rootURL: root.appendingPathComponent("Catalog"),
            mediaURL: managed
        )
        let oldImport = await repository.importFiles([source], existing: [])
        #expect(oldImport.imported.count == 1)
        let oldManagedCopy = try #require(oldImport.imported.first?.fileURL)
        try await repository.save(tracks: oldImport.imported)

        let store = LibraryStore(repository: repository)
        await store.load()
        let first = await store.importAppleMusicMediaFolder(media, excluding: managed)
        #expect(first.discovered == 2)
        #expect(first.imported == 1)
        #expect(first.relinked == 1)
        #expect(store.tracks.count == 2)
        #expect(Set(store.tracks.map { $0.fileURL.standardizedFileURL }) == Set([
            source.standardizedFileURL,
            secondSource.standardizedFileURL
        ]))
        #expect(FileManager.default.fileExists(atPath: oldManagedCopy.path))

        let second = await store.importAppleMusicMediaFolder(media, excluding: managed)
        #expect(second.discovered == 2)
        #expect(second.imported == 0)
        #expect(second.relinked == 0)
        #expect(store.tracks.count == 2)
        try? FileManager.default.removeItem(at: root)
    }

    @Test("Registering a dropped folder preserves its hierarchy and every audio file")
    @MainActor
    func registersDroppedFolderInPlace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let musicFolder = root.appendingPathComponent("Existing Music", isDirectory: true)
        let firstDirectory = musicFolder.appendingPathComponent(
            "Artist/First Album", isDirectory: true)
        let secondDirectory = musicFolder.appendingPathComponent(
            "Artist/Second Album/Disc 2", isDirectory: true)
        let first = firstDirectory.appendingPathComponent("First Track.mp3")
        let second = secondDirectory.appendingPathComponent("Second Track.flac")
        let firstData = Data([0x49, 0x44, 0x33, 31, 32, 33])
        let secondData = Data([0x66, 0x4C, 0x61, 0x43, 41, 42, 43])
        try FileManager.default.createDirectory(
            at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: secondDirectory, withIntermediateDirectories: true)
        try firstData.write(to: first)
        try secondData.write(to: second)
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = LibraryRepository(
            rootURL: root.appendingPathComponent("Catalog"),
            mediaURL: musicFolder
        )
        let store = LibraryStore(repository: repository)
        let summary = await store.registerMediaFolderInPlace(musicFolder)

        #expect(summary.discovered == 2)
        #expect(summary.imported == 2)
        #expect(summary.issues == 0)
        #expect(
            Set(store.tracks.map { $0.fileURL.standardizedFileURL })
                == Set([
                    first.standardizedFileURL,
                    second.standardizedFileURL,
                ]))
        #expect(try Data(contentsOf: first) == firstData)
        #expect(try Data(contentsOf: second) == secondData)
        #expect(
            !FileManager.default.fileExists(
                atPath: musicFolder.appendingPathComponent("Ongaku Media").path))
    }

    @Test("URL audio import accepts only public standard-port HTTPS URLs")
    func validatesAudioImportURLs() throws {
        let valid = try URLAudioImportPolicy.validatedURL(
            from: "https://cdn.example.com/releases/song.flac"
        )
        #expect(valid.host == "cdn.example.com")

        let blocked = [
            "http://cdn.example.com/song.flac",
            "https://localhost/song.flac",
            "https://127.0.0.1/song.flac",
            "https://10.1.2.3/song.flac",
            "https://172.20.1.2/song.flac",
            "https://192.168.1.2/song.flac",
            "https://user:password@cdn.example.com/song.flac",
            "https://cdn.example.com:8443/song.flac",
        ]
        for value in blocked {
            #expect(throws: URLAudioImportError.self) {
                try URLAudioImportPolicy.validatedURL(from: value)
            }
        }
    }

    @Test("URL audio response requires a compatible MIME type, extension, and size")
    func validatesAudioImportResponse() throws {
        let url = URL(string: "https://cdn.example.com/song.flac")!
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "audio/flac",
                "Content-Length": "1234",
            ]
        ))
        let descriptor = try URLAudioImportPolicy.descriptor(
            response: response,
            fallbackURL: url
        )
        #expect(descriptor.pathExtension == "flac")
        #expect(descriptor.mimeType == "audio/flac")
        #expect(descriptor.expectedSize == 1_234)

        let mismatched = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "audio/mpeg"]
        ))
        #expect(throws: URLAudioImportError.mismatchedFileType) {
            try URLAudioImportPolicy.descriptor(response: mismatched, fallbackURL: url)
        }

        let oversized = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "Content-Type": "audio/flac",
                "Content-Length": String(URLAudioImportPolicy.maximumFileSize + 1),
            ]
        ))
        #expect(throws: URLAudioImportError.fileTooLarge) {
            try URLAudioImportPolicy.descriptor(response: oversized, fallbackURL: url)
        }
    }

    @Test("URL audio import validates the downloaded audio contents")
    func validatesDownloadedAudioContents() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let audioURL = root.appendingPathComponent("valid.aiff")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
            buffer.frameLength = 64
            try file.write(from: buffer)
        }
        try URLAudioImportPolicy.validateDownloadedFile(audioURL)

        let fakeURL = root.appendingPathComponent("fake.mp3")
        try Data("not audio".utf8).write(to: fakeURL)
        #expect(throws: URLAudioImportError.invalidAudio) {
            try URLAudioImportPolicy.validateDownloadedFile(fakeURL)
        }
    }

    @Test("Music and iTunes XML migration previews songs, metadata, and user playlists")
    func previewsLegacyMusicLibrary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let registeredURL = root.appendingPathComponent("Registered.mp3")
        let readyURL = root.appendingPathComponent("Ready.flac")
        let unsupportedURL = root.appendingPathComponent("Notes.txt")
        try Data([0x49, 0x44, 0x33]).write(to: registeredURL)
        try Data([0x66, 0x4C, 0x61, 0x43]).write(to: readyURL)
        try Data("notes".utf8).write(to: unsupportedURL)
        let existing = Track(
            id: UUID(), title: "Registered", artist: "Artist", album: "Album",
            duration: 1, fileSize: 3, managedPath: registeredURL.path,
            sha256: "existing", addedAt: .now, health: .verified
        )
        let xmlURL = root.appendingPathComponent("Music Library.xml")
        let library: [String: Any] = [
            "Library Persistent ID": "LIBRARY123",
            "Tracks": [
                "1": [
                    "Track ID": 1, "Name": "Registered", "Artist": "Artist",
                    "Album": "Album", "Location": registeredURL.absoluteString,
                ],
                "2": [
                    "Track ID": 2, "Name": "Migration Song", "Artist": "Migration Artist",
                    "Sort Artist": "Artist, Migration", "Album": "Migration Album",
                    "Album Artist": "Various", "Composer": "Composer", "Genre": "Jazz",
                    "BPM": 123, "Copyright": "© Migration",
                    "Year": 1999, "Track Number": 3, "Track Count": 12,
                    "Disc Number": 1, "Disc Count": 2, "Rating": 80,
                    "Play Count": 7, "Loved": true, "Compilation": true,
                    "Comments": "From XML", "Location": readyURL.absoluteString,
                ],
                "3": [
                    "Track ID": 3, "Name": "Missing",
                    "Location": root.appendingPathComponent("Missing.mp3").absoluteString,
                ],
                "4": [
                    "Track ID": 4, "Name": "Unsupported",
                    "Location": unsupportedURL.absoluteString,
                ],
            ],
            "Playlists": [
                [
                    "Name": "Road Songs", "Playlist Persistent ID": "PLAYLIST1",
                    "Playlist Items": [["Track ID": 2], ["Track ID": 1]],
                ],
                ["Name": "Library", "Master": true, "Playlist Items": []],
                ["Name": "Smart", "Smart Info": Data([1]), "Playlist Items": []],
            ],
        ]
        try PropertyListSerialization.data(
            fromPropertyList: library,
            format: .xml,
            options: 0
        ).write(to: xmlURL)

        let preview = try LegacyLibraryMigrationService.preview(
            from: xmlURL,
            existingTracks: [existing]
        )

        #expect(preview.sourceName == "LIBRARY123")
        #expect(preview.readyCount == 1)
        #expect(preview.registeredCount == 1)
        #expect(preview.missingCount == 1)
        #expect(preview.unsupportedCount == 1)
        let track = try #require(preview.tracks.first { $0.id == 2 })
        #expect(track.artistSortName == "Artist, Migration")
        #expect(track.albumArtist == "Various")
        #expect(track.beatsPerMinute == 123)
        #expect(track.copyright == "© Migration")
        #expect(track.rating == 4)
        #expect(track.playCount == 7)
        #expect(track.isFavorite)
        #expect(track.isCompilation)
        #expect(preview.playlists.map(\.name) == ["Road Songs"])
        #expect(preview.playlists[0].trackIDs == [2, 1])
    }

    @Test("Music XML migration copies originals, restores metadata and playlists, and is idempotent")
    @MainActor
    func importsLegacyMusicLibrary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Original.aiff")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
            buffer.frameLength = 128
            try file.write(from: buffer)
        }
        let originalHash = try LibraryRepository.sha256(of: source)
        let addedAt = Date(timeIntervalSince1970: 1_000_000)
        let xmlURL = root.appendingPathComponent("Library.xml")
        let library: [String: Any] = [
            "Tracks": [
                "10": [
                    "Track ID": 10, "Name": "Imported Title", "Artist": "Imported Artist",
                    "Album": "Imported Album", "Composer": "Imported Composer",
                    "Genre": "Ambient", "Year": 2005, "Track Number": 2,
                    "Track Count": 8, "Rating": 100, "Play Count": 11,
                    "Loved": true, "Date Added": addedAt, "Location": source.absoluteString,
                ],
            ],
            "Playlists": [[
                "Name": "XML Favorites", "Playlist Persistent ID": "XMLFAVORITES",
                "Playlist Items": [["Track ID": 10]],
            ]],
        ]
        try PropertyListSerialization.data(
            fromPropertyList: library,
            format: .xml,
            options: 0
        ).write(to: xmlURL)
        let repository = LibraryRepository(
            rootURL: root.appendingPathComponent("Catalog"),
            mediaURL: root.appendingPathComponent("Managed Media")
        )
        let store = LibraryStore(repository: repository)
        await store.load()
        let preview = try LegacyLibraryMigrationService.preview(from: xmlURL, existingTracks: [])

        let first = try await store.importLegacyLibrary(preview)

        #expect(first.imported == 1)
        #expect(first.playlists == 1)
        let imported = try #require(store.tracks.first)
        #expect(imported.title == "Imported Title")
        #expect(imported.artist == "Imported Artist")
        #expect(imported.album == "Imported Album")
        #expect(imported.composer == "Imported Composer")
        #expect(imported.rating == 5)
        #expect(imported.playCount == 11)
        #expect(imported.isFavorite)
        #expect(imported.addedAt == addedAt)
        #expect(imported.fileURL.standardizedFileURL != source.standardizedFileURL)
        #expect(try LibraryRepository.sha256(of: source) == originalHash)
        #expect(store.playlists.first?.name == "XML Favorites")
        #expect(store.playlists.first?.entries.map(\.trackID) == [imported.id])

        let second = try await store.importLegacyLibrary(preview)
        #expect(second.imported == 0)
        #expect(second.playlists == 0)
        #expect(store.tracks.count == 1)
        #expect(store.playlists.count == 1)
    }

    @Test("Another Ongaku library merges metadata, smart playlists, folders, and audio non-destructively")
    @MainActor
    func importsAnotherOngakuLibrary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("Source Library", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let sourceAudio = sourceRoot.appendingPathComponent("Source Song.aiff")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: sourceAudio, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
            buffer.frameLength = 128
            try file.write(from: buffer)
        }
        let sourceAudioHash = try LibraryRepository.sha256(of: sourceAudio)
        let sourceTrack = Track(
            id: UUID(), title: "Ongaku Source", artist: "Source Artist",
            album: "Source Album", composer: "Source Composer", genre: "Electronic",
            playCount: 19, comments: "Preserved", lyrics: TrackLyrics(
                plainText: "Source lyrics", source: .manual, isManuallyEdited: true
            ), duration: 1, fileSize: 1, managedPath: sourceAudio.path,
            sha256: sourceAudioHash, addedAt: Date(timeIntervalSince1970: 2_000_000),
            lastVerifiedAt: .now, health: .verified, isPinned: true,
            isFavorite: true, rating: 5
        )
        let missingTrack = Track(
            id: UUID(), title: "Missing", artist: "Source Artist", album: "Source Album",
            duration: 1, fileSize: 1,
            managedPath: sourceRoot.appendingPathComponent("Missing.mp3").path,
            sha256: "missing-hash", addedAt: .now, health: .missing
        )
        let folder = PlaylistFolder(name: "Imported Folder", sortOrder: 0)
        let regular = Playlist(
            name: "Imported Regular", folderID: folder.id, sortOrder: 0,
            entries: [PlaylistEntry(trackID: sourceTrack.id)]
        )
        var smartDefinition = SmartPlaylistDefinition()
        smartDefinition.root.rules = [SmartPlaylistRule(
            field: .favorite,
            comparison: .isTrue,
            value: ""
        )]
        let smart = Playlist(
            name: "Imported Smart", sortOrder: 0,
            smartDefinition: smartDefinition
        )
        let sourceDocument = LibraryDocument(
            tracks: [sourceTrack, missingTrack],
            libraryID: UUID(),
            playlists: [regular, smart],
            playlistFolders: [folder]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let sourceManifest = sourceRoot.appendingPathComponent("library-v1.json")
        try encoder.encode(sourceDocument).write(to: sourceManifest, options: .atomic)
        let manifestBefore = try Data(contentsOf: sourceManifest)

        let repository = LibraryRepository(
            rootURL: destinationRoot,
            mediaURL: destinationRoot.appendingPathComponent("Ongaku Media")
        )
        let store = LibraryStore(repository: repository)
        await store.load()
        let preview = try await store.previewOngakuLibrary(at: sourceRoot)

        #expect(preview.readyCount == 1)
        #expect(preview.missingCount == 1)
        #expect(preview.document.playlists.count == 2)
        #expect(preview.document.playlistFolders.count == 1)

        let first = try await store.importOngakuLibrary(preview)

        #expect(first.imported == 1)
        #expect(first.playlists == 2)
        #expect(first.folders == 1)
        let imported = try #require(store.tracks.first)
        #expect(imported.title == "Ongaku Source")
        #expect(imported.composer == "Source Composer")
        #expect(imported.genre == "Electronic")
        #expect(imported.playCount == 19)
        #expect(imported.comments == "Preserved")
        #expect(imported.lyrics?.plainText == "Source lyrics")
        #expect(imported.isPinned)
        #expect(imported.isFavorite)
        #expect(imported.rating == 5)
        #expect(imported.fileURL.standardizedFileURL != sourceAudio.standardizedFileURL)
        #expect(try LibraryRepository.sha256(of: sourceAudio) == sourceAudioHash)
        #expect(try Data(contentsOf: sourceManifest) == manifestBefore)
        #expect(!FileManager.default.fileExists(
            atPath: sourceRoot.appendingPathComponent("library-schema-12.migration-backup.json").path
        ))
        let importedFolder = try #require(store.playlistFolders.first)
        let importedRegular = try #require(store.playlists.first { $0.name == "Imported Regular" })
        let importedSmart = try #require(store.playlists.first { $0.name == "Imported Smart" })
        #expect(importedRegular.folderID == importedFolder.id)
        #expect(importedRegular.entries.map(\.trackID) == [imported.id])
        #expect(importedSmart.smartDefinition == smartDefinition)

        let secondPreview = try await store.previewOngakuLibrary(at: sourceRoot)
        #expect(secondPreview.registeredCount == 1)
        let second = try await store.importOngakuLibrary(secondPreview)
        #expect(second.imported == 0)
        #expect(second.playlists == 0)
        #expect(second.folders == 0)
        #expect(store.tracks.count == 1)
        #expect(store.playlists.count == 2)
        #expect(store.playlistFolders.count == 1)
        #expect(try Data(contentsOf: sourceManifest) == manifestBefore)
    }

    @Test("Shared folder migration previews, verifies, copies, and remains idempotent")
    @MainActor
    func importsSharedFolderNonDestructively() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("Mounted Share", isDirectory: true)
        let nested = shared.appendingPathComponent("Artist/Album", isDirectory: true)
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let source = nested.appendingPathComponent("Shared Song.aiff")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
            buffer.frameLength = 128
            try file.write(from: buffer)
        }
        let sourceHash = try LibraryRepository.sha256(of: source)
        let sourceData = try Data(contentsOf: source)

        let repository = LibraryRepository(
            rootURL: destination,
            mediaURL: destination.appendingPathComponent("Ongaku Media")
        )
        let store = LibraryStore(repository: repository)
        await store.load()
        let preview = try await store.previewSharedFolder(at: shared)

        #expect(preview.readyCount == 1)
        #expect(preview.registeredCount == 0)
        #expect(preview.rows.first?.relativePath == "Artist/Album/Shared Song.aiff")
        #expect(preview.rows.first?.sha256 == sourceHash)

        let first = try await store.importSharedFolder(preview)
        #expect(first.imported == 1)
        #expect(first.issues == 0)
        #expect(store.tracks.count == 1)
        #expect(store.tracks[0].fileURL.standardizedFileURL != source.standardizedFileURL)
        #expect(try LibraryRepository.sha256(of: store.tracks[0].fileURL) == sourceHash)
        #expect(try Data(contentsOf: source) == sourceData)

        let secondPreview = try await store.previewSharedFolder(at: shared)
        #expect(secondPreview.readyCount == 0)
        #expect(secondPreview.registeredCount == 1)
        #expect(try Data(contentsOf: source) == sourceData)
    }

    @Test("Media organization dry-runs and transactionally moves only managed files")
    @MainActor
    func organizesManagedMediaWithDryRun() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = root.appendingPathComponent("Catalog", isDirectory: true)
        let oldMedia = root.appendingPathComponent("Old Media", isDirectory: true)
        let newMedia = root.appendingPathComponent("New Media", isDirectory: true)
        let externalRoot = root.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: oldMedia, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)

        func writeAudio(_ url: URL) throws {
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
            buffer.frameLength = 128
            try file.write(from: buffer)
        }
        let managedSource = oldMedia.appendingPathComponent("Loose.aiff")
        let externalSource = externalRoot.appendingPathComponent("Reference.aiff")
        try writeAudio(managedSource)
        try writeAudio(externalSource)
        let managedHash = try LibraryRepository.sha256(of: managedSource)
        let externalHash = try LibraryRepository.sha256(of: externalSource)
        let managed = Track(
            id: UUID(), title: "Managed", artist: "Artist", album: "Album", duration: 1,
            fileSize: 1, managedPath: managedSource.path, sha256: managedHash,
            addedAt: .now, health: .verified
        )
        let external = Track(
            id: UUID(), title: "External", artist: "Artist", album: "Album", duration: 1,
            fileSize: 1, managedPath: externalSource.path, sha256: externalHash,
            addedAt: .now, health: .verified
        )
        let repository = LibraryRepository(rootURL: catalog, mediaURL: oldMedia)
        try await repository.save(document: LibraryDocument(tracks: [managed, external]))
        let store = LibraryStore(repository: repository)
        await store.load()

        let preview = try await store.previewMediaOrganization(destination: newMedia)
        #expect(preview.moveCount == 1)
        #expect(preview.externalCount == 1)
        let planned = try #require(preview.items.first { $0.status == .move })
        #expect(planned.destinationURL.path.hasSuffix("Artist/Album/Loose.aiff"))
        #expect(FileManager.default.fileExists(atPath: managedSource.path))
        #expect(!FileManager.default.fileExists(atPath: planned.destinationURL.path))

        let summary = try await store.executeMediaOrganization(preview)
        #expect(summary.moved == 1)
        #expect(summary.updatedTracks == 1)
        #expect(!FileManager.default.fileExists(atPath: managedSource.path))
        #expect(FileManager.default.fileExists(atPath: planned.destinationURL.path))
        #expect(try LibraryRepository.sha256(of: planned.destinationURL) == managedHash)
        #expect(store.tracks.first { $0.id == managed.id }?.fileURL == planned.destinationURL)
        #expect(store.tracks.first { $0.id == external.id }?.fileURL == externalSource)
        #expect(!FileManager.default.fileExists(
            atPath: catalog.appendingPathComponent("media-organization-journal-v1.json").path
        ))
    }

    @Test("Media organization rolls back completed moves when a later checksum changes")
    @MainActor
    func rollsBackFailedMediaOrganization() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = root.appendingPathComponent("Catalog", isDirectory: true)
        let media = root.appendingPathComponent("Media", isDirectory: true)
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        var sourceURLs: [URL] = []
        var tracks: [Track] = []
        for name in ["A.aiff", "B.aiff"] {
            let url = media.appendingPathComponent(name)
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
                buffer.frameLength = 128
                try file.write(from: buffer)
            }
            let hash = try LibraryRepository.sha256(of: url)
            sourceURLs.append(url)
            tracks.append(Track(
                id: UUID(), title: name, artist: "Artist", album: "Album", duration: 1,
                fileSize: 1, managedPath: url.path, sha256: hash,
                addedAt: .now, health: .verified
            ))
        }
        let repository = LibraryRepository(rootURL: catalog, mediaURL: media)
        try await repository.save(document: LibraryDocument(tracks: tracks))
        let store = LibraryStore(repository: repository)
        await store.load()
        let preview = try await store.previewMediaOrganization(destination: destination)
        try Data("changed".utf8).write(to: sourceURLs[1])
        #expect(preview.moveCount == 2)
        #expect(try LibraryRepository.sha256(of: sourceURLs[1]) != tracks[1].sha256)

        do {
            _ = try await store.executeMediaOrganization(preview)
            Issue.record("Expected checksum verification to fail")
        } catch {}

        #expect(FileManager.default.fileExists(atPath: sourceURLs[0].path))
        #expect(FileManager.default.fileExists(atPath: sourceURLs[1].path))
        #expect(!FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("Artist/Album/A.aiff").path
        ))
        #expect(store.tracks.map(\.managedPath) == tracks.map(\.managedPath))
        #expect(!FileManager.default.fileExists(
            atPath: catalog.appendingPathComponent("media-organization-journal-v1.json").path
        ))
    }

    @Test("An interrupted Media organization journal rolls files back on next launch")
    func recoversInterruptedMediaOrganization() async throws {
        struct Entry: Codable {
            var sourcePath: String
            var destinationPath: String
            var expectedSHA256: String
            var moved: Bool
        }
        struct Journal: Codable {
            var schemaVersion = 1
            var updatedAt = Date.now
            var entries: [Entry]
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = root.appendingPathComponent("Catalog", isDirectory: true)
        let media = root.appendingPathComponent("Media", isDirectory: true)
        let source = media.appendingPathComponent("Loose.aiff")
        let destination = media.appendingPathComponent("Artist/Album/Loose.aiff")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
            buffer.frameLength = 128
            try file.write(from: buffer)
        }
        let hash = try LibraryRepository.sha256(of: source)
        let track = Track(
            id: UUID(), title: "Loose", artist: "Artist", album: "Album",
            duration: 1, fileSize: 1, managedPath: source.path, sha256: hash,
            addedAt: .now, health: .verified
        )
        let repository = LibraryRepository(rootURL: catalog, mediaURL: media)
        try await repository.save(document: LibraryDocument(tracks: [track]))
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: source, to: destination)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Journal(entries: [Entry(
            sourcePath: source.path,
            destinationPath: destination.path,
            expectedSHA256: hash,
            moved: false
        )])).write(
            to: catalog.appendingPathComponent("media-organization-journal-v1.json"),
            options: .atomic
        )

        let relaunched = LibraryRepository(rootURL: catalog, mediaURL: media)
        let loaded = try await relaunched.load()
        #expect(loaded.document.tracks.first?.managedPath == source.path)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(
            atPath: catalog.appendingPathComponent("media-organization-journal-v1.json").path
        ))
    }

    @Test("Apple Music media-folder-url is decoded")
    func decodesAppleMusicMediaFolder() {
        let expected = URL(fileURLWithPath: "/Volumes/Music/Media.localized", isDirectory: true)
        let preferences: [String: Any] = ["media-folder-url": expected.absoluteString]
        #expect(AppleMusicSettingsReader.mediaFolderURL(from: preferences) == expected.standardizedFileURL)
    }
}
