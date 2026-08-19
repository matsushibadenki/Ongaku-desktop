import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Catalog metadata editing")
struct MetadataEditingTests {
    @Test("Song, album, and artist edits persist without changing unsupported files")
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
        try await store.updateArtistMetadata(
            trackIDs: [first.id, second.id],
            artist: "Renamed Artist"
        )

        let loaded = try await repository.load().document.tracks
        #expect(loaded.count == 2)
        #expect(loaded.first(where: { $0.id == first.id })?.title == "One Edited")
        #expect(loaded.allSatisfy { $0.artist == "Renamed Artist" && $0.album == "After" })
        #expect(loaded.first(where: { $0.id == first.id })?.managedPath == first.managedPath)
        #expect(loaded.first(where: { $0.id == first.id })?.sha256 == first.sha256)
    }

    @Test("Only lossless passthrough containers are selected for embedding")
    func embeddingSupportPolicy() {
        #expect(AudioFileMetadataWriter.supportsEmbedding(at: URL(fileURLWithPath: "/tmp/song.m4a")))
        #expect(AudioFileMetadataWriter.supportsEmbedding(at: URL(fileURLWithPath: "/tmp/song.M4B")))
        #expect(AudioFileMetadataWriter.supportsEmbedding(at: URL(fileURLWithPath: "/tmp/song.mp4")))
        #expect(!AudioFileMetadataWriter.supportsEmbedding(at: URL(fileURLWithPath: "/tmp/song.mp3")))
        #expect(!AudioFileMetadataWriter.supportsEmbedding(at: URL(fileURLWithPath: "/tmp/song.flac")))
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
