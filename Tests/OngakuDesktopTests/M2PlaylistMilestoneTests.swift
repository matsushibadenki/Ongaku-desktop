import AppKit
import Foundation
import Testing
@testable import OngakuDesktop

@Suite("M2 playlist organization milestone")
struct M2PlaylistMilestoneTests {
    @Test("Every playlist organization operation supports Undo and Redo")
    @MainActor
    func undoesAndRedoesEveryPlaylistOperation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ongaku-M2-Undo-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let tracks = (1...3).map { index in
            Track(
                id: UUID(), title: "Track \(index)", artist: "Artist", album: "Album",
                duration: 180, fileSize: 1,
                managedPath: root.appendingPathComponent("\(index).m4a").path,
                sha256: "m2-\(index)", addedAt: .now, health: .missing
            )
        }
        let repository = LibraryRepository(rootURL: root)
        try await repository.save(tracks: tracks)
        let store = LibraryStore(repository: repository)
        await store.load()
        let undoManager = UndoManager()
        store.undoManager = undoManager

        let playlistID = try await store.createPlaylist(
            name: "Reference", description: "Original", artworkData: nil
        )
        try await verifyUndoRedo(
            undoManager,
            undoCondition: { !store.playlists.contains { $0.id == playlistID } },
            redoCondition: { store.playlists.contains { $0.id == playlistID } }
        )

        let artworkData = try makeArtworkData()
        try await store.updatePlaylist(
            id: playlistID,
            name: "Edited Reference",
            description: "Undo-qualified",
            artworkData: artworkData,
            removesArtwork: false
        )
        let artworkPath = try #require(store.playlists.first { $0.id == playlistID }?.artworkPath)
        try await verifyUndoRedo(
            undoManager,
            undoCondition: {
                store.playlists.first { $0.id == playlistID }?.name == "Reference"
                    && store.playlists.first { $0.id == playlistID }?.artworkPath == nil
            },
            redoCondition: {
                store.playlists.first { $0.id == playlistID }?.name == "Edited Reference"
                    && store.playlists.first { $0.id == playlistID }?.artworkPath == artworkPath
            }
        )

        _ = try await store.addTracks(tracks.map(\.id), to: playlistID)
        try await verifyUndoRedo(
            undoManager,
            undoCondition: { store.playlists.first { $0.id == playlistID }?.entries.isEmpty == true },
            redoCondition: {
                store.playlists.first { $0.id == playlistID }?.entries.map(\.trackID)
                    == tracks.map(\.id)
            }
        )

        _ = try await store.removeTracks([tracks[1].id], from: playlistID)
        try await verifyUndoRedo(
            undoManager,
            undoCondition: {
                store.playlists.first { $0.id == playlistID }?.entries.map(\.trackID)
                    == tracks.map(\.id)
            },
            redoCondition: {
                store.playlists.first { $0.id == playlistID }?.entries.map(\.trackID)
                    == [tracks[0].id, tracks[2].id]
            }
        )
        undoManager.undo()
        try await waitUntil {
            store.playlists.first { $0.id == playlistID }?.entries.map(\.trackID)
                == tracks.map(\.id)
        }

        _ = try await store.moveTracks(
            [tracks[2].id], before: tracks[0].id, in: playlistID
        )
        let reorderedIDs = [tracks[2].id, tracks[0].id, tracks[1].id]
        try await verifyUndoRedo(
            undoManager,
            undoCondition: {
                store.playlists.first { $0.id == playlistID }?.entries.map(\.trackID)
                    == tracks.map(\.id)
            },
            redoCondition: {
                store.playlists.first { $0.id == playlistID }?.entries.map(\.trackID)
                    == reorderedIDs
            }
        )

        let duplicateID = try #require(try await store.duplicatePlaylist(playlistID))
        try await verifyUndoRedo(
            undoManager,
            undoCondition: { !store.playlists.contains { $0.id == duplicateID } },
            redoCondition: { store.playlists.contains { $0.id == duplicateID } }
        )

        try await store.deletePlaylist(duplicateID)
        try await verifyUndoRedo(
            undoManager,
            undoCondition: { store.playlists.contains { $0.id == duplicateID } },
            redoCondition: { !store.playlists.contains { $0.id == duplicateID } }
        )

        let folderID = try await store.createPlaylistFolder(name: "Sets")
        try await verifyUndoRedo(
            undoManager,
            undoCondition: { !store.playlistFolders.contains { $0.id == folderID } },
            redoCondition: { store.playlistFolders.contains { $0.id == folderID } }
        )

        try await store.renamePlaylistFolder(folderID, name: "Live Sets")
        try await verifyUndoRedo(
            undoManager,
            undoCondition: { store.playlistFolders.first { $0.id == folderID }?.name == "Sets" },
            redoCondition: {
                store.playlistFolders.first { $0.id == folderID }?.name == "Live Sets"
            }
        )

        try await store.movePlaylist(playlistID, to: folderID)
        try await verifyUndoRedo(
            undoManager,
            undoCondition: { store.playlists.first { $0.id == playlistID }?.folderID == nil },
            redoCondition: {
                store.playlists.first { $0.id == playlistID }?.folderID == folderID
            }
        )

        let secondFolderID = try await store.createPlaylistFolder(name: "Archive")
        try await store.movePlaylistFolder(secondFolderID, before: folderID)
        try await verifyUndoRedo(
            undoManager,
            undoCondition: { store.sortedPlaylistFolders.map(\.id) == [folderID, secondFolderID] },
            redoCondition: { store.sortedPlaylistFolders.map(\.id) == [secondFolderID, folderID] }
        )

        try await store.deletePlaylistFolder(folderID)
        try await verifyUndoRedo(
            undoManager,
            undoCondition: {
                store.playlistFolders.contains { $0.id == folderID }
                    && store.playlists.first { $0.id == playlistID }?.folderID == folderID
            },
            redoCondition: {
                !store.playlistFolders.contains { $0.id == folderID }
                    && store.playlists.first { $0.id == playlistID }?.folderID == nil
            }
        )

        let restarted = LibraryStore(repository: LibraryRepository(rootURL: root))
        await restarted.load()
        #expect(restarted.playlists.first { $0.id == playlistID }?.entries.map(\.trackID)
            == reorderedIDs)
        #expect(restarted.playlistFolders.map(\.id) == [secondFolderID])
    }

    @Test("Playlist references survive file relocation, metadata edits, and restart")
    @MainActor
    func preservesReferencesAcrossRelocationMetadataAndRestart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ongaku-M2-References-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let originalURL = root.appendingPathComponent("Original/reference.m4a")
        let relocatedURL = root.appendingPathComponent("Relocated/reference.m4a")
        try FileManager.default.createDirectory(
            at: originalURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: relocatedURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let audioBytes = Data("M2 stable identity fixture".utf8)
        try audioBytes.write(to: originalURL)
        let track = Track(
            id: UUID(), title: "Before", artist: "Old Artist", album: "Old Album",
            duration: 180, fileSize: Int64(audioBytes.count), managedPath: originalURL.path,
            sha256: try LibraryRepository.sha256(of: originalURL), addedAt: .now,
            lastVerifiedAt: .now, health: .verified
        )
        let repository = LibraryRepository(rootURL: root)
        try await repository.save(tracks: [track])
        let store = LibraryStore(repository: repository)
        await store.load()
        let playlistID = try await store.createPlaylist(
            name: "Stable References", description: "", artworkData: nil
        )
        _ = try await store.addTracks([track.id], to: playlistID)

        try FileManager.default.moveItem(at: originalURL, to: relocatedURL)
        await store.relinkTrack(id: track.id, to: relocatedURL)
        try await store.updateTrackMetadata(
            id: track.id,
            title: "After",
            artist: "New Artist",
            album: "New Album"
        )

        let currentPlaylist = try #require(store.playlists.first { $0.id == playlistID })
        let resolved = try #require(store.tracks(in: currentPlaylist).first)
        #expect(resolved.id == track.id)
        #expect(resolved.managedPath == relocatedURL.path)
        #expect(resolved.title == "After")

        let restarted = LibraryStore(repository: LibraryRepository(rootURL: root))
        await restarted.load()
        let restoredPlaylist = try #require(restarted.playlists.first { $0.id == playlistID })
        let restoredTrack = try #require(restarted.tracks(in: restoredPlaylist).first)
        #expect(restoredPlaylist.entries.map(\.trackID) == [track.id])
        #expect(restoredTrack.id == track.id)
        #expect(restoredTrack.managedPath == relocatedURL.path)
        #expect(restoredTrack.title == "After")
        #expect(restoredTrack.artist == "New Artist")
        #expect(restoredTrack.album == "New Album")
    }

    @MainActor
    private func verifyUndoRedo(
        _ undoManager: UndoManager,
        undoCondition: @escaping @MainActor () -> Bool,
        redoCondition: @escaping @MainActor () -> Bool
    ) async throws {
        #expect(undoManager.canUndo)
        undoManager.undo()
        try await waitUntil(undoCondition)
        #expect(undoManager.canRedo)
        undoManager.redo()
        try await waitUntil(redoCondition)
    }

    @MainActor
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for the asynchronous playlist operation")
    }

    private func makeArtworkData() throws -> Data {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemPurple.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 8, height: 8)).fill()
        image.unlockFocus()
        return try #require(image.tiffRepresentation)
    }
}
