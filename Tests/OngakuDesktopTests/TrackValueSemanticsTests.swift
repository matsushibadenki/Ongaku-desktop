import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Track value semantics")
struct TrackValueSemanticsTests {
    @Test("Editing a copied track leaves catalog arrays, dictionaries and hash sets unchanged")
    func independentCopies() {
        let original = LargeLibraryFixture.makeDocument(trackCount: 1).tracks[0]
        let catalog = [original]
        let index = [original.id: original]
        let members = Set([original])
        var edited = original
        edited.title = "Edited"
        edited.genre = "Jazz"
        edited.playCount += 1
        edited.rating = 5
        edited.managedPath = "/Moved/Edited.m4a"
        edited.isFavorite.toggle()
        #expect(catalog[0] == original)
        #expect(index[original.id] == original)
        #expect(members.contains(original))
        #expect(!members.contains(edited))
        #expect(edited.id == original.id)
        #expect(edited != original)
        var sameEdit = original
        sameEdit.title = edited.title
        sameEdit.genre = edited.genre
        sameEdit.playCount = edited.playCount
        sameEdit.rating = edited.rating
        sameEdit.managedPath = edited.managedPath
        sameEdit.isFavorite = edited.isFavorite
        #expect(Set([edited, sameEdit]).count == 1)
        print("ONGAKU_TRACK_VALUE stride=\(MemoryLayout<Track>.stride)")
    }

    @Test("Key-path writes preserve independent values and the existing JSON format")
    func keyPathsAndPersistence() throws {
        let original = LargeLibraryFixture.makeDocument(trackCount: 1).tracks[0]
        var edited = original
        edited[keyPath: \Track.comments] = "英語 日本語 简体中文"
        edited[keyPath: \Track.lastVerifiedAt] = Date(timeIntervalSince1970: 1_700_000_123)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(edited)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["comments"] as? String == edited.comments)
        #expect(object["storage"] == nil)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Track.self, from: data)
        #expect(decoded == edited)
        #expect(decoded != original)
        #expect(original.comments.isEmpty)
    }

    @Test("Concurrent snapshot edits do not modify a shared catalog")
    func concurrentEdits() async {
        let original = LargeLibraryFixture.makeDocument(trackCount: 1).tracks[0]
        let results = await withTaskGroup(of: Track.self, returning: [Track].self) { group in
            for index in 0..<32 {
                group.addTask {
                    var local = original
                    local.title = "Edit \(index)"
                    local.playCount = index
                    return local
                }
            }
            var tracks: [Track] = []
            for await track in group { tracks.append(track) }
            return tracks
        }
        #expect(Set(results.map(\.title)).count == 32)
        #expect(results.allSatisfy { $0.title == "Edit \($0.playCount)" })
        #expect(original.title == "Track 000000")
        #expect(original.playCount == 0)
    }

    @Test("Nested lyrics edits detach both the track and its timed lines")
    func nestedLyrics() {
        var original = LargeLibraryFixture.makeDocument(trackCount: 1).tracks[0]
        original.lyrics = TrackLyrics(
            plainText: "Original", syncedLines: [TimedLyricsLine(time: 1, text: "First")],
            source: .manual
        )
        var edited = original
        edited.lyrics?.plainText = "Edited"
        edited.lyrics?.syncedLines[0].text = "Changed"
        edited.lyrics?.syncedLines.append(TimedLyricsLine(time: 2, text: "Second"))
        #expect(original.lyrics?.plainText == "Original")
        #expect(original.lyrics?.syncedLines.map(\.text) == ["First"])
        #expect(edited.lyrics?.syncedLines.map(\.text) == ["Changed", "Second"])
    }
}
