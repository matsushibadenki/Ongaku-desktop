import Foundation
import Testing
@testable import OngakuDesktop

@Suite("External lyrics search")
struct ExternalLyricsSiteTests {
    @Test("Provider URLs preserve Unicode and special characters")
    func urls() throws {
        for site in ExternalLyricsSite.allCases {
            let query = "日本語 A+B & #? 歌手/名"
            let url = try #require(site.searchURL(query: "  " + query + "  "))
            let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(parts.scheme == "https")
            #expect(parts.host == (site == .genius ? "genius.com" : "www.smule.com"))
            #expect(parts.path == "/search")
            #expect(parts.fragment == nil)
            #expect(parts.queryItems == [URLQueryItem(name: "q", value: query)])
            #expect(url.absoluteString.contains("%2B"))
            #expect(site.searchURL(query: " \n") == nil)
            #expect(site.searchURL(query: "歌手") != nil)
        }
    }
}
