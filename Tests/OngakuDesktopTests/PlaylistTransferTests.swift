import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Playlist transfer")
struct PlaylistTransferTests {
    @Test("M3U resolves relative paths and previews duplicates and missing files")
    func previewsM3UDifferences() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let track = makeTrack(path: root.appendingPathComponent("Music/Artist/Song.flac").path)
        let playlistURL = root.appendingPathComponent("Imported.m3u8")
        let text = """
        #EXTM3U
        #PLAYLIST:Road Trip
        #EXTINF:181,Artist - Song
        Music/Artist/Song.flac
        Music/Artist/Song.flac
        Music/Artist/Missing.flac
        """
        try Data(text.utf8).write(to: playlistURL)

        let preview = try PlaylistTransferService.preview(from: playlistURL, tracks: [track])

        #expect(preview.name == "Road Trip")
        #expect(preview.matchedTrackIDs == [track.id])
        #expect(preview.matchedCount == 1)
        #expect(preview.duplicateCount == 1)
        #expect(preview.missingCount == 1)
    }

    @Test("Ongaku JSON preserves metadata and stable IDs across export and import")
    func roundTripsJSON() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = makeTrack(title: "First", path: root.appendingPathComponent("first.m4a").path)
        let second = makeTrack(title: "Second", path: root.appendingPathComponent("second.flac").path)
        let playlist = Playlist(
            name: "Favorites",
            description: "Portable playlist",
            entries: [PlaylistEntry(trackID: first.id), PlaylistEntry(trackID: second.id)]
        )
        let data = try PlaylistTransferService.exportData(
            playlist: playlist,
            tracks: [first, second],
            format: .json
        )
        let url = root.appendingPathComponent("Favorites.json")
        try data.write(to: url)

        let preview = try PlaylistTransferService.preview(from: url, tracks: [second, first])

        #expect(preview.name == playlist.name)
        #expect(preview.description == playlist.description)
        #expect(preview.matchedTrackIDs == [first.id, second.id])
        #expect(preview.missingCount == 0)
    }

    @Test("M3U export includes extended metadata and ordered absolute paths")
    func exportsM3U() throws {
        let first = makeTrack(title: "First", path: "/Music/Artist/first.flac")
        let second = makeTrack(title: "Second", path: "/Music/Artist/second.flac")
        let playlist = Playlist(name: "Ordered")

        let data = try PlaylistTransferService.exportData(
            playlist: playlist,
            tracks: [second, first],
            format: .m3u8
        )
        let text = try #require(String(data: data, encoding: .utf8))

        #expect(text.hasPrefix("#EXTM3U\n#PLAYLIST:Ordered\n"))
        #expect(text.range(of: second.managedPath)!.lowerBound < text.range(of: first.managedPath)!.lowerBound)
        #expect(text.contains("#EXTINF:181,Artist - Second"))
    }

    private func makeTrack(
        title: String = "Song",
        path: String
    ) -> Track {
        Track(
            id: UUID(),
            title: title,
            artist: "Artist",
            album: "Album",
            duration: 181,
            fileSize: 1_024,
            managedPath: path,
            sha256: UUID().uuidString,
            addedAt: .now,
            lastVerifiedAt: .now,
            health: .verified
        )
    }
}
