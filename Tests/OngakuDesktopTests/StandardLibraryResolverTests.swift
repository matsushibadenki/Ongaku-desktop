import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Standard library views")
struct StandardLibraryResolverTests {
    @Test("Pinned and favorite views include only matching songs")
    func resolvesManualCollections() {
        var pinned = makeTrack(title: "Pinned")
        pinned.isPinned = true
        var favorite = makeTrack(title: "Favorite")
        favorite.isFavorite = true
        let ordinary = makeTrack(title: "Ordinary")

        #expect(StandardLibraryResolver.tracks(
            for: .pinned,
            tracks: [ordinary, pinned, favorite],
            events: []
        ).map(\.id) == [pinned.id])
        #expect(StandardLibraryResolver.tracks(
            for: .favorites,
            tracks: [ordinary, pinned, favorite],
            events: []
        ).map(\.id) == [favorite.id])
    }

    @Test("Recently added and recently played views keep their newest-first order")
    func resolvesRecentCollections() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var older = makeTrack(title: "Older")
        older.addedAt = base
        var newer = makeTrack(title: "Newer")
        newer.addedAt = base.addingTimeInterval(60)
        let events = [
            PlaybackEvent(
                trackID: newer.id,
                kind: .started,
                occurredAt: base.addingTimeInterval(120)
            ),
            PlaybackEvent(
                trackID: older.id,
                kind: .skipped,
                occurredAt: base.addingTimeInterval(180)
            ),
        ]

        #expect(StandardLibraryResolver.tracks(
            for: .recentlyAdded,
            tracks: [older, newer],
            events: events
        ).map(\.id) == [newer.id, older.id])
        #expect(StandardLibraryResolver.tracks(
            for: .recentlyPlayed,
            tracks: [older, newer],
            events: events
        ).map(\.id) == [older.id, newer.id])
    }

    @Test("Frequently played ranks completed plays and catalog play counts")
    func resolvesFrequentlyPlayed() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var catalogLeader = makeTrack(title: "Catalog Leader")
        catalogLeader.playCount = 3
        let eventLeader = makeTrack(title: "Event Leader")
        let unplayed = makeTrack(title: "Unplayed")
        let events = (0..<2).map { offset in
            PlaybackEvent(
                trackID: eventLeader.id,
                kind: .completed,
                occurredAt: base.addingTimeInterval(TimeInterval(offset))
            )
        }

        let result = StandardLibraryResolver.tracks(
            for: .frequentlyPlayed,
            tracks: [unplayed, eventLeader, catalogLeader],
            events: events
        )

        #expect(result.map(\.id) == [catalogLeader.id, eventLeader.id])
    }

    private func makeTrack(title: String) -> Track {
        Track(
            id: UUID(),
            title: title,
            artist: "Artist",
            album: "Album",
            duration: 120,
            fileSize: 1,
            managedPath: "/tmp/\(UUID().uuidString).m4a",
            sha256: UUID().uuidString,
            addedAt: .now,
            health: .verified
        )
    }
}
