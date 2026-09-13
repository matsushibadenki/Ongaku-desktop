import Foundation
import Testing
@testable import OngakuDesktop

private final class ArtworkRequestProbeURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var count = 0
    private static let lock = NSLock()

    static func reset() {
        lock.withLock { count = 0 }
    }

    static var requestCount: Int {
        lock.withLock { count }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.count += 1 }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct ArtworkResolverTests {
    @Test("Disabled automatic artwork never sends an external request")
    func disabledAutomaticArtworkDoesNotUseNetwork() async throws {
        ArtworkRequestProbeURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtworkRequestProbeURLProtocol.self]
        let resolver = ArtworkResolver(session: URLSession(configuration: configuration))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Artwork-Privacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try await resolver.configure(libraryRootURL: root)

        let result = await resolver.artworkData(
            for: .album(name: "Private Album", artist: "Private Artist"),
            allowsNetwork: false
        )

        #expect(result == nil)
        let defaultResult = await resolver.artworkData(
            for: .artist(name: "Private Artist")
        )
        #expect(defaultResult == nil)
        #expect(ArtworkRequestProbeURLProtocol.requestCount == 0)
    }

    @Test("Automatic artwork consent is disabled by default and persists")
    @MainActor
    func automaticArtworkConsentPersists() {
        let suite = "Artwork-Privacy-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ArtworkPrivacySettings(defaults: defaults)
        #expect(!settings.allowsAutomaticExternalArtwork)
        settings.allowsAutomaticExternalArtwork = true
        #expect(ArtworkPrivacySettings(defaults: defaults).allowsAutomaticExternalArtwork)
    }

    @Test("Artwork matching ignores case, accents, width, and punctuation")
    func normalization() {
        #expect(ArtworkResolver.normalized("Beyoncé — RENAISSANCE") == "beyoncerenaissance")
        #expect(ArtworkResolver.normalized("ＡＢＣ・１２３") == "abc123")
    }

    @Test("Artist image candidates prefer exact matches and Apple Music")
    func artistImageCandidateOrdering() {
        let url = URL(string: "https://example.com/photo.jpg")!
        let candidates = [
            ArtistImageCandidate(
                id: "commons:exact",
                artistName: "Artist",
                previewURL: url,
                downloadURL: url,
                sourceURL: nil,
                source: .wikimediaCommons,
                attribution: "Photographer",
                licenseName: "CC BY 4.0",
                licenseURL: nil,
                matchScore: 1
            ),
            ArtistImageCandidate(
                id: "apple:fuzzy",
                artistName: "Artist Band",
                previewURL: url,
                downloadURL: url,
                sourceURL: nil,
                source: .appleMusic,
                attribution: nil,
                licenseName: nil,
                licenseURL: nil,
                matchScore: 0.8
            ),
            ArtistImageCandidate(
                id: "apple:exact",
                artistName: "Artist",
                previewURL: url,
                downloadURL: url,
                sourceURL: nil,
                source: .appleMusic,
                attribution: nil,
                licenseName: nil,
                licenseURL: nil,
                matchScore: 1
            )
        ]

        let ordered = ArtworkResolver.orderedArtistImageCandidates(candidates)

        #expect(ordered.map(\.id) == ["apple:exact", "commons:exact", "apple:fuzzy"])
    }

    @Test("Artist artwork attribution survives persistence encoding")
    func artistArtworkAttributionCoding() throws {
        let previewURL = URL(string: "https://commons.wikimedia.org/preview.jpg")!
        let sourceURL = URL(string: "https://commons.wikimedia.org/wiki/File:Artist.jpg")!
        let licenseURL = URL(string: "https://creativecommons.org/licenses/by/4.0/")!
        let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let candidate = ArtistImageCandidate(
            id: "commons:artist",
            artistName: "Artist",
            previewURL: previewURL,
            downloadURL: previewURL,
            sourceURL: sourceURL,
            source: .wikimediaCommons,
            attribution: "Example Photographer",
            licenseName: "CC BY 4.0",
            licenseURL: licenseURL,
            matchScore: 1
        )
        let attribution = ArtistArtworkAttribution(candidate: candidate, savedAt: savedAt)

        let data = try JSONEncoder().encode(attribution)
        let decoded = try JSONDecoder().decode(ArtistArtworkAttribution.self, from: data)

        #expect(decoded == attribution)
    }
}
