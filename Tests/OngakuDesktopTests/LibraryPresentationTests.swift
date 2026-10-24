import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Asynchronous library presentation", .serialized)
struct LibraryPresentationTests {
    @Test("Fast filename extraction preserves file URL semantics and search text")
    func fileNameCompatibility() {
        let paths = [
            "/Music/Track 001.m4a", "/音楽/夜の曲.flac", "/音乐/简体中文歌曲.mp3",
            "/Music/Àlpha Ｓong.m4a", "/Music/e\u{301}.mp3", "/Music/😀.caf",
            "/Music/100% %2F # ? +.m4a", "/Music/file\\name.m4a", "/Music/a\nb.m4a",
            "/Music//Track.m4a", "//Music/Track.m4a", "/Music/../Track.m4a",
            "/音楽/Track.m4a", "/Music/a\u{0}b.m4a",
            "/Music/.hidden", "/", "/Music/", "/Music/.", "/Music/..",
            "relative/Track.m4a", "Track.m4a", "", ".", "..", "~/Music/Track.m4a",
        ]
        var track = LargeLibraryFixture.makeDocument(trackCount: 1).tracks[0]
        for path in paths {
            track.managedPath = path
            let expected = track.fileURL.lastPathComponent
            #expect(CatalogSearch.fileName(forPath: path).utf8.elementsEqual(expected.utf8))
            #expect(CatalogSearch.searchableText(for: track).utf8.elementsEqual(
                CatalogSearch.searchableText(for: track, fileName: expected).utf8
            ))
        }
    }

    @Test("Search text keeps the original field separators and optional-number order")
    func searchTextCompatibility() {
        var tracks = LargeLibraryFixture.makeDocument(trackCount: 3).tracks
        tracks[0].releaseYear = 2026
        tracks[0].trackNumber = 1
        tracks[0].trackCount = 12
        tracks[0].discNumber = 2
        tracks[0].discCount = 3
        tracks[0].movementNumber = 4
        tracks[0].movementCount = 5
        tracks[0].beatsPerMinute = 120
        tracks[0].rating = 5
        tracks[0].playCount = 42
        tracks[1].releaseYear = -1
        tracks[1].comments = "Àlpha\u{1f}音楽 简体中文"
        tracks[1].rating = 0
        tracks[1].playCount = Int.max
        for track in tracks {
            // The pre-optimization representation is also persisted in SQLite.
            let strings = [
                track.title, track.artist, track.artistSortName,
                track.album, track.albumSortName, track.albumArtist,
                track.albumArtistSortName, track.composer, track.composerSortName,
                track.grouping, track.genre, track.participantCredits,
                track.workName, track.movementName, track.copyright,
                track.isrc, track.comments, "", "", track.fileURL.lastPathComponent,
            ]
            let numbers = [
                track.releaseYear, track.trackNumber, track.trackCount,
                track.discNumber, track.discCount, track.movementNumber,
                track.movementCount, track.beatsPerMinute, track.rating, track.playCount,
            ].compactMap { $0.map(String.init) }
            let expected = (strings + numbers).joined(separator: "\u{1f}").folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            #expect(CatalogSearch.searchableText(for: track) == expected)
        }
    }

    @Test("Search normalization preserves POSIX folding for ASCII and multilingual text")
    func normalizationParity() {
        let ascii = String(decoding: Array(UInt8(0)...UInt8(127)), as: UTF8.self)
        for value in ["", ascii, "Track 123 / ARTIST", "Àlpha Ｓong", "音楽の夜", "简体中文歌曲",
                      "İıßΣς", "e\u{301}", "😀\u{1f}Album", "ＡＢＣ１２３"] {
            #expect(CatalogSearch.normalize(value) == value.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            ))
        }
    }

    @Test("Oversized fallback text remains searchable without retaining the text cache")
    func boundedFallbackSearchCache() async throws {
        let tracks = LargeLibraryFixture.makeDocument(trackCount: 40).tracks
        let libraryID = UUID()
        let worker = CatalogFallbackSearchWorker(maximumTextBytes: 32)
        for query in ["Track 000000", "楽曲 000001", "曲目 000002"] {
            #expect(try await worker.search(
                tracks: tracks, libraryID: libraryID, revision: 1, query: query
            ) == Set(tracks.filter { CatalogSearch.matches($0, query: query) }.map(\.id)))
            #expect(await worker.cachedTextBytes == 0)
        }
        let retained = CatalogFallbackSearchWorker()
        _ = try await retained.search(tracks: tracks, libraryID: libraryID, revision: 1, query: "Track")
        #expect(await retained.cachedTextBytes > 0)
        await retained.discardOtherLibrary(UUID())
        #expect(await retained.cachedTextBytes == 0)
    }

    @Test("Fallback text remains correct across edits, reordering, removal, and library switches")
    func fallbackSearchCache() async throws {
        let worker = CatalogFallbackSearchWorker()
        let libraryID = UUID()
        var tracks = LargeLibraryFixture.makeDocument(trackCount: 40).tracks
        var revision = 1
        func verify(_ query: String) async throws {
            let expected = Set(tracks.filter { CatalogSearch.matches($0, query: query) }.map(\.id))
            #expect(try await worker.search(
                tracks: tracks, libraryID: libraryID, revision: revision, query: query
            ) == expected)
        }
        for query in ["track", "楽", "目", "missing"] { try await verify(query) }
        tracks[0].title = "Àlpha Ｓong"
        tracks[0].lyrics = TrackLyrics(plainText: "hidden lyric", source: .manual)
        tracks[0].rating = 5
        tracks[0].managedPath = "/Disposable/Renamed.caf"
        revision += 1
        for query in ["alpha", "ＳＯＮＧ", "hidden lyric", "Renamed.caf", "5"] {
            try await verify(query)
        }
        tracks.swapAt(0, 1)
        revision += 1
        try await verify("alpha")
        tracks.removeFirst()
        revision += 1
        try await verify("楽曲 000001")
        let snapshot = tracks
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await worker.search(
                tracks: snapshot, libraryID: libraryID, revision: 100, query: "alpha"
            )
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        try await verify("alpha")
        var otherLibrary = snapshot
        otherLibrary[0].title = "Other library"
        #expect(try await worker.search(
            tracks: otherLibrary, libraryID: UUID(), revision: revision, query: "Other library"
        ) == [otherLibrary[0].id])
        #expect(try await worker.search(
            tracks: [], libraryID: libraryID, revision: revision + 1, query: "alpha"
        ).isEmpty)
    }

    @Test("SQLite promotion releases only the superseded fallback snapshot")
    func fallbackCachePromotion() async throws {
        let worker = CatalogFallbackSearchWorker()
        let library = UUID()
        let tracks = LargeLibraryFixture.makeDocument(trackCount: 40).tracks
        func prepare(_ revision: Int, _ id: UUID) async throws {
            _ = try await worker.search(tracks: tracks, libraryID: id, revision: revision, query: "track")
            #expect(await worker.cachedTextBytes > 0)
        }
        try await prepare(2, library)
        await worker.releaseCache(libraryID: UUID(), throughRevision: 2)
        #expect(await worker.cachedTextBytes > 0)
        await worker.releaseCache(libraryID: library, throughRevision: 1)
        #expect(await worker.cachedTextBytes > 0)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await worker.releaseCache(libraryID: library, throughRevision: 2)
        }
        await cancelled.value
        #expect(await worker.cachedTextBytes > 0)
        await worker.releaseCache(libraryID: library, throughRevision: 2)
        #expect(await worker.cachedTextBytes == 0)
        // An index failure can still reconstruct the fallback after promotion.
        try await prepare(3, library)
        #expect(try await worker.search(tracks: tracks, libraryID: library, revision: 3, query: "楽")
            == Set(tracks.filter { CatalogSearch.matches($0, query: "楽") }.map(\.id)))
        await worker.releaseCache(libraryID: library, throughRevision: 4)
        #expect(await worker.cachedTextBytes == 0)
    }

    @Test("Duplicate analysis remains complete when the retained key budget is exceeded")
    func boundedDuplicateKeys() async throws {
        var tracks = LargeLibraryFixture.makeDocument(trackCount: 6).tracks
        tracks[0].title = "Àlpha Ｓong"
        tracks[1].title = "alpha song"
        tracks[1].artist = tracks[0].artist
        tracks[1].duration = tracks[0].duration
        tracks[2].sha256 = "shared-hash"
        tracks[3].sha256 = "shared-hash"
        tracks[4].title = String(repeating: "长い音楽タイトル", count: 100)
        for budget in [0, 32, 16 * 1_024 * 1_024] {
            let worker = LibraryPresentationWorker(maximumDuplicateKeyBytes: budget)
            for revision in 1...3 {
                let snapshot = try await worker.resolve(request(
                    tracks, tracksRevision: revision, section: .duplicates
                ))
                let expected = DuplicateTrackAnalyzer.groups(in: tracks)
                #expect(Set(snapshot.allDuplicates.map(\.id)) == Set(expected.map(\.id)))
                for group in expected {
                    let actual = snapshot.allDuplicates.first { $0.id == group.id }
                    #expect(actual?.kind == group.kind)
                    #expect(actual?.tracks == group.tracks)
                    #expect(actual?.recommendedTrackID == group.recommendedTrackID)
                }
                #expect(await worker.cachedDuplicateKeyBytes <= budget)
                tracks.reverse()
                tracks[0].comments = "Updated metadata \(revision)"
            }
            let empty = try await worker.resolve(request([], tracksRevision: 4, section: .duplicates))
            #expect(empty.allDuplicates.isEmpty)
            #expect(await worker.cachedDuplicateKeyBytes == 0)
        }
    }

    @Test("Cached duplicate keys preserve fresh analysis across all metadata changes")
    func duplicateCacheInvalidation() async throws {
        let worker = LibraryPresentationWorker()
        var tracks = LargeLibraryFixture.makeDocument(trackCount: 6).tracks
        var revision = 0
        func verify() async throws {
            revision += 1
            let result = try await worker.resolve(request(
                tracks, tracksRevision: revision, section: .duplicates
            ))
            let expected = DuplicateTrackAnalyzer.groups(in: tracks)
            #expect(result.allDuplicates.map(\.id) == expected.map(\.id))
            #expect(result.allDuplicates.map(\.kind) == expected.map(\.kind))
            #expect(result.allDuplicates.map(\.recommendedTrackID) == expected.map(\.recommendedTrackID))
            #expect(result.allDuplicates.map { $0.tracks } == expected.map { $0.tracks })
        }
        tracks[0].title = "Àlpha Ｓong"
        tracks[1].title = "alpha song"
        tracks[0].artist = "音楽"
        tracks[1].artist = "音楽"
        tracks[1].duration = tracks[0].duration + 2
        try await verify()
        tracks[1].fileSize += 1_000_000
        tracks[1].comments = "Updated metadata"
        try await verify()
        tracks[1].rating = 5
        tracks[1].lyrics = TrackLyrics(plainText: "Updated lyrics", source: .manual)
        tracks[1].health = .verified
        tracks[1].addedAt = tracks[0].addedAt.addingTimeInterval(-10)
        try await verify()
        tracks.reverse()
        try await verify()
        tracks.reverse()
        tracks[1].duration += 10
        try await verify()
        tracks[0].sha256 = "shared-hash"
        tracks[1].sha256 = "shared-hash"
        try await verify()
        tracks[1].title = "独立的歌曲"
        tracks[1].artist = "另一位艺术家"
        try await verify()
        tracks[1].sha256 = "different-hash"
        try await verify()
        tracks.reverse()
        try await verify()
        tracks[0] = LargeLibraryFixture.makeDocument(trackCount: 7).tracks[6]
        try await verify()
        tracks.removeLast()
        try await verify()
        tracks.removeAll()
        try await verify()
    }

    @Test("Cached history matches direct statistics across track edits and history replacement")
    func historyCacheInvalidation() async throws {
        let worker = LibraryPresentationWorker()
        var tracks = LargeLibraryFixture.makeDocument(trackCount: 4).tracks
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        let orphanID = UUID()
        var events = [
            PlaybackEvent(trackID: tracks[0].id, kind: .completed, occurredAt: older),
            PlaybackEvent(trackID: tracks[0].id, kind: .skipped, occurredAt: newer),
            PlaybackEvent(trackID: tracks[1].id, kind: .started, occurredAt: newer),
            PlaybackEvent(trackID: orphanID, kind: .completed, occurredAt: older),
        ]
        var tracksRevision = 1
        var eventsRevision = 1
        func verify() async throws {
            let snapshot = try await worker.resolve(request(
                tracks, events: events, tracksRevision: tracksRevision,
                eventsRevision: eventsRevision, section: .frequentlyPlayed
            ))
            let expected = PlaybackStatisticsResolver.statistics(events: events, tracks: tracks)
            #expect(Set(snapshot.statistics.keys) == Set(expected.keys))
            for (id, value) in expected {
                #expect(snapshot.statistics[id]?.playCount == value.playCount)
                #expect(snapshot.statistics[id]?.skipCount == value.skipCount)
                #expect(snapshot.statistics[id]?.lastPlayedAt == value.lastPlayedAt)
            }
        }
        try await verify()
        tracks[0].playCount = 9
        tracks[0].syncedSkipCount = 3
        tracks[0].syncedLastPlayedAt = newer.addingTimeInterval(10)
        tracks[1].syncedLastPlayedAt = older
        tracksRevision += 1
        try await verify()
        tracks.removeFirst()
        tracksRevision += 1
        try await verify()
        events[0].kind = .started
        events[1].occurredAt = older
        eventsRevision += 1
        try await verify()
        events.removeAll()
        eventsRevision += 1
        try await verify()
        tracks.removeAll()
        tracksRevision += 1
        try await verify()
    }

    @Test("Returning to albums reuses current groups and edits invalidate them")
    func albumCacheInvalidation() async throws {
        var tracks = LargeLibraryFixture.makeDocument(trackCount: 40).tracks
        let worker = LibraryPresentationWorker()
        let first = try await worker.resolve(request(tracks, section: .albums))
        _ = try await worker.resolve(request(tracks, section: .artists))
        let again = try await worker.resolve(request(tracks, section: .albums))
        #expect(again.albums.map(\.id) == first.albums.map(\.id))
        tracks[0].duration += 100
        let edited = try await worker.resolve(request(tracks, tracksRevision: 2, section: .albums))
        let id = tracks[0].albumID
        #expect(edited.albums.first { $0.id == id }!.totalDuration
            == first.albums.first { $0.id == id }!.totalDuration + 100)
    }

    @Test("Album and artist snapshots retain grouping, ordering, and durations")
    func grouping() async throws {
        let tracks = LargeLibraryFixture.makeDocument(trackCount: 40).tracks
        let worker = LibraryPresentationWorker()
        let albums = try await worker.resolve(request(tracks, section: .albums))
        #expect(albums.albums.count == 4)
        #expect(albums.albumSections.flatMap(\.albums).map(\.id) == albums.albums.map(\.id))
        #expect(albums.albums[0].totalDuration == tracks.prefix(10).reduce(0) { $0 + $1.duration })
        let artists = try await worker.resolve(request(tracks, section: .artists))
        #expect(artists.artists.count == 2)
        #expect(artists.artists.allSatisfy { $0.tracks.count == 20 && $0.albumCount == 2 })
        #expect(artists.totalBytes == tracks.reduce(0) { $0 + $1.fileSize })
        #expect(artists.attentionCount == tracks.filter { $0.health != .verified }.count)
    }

    @Test("Same-size edits and removed history invalidate cached aggregates")
    func invalidation() async throws {
        var tracks = LargeLibraryFixture.makeDocument(trackCount: 3).tracks
        let worker = LibraryPresentationWorker()
        let event = PlaybackEvent(trackID: tracks[1].id, kind: .completed)
        let first = try await worker.resolve(request(tracks, events: [event], section: .frequentlyPlayed))
        #expect(first.tracks.map(\.id) == [tracks[1].id])
        #expect(first.statistics[tracks[1].id]?.playCount == 1)
        tracks[0].playCount = 5
        tracks[0].fileSize = 17
        let edited = try await worker.resolve(request(
            tracks, events: [event], tracksRevision: 2, section: .frequentlyPlayed
        ))
        #expect(edited.tracks.map(\.id) == [tracks[0].id, tracks[1].id])
        #expect(edited.totalBytes == tracks.reduce(0) { $0 + $1.fileSize })
        let cleared = try await worker.resolve(request(
            tracks, tracksRevision: 2, eventsRevision: 2, section: .frequentlyPlayed
        ))
        #expect(cleared.tracks.map(\.id) == [tracks[0].id])
        #expect(cleared.statistics[tracks[1].id]?.lastPlayedAt == nil)
    }

    @Test("Cancelled work does not poison the next worker request")
    @MainActor
    func cancellation() async throws {
        let tracks = LargeLibraryFixture.makeDocument(trackCount: 40).tracks
        let worker = LibraryPresentationWorker()
        let input = request(tracks, section: .artists)
        let cancelled = Task { try await worker.resolve(input) }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let result = try await worker.resolve(input)
        #expect(result.artists.count == 2)
    }

    @Test("Rapid section and filter changes publish only the last request and preserve selection")
    @MainActor
    func rapidChanges() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let tracks = LargeLibraryFixture.makeDocument(trackCount: 200).tracks
        let repository = LibraryRepository(rootURL: root)
        try await repository.save(tracks: tracks)
        let store = LibraryStore(repository: repository)
        await store.load()
        let selected = tracks[21].id
        store.updateTrackSelection([selected], focusedID: selected)
        store.selectedSection = .albums
        await Task.yield()
        store.selectedSection = .favorites
        store.searchText = "楽曲"
        store.searchText = "曲目"
        store.searchText = ""
        store.filterCriteria.artist = "nonexistent"
        store.selectedSection = .artists
        store.filterCriteria.artist = tracks[21].artist
        #expect(store.isPresentationUpdating)
        #expect(store.filteredTracks.isEmpty)
        await store.waitForPresentation()
        #expect(!store.isPresentationUpdating)
        #expect(store.presentation.artists.map(\.name) == [tracks[21].artist])
        #expect(store.filteredTracks.count == 20)
        #expect(store.selectedTrackID == selected)
        #expect(store.selectedTrackIDs == [selected])
    }

    @Test("Switching libraries rejects an old pending presentation")
    @MainActor
    func librarySwitch() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = LibraryRepository(rootURL: root.appendingPathComponent("First"))
        let second = LibraryRepository(rootURL: root.appendingPathComponent("Second"))
        let oldTracks = LargeLibraryFixture.makeDocument(trackCount: 200).tracks
        var newTrack = oldTracks[0]
        newTrack.title = "New library"
        try await first.save(tracks: oldTracks)
        try await second.save(tracks: [newTrack])
        let store = LibraryStore(repository: first)
        await store.load()
        store.selectedSection = .artists
        await Task.yield()
        await store.switchLibrary(catalogURL: second.rootURL, mediaURL: second.rootURL.appendingPathComponent("Media"))
        await store.waitForPresentation()
        #expect(store.filteredTracks.map(\.title) == ["New library"])
        #expect(store.presentation.artists.isEmpty)
        #expect(store.totalBytes == newTrack.fileSize)
    }

    private func request(
        _ tracks: [Track], events: [PlaybackEvent] = [], tracksRevision: Int = 1,
        eventsRevision: Int = 1, section: LibrarySection
    ) -> LibraryPresentationRequest {
        LibraryPresentationRequest(
            tracks: tracks, events: events, tracksRevision: tracksRevision,
            eventsRevision: eventsRevision, section: section, playlist: nil,
            filter: LibraryFilterCriteria(), searchIDs: nil, audioFeatures: [:]
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Presentation-\(UUID())")
    }
}
