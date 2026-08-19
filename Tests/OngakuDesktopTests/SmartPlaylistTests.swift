import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Smart playlists")
struct SmartPlaylistTests {
    @Test("Nested all and any rules evaluate metadata, statistics, and limits")
    func evaluatesNestedRules() {
        var first = makeTrack(title: "Blue Night", artist: "Mina", rating: 5)
        first.isFavorite = false
        var second = makeTrack(title: "Morning", artist: "Mina", rating: 4)
        second.isFavorite = true
        let third = makeTrack(title: "Blue Night", artist: "Other", rating: 5)
        let definition = SmartPlaylistDefinition(
            root: SmartPlaylistRuleGroup(
                mode: .all,
                rules: [
                    SmartPlaylistRule(field: .artist, comparison: .equals, value: "mina"),
                    SmartPlaylistRule(field: .rating, comparison: .atLeast, value: "4")
                ],
                groups: [
                    SmartPlaylistRuleGroup(
                        mode: .any,
                        rules: [
                            SmartPlaylistRule(
                                field: .title,
                                comparison: .contains,
                                value: "night"
                            ),
                            SmartPlaylistRule(field: .favorite, comparison: .isTrue)
                        ]
                    )
                ]
            ),
            limit: 1
        )

        let result = SmartPlaylistResolver.tracks(
            matching: definition,
            tracks: [first, second, third],
            statistics: [:]
        )
        #expect(result.map(\.id) == [first.id])
    }

    @Test("A smart playlist updates live and survives restart")
    @MainActor
    func updatesLiveAndPersists() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        let first = makeTrack(title: "First", artist: "Artist", rating: 2)
        let second = makeTrack(title: "Second", artist: "Artist", rating: 5)
        try await repository.save(tracks: [first, second])
        let store = LibraryStore(repository: repository)
        await store.load()
        let definition = SmartPlaylistDefinition(
            root: SmartPlaylistRuleGroup(
                rules: [
                    SmartPlaylistRule(field: .rating, comparison: .atLeast, value: "4")
                ]
            )
        )
        let playlistID = try await store.createSmartPlaylist(
            name: "Highly Rated",
            definition: definition
        )
        #expect(store.filteredTracks.map(\.id) == [second.id])

        await store.setRating(5, for: first.id)
        #expect(Set(store.filteredTracks.map(\.id)) == [first.id, second.id])
        await store.setRating(1, for: second.id)
        #expect(store.filteredTracks.map(\.id) == [first.id])

        let restored = try await LibraryRepository(rootURL: root).load().document
        let smart = try #require(restored.playlists.first { $0.id == playlistID })
        #expect(smart.smartDefinition == definition)
        #expect(smart.entries.isEmpty)
    }

    private func makeTrack(
        title: String,
        artist: String,
        rating: Int
    ) -> Track {
        Track(
            id: UUID(), title: title, artist: artist, album: "Album",
            duration: 100, fileSize: 1, managedPath: "/tmp/\(UUID().uuidString).m4a",
            sha256: UUID().uuidString, addedAt: .now, lastVerifiedAt: .now,
            health: .verified, rating: rating
        )
    }
}
