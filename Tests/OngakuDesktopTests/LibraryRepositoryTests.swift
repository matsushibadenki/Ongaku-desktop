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

    @Test("Manifest round-trips atomically")
    func manifestRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = LibraryRepository(rootURL: root)
        let track = Track(
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

        try await repository.save(tracks: [track])
        let loaded = try await repository.load()
        #expect(loaded.document.tracks.count == 1)
        #expect(loaded.document.tracks[0].id == track.id)
        #expect(loaded.document.tracks[0].title == track.title)
        #expect(loaded.document.tracks[0].sha256 == track.sha256)
        #expect(loaded.document.tracks[0].health == .verified)
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

    @Test("Apple Music media-folder-url is decoded")
    func decodesAppleMusicMediaFolder() {
        let expected = URL(fileURLWithPath: "/Volumes/Music/Media.localized", isDirectory: true)
        let preferences: [String: Any] = ["media-folder-url": expected.absoluteString]
        #expect(AppleMusicSettingsReader.mediaFolderURL(from: preferences) == expected.standardizedFileURL)
    }
}
