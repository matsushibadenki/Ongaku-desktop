import Foundation
import Testing
@testable import OngakuDesktop

struct ArtworkResolverTests {
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
