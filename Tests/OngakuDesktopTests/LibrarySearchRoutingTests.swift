import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Library search routing", .serialized)
struct LibrarySearchRoutingTests {
    @Test("Search switches to SQLite after parity verification and resynchronizes after edits")
    @MainActor
    func routesSearchToSQLite() async throws {
        let root = temporaryRoot(named: "Routing")
        defer { try? FileManager.default.removeItem(at: root) }

        let first = makeTrack(title: "Àlpha Ｓong", artist: "First Artist", album: "Shared Album")
        let second = makeTrack(title: "夜の歌", artist: "第二歌手", album: "Second Album")
        let repository = LibraryRepository(rootURL: root)
        try await repository.save(tracks: [first, second])

        let store = LibraryStore(
            repository: repository,
            searchIndex: SQLiteCatalogPrototype(rootURL: root)
        )
        await store.load()
        try await waitUntil { store.searchBackendStatus == .sqlite }

        store.searchText = "LPH"
        try await waitUntil { store.indexedSearchQuery == CatalogSearch.normalize("LPH") }
        #expect(store.filteredTracks.map(\.id) == [first.id])

        store.searchText = "夜"
        try await waitUntil { store.indexedSearchQuery == CatalogSearch.normalize("夜") }
        #expect(store.filteredTracks.map(\.id) == [second.id])

        try await store.updateTrackMetadata(
            id: first.id,
            title: "Renamed Track",
            artist: first.artist,
            album: first.album
        )
        try await waitUntil { store.searchBackendStatus == .sqlite }
        store.searchText = "named"
        try await waitUntil { store.indexedSearchQuery == CatalogSearch.normalize("named") }
        #expect(store.filteredTracks.map(\.id) == [first.id])
    }

    @Test("SQLite setup failure retains JSON search")
    @MainActor
    func fallsBackToJSON() async throws {
        let root = temporaryRoot(named: "Fallback")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let libraryRoot = root.appendingPathComponent("Library", isDirectory: true)
        let blockedIndexRoot = root.appendingPathComponent("blocked-index")
        try Data("not a directory".utf8).write(to: blockedIndexRoot)
        let track = makeTrack(title: "Fallback Song", artist: "Artist", album: "Album")
        let repository = LibraryRepository(rootURL: libraryRoot)
        try await repository.save(tracks: [track])

        let store = LibraryStore(
            repository: repository,
            searchIndex: SQLiteCatalogPrototype(rootURL: blockedIndexRoot)
        )
        await store.load()
        try await waitUntil { store.searchBackendStatus == .jsonFallback }

        store.searchText = "back"
        #expect(store.filteredTracks.map(\.id) == [track.id])
        #expect(store.indexedSearchQuery == nil)
    }

    private func temporaryRoot(named name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Ongaku-Search-\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeTrack(title: String, artist: String, album: String) -> Track {
        Track(
            id: UUID(),
            title: title,
            artist: artist,
            album: album,
            duration: 180,
            fileSize: 1_000,
            managedPath: "/Music/\(UUID().uuidString).m4a",
            sha256: UUID().uuidString,
            addedAt: .now,
            lastVerifiedAt: .now,
            health: .verified
        )
    }

    @MainActor
    private func waitUntil(
        timeoutIterations: Int = 300,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<timeoutIterations {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for asynchronous search state")
    }
}
