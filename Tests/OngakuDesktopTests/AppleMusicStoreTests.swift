import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Apple Music Store integration")
struct AppleMusicStoreTests {
    @Test("Catalog queue resolves the current entry and safely falls back")
    func resolvesCatalogQueueCurrentItem() {
        let first = AppleMusicQueueItem(
            id: "first",
            title: "First",
            subtitle: "Artist",
            duration: 180,
            artworkURL: nil
        )
        let second = AppleMusicQueueItem(
            id: "second",
            title: "Second",
            subtitle: "Artist",
            duration: 200,
            artworkURL: nil
        )

        #expect(AppleMusicQueuePresentation.currentItem(
            in: [first, second],
            currentEntryID: "second"
        ) == second)
        #expect(AppleMusicQueuePresentation.currentItem(
            in: [first, second],
            currentEntryID: "missing"
        ) == first)
        #expect(AppleMusicQueuePresentation.currentItem(
            in: [],
            currentEntryID: nil
        ) == nil)
    }

    @Test("Catalog queue moves upcoming items but protects the current item")
    func editsCatalogQueueSafely() {
        let items = ["current", "second", "third"].map {
            AppleMusicQueueItem(
                id: $0,
                title: $0,
                subtitle: "Artist",
                duration: 180,
                artworkURL: nil
            )
        }

        let moved = AppleMusicQueueEditor.moving(
            items,
            fromOffsets: IndexSet(integer: 2),
            toOffset: 1,
            currentItemID: "current"
        )
        #expect(moved.map(\.id) == ["current", "third", "second"])

        let protected = AppleMusicQueueEditor.moving(
            items,
            fromOffsets: IndexSet(integer: 0),
            toOffset: 3,
            currentItemID: "current"
        )
        #expect(protected == items)

        let keptAfterCurrent = AppleMusicQueueEditor.moving(
            items,
            fromOffsets: IndexSet(integer: 1),
            toOffset: 0,
            currentItemID: "current"
        )
        #expect(keptAfterCurrent == items)
    }

    @Test("Catalog queue removes multiple upcoming items but protects the current item")
    func removesCatalogQueueItemsSafely() {
        let items = ["current", "second", "third", "fourth"].map {
            AppleMusicQueueItem(
                id: $0,
                title: $0,
                subtitle: "Artist",
                duration: 180,
                artworkURL: nil
            )
        }

        let removed = AppleMusicQueueEditor.removing(
            items,
            ids: ["second", "fourth"],
            currentItemID: "current"
        )
        #expect(removed.map(\.id) == ["current", "third"])

        let protected = AppleMusicQueueEditor.removing(
            items,
            ids: ["current", "third"],
            currentItemID: "current"
        )
        #expect(protected.map(\.id) == ["current", "second", "fourth"])

        #expect(AppleMusicQueueEditor.removing(
            items,
            ids: [],
            currentItemID: "current"
        ) == items)
    }

    @Test("Discovery keeps unique recent releases in newest-first order")
    func plansRecentReleases() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let cutoff = now.addingTimeInterval(-1_000)
        let candidates: [(id: String, releaseDate: Date?)] = [
            ("older", now.addingTimeInterval(-800)),
            ("newest", now.addingTimeInterval(-100)),
            ("newest", now.addingTimeInterval(-100)),
            ("future", now.addingTimeInterval(500)),
            ("expired", now.addingTimeInterval(-1_500)),
            ("unknown", nil),
        ]

        #expect(AppleMusicDiscoveryPlanner.recentReleaseIDs(
            candidates,
            since: cutoff,
            through: now,
            limit: 10
        ) == ["newest", "older"])
        #expect(AppleMusicDiscoveryPlanner.recentReleaseIDs(
            candidates,
            since: cutoff,
            through: now,
            limit: 1
        ) == ["newest"])
    }

    @Test("Discovery paging replaces matching shelves and appends new shelves")
    func mergesDiscoveryShelves() {
        func item(_ id: String) -> AppleMusicCatalogItem {
            AppleMusicCatalogItem(
                id: id,
                musicItemID: id,
                kind: .album,
                title: id,
                subtitle: "Artist",
                detail: "",
                artworkURL: nil,
                destinationURL: nil
            )
        }
        let original = [
            AppleMusicDiscoveryShelf(
                id: "for-you",
                title: "For You",
                subtitle: nil,
                items: [item("one")]
            ),
        ]
        let incoming = [
            AppleMusicDiscoveryShelf(
                id: "for-you",
                title: "Updated",
                subtitle: nil,
                items: [item("two")]
            ),
            AppleMusicDiscoveryShelf(
                id: "more",
                title: "More",
                subtitle: nil,
                items: [item("three")]
            ),
        ]

        let merged = AppleMusicDiscoveryPlanner.mergingShelves(
            original,
            with: incoming,
            replacingAll: false
        )
        #expect(merged.map(\.id) == ["for-you", "more"])
        #expect(merged.first?.title == "Updated")
        #expect(merged.first?.items.map(\.id) == ["two"])
        #expect(AppleMusicDiscoveryPlanner.mergingShelves(
            original,
            with: incoming,
            replacingAll: true
        ) == incoming)
    }

    @Test("City chart filtering keeps complete pages and stable city names")
    func filtersCityCharts() {
        func item(_ id: String, city: String) -> AppleMusicCatalogItem {
            AppleMusicCatalogItem(
                id: id,
                musicItemID: id,
                kind: .song,
                title: id,
                subtitle: "Artist",
                detail: "",
                artworkURL: nil,
                destinationURL: nil,
                groupTitle: city
            )
        }
        let items = [
            item("tokyo-1", city: "Tokyo"),
            item("osaka-1", city: "Osaka"),
            item("tokyo-2", city: "Tokyo"),
        ]

        #expect(AppleMusicDiscoveryPlanner.chartGroupTitles(in: items)
            == ["Osaka", "Tokyo"])
        #expect(AppleMusicDiscoveryPlanner.filteringChartItems(
            items,
            groupTitle: "Tokyo"
        ).map(\.id) == ["tokyo-1", "tokyo-2"])
        #expect(AppleMusicDiscoveryPlanner.filteringChartItems(
            items,
            groupTitle: nil
        ) == items)
    }

    @Test("Catalog kinds expose playback and queue capabilities accurately")
    func playableCatalogKinds() {
        #expect(AppleMusicCatalogItemKind.song.isPlayable)
        #expect(AppleMusicCatalogItemKind.album.isPlayable)
        #expect(AppleMusicCatalogItemKind.playlist.isPlayable)
        #expect(AppleMusicCatalogItemKind.station.isPlayable)
        #expect(!AppleMusicCatalogItemKind.artist.isPlayable)
        #expect(!AppleMusicCatalogItemKind.musicVideo.isPlayable)

        #expect(AppleMusicCatalogItemKind.song.canEnqueue)
        #expect(AppleMusicCatalogItemKind.album.canEnqueue)
        #expect(AppleMusicCatalogItemKind.playlist.canEnqueue)
        #expect(!AppleMusicCatalogItemKind.station.canEnqueue)
        #expect(!AppleMusicCatalogItemKind.musicVideo.canEnqueue)
    }

    @Test("Chart labels preserve the chart name and one-based rank")
    func formatsChartDetails() {
        #expect(AppleMusicStoreController.chartDetail("Top Songs", rank: 1) == "Top Songs · #1")
        #expect(AppleMusicStoreController.chartDetail("トップ100", rank: 42) == "トップ100 · #42")
    }

    @Test("Subscription guidance uses the official secure Apple page")
    func subscriptionGuidanceURL() {
        let url = AppleMusicStoreController.subscriptionURL
        #expect(url.scheme == "https")
        #expect(url.host == "www.apple.com")
        #expect(url.path == "/apple-music")
    }

    @Test("Replay guidance uses Apple's official secure site")
    func replayGuidanceURL() {
        let url = AppleMusicStoreController.replayURL
        #expect(url.scheme == "https")
        #expect(url.host == "replay.music.apple.com")
    }

    @Test("Playlist creation body is private and preserves localized text")
    func playlistCreationRequestBody() throws {
        let data = try AppleMusicStoreController.playlistCreationBody(
            name: "夜の選曲",
            description: "静かな曲"
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let attributes = try #require(object["attributes"] as? [String: Any])
        #expect(attributes["name"] as? String == "夜の選曲")
        #expect(attributes["description"] as? String == "静かな曲")
        #expect(attributes["isPublic"] as? Bool == false)
    }

    @Test("Playlist track body identifies catalog and library songs")
    func playlistTrackRequestBody() throws {
        for type in ["songs", "library-songs"] {
            let data = try AppleMusicStoreController.playlistTracksBody(
                id: "song-id",
                type: type
            )
            let object = try #require(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            let entries = try #require(object["data"] as? [[String: String]])
            #expect(entries == [["id": "song-id", "type": type]])
        }
    }

    @Test("Favorite rating body uses Apple Music's positive rating value")
    func favoriteRatingRequestBody() throws {
        let data = try AppleMusicStoreController.favoriteRatingBody()
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let attributes = try #require(object["attributes"] as? [String: Int])
        #expect(object["type"] as? String == "rating")
        #expect(attributes["value"] == 1)
    }

    @Test("Library paging appends only previously unseen resources")
    func mergesLibraryPages() {
        func item(_ id: String) -> AppleMusicCatalogItem {
            AppleMusicCatalogItem(
                id: id,
                musicItemID: id,
                kind: .song,
                title: id,
                subtitle: "Artist",
                detail: "Album",
                artworkURL: nil,
                destinationURL: nil
            )
        }

        let merged = AppleMusicStoreController.merging(
            [item("one"), item("two")],
            with: [item("two"), item("three")]
        )
        #expect(merged.map(\.id) == ["one", "two", "three"])
    }

    @Test("Apple Music playlist conversion classifies matches without changing files")
    func plansPlaylistConversion() {
        func track(_ id: UUID, title: String, duration: TimeInterval) -> Track {
            Track(
                id: id,
                title: title,
                artist: "Ongaku Ensemble",
                album: "Listening Room",
                duration: duration,
                fileSize: 1_024,
                managedPath: "/tmp/\(id.uuidString).flac",
                sha256: String(repeating: "a", count: 64),
                addedAt: .distantPast,
                health: .verified
            )
        }
        func item(_ id: String, title: String, duration: TimeInterval) -> AppleMusicCatalogItem {
            AppleMusicCatalogItem(
                id: id,
                musicItemID: id,
                kind: .song,
                title: title,
                subtitle: "Ongaku Ensemble",
                detail: "Listening Room",
                artworkURL: nil,
                destinationURL: nil,
                duration: duration
            )
        }
        let uniqueID = UUID()
        let ambiguousOne = UUID()
        let ambiguousTwo = UUID()
        let unique = item("unique", title: "Night Record", duration: 245)
        let preview = AppleMusicPlaylistConversionPlanner.preview(
            name: "Night Focus",
            entries: [
                unique,
                item("ambiguous", title: "Shared", duration: 200),
                item("missing", title: "Missing", duration: 180),
                unique,
            ],
            tracks: [
                track(uniqueID, title: "Ｎｉｇｈｔ Record", duration: 247),
                track(ambiguousOne, title: "Shared", duration: 200),
                track(ambiguousTwo, title: "Shared", duration: 201),
            ]
        )

        #expect(preview.rows.map(\.status) == [.matched, .ambiguous, .missing, .duplicate])
        #expect(preview.matchedTrackIDs == [uniqueID])
        #expect(preview.matchedCount == 1)
        #expect(preview.ambiguousCount == 1)
        #expect(preview.missingCount == 1)
        #expect(preview.duplicateCount == 1)
    }

    @Test("Apple Music HTTP failures are rejected while expected statuses pass")
    func validatesServiceStatuses() throws {
        try AppleMusicStoreController.validateStatus(204, accepted: [204])
        for status in [401, 403, 409, 429, 500] {
            var rejected = false
            do {
                try AppleMusicStoreController.validateStatus(status, accepted: [200])
            } catch {
                rejected = true
            }
            #expect(rejected)
        }
    }

    @Test("Ongaku playlist export preserves order and classifies unsafe matches")
    func plansOngakuPlaylistExport() {
        func track(_ id: UUID, title: String, duration: TimeInterval) -> Track {
            Track(
                id: id,
                title: title,
                artist: "Ongaku Ensemble",
                album: "Listening Room",
                duration: duration,
                fileSize: 1_024,
                managedPath: "/tmp/\(id.uuidString).flac",
                sha256: String(repeating: "c", count: 64),
                addedAt: .distantPast,
                health: .verified
            )
        }
        func item(_ id: String, title: String, duration: TimeInterval) -> AppleMusicCatalogItem {
            AppleMusicCatalogItem(
                id: "librarySong:\(id)",
                musicItemID: id,
                kind: .song,
                title: title,
                subtitle: "Ongaku Ensemble",
                detail: "Listening Room",
                artworkURL: nil,
                destinationURL: nil,
                duration: duration,
                playlistTrackType: "library-songs"
            )
        }
        let first = track(UUID(), title: "First", duration: 180)
        let ambiguous = track(UUID(), title: "Shared", duration: 200)
        let missing = track(UUID(), title: "Missing", duration: 220)
        let playlist = Playlist(
            name: "Export Order",
            entries: [first, ambiguous, missing].map { PlaylistEntry(trackID: $0.id) }
        )
        let preview = OngakuPlaylistAppleMusicExportPlanner.preview(
            playlist: playlist,
            tracks: [first, ambiguous, missing],
            appleMusicSongs: [
                item("first", title: "First", duration: 181),
                item("shared-1", title: "Shared", duration: 200),
                item("shared-2", title: "Shared", duration: 201),
            ]
        )

        #expect(preview.rows.map(\.status) == [.matched, .ambiguous, .missing])
        #expect(preview.matchedItems.map(\.musicItemID) == ["first"])
    }

    @Test("Playlist export request preserves selected Apple Music song order")
    func playlistExportRequestBody() throws {
        func item(_ id: String) -> AppleMusicCatalogItem {
            AppleMusicCatalogItem(
                id: id,
                musicItemID: id,
                kind: .song,
                title: id,
                subtitle: "Artist",
                detail: "Album",
                artworkURL: nil,
                destinationURL: nil,
                playlistTrackType: "library-songs"
            )
        }
        let data = try AppleMusicStoreController.playlistTracksBody(
            items: [item("second"), item("first")]
        )
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try #require(object["data"] as? [[String: String]])
        #expect(rows == [
            ["id": "second", "type": "library-songs"],
            ["id": "first", "type": "library-songs"],
        ])
    }

    @Test("Playlist export audit history survives controller recreation")
    @MainActor
    func restoresPlaylistExportHistory() throws {
        let suiteName = "AppleMusicStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let entry = AppleMusicPlaylistExportAuditEntry(
            id: UUID(),
            occurredAt: Date(timeIntervalSince1970: 1_725_000_000),
            sourcePlaylistID: UUID(),
            sourcePlaylistName: "Night Focus",
            appleMusicPlaylistID: "p.test",
            requestedTrackCount: 3,
            addedTrackCount: 2,
            failedTrackCount: 1
        )
        defaults.set(
            try JSONEncoder().encode([entry]),
            forKey: "appleMusic.playlistExportHistory.v1"
        )

        let controller = AppleMusicStoreController(defaults: defaults)
        #expect(controller.playlistExportHistory == [entry])
    }

    @Test("Library filters include only their matching catalog kind")
    func libraryKindFilters() {
        #expect(AppleMusicLibraryFilter.all.includes(.song))
        #expect(AppleMusicLibraryFilter.all.includes(.album))
        #expect(AppleMusicLibraryFilter.all.includes(.playlist))
        #expect(AppleMusicLibraryFilter.songs.includes(.song))
        #expect(!AppleMusicLibraryFilter.songs.includes(.album))
        #expect(AppleMusicLibraryFilter.albums.includes(.album))
        #expect(!AppleMusicLibraryFilter.albums.includes(.playlist))
        #expect(AppleMusicLibraryFilter.playlists.includes(.playlist))
        #expect(!AppleMusicLibraryFilter.playlists.includes(.song))
    }

    @Test("Catalog playback state preserves the selected song while paused")
    func catalogPlaybackPauseState() {
        var state = AppleMusicPlaybackState()
        state.begin(itemID: "song-1")
        #expect(state.currentItemID == "song-1")
        #expect(state.isWorking)

        state.didStart()
        #expect(state.isPlaying)
        #expect(!state.isWorking)

        state.didPause()
        #expect(state.currentItemID == "song-1")
        #expect(!state.isPlaying)
    }

    @Test("Stopping catalog playback clears its ownership of playback")
    func catalogPlaybackStopState() {
        var state = AppleMusicPlaybackState()
        state.begin(itemID: "song-1")
        state.didStart()
        state.didStop()

        #expect(state.currentItemID == nil)
        #expect(!state.isPlaying)
        #expect(!state.isWorking)
    }

    @Test("iTunes Store search URL is regional, music-only, and safely encoded")
    func buildsStoreSearchURL() throws {
        let url = try #require(ITunesStoreClient.searchURL(
            term: "坂本 龍一 & YMO",
            countryCode: "jp",
            limit: 40
        ))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )

        #expect(url.scheme == "https")
        #expect(url.host == "itunes.apple.com")
        #expect(query["term"] == "坂本 龍一 & YMO")
        #expect(query["country"] == "JP")
        #expect(query["media"] == "music")
        #expect(query["entity"] == "song")
        #expect(query["limit"] == "40")
    }

    @Test("iTunes Store response preserves purchase URL and localized price")
    func decodesStoreResult() throws {
        let data = Data(#"""
        {
          "resultCount": 1,
          "results": [{
            "trackId": 123,
            "trackName": "Energy Flow",
            "artistName": "Ryuichi Sakamoto",
            "collectionName": "BTTB",
            "artworkUrl100": "https://example.com/art.jpg",
            "trackViewUrl": "https://itunes.apple.com/jp/album/id123?i=123",
            "trackPrice": 255.0,
            "currency": "JPY"
          }]
        }
        """#.utf8)

        let result = try #require(ITunesStoreClient.decodeResponse(data).first)
        #expect(result.id == 123)
        #expect(result.trackName == "Energy Flow")
        #expect(result.artistName == "Ryuichi Sakamoto")
        #expect(result.collectionName == "BTTB")
        #expect(result.trackPrice == 255)
        #expect(result.currency == "JPY")
        #expect(result.trackViewUrl?.host == "itunes.apple.com")
    }
}
