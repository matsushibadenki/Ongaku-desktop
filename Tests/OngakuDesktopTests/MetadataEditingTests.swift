import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Catalog metadata editing")
struct MetadataEditingTests {
    @Test("Song and album edits persist without changing file identity")
    @MainActor
    func editsPersistAtomically() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = LibraryRepository(rootURL: root)
        let first = makeTrack(title: "One", album: "Before")
        let second = makeTrack(title: "Two", album: "Before")
        try await repository.save(tracks: [first, second])

        let store = LibraryStore(repository: repository)
        await store.load()
        try await store.updateTrackMetadata(
            id: first.id,
            title: "One Edited",
            artist: "Artist",
            album: "Before"
        )
        try await store.updateAlbumMetadata(
            trackIDs: [first.id, second.id],
            artist: "Album Artist",
            album: "After"
        )

        let loaded = try await repository.load().document.tracks
        #expect(loaded.count == 2)
        #expect(loaded.first(where: { $0.id == first.id })?.title == "One Edited")
        #expect(loaded.allSatisfy { $0.artist == "Album Artist" && $0.album == "After" })
        #expect(loaded.first(where: { $0.id == first.id })?.managedPath == first.managedPath)
        #expect(loaded.first(where: { $0.id == first.id })?.sha256 == first.sha256)
    }

    private func makeTrack(title: String, album: String) -> Track {
        Track(
            id: UUID(),
            title: title,
            artist: "Artist",
            album: album,
            duration: 10,
            fileSize: 100,
            managedPath: "/tmp/\(UUID().uuidString).m4a",
            sha256: UUID().uuidString,
            addedAt: .now,
            lastVerifiedAt: .now,
            health: .verified
        )
    }
}
