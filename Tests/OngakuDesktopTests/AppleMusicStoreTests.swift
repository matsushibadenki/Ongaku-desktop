import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Apple Music Store integration")
struct AppleMusicStoreTests {
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
