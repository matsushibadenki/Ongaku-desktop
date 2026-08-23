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
