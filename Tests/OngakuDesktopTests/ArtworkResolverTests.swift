import Testing
@testable import OngakuDesktop

struct ArtworkResolverTests {
    @Test("Artwork matching ignores case, accents, width, and punctuation")
    func normalization() {
        #expect(ArtworkResolver.normalized("Beyoncé — RENAISSANCE") == "beyoncerenaissance")
        #expect(ArtworkResolver.normalized("ＡＢＣ・１２３") == "abc123")
    }
}
