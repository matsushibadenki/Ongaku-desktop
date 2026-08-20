import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Catalog metadata editing")
struct MetadataEditingTests {
    @Test("Song, album, and artist edits persist without changing unsupported files")
    @MainActor
    func editsPersistAtomically() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = LibraryRepository(rootURL: root)
        let first = makeTrack(title: "One", album: "Before")
        let second = makeTrack(title: "Two", album: "Before")
        try await repository.save(tracks: [first, second])

        let store = LibraryStore(repository: repository)
        await store.load()
        try await store.updateTrackMetadata(
            id: first.id,
            title: "One Edited",
            artist: "Artist",
            album: "Before"
        )
        try await store.updateAlbumMetadata(
            trackIDs: [first.id, second.id],
            artist: "Album Artist",
            album: "After"
        )
        try await store.updateArtistMetadata(
            trackIDs: [first.id, second.id],
            artist: "Renamed Artist"
        )

        let loaded = try await repository.load().document.tracks
        #expect(loaded.count == 2)
        #expect(loaded.first(where: { $0.id == first.id })?.title == "One Edited")
        #expect(loaded.allSatisfy { $0.artist == "Renamed Artist" && $0.album == "After" })
        #expect(loaded.first(where: { $0.id == first.id })?.managedPath == first.managedPath)
        #expect(loaded.first(where: { $0.id == first.id })?.sha256 == first.sha256)
    }

    @Test("Only lossless passthrough containers are selected for embedding")
    func embeddingSupportPolicy() {
        #expect(AudioFileMetadataWriter.supportsEmbedding(at: URL(fileURLWithPath: "/tmp/song.m4a")))
        #expect(AudioFileMetadataWriter.supportsEmbedding(at: URL(fileURLWithPath: "/tmp/song.M4B")))
        #expect(AudioFileMetadataWriter.supportsEmbedding(at: URL(fileURLWithPath: "/tmp/song.mp4")))
        #expect(!AudioFileMetadataWriter.supportsEmbedding(at: URL(fileURLWithPath: "/tmp/song.mp3")))
        #expect(!AudioFileMetadataWriter.supportsEmbedding(at: URL(fileURLWithPath: "/tmp/song.flac")))
    }

    @Test("Music-style song metadata persists and seeds playback statistics")
    @MainActor
    func extendedMetadataPersists() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        let track = makeTrack(title: "Before", album: "Album")
        try await repository.save(tracks: [track])
        let store = LibraryStore(repository: repository)
        await store.load()

        var metadata = TrackMetadataValues(track: track)
        metadata.title = "After"
        metadata.artistSortName = "Artist Reading"
        metadata.albumSortName = "Album Reading"
        metadata.albumArtist = "Album Artist"
        metadata.albumArtistSortName = "Album Artist Reading"
        metadata.composer = "Composer"
        metadata.composerSortName = "Composer Reading"
        metadata.grouping = "Movement"
        metadata.genre = "Ambient"
        metadata.releaseYear = 2026
        metadata.trackNumber = 2
        metadata.trackCount = 12
        metadata.discNumber = 1
        metadata.discCount = 2
        metadata.isCompilation = true
        metadata.rating = 4
        metadata.playCount = 7
        metadata.comments = "Archival master"
        try await store.updateTrackMetadata(id: track.id, metadata: metadata)

        let loaded = try #require(try await repository.load().document.tracks.first)
        #expect(loaded.title == "After")
        #expect(loaded.artistSortName == "Artist Reading")
        #expect(loaded.albumSortName == "Album Reading")
        #expect(loaded.albumArtist == "Album Artist")
        #expect(loaded.albumArtistSortName == "Album Artist Reading")
        #expect(loaded.composer == "Composer")
        #expect(loaded.composerSortName == "Composer Reading")
        #expect(loaded.grouping == "Movement")
        #expect(loaded.genre == "Ambient")
        #expect(loaded.releaseYear == 2026)
        #expect(loaded.trackNumber == 2 && loaded.trackCount == 12)
        #expect(loaded.discNumber == 1 && loaded.discCount == 2)
        #expect(loaded.isCompilation)
        #expect(loaded.rating == 4)
        #expect(loaded.comments == "Archival master")
        #expect(store.playbackStatistics(for: track.id).playCount == 7)
    }

    @Test("Music-style album edits preserve each song title and track number")
    @MainActor
    func albumMetadataPreservesSongSpecificValues() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        var first = makeTrack(title: "First", album: "Before")
        first.trackNumber = 1
        var second = makeTrack(title: "Second", album: "Before")
        second.trackNumber = 2
        try await repository.save(tracks: [first, second])
        let store = LibraryStore(repository: repository)
        await store.load()

        var metadata = TrackMetadataValues(track: first)
        metadata.title = "Must Not Replace Song Titles"
        metadata.artist = "New Artist"
        metadata.album = "After"
        metadata.albumArtist = "Various Artists"
        metadata.genre = "Soundtrack"
        metadata.releaseYear = 2026
        metadata.trackNumber = 99
        metadata.discNumber = 1
        metadata.discCount = 2
        metadata.isCompilation = true
        metadata.comments = "Album note"
        try await store.updateAlbumMetadata(
            trackIDs: [first.id, second.id],
            metadata: metadata
        )

        let loaded = try await repository.load().document.tracks
        let loadedFirst = try #require(loaded.first(where: { $0.id == first.id }))
        let loadedSecond = try #require(loaded.first(where: { $0.id == second.id }))
        #expect(loadedFirst.title == "First" && loadedSecond.title == "Second")
        #expect(loadedFirst.trackNumber == 1 && loadedSecond.trackNumber == 2)
        #expect(loaded.allSatisfy {
            $0.artist == "New Artist"
                && $0.album == "After"
                && $0.albumArtist == "Various Artists"
                && $0.genre == "Soundtrack"
                && $0.releaseYear == 2026
                && $0.discNumber == 1
                && $0.discCount == 2
                && $0.isCompilation
                && $0.comments == "Album note"
        })
    }

    @Test("Bulk edits change only checked metadata fields")
    @MainActor
    func bulkMetadataPatchPreservesUncheckedValues() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        var first = makeTrack(title: "First", album: "One")
        first.genre = "Jazz"
        first.comments = "Keep first"
        var second = makeTrack(title: "Second", album: "Two")
        second.genre = "Rock"
        second.comments = "Keep second"
        try await repository.save(tracks: [first, second])
        let store = LibraryStore(repository: repository)
        await store.load()

        var values = TrackMetadataValues(track: first)
        values.genre = "Ambient"
        values.comments = "Must not be applied"
        values.title = "Must not replace titles"
        try await store.updateTracksMetadata(
            trackIDs: [first.id, second.id],
            patch: TrackMetadataPatch(fields: [.genre], values: values)
        )

        let loaded = try await repository.load().document.tracks
        let loadedFirst = try #require(loaded.first(where: { $0.id == first.id }))
        let loadedSecond = try #require(loaded.first(where: { $0.id == second.id }))
        #expect(loadedFirst.genre == "Ambient" && loadedSecond.genre == "Ambient")
        #expect(loadedFirst.title == "First" && loadedSecond.title == "Second")
        #expect(loadedFirst.comments == "Keep first")
        #expect(loadedSecond.comments == "Keep second")
        #expect(loadedFirst.album == "One" && loadedSecond.album == "Two")
    }

    @Test("Bulk artist and album edits reconcile shared catalog identities")
    @MainActor
    func bulkMetadataPatchReconcilesIdentities() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        let first = makeTrack(title: "First", album: "One")
        let second = makeTrack(title: "Second", album: "Two")
        try await repository.save(tracks: [first, second])
        let store = LibraryStore(repository: repository)
        await store.load()

        var values = TrackMetadataValues(track: first)
        values.artist = "Shared Artist"
        values.album = "Shared Album"
        try await store.updateTracksMetadata(
            trackIDs: [first.id, second.id],
            patch: TrackMetadataPatch(fields: [.artist, .album], values: values)
        )

        let loaded = try await repository.load().document.tracks
        #expect(loaded.allSatisfy {
            $0.artist == "Shared Artist" && $0.album == "Shared Album"
        })
        #expect(Set(loaded.map(\.artistID)).count == 1)
        #expect(Set(loaded.map(\.albumID)).count == 1)
    }

    @Test("Bulk artist edits preserve distinct album identities")
    @MainActor
    func bulkArtistPatchDoesNotMergeSameNamedAlbums() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        var first = makeTrack(title: "First", album: "Greatest Hits")
        var second = makeTrack(title: "Second", album: "Greatest Hits")
        first.albumID = UUID()
        second.albumID = UUID()
        try await repository.save(tracks: [first, second])
        let store = LibraryStore(repository: repository)
        await store.load()

        var values = TrackMetadataValues(track: first)
        values.artist = "Corrected Artist"
        try await store.updateTracksMetadata(
            trackIDs: [first.id, second.id],
            patch: TrackMetadataPatch(fields: [.artist], values: values)
        )

        let loaded = try await repository.load().document.tracks
        #expect(loaded.allSatisfy { $0.artist == "Corrected Artist" })
        #expect(Set(loaded.map(\.artistID)).count == 1)
        #expect(Set(loaded.map(\.albumID)).count == 2)
    }

    @Test("Schema 7 catalogs migrate to Music-style metadata defaults")
    func migratesSchemaSevenMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var document = LibraryDocument(tracks: [makeTrack(title: "Legacy", album: "Album")])
        document.schemaVersion = 7
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(
            to: root.appendingPathComponent("library-v1.json"),
            options: .atomic
        )

        let result = try await LibraryRepository(rootURL: root).load()

        #expect(result.migratedFromSchemaVersion == 7)
        #expect(result.document.schemaVersion == LibraryDocument.currentSchema)
        #expect(result.document.tracks.first?.composer == "")
        #expect(result.document.tracks.first?.playCount == 0)
    }

    @Test("Schema 8 catalogs migrate to unpinned standard-view defaults")
    func migratesSchemaEightPinDefaults() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var document = LibraryDocument(tracks: [makeTrack(title: "Legacy", album: "Album")])
        document.schemaVersion = 8
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(
            to: root.appendingPathComponent("library-v1.json"),
            options: .atomic
        )

        let result = try await LibraryRepository(rootURL: root).load()

        #expect(result.migratedFromSchemaVersion == 8)
        #expect(result.document.schemaVersion == LibraryDocument.currentSchema)
        #expect(result.document.tracks.first?.isPinned == false)
    }

    private func makeTrack(title: String, album: String) -> Track {
        Track(
            id: UUID(),
            title: title,
            artist: "Artist",
            album: album,
            duration: 10,
            fileSize: 100,
            managedPath: "/tmp/\(UUID().uuidString).m4a",
            sha256: UUID().uuidString,
            addedAt: .now,
            lastVerifiedAt: .now,
            health: .verified
        )
    }
}
