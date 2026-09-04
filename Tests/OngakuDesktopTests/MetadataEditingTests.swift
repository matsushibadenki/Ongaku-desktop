import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Catalog metadata editing")
struct MetadataEditingTests {
    @Test("Confirmed artist and album edits move only affected managed files")
    @MainActor
    func organizesAffectedFilesAfterMetadataEdit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = root.appendingPathComponent("Catalog", isDirectory: true)
        let media = root.appendingPathComponent("Media", isDirectory: true)
        let oldDirectory = media.appendingPathComponent(
            "Old Artist/Old Album",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: oldDirectory,
            withIntermediateDirectories: true
        )
        let editedSource = oldDirectory.appendingPathComponent("Edited.mp3")
        let untouchedSource = oldDirectory.appendingPathComponent("Untouched.mp3")
        try Data("edited audio".utf8).write(to: editedSource)
        try Data("untouched audio".utf8).write(to: untouchedSource)

        let edited = Track(
            id: UUID(), title: "Edited", artist: "Old Artist", album: "Old Album",
            duration: 1, fileSize: 12, managedPath: editedSource.path,
            sha256: try LibraryRepository.sha256(of: editedSource),
            addedAt: .now, health: .verified
        )
        let untouched = Track(
            id: UUID(), title: "Untouched", artist: "Old Artist", album: "Old Album",
            duration: 1, fileSize: 15, managedPath: untouchedSource.path,
            sha256: try LibraryRepository.sha256(of: untouchedSource),
            addedAt: .now, health: .verified
        )
        let repository = LibraryRepository(rootURL: catalog, mediaURL: media)
        try await repository.save(document: LibraryDocument(tracks: [edited, untouched]))
        let store = LibraryStore(repository: repository)
        await store.load()

        try await store.updateTrackMetadata(
            id: edited.id,
            title: edited.title,
            artist: "New Artist",
            album: "New Album"
        )
        let summary = try await store.organizeManagedMediaAfterMetadataChange(
            trackIDs: [edited.id]
        )

        let destination = media.appendingPathComponent("New Artist/New Album/Edited.mp3")
        #expect(summary.moved == 1)
        #expect(summary.updatedTracks == 1)
        #expect(store.tracks.first { $0.id == edited.id }?.fileURL == destination)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: editedSource.path))
        #expect(store.tracks.first { $0.id == untouched.id }?.fileURL == untouchedSource)
        #expect(FileManager.default.fileExists(atPath: untouchedSource.path))
    }

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
        metadata.participantCredits = "Piano: Example Player"
        metadata.workName = "Example Suite"
        metadata.movementName = "Finale"
        metadata.movementNumber = 4
        metadata.movementCount = 4
        metadata.beatsPerMinute = 128
        metadata.copyright = "© 2026 Example Records"
        metadata.isrc = "JPAAA2600001"
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
        #expect(loaded.participantCredits == "Piano: Example Player")
        #expect(loaded.workName == "Example Suite")
        #expect(loaded.movementName == "Finale")
        #expect(loaded.movementNumber == 4 && loaded.movementCount == 4)
        #expect(loaded.beatsPerMinute == 128)
        #expect(loaded.copyright == "© 2026 Example Records")
        #expect(loaded.isrc == "JPAAA2600001")
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
        first.movementName = "Allegro"
        first.beatsPerMinute = 120
        first.isrc = "JPAAA2600001"
        var second = makeTrack(title: "Second", album: "Before")
        second.trackNumber = 2
        second.movementName = "Adagio"
        second.beatsPerMinute = 72
        second.isrc = "JPAAA2600002"
        try await repository.save(tracks: [first, second])
        let store = LibraryStore(repository: repository)
        await store.load()

        var metadata = TrackMetadataValues(track: first)
        metadata.title = "Must Not Replace Song Titles"
        metadata.artist = "New Artist"
        metadata.album = "After"
        metadata.albumArtist = "Various Artists"
        metadata.genre = "Soundtrack"
        metadata.participantCredits = "Orchestra: Example Ensemble"
        metadata.workName = "Shared Work"
        metadata.movementName = "Must Not Spread"
        metadata.beatsPerMinute = 200
        metadata.copyright = "© Example"
        metadata.isrc = "INVALIDSHARED"
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
        #expect(loadedFirst.movementName == "Allegro" && loadedSecond.movementName == "Adagio")
        #expect(loadedFirst.beatsPerMinute == 120 && loadedSecond.beatsPerMinute == 72)
        #expect(loadedFirst.isrc == "JPAAA2600001" && loadedSecond.isrc == "JPAAA2600002")
        #expect(loaded.allSatisfy {
            $0.artist == "New Artist"
                && $0.album == "After"
                && $0.albumArtist == "Various Artists"
                && $0.genre == "Soundtrack"
                && $0.participantCredits == "Orchestra: Example Ensemble"
                && $0.workName == "Shared Work"
                && $0.copyright == "© Example"
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

    @Test("LRC parsing supports offsets, fractions, and repeated timestamps")
    func parsesSyncedLyrics() throws {
        let lyrics = try LRCParser.parse(
            """
            [ar:Artist]
            [offset:+500]
            [00:01.00][00:02.50]Hello
            [01:00.25]World
            """
        )

        #expect(lyrics.source == .lrcFile)
        #expect(lyrics.plainText == "Hello\nHello\nWorld")
        #expect(lyrics.syncedLines.map(\.time) == [1.5, 3.0, 60.75])
        #expect(lyrics.syncedLines.map(\.text) == ["Hello", "Hello", "World"])
    }

    @Test("Synced lyrics select the latest line at the playback position")
    func resolvesActiveLyricsLine() {
        let first = TimedLyricsLine(time: 2, text: "First")
        let second = TimedLyricsLine(time: 5, text: "Second")
        let lines = [first, second]

        #expect(LyricsTimeline.activeLineID(in: lines, at: 1) == nil)
        #expect(LyricsTimeline.activeLineID(in: lines, at: 2) == first.id)
        #expect(LyricsTimeline.activeLineID(in: lines, at: 8) == second.id)
    }

    @Test("Manual and synchronized lyrics persist with the song")
    @MainActor
    func lyricsPersist() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        let track = makeTrack(title: "Lyrics Song", album: "Album")
        try await repository.save(tracks: [track])
        let store = LibraryStore(repository: repository)
        await store.load()
        let lyrics = try LRCParser.parse("[00:01.25]First\n[00:03.00]Second")

        try await store.updateTrackLyrics(id: track.id, lyrics: lyrics)

        let loaded = try #require(try await repository.load().document.tracks.first?.lyrics)
        #expect(loaded.plainText == "First\nSecond")
        #expect(loaded.syncedLines.map(\.time) == [1.25, 3.0])
        #expect(loaded.source == .lrcFile)
    }

    @Test("Schema 9 catalogs migrate to empty lyrics")
    func migratesSchemaNineLyricsDefaults() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var document = LibraryDocument(tracks: [makeTrack(title: "Legacy", album: "Album")])
        document.schemaVersion = 9
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(
            to: root.appendingPathComponent("library-v1.json"),
            options: .atomic
        )

        let result = try await LibraryRepository(rootURL: root).load()

        #expect(result.migratedFromSchemaVersion == 9)
        #expect(result.document.schemaVersion == LibraryDocument.currentSchema)
        #expect(result.document.tracks.first?.lyrics == nil)
    }

    @Test("LRCLIB URLs preserve structured metadata and duration")
    func lrclibBuildsStructuredURLs() throws {
        var track = makeTrack(title: "A Song & More", album: "Album / One")
        track.artist = "Artist + Guest"
        track.duration = 233.4

        let exact = try #require(
            URLComponents(url: LRCLIBService.exactMatchURL(for: track), resolvingAgainstBaseURL: false)
        )
        let exactItems = Dictionary(uniqueKeysWithValues: (exact.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })
        #expect(exact.path == "/api/get")
        #expect(exactItems["track_name"] == "A Song & More")
        #expect(exactItems["artist_name"] == "Artist + Guest")
        #expect(exactItems["album_name"] == "Album / One")
        #expect(exactItems["duration"] == "233")

        let search = try #require(
            URLComponents(url: LRCLIBService.searchURL(for: track), resolvingAgainstBaseURL: false)
        )
        #expect(search.path == "/api/search")
        #expect(search.queryItems?.contains {
            $0.name == "track_name" && $0.value == "A Song & More"
        } == true)
        let titleOnly = try #require(URLComponents(
            url: LRCLIBService.titleOnlySearchURL(for: track),
            resolvingAgainstBaseURL: false
        ))
        #expect(titleOnly.queryItems?.map(\.name) == ["track_name"])
        let albumOnly = try #require(URLComponents(
            url: LRCLIBService.albumOnlySearchURL(for: track),
            resolvingAgainstBaseURL: false
        ))
        #expect(albumOnly.queryItems?.map(\.name) == ["album_name"])
    }

    @Test("LRCLIB confidence rewards matching metadata and duration")
    func lrclibCandidateConfidence() {
        var track = makeTrack(title: "The Song", album: "The Album")
        track.artist = "The Artist"
        track.duration = 180
        let matching = LRCLIBRecord(
            id: 1,
            name: nil,
            trackName: "The Song",
            artistName: "The Artist",
            albumName: "The Album",
            duration: 181,
            instrumental: false,
            plainLyrics: "Lyrics",
            syncedLyrics: nil
        )
        let unrelated = LRCLIBRecord(
            id: 2,
            name: nil,
            trackName: "Different",
            artistName: "Someone Else",
            albumName: "Other",
            duration: 260,
            instrumental: false,
            plainLyrics: "Lyrics",
            syncedLyrics: nil
        )

        let matchingScore = LRCLIBService.evaluate(matching, against: track).confidence
        let unrelatedScore = LRCLIBService.evaluate(unrelated, against: track).confidence
        #expect(matchingScore > 0.95)
        #expect(unrelatedScore < 0.25)
        let titleHint = LRCLIBService.evaluate(
            matching,
            against: track,
            matchKind: .titleHint
        )
        #expect(LRCLIBService.isUsefulFallback(titleHint, for: track))
    }

    @Test("LRCLIB synchronized results retain source identity")
    func lrclibRecordCreatesCachedLyrics() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let record = LRCLIBRecord(
            id: 42,
            name: "Example",
            trackName: "Song",
            artistName: "Artist",
            albumName: "Album",
            duration: 120,
            instrumental: false,
            plainLyrics: "First\nSecond",
            syncedLyrics: "[00:01.00]First\n[00:02.00]Second"
        )

        let lyrics = try #require(record.trackLyrics(fetchedAt: fetchedAt))
        #expect(lyrics.source == .lrclib)
        #expect(lyrics.sourceIdentifier == "42")
        #expect(lyrics.updatedAt == fetchedAt)
        #expect(lyrics.syncedLines.count == 2)
    }

    @Test("MusicBrainz builds an escaped recording search and release artwork URL")
    func musicBrainzBuildsURLs() throws {
        var track = makeTrack(title: "Song \"One\"", album: "Album / One")
        track.artist = "Artist + Guest"
        let search = try #require(URLComponents(
            url: MusicBrainzService.searchURL(for: track),
            resolvingAgainstBaseURL: false
        ))
        let items = Dictionary(uniqueKeysWithValues: (search.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })

        #expect(search.path == "/ws/2/recording/")
        #expect(items["query"]?.contains("recording:\"Song \\\"One\\\"\"") == true)
        #expect(items["query"]?.contains("artist:\"Artist + Guest\"") == true)
        #expect(items["fmt"] == "json")
        #expect(items["limit"] == "20")
        let isrc = try #require(URLComponents(
            url: MusicBrainzService.isrcSearchURL("JP-AAA-26-00001"),
            resolvingAgainstBaseURL: false
        ))
        #expect(isrc.queryItems?.first(where: { $0.name == "query" })?.value == "isrc:JPAAA2600001")
        let relaxed = try #require(URLComponents(
            url: MusicBrainzService.searchURL(for: track, includesAlbum: false),
            resolvingAgainstBaseURL: false
        ))
        let relaxedQuery = relaxed.queryItems?.first(where: { $0.name == "query" })?.value
        #expect(relaxedQuery?.contains("recording:") == true)
        #expect(relaxedQuery?.contains("artist:") == true)
        #expect(relaxedQuery?.contains("release:") == false)
        let titleHintQuery = URLComponents(
            url: MusicBrainzService.titleOnlySearchURL(for: track),
            resolvingAgainstBaseURL: false
        )?.queryItems?.first(where: { $0.name == "query" })?.value
        #expect(titleHintQuery == "recording:\"Song \\\"One\\\"\"")
        let albumHintQuery = URLComponents(
            url: MusicBrainzService.albumOnlySearchURL(for: track),
            resolvingAgainstBaseURL: false
        )?.queryItems?.first(where: { $0.name == "query" })?.value
        #expect(albumHintQuery == "release:\"Album / One\"")
        #expect(
            MusicBrainzService.coverArtURL(for: "release-id").path
                == "/release/release-id"
        )
    }

    @Test("Album references retain release identity without assigning one recording to every song")
    func musicBrainzAlbumReferenceDropsRecordingIdentity() {
        let reference = MusicBrainzReference(
            recordingID: "recording-id",
            releaseID: "release-id",
            releaseGroupID: "release-group-id",
            artistIDs: ["artist-id"],
            isrc: "JPAAA2600001",
            country: "JP",
            mediaFormat: "Digital Media",
            coverArtID: "cover-id",
            coverArtTypes: ["Front"],
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        #expect(reference.albumReference.recordingID == nil)
        #expect(reference.albumReference.isrc == nil)
        #expect(reference.albumReference.releaseID == "release-id")
        #expect(reference.albumReference.releaseGroupID == "release-group-id")
        #expect(reference.albumReference.artistIDs == ["artist-id"])
        #expect(reference.albumReference.coverArtID == "cover-id")
    }

    @Test("Selected MusicBrainz identity persists with edited song metadata")
    @MainActor
    func musicBrainzReferencePersists() async throws {
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
        let reference = MusicBrainzReference(
            recordingID: "recording-id",
            releaseID: "release-id",
            releaseGroupID: "release-group-id",
            artistIDs: ["artist-id"],
            isrc: "JPAAA2600001",
            country: "JP",
            mediaFormat: "CD",
            coverArtID: "cover-id",
            coverArtTypes: ["Front"],
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        try await store.updateTrackMetadata(
            id: track.id,
            metadata: metadata,
            musicBrainzReference: reference
        )

        let loaded = try #require(try await repository.load().document.tracks.first)
        #expect(loaded.title == "After")
        #expect(loaded.musicBrainzReference == reference)
    }

    @Test("Schema 10 catalogs migrate to empty MusicBrainz identity")
    func migratesSchemaTenMusicBrainzDefaults() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var document = LibraryDocument(tracks: [makeTrack(title: "Legacy", album: "Album")])
        document.schemaVersion = 10
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(
            to: root.appendingPathComponent("library-v1.json"),
            options: .atomic
        )

        let result = try await LibraryRepository(rootURL: root).load()

        #expect(result.migratedFromSchemaVersion == 10)
        #expect(result.document.schemaVersion == LibraryDocument.currentSchema)
        #expect(result.document.tracks.first?.musicBrainzReference == nil)
    }

    @Test("Schema 11 catalogs migrate to empty extended credits and work metadata")
    func migratesSchemaElevenExtendedMetadataDefaults() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var document = LibraryDocument(tracks: [makeTrack(title: "Legacy", album: "Album")])
        document.schemaVersion = 11
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(
            to: root.appendingPathComponent("library-v1.json"),
            options: .atomic
        )

        let result = try await LibraryRepository(rootURL: root).load()
        let migrated = try #require(result.document.tracks.first)

        #expect(result.migratedFromSchemaVersion == 11)
        #expect(result.document.schemaVersion == LibraryDocument.currentSchema)
        #expect(migrated.participantCredits.isEmpty)
        #expect(migrated.workName.isEmpty)
        #expect(migrated.movementName.isEmpty)
        #expect(migrated.movementNumber == nil)
        #expect(migrated.beatsPerMinute == nil)
        #expect(migrated.copyright.isEmpty)
        #expect(migrated.isrc.isEmpty)
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
