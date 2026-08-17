import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Album title initial grouping")
struct AlbumTitleGroupingTests {
    private let locale = Locale(identifier: "en_US_POSIX")

    @Test("Latin titles are normalized across case, accents, and character width")
    func normalizesLatinInitials() {
        #expect(AlbumTitleGrouping.initial(for: "album", locale: locale) == "A")
        #expect(AlbumTitleGrouping.initial(for: "  Été", locale: locale) == "E")
        #expect(AlbumTitleGrouping.initial(for: "Ａlbum", locale: locale) == "A")
    }

    @Test("Japanese and Simplified Chinese titles preserve their first character")
    func preservesCJKInitials() {
        #expect(AlbumTitleGrouping.initial(for: "アルバム", locale: locale) == "ア")
        #expect(AlbumTitleGrouping.initial(for: "音楽", locale: locale) == "音")
        #expect(AlbumTitleGrouping.initial(for: "音乐", locale: locale) == "音")
    }

    @Test("Numbers, symbols, and empty titles use the miscellaneous group")
    func groupsNonLettersAsMiscellaneous() {
        #expect(AlbumTitleGrouping.initial(for: "1989", locale: locale) == "#")
        #expect(AlbumTitleGrouping.initial(for: "!Live", locale: locale) == "#")
        #expect(AlbumTitleGrouping.initial(for: "   ", locale: locale) == "#")
    }

    @Test("The miscellaneous section is ordered after named initials")
    func ordersMiscellaneousLast() {
        #expect(AlbumTitleGrouping.ordered(["#", "B", "A"], locale: locale) == ["A", "B", "#"])
    }
}
