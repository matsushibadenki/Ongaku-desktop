import Foundation
import Testing
@testable import OngakuDesktop

@Suite("M3 library management milestone")
struct M3LibraryManagementMilestoneTests {
    private static let resourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/OngakuDesktop/Resources", isDirectory: true)

    @Test("Duplicate deletion explains the exact target and recovery policy in every language")
    func deletionImpactIsExplicit() throws {
        for language in ["en", "ja", "zh-Hans"] {
            let strings = try localizationStrings(language)
            let format = try #require(strings["duplicates.confirm.message"])
            let message = String(format: format, locale: Locale(identifier: "en_US_POSIX"), 2)
            #expect(message.contains("2"))
            #expect(message != "duplicates.confirm.message")
        }
    }

    @Test("Managed duplicate files are recoverable while external references remain untouched")
    func deletionPolicyMatchesTheConfirmation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ongaku-M3-Deletion-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("Ongaku Media", isDirectory: true)
        let external = root.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)

        let managedURL = media.appendingPathComponent("managed.m4a")
        let externalURL = external.appendingPathComponent("external.m4a")
        try Data("managed".utf8).write(to: managedURL)
        try Data("external".utf8).write(to: externalURL)
        let managed = makeTrack(url: managedURL, hash: "managed")
        let referenced = makeTrack(url: externalURL, hash: "external")
        let repository = LibraryRepository(rootURL: root, mediaURL: media)

        let result = await repository.trashManagedFiles(
            removedTracks: [managed, referenced],
            retainedTracks: []
        )

        #expect(result.trashed == 1)
        #expect(result.retained == 1)
        #expect(result.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: managedURL.path))
        #expect(FileManager.default.fileExists(atPath: externalURL.path))
    }

    @Test("Song deletion keeps catalog relationships consistent and honors both file choices")
    @MainActor
    func deletesSongsWithExplicitFilePolicy() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ongaku-M3-Song-Deletion-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("Ongaku Media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)

        let keepFile = media.appendingPathComponent("keep.m4a")
        let trashFile = media.appendingPathComponent("trash.m4a")
        try Data("keep".utf8).write(to: keepFile)
        try Data("trash".utf8).write(to: trashFile)
        let keep = makeTrack(url: keepFile, hash: "keep")
        let trash = makeTrack(url: trashFile, hash: "trash")
        let playlist = Playlist(
            name: "Album",
            entries: [PlaylistEntry(trackID: keep.id), PlaylistEntry(trackID: trash.id)]
        )
        let repository = LibraryRepository(rootURL: root, mediaURL: media)
        try await repository.save(document: LibraryDocument(
            tracks: [keep, trash],
            playlists: [playlist],
            playbackEvents: [
                PlaybackEvent(trackID: keep.id, kind: .completed),
                PlaybackEvent(trackID: trash.id, kind: .completed),
            ],
            playbackQueue: PlaybackQueueState(
                trackIDs: [keep.id, trash.id],
                currentTrackID: trash.id,
                position: 12
            )
        ))
        let store = LibraryStore(repository: repository)
        await store.load()

        let first = try await store.deleteTracks([keep.id], moveFilesToTrash: false)
        #expect(first.removedCount == 1)
        #expect(first.trashedFileCount == 0)
        #expect(FileManager.default.fileExists(atPath: keepFile.path))
        #expect(store.playlists[0].entries.map(\.trackID) == [trash.id])
        #expect(store.playbackEvents.map(\.trackID) == [trash.id])

        let second = try await store.deleteTracks([trash.id], moveFilesToTrash: true)
        #expect(second.removedCount == 1)
        #expect(second.trashedFileCount == 1)
        #expect(!FileManager.default.fileExists(atPath: trashFile.path))
        #expect(store.tracks.isEmpty)
        #expect(store.playlists[0].entries.isEmpty)
        #expect(store.playbackEvents.isEmpty)
        #expect(store.playbackQueue?.trackIDs.isEmpty == true)
        #expect(store.playbackQueue?.currentTrackID == nil)

        let restored = try await LibraryRepository(rootURL: root, mediaURL: media).load().document
        #expect(restored.tracks.isEmpty)
        #expect(restored.playlists[0].entries.isEmpty)
        #expect(restored.playbackEvents.isEmpty)
    }

    private func makeTrack(url: URL, hash: String) -> Track {
        Track(
            id: UUID(), title: url.deletingPathExtension().lastPathComponent,
            artist: "Artist", album: "Album", duration: 1, fileSize: 1,
            managedPath: url.path, sha256: hash, addedAt: .now, health: .verified
        )
    }

    private func localizationStrings(_ language: String) throws -> [String: String] {
        let url = Self.resourceRoot
            .appendingPathComponent("\(language).lproj", isDirectory: true)
            .appendingPathComponent("Localizable.strings")
        let data = try Data(contentsOf: url)
        let propertyList = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(propertyList as? [String: String])
    }
}
