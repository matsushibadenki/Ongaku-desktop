import AppKit
import AVFoundation
import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Library repository integrity")
struct LibraryRepositoryTests {
    private final class FailingRecoveryFileManager: FileManager, @unchecked Sendable {
        override func moveItem(at source: URL, to destination: URL) throws {
            if source.deletingLastPathComponent().lastPathComponent == "Prepared",
               source.lastPathComponent == "library-v1.json" {
                throw CocoaError(.fileWriteNoPermission)
            }
            try super.moveItem(at: source, to: destination)
        }
    }

    @Test("A recovery commit failure restores the active catalog and its sidecars")
    func preservedRecoveryRollsBack() async throws {
        let media = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: media) }
        let catalog = PortableLibraryStorage(mediaURL: media).rootURL
        _ = try await LibraryRepository(rootURL: catalog, mediaURL: media).load()
        let names = ["library-v1.json", "playback-queue-v1.json", "playback-events-v1.json"]
        let originals = try names.map { try Data(contentsOf: catalog.appendingPathComponent($0)) }
        let archived = catalog.appendingPathComponent("Legacy Imports/original")
        try await LibraryRepository(rootURL: archived, mediaURL: media).save(playlists: [Playlist(name: "Original")])
        let archivedBytes = try Data(contentsOf: archived.appendingPathComponent("library-v1.json"))
        let failing = LibraryRepository(rootURL: catalog, mediaURL: media, fileManager: FailingRecoveryFileManager())
        do {
            try await failing.restorePreservedLibraryIfEmpty()
            Issue.record("Injected recovery failure must be reported")
        } catch {
            #expect((error as NSError).code == CocoaError.fileWriteNoPermission.rawValue)
        }
        for (name, bytes) in zip(names, originals) {
            #expect(try Data(contentsOf: catalog.appendingPathComponent(name)) == bytes)
        }
        #expect(try Data(contentsOf: archived.appendingPathComponent("library-v1.json")) == archivedBytes)
    }

#if DEBUG
    @Test("Interrupted storage restore rolls back without deleting files", arguments: [0, 1, 2, 3], [false, true])
    func interruptedStorageRestore(step: Int, diskFull: Bool) async throws {
        let media = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: media) }
        let catalog = PortableLibraryStorage(mediaURL: media).rootURL
        let original = LibraryRepository(rootURL: catalog, mediaURL: media)
        let old = try await original.load().document
        let oldManifest = try Data(contentsOf: catalog.appendingPathComponent("library-v1.json"))
        let oldQueue = try Data(contentsOf: catalog.appendingPathComponent("playback-queue-v1.json"))
        let archived = catalog.appendingPathComponent("Legacy Imports/original")
        let preserved = LibraryRepository(rootURL: archived, mediaURL: media)
        try await preserved.save(playlists: [Playlist(name: "Preserved", description: "")])
        let archiveBytes = try Data(contentsOf: archived.appendingPathComponent("library-v1.json"))
        let restoring = LibraryRepository(rootURL: catalog, mediaURL: media)
        await restoring.setStorageRestoreTestHook { point in
            let shouldStop: Bool
            switch point {
            case .afterBackup(let name): shouldStop = (step == 0 && name == "playback-queue-v1.json") || (step == 2 && name == "library-v1.json")
            case .afterInstall(let name): shouldStop = (step == 1 && name == "playback-queue-v1.json") || (step == 3 && name == "library-v1.json")
            case .beforeRollbackCopy: shouldStop = false
            }
            if shouldStop {
                if diskFull { throw POSIXError(.ENOSPC) }
                throw LibraryRepository.StorageRestoreInterruption()
            }
        }
        do { try await restoring.restorePreservedLibraryIfEmpty(); Issue.record("Expected interruption") }
        catch is LibraryRepository.StorageRestoreInterruption { }
        catch let error as POSIXError { #expect(diskFull && error.code == .ENOSPC) }
        let journal = catalog.appendingPathComponent("storage-restore-journal-v1.json")
        #expect(FileManager.default.fileExists(atPath: journal.path) == !diskFull)
        let restarted = LibraryRepository(rootURL: catalog, mediaURL: media)
        let recovered = try await restarted.load().document
        #expect(recovered.libraryID == old.libraryID)
        #expect(recovered.playlists.isEmpty)
        #expect(try Data(contentsOf: catalog.appendingPathComponent("library-v1.json")) == oldManifest)
        #expect(try Data(contentsOf: catalog.appendingPathComponent("playback-queue-v1.json")) == oldQueue)
        #expect(try Data(contentsOf: archived.appendingPathComponent("library-v1.json")) == archiveBytes)
        #expect(!FileManager.default.fileExists(atPath: journal.path))
        try await restarted.restorePreservedLibraryIfEmpty()
        let retried = try await restarted.load().document
        #expect(retried.playlists.map(\.name) == ["Preserved"])
    }

    @Test("Interrupted rollback can be retried without losing the prior catalog")
    func interruptedStorageRollbackRetries() async throws {
        let media = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: media) }
        let catalog = PortableLibraryStorage(mediaURL: media).rootURL
        let original = LibraryRepository(rootURL: catalog, mediaURL: media)
        _ = try await original.load()
        let oldManifest = try Data(contentsOf: catalog.appendingPathComponent("library-v1.json"))
        let archived = catalog.appendingPathComponent("Legacy Imports/original")
        try await LibraryRepository(rootURL: archived, mediaURL: media).save(playlists: [Playlist(name: "Preserved", description: "")])
        let restoring = LibraryRepository(rootURL: catalog, mediaURL: media)
        await restoring.setStorageRestoreTestHook { point in
            if case .afterInstall("library-v1.json") = point { throw LibraryRepository.StorageRestoreInterruption() }
        }
        do { try await restoring.restorePreservedLibraryIfEmpty(); Issue.record("Expected interruption") }
        catch is LibraryRepository.StorageRestoreInterruption { }
        let recovering = LibraryRepository(rootURL: catalog, mediaURL: media)
        await recovering.setStorageRestoreTestHook { point in
            if case .beforeRollbackCopy("library-v1.json") = point { throw LibraryRepository.StorageRestoreInterruption() }
        }
        do { _ = try await recovering.load(); Issue.record("Expected second interruption") }
        catch is LibraryRepository.StorageRestoreInterruption { }
        #expect(FileManager.default.fileExists(atPath: catalog.appendingPathComponent("storage-restore-journal-v1.json").path))
        let recovered = try await LibraryRepository(rootURL: catalog, mediaURL: media).load().document
        #expect(recovered.playlists.isEmpty)
        #expect(try Data(contentsOf: catalog.appendingPathComponent("library-v1.json")) == oldManifest)
        #expect(!FileManager.default.fileExists(atPath: catalog.appendingPathComponent("storage-restore-journal-v1.json").path))
    }
#endif

    @Test("Storage selection recovers preserved catalogs without moving originals", arguments: [
        "Ongaku Library Data/Legacy Imports/preserved",
        "Ongaku Desktop/Ongaku Media/Ongaku Library Data",
        "Ongaku Desktop"
    ])
    @MainActor
    func recoversPreservedStorage(relativePath: String) async throws {
        let media = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: media) }
        let catalog = PortableLibraryStorage(mediaURL: media).rootURL
        let active = LibraryRepository(rootURL: catalog, mediaURL: media)
        let empty = try await active.load().document
        let originalPrimary = try Data(contentsOf: catalog.appendingPathComponent("library-v1.json"))
        let preservedURL = media.appendingPathComponent(relativePath)
        let preserved = LibraryRepository(rootURL: preservedURL, mediaURL: media)
        let song = media.appendingPathComponent("Artist/Album/song.mp3")
        try FileManager.default.createDirectory(at: song.deletingLastPathComponent(), withIntermediateDirectories: true)
        let audio = Data("original audio".utf8)
        try audio.write(to: song)
        let track = Track(
            id: UUID(), title: "Preserved title", artist: "Artist", album: "Album",
            duration: 30, fileSize: Int64(audio.count), managedPath: song.path,
            sha256: try LibraryRepository.sha256(of: song), addedAt: .now, health: .verified
        )
        try await preserved.save(tracks: [track])
        let playlist = Playlist(name: "Preserved playlist", entries: [PlaylistEntry(trackID: track.id)])
        try await preserved.save(playlists: [playlist])
        let queue = PlaybackQueueState(trackIDs: [track.id], currentTrackID: track.id, position: 12)
        try await preserved.save(playbackQueue: queue)
        let preservedID = try await preserved.load().document.libraryID
        let preservedBytes = try Data(contentsOf: preservedURL.appendingPathComponent("library-v1.json"))
        let artwork = preservedURL.appendingPathComponent("Artwork/Custom/cover.png")
        try FileManager.default.createDirectory(at: artwork.deletingLastPathComponent(), withIntermediateDirectories: true)
        let artworkData = Data("artwork fixture".utf8)
        try artworkData.write(to: artwork)

        let store = LibraryStore(repository: active)
        await store.load()
        try await store.openStorageDirectory(media)
        #expect(store.tracks.map(\.id) == [track.id])
        #expect(store.playlists.map(\.id) == [playlist.id])
        #expect(store.playbackQueue == queue)
        let restored = try await LibraryRepository(rootURL: catalog, mediaURL: media).load().document
        #expect(restored.libraryID == preservedID)
        #expect(restored.libraryID != empty.libraryID)
        #expect(try Data(contentsOf: song) == audio)
        #expect(try Data(contentsOf: preservedURL.appendingPathComponent("library-v1.json")) == preservedBytes)
        #expect(try Data(contentsOf: catalog.appendingPathComponent("Artwork/Custom/cover.png")) == artworkData)
        let backups = try FileManager.default.contentsOfDirectory(
            at: catalog.appendingPathComponent("Recovery Backups"), includingPropertiesForKeys: nil
        )
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: backups[0].appendingPathComponent("Previous/library-v1.json")) == originalPrimary)
        try await store.openStorageDirectory(media)
        #expect(store.tracks.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: catalog.appendingPathComponent("Recovery Backups").path).count == 1)
    }

    @Test("Restoring a preserved library invalidates other repositories")
    func preservedRecoveryInvalidatesStaleWriter() async throws {
        let media = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: media) }
        let catalog = PortableLibraryStorage(mediaURL: media).rootURL
        let original = LibraryRepository(rootURL: catalog, mediaURL: media)
        _ = try await original.load()
        let stale = LibraryRepository(rootURL: catalog, mediaURL: media)
        _ = try await stale.load()
        let generationURL = catalog.appendingPathComponent("catalog-generation-v1")
        let before = try #require(UInt64(try String(contentsOf: generationURL, encoding: .utf8)))
        let archive = catalog.appendingPathComponent("Legacy Imports/preserved")
        let preserved = LibraryRepository(rootURL: archive, mediaURL: media)
        try await preserved.save(playlists: [Playlist(name: "Preserved", description: "")])
        try await original.restorePreservedLibraryIfEmpty()
        let after = try #require(UInt64(try String(contentsOf: generationURL, encoding: .utf8)))
        #expect(after > before)
        do { try await stale.save(playlists: []); Issue.record("Stale writer overwrote restored library") }
        catch LibraryRepository.RepositoryError.staleOrganizedTrack { }
        let actual = try await LibraryRepository(rootURL: catalog, mediaURL: media).load().document
        #expect(actual.playlists.map(\.name) == ["Preserved"])
    }

    @Test("Damaged recovery journals preserve catalog and stop writes", arguments: ["storage-restore-journal-v1.json", "catalog-write-journal-v1.json"])
    func damagedRecoveryJournalIsRetained(name: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        try await repository.save(playlists: [Playlist(name: "Original", description: "")])
        let names = ["library-v1.json", "playback-queue-v1.json", "playback-events-v1.json"]
        let originals = try names.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        let damaged = Data("invalid journal".utf8)
        let journal = root.appendingPathComponent(name)
        try damaged.write(to: journal)
        let reopened = LibraryRepository(rootURL: root)
        do { _ = try await reopened.load(); Issue.record("Damaged journal accepted") }
        catch is LibraryRepository.CatalogWriteRecoveryRequired { }
        do { try await reopened.save(playlists: []); Issue.record("Write bypassed damaged journal") }
        catch is LibraryRepository.CatalogWriteRecoveryRequired { }
        let source = root.appendingPathComponent("source.mp3")
        try Data("audio".utf8).write(to: source)
        let attempted = await reopened.importFiles([source], existing: [])
        #expect(attempted.imported.isEmpty)
        #expect(attempted.issues.count == 1)
        #expect(try Data(contentsOf: journal) == damaged)
        for (file, data) in zip(names, originals) {
            #expect(try Data(contentsOf: root.appendingPathComponent(file)) == data)
        }
    }

#if DEBUG
    @Test("A modified but decodable journal payload cannot replace the catalog")
    func changedJournalPayloadIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        try await repository.save(playlists: [Playlist(name: "Original", description: "")])
        let baseline = try await repository.load().document
        var pending = baseline
        pending.playlists = [Playlist(name: "Pending", description: "")]
        await repository.setCatalogWriteTestHook { stage in
            if case .journal = stage { throw CocoaError(.fileWriteUnknown) }
        }
        do { try await repository.save(document: pending, expectedDocument: baseline); Issue.record("Expected interruption") } catch { }
        let journalURL = root.appendingPathComponent("catalog-write-journal-v1.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any])
        var altered = baseline
        altered.playlists = [Playlist(name: "Altered", description: "")]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        object["manifest"] = try encoder.encode(altered).base64EncodedString()
        let corruptJournal = try JSONSerialization.data(withJSONObject: object)
        try corruptJournal.write(to: journalURL, options: .atomic)
        let manifestURL = root.appendingPathComponent("library-v1.json")
        let original = try Data(contentsOf: manifestURL)
        do { _ = try await LibraryRepository(rootURL: root).load(); Issue.record("Altered journal accepted") }
        catch is LibraryRepository.CatalogWriteRecoveryRequired { }
        #expect(try Data(contentsOf: manifestURL) == original)
        #expect(try Data(contentsOf: journalURL) == corruptJournal)
    }
#endif

    @Test("A preserved catalog with pending recovery is never transplanted", arguments: ["catalog-write-journal-v1.json", "storage-restore-journal-v1.json", "import-journal-v1.json", "self-containment-journal-v1.json"])
    func preservedCatalogPendingRecoveryIsRejected(name: String) async throws {
        let media = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: media) }
        let catalog = PortableLibraryStorage(mediaURL: media).rootURL
        let active = LibraryRepository(rootURL: catalog, mediaURL: media)
        let original = try await active.load().document
        let activeURL = catalog.appendingPathComponent("library-v1.json")
        let originalBytes = try Data(contentsOf: activeURL)
        let archive = catalog.appendingPathComponent("Legacy Imports/preserved")
        let candidate = LibraryRepository(rootURL: archive, mediaURL: media)
        try await candidate.save(playlists: [Playlist(name: "Preserved", description: "")])
        let archivedURL = archive.appendingPathComponent("library-v1.json")
        let archivedBytes = try Data(contentsOf: archivedURL)
        let journalURL = archive.appendingPathComponent(name)
        let journalBytes = Data("pending".utf8)
        try journalBytes.write(to: journalURL)
        do { try await active.restorePreservedLibraryIfEmpty(); Issue.record("Pending recovery was ignored") }
        catch LibraryRepository.RepositoryError.sourceRecoveryRequired(let path) {
            #expect(URL(fileURLWithPath: path).resolvingSymlinksInPath() == archive.resolvingSymlinksInPath())
        }
        #expect(try Data(contentsOf: activeURL) == originalBytes)
        #expect(try Data(contentsOf: archivedURL) == archivedBytes)
        #expect(try Data(contentsOf: journalURL) == journalBytes)
        #expect(try await active.load().document.libraryID == original.libraryID)
    }

    @Test("Pending imports in the active library recover before selecting a preserved catalog")
    func activePendingImportRecoversBeforePreservedSelection() async throws {
        let media = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: media) }
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let catalog = PortableLibraryStorage(mediaURL: media).rootURL
        let active = LibraryRepository(rootURL: catalog, mediaURL: media)
        _ = try await active.load()
        let source = media.appendingPathComponent("source.mp3")
        let bytes = Data([0x49, 0x44, 0x33, 5, 6, 7])
        try bytes.write(to: source)
        let imported = await active.importFiles([source], existing: [])
        let track = try #require(imported.imported.first)
        let archive = catalog.appendingPathComponent("Legacy Imports/preserved")
        let candidate = LibraryRepository(rootURL: archive, mediaURL: media)
        try await candidate.save(playlists: [Playlist(name: "Preserved", description: "")])
        let archivedURL = archive.appendingPathComponent("library-v1.json")
        let archivedBytes = try Data(contentsOf: archivedURL)
        try await active.restorePreservedLibraryIfEmpty()
        let recovered = try await active.load().document
        #expect(recovered.tracks.map(\.id) == [track.id])
        #expect(recovered.playlists.isEmpty)
        #expect(try Data(contentsOf: track.fileURL) == bytes)
        #expect(try Data(contentsOf: archivedURL) == archivedBytes)
    }

    @Test("Recovery never replaces a populated catalog or revives intentionally cleared songs")
    func preservedRecoveryRespectsActiveLibrary() async throws {
        let media = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: media) }
        let catalog = PortableLibraryStorage(mediaURL: media).rootURL
        let repository = LibraryRepository(rootURL: catalog, mediaURL: media)
        let track = Track(id: UUID(), title: "Current", artist: "Artist", album: "Album", duration: 1,
                          fileSize: 1, managedPath: media.appendingPathComponent("song.mp3").path,
                          sha256: "current", addedAt: .now, health: .verified)
        try await repository.save(tracks: [track])
        let archive = catalog.appendingPathComponent("Legacy Imports/old")
        let preserved = LibraryRepository(rootURL: archive, mediaURL: media)
        var oldTrack = track
        oldTrack.title = "Old"
        try await preserved.save(tracks: [oldTrack])
        try await repository.restorePreservedLibraryIfEmpty()
        #expect(try await repository.load().document.tracks.first?.title == "Current")
        try await repository.clearAllRegistrations()
        try await repository.restorePreservedLibraryIfEmpty()
        #expect(try await repository.load().document.tracks.isEmpty)
    }

    @Test("Multiple preserved catalogs are reported without modifying any catalog")
    func ambiguousPreservedLibraries() async throws {
        let media = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: media) }
        let catalog = PortableLibraryStorage(mediaURL: media).rootURL
        let repository = LibraryRepository(rootURL: catalog, mediaURL: media)
        _ = try await repository.load()
        let original = try Data(contentsOf: catalog.appendingPathComponent("library-v1.json"))
        for name in ["First", "Second"] {
            let archive = catalog.appendingPathComponent("Legacy Imports/\(name)")
            try await LibraryRepository(rootURL: archive, mediaURL: media).save(playlists: [Playlist(name: name)])
        }
        do {
            try await repository.restorePreservedLibraryIfEmpty()
            Issue.record("Ambiguous catalogs must not be selected automatically")
        } catch LibraryRepository.RepositoryError.multiplePreservedLibraries(let paths) {
            #expect(paths.contains("First"))
            #expect(paths.contains("Second"))
        }
        #expect(try Data(contentsOf: catalog.appendingPathComponent("library-v1.json")) == original)
        #expect(!FileManager.default.fileExists(atPath: catalog.appendingPathComponent("Recovery Backups").path))
    }

    @Test("A missing primary catalog recovers the existing library from its backup")
    func missingPrimaryRecoversBackup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root, mediaURL: root.appendingPathComponent("Media"))
        let initial = try await repository.load().document
        let manifest = root.appendingPathComponent("library-v1.json")
        #expect(FileManager.default.fileExists(atPath: manifest.path))
        let backup = root.appendingPathComponent("library-v1.backup.json")
        try FileManager.default.moveItem(at: manifest, to: backup)
        let recovered = try await repository.load()
        #expect(recovered.recoveredFromBackup)
        #expect(recovered.document.libraryID == initial.libraryID)
        #expect(FileManager.default.fileExists(atPath: manifest.path))
        #expect(try await repository.load().document.libraryID == initial.libraryID)
    }

    @Test("External songs become portable without changing metadata or deleting originals")
    func externalSongsBecomePortable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("original.mp3")
        let bytes = Data("external audio fixture".utf8)
        try bytes.write(to: original)
        let media = root.appendingPathComponent("SSD-A")
        let catalog = PortableLibraryStorage(mediaURL: media).rootURL
        let repository = LibraryRepository(rootURL: catalog, mediaURL: media)
        let song = Track(id: UUID(), title: "Song", artist: "Artist", album: "Album",
                         duration: 12, fileSize: Int64(bytes.count), managedPath: original.path,
                         sha256: try LibraryRepository.sha256(of: original), addedAt: .now, health: .verified)
        try await repository.save(tracks: [song])
        let playlist = Playlist(name: "Keep", entries: [PlaylistEntry(trackID: song.id)])
        try await repository.save(playlists: [playlist])
        let libraryID = try await repository.load().document.libraryID
        try await repository.makeLibrarySelfContained()
        let loaded = try await repository.load().document
        let copied = try #require(loaded.tracks.first)
        #expect(copied.id == song.id)
        #expect(copied.title == song.title)
        #expect(loaded.libraryID == libraryID)
        #expect(loaded.playlists.map(\.id) == [playlist.id])
        #expect(loaded.playlists.first?.entries.map(\.trackID) == [song.id])
        #expect(copied.fileURL.path.hasPrefix(media.path + "/"))
        #expect(try Data(contentsOf: original) == bytes)
        #expect(try Data(contentsOf: copied.fileURL) == bytes)
        // Carry just the selected folder to a differently named volume/folder.
        let moved = root.appendingPathComponent("SSD-B")
        try FileManager.default.moveItem(at: media, to: moved)
        try FileManager.default.removeItem(at: original)
        let reopened = try await LibraryRepository(rootURL: PortableLibraryStorage(mediaURL: moved).rootURL,
                                                  mediaURL: moved).load().document
        #expect(reopened.tracks.first?.id == song.id)
        #expect(try Data(contentsOf: #require(reopened.tracks.first).fileURL) == bytes)
    }

    private final class FullDiskCopyFileManager: FileManager, @unchecked Sendable {
        let failingSource: URL
        init(failingSource: URL) { self.failingSource = failingSource; super.init() }
        override func copyItem(at source: URL, to destination: URL) throws {
            if source.standardizedFileURL == failingSource.standardizedFileURL {
                // Simulate a partially written staging file followed by ENOSPC.
                try Data("partial".utf8).write(to: destination)
                throw POSIXError(.ENOSPC)
            }
            try super.copyItem(at: source, to: destination)
        }
    }

    @Test("Self-contained copy retains both originals and catalog on a full disk")
    func selfContainedCopyOutOfSpace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let media = root.appendingPathComponent("Media")
        let catalog = PortableLibraryStorage(mediaURL: media).rootURL
        let urls = [root.appendingPathComponent("one.mp3"), root.appendingPathComponent("two.mp3")]
        let contents = [Data("first original".utf8), Data("second original".utf8)]
        for (url, data) in zip(urls, contents) { try data.write(to: url) }
        let tracks = try zip(urls, contents).enumerated().map { index, entry in
            Track(id: UUID(), title: "Track \(index)", artist: "Artist", album: "Album",
                  duration: 1, fileSize: Int64(entry.1.count), managedPath: entry.0.path,
                  sha256: try LibraryRepository.sha256(of: entry.0), addedAt: .now, health: .verified)
        }
        let normal = LibraryRepository(rootURL: catalog, mediaURL: media)
        try await normal.save(tracks: tracks)
        let failing = LibraryRepository(rootURL: catalog, mediaURL: media,
                                        fileManager: FullDiskCopyFileManager(failingSource: urls[1]))
        do {
            try await failing.makeLibrarySelfContained()
            Issue.record("The simulated full disk must be reported")
        } catch let error as POSIXError {
            #expect(error.code == .ENOSPC)
        }
        let reopened = LibraryRepository(rootURL: catalog, mediaURL: media)
        let beforeRetry = try await reopened.load().document
        #expect(beforeRetry.tracks.map(\.managedPath) == tracks.map(\.managedPath))
        for (url, data) in zip(urls, contents) { #expect(try Data(contentsOf: url) == data) }
        let incoming = catalog.appendingPathComponent("Incoming")
        #expect(try FileManager.default.contentsOfDirectory(atPath: incoming.path).isEmpty)
        try await reopened.makeLibrarySelfContained()
        let afterRetry = try await reopened.load().document
        #expect(afterRetry.tracks.count == tracks.count)
        for (track, data) in zip(afterRetry.tracks, contents) {
            #expect(track.fileURL.path.hasPrefix(media.path + "/"))
            #expect(try Data(contentsOf: track.fileURL) == data)
        }
        for (url, data) in zip(urls, contents) { #expect(try Data(contentsOf: url) == data) }
    }

    @Test("Interrupted self-containment cleans only its recorded staging directory", arguments: [false, true])
    func interruptedSelfContainmentStaging(stagedFileExists: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        let baseline = try await repository.load().document
        let incoming = root.appendingPathComponent("Incoming")
        let transaction = UUID()
        let staging = incoming.appendingPathComponent("self-containment-\(transaction.uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        if stagedFileExists { try Data("partial".utf8).write(to: staging.appendingPathComponent(UUID().uuidString)) }
        let unrelated = incoming.appendingPathComponent("unrelated")
        try Data("keep".utf8).write(to: unrelated)
        let journal = root.appendingPathComponent("self-containment-journal-v1.json")
        let bytes = try JSONSerialization.data(withJSONObject: ["version": 1, "transactionID": transaction.uuidString])
        try bytes.write(to: journal)
        let actual = try await LibraryRepository(rootURL: root).load().document
        #expect(actual.libraryID == baseline.libraryID)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(!FileManager.default.fileExists(atPath: journal.path))
        #expect(try Data(contentsOf: unrelated) == Data("keep".utf8))
        #expect(try await LibraryRepository(rootURL: root).load().document.libraryID == baseline.libraryID)
    }

    @Test("Unsafe self-containment recovery preserves files and quarantines its journal", arguments: [false, true])
    func unsafeSelfContainmentRecovery(corruptJournal: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        _ = try await repository.load()
        let catalog = root.appendingPathComponent("library-v1.json")
        let originalCatalog = try Data(contentsOf: catalog)
        let transaction = UUID()
        let staging = root.appendingPathComponent("Incoming/self-containment-\(transaction.uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let unexpected = staging.appendingPathComponent("do-not-delete")
        try Data("keep".utf8).write(to: unexpected)
        let journal = root.appendingPathComponent("self-containment-journal-v1.json")
        let bytes = corruptJournal ? Data("broken".utf8) : try JSONSerialization.data(withJSONObject: ["version": 1, "transactionID": transaction.uuidString])
        try bytes.write(to: journal)
        _ = try await LibraryRepository(rootURL: root).load()
        #expect(try Data(contentsOf: unexpected) == Data("keep".utf8))
        #expect(!FileManager.default.fileExists(atPath: journal.path))
        let backups = root.appendingPathComponent("Recovery Backups")
        let entries = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        let preserved = try #require(entries.first { $0.lastPathComponent.hasPrefix("Self-Containment-") })
        #expect(try Data(contentsOf: preserved.appendingPathComponent("self-containment-journal-v1.json")) == bytes)
        #expect(try Data(contentsOf: catalog) == originalCatalog)
    }

#if DEBUG
    @Test("Self-containment staging recovery follows interrupted catalog commit")
    func selfContainmentRecoversWithCatalogJournal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("source.mp3")
        let bytes = Data("source audio".utf8)
        try bytes.write(to: original)
        let media = root.appendingPathComponent("Media")
        let catalog = PortableLibraryStorage(mediaURL: media).rootURL
        let repository = LibraryRepository(rootURL: catalog, mediaURL: media)
        let track = Track(id: UUID(), title: "Song", artist: "Artist", album: "Album", duration: 1,
                          fileSize: Int64(bytes.count), managedPath: original.path,
                          sha256: try LibraryRepository.sha256(of: original), addedAt: .now, health: .verified)
        try await repository.save(tracks: [track])
        await repository.setCatalogWriteTestHook { step in
            if case .journal = step { throw POSIXError(.ENOSPC) }
        }
        do { try await repository.makeLibrarySelfContained(); Issue.record("Expected interruption") }
        catch let error as POSIXError { #expect(error.code == .ENOSPC) }
        #expect(FileManager.default.fileExists(atPath: catalog.appendingPathComponent("catalog-write-journal-v1.json").path))
        // Recreate the staging state left by a process termination before defer runs.
        let id = UUID()
        let staging = catalog.appendingPathComponent("Incoming/self-containment-\(id.uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: staging.appendingPathComponent(UUID().uuidString))
        let journal = catalog.appendingPathComponent("self-containment-journal-v1.json")
        try JSONSerialization.data(withJSONObject: ["version": 1, "transactionID": id.uuidString]).write(to: journal)
        let reopened = try await LibraryRepository(rootURL: catalog, mediaURL: media).load().document
        let recovered = try #require(reopened.tracks.first)
        #expect(recovered.id == track.id)
        #expect(recovered.fileURL.path.hasPrefix(media.path + "/"))
        #expect(try Data(contentsOf: recovered.fileURL) == bytes)
        #expect(try Data(contentsOf: original) == bytes)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(!FileManager.default.fileExists(atPath: journal.path))
    }
#endif

    @Test("Damaged generation and journals can be exported without changing the source", arguments: ["catalog-generation-v1", "catalog-write-journal-v1.json", "storage-restore-journal-v1.json", "import-journal-v1.json"])
    func damagedRecoverySnapshot(name: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = root.appendingPathComponent("Catalog")
        let target = root.appendingPathComponent("Export")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let repository = LibraryRepository(rootURL: catalog)
        try await repository.save(playlists: [Playlist(name: "Original")])
        let damaged = Data("broken".utf8)
        let source = catalog.appendingPathComponent(name)
        try damaged.write(to: source)
        let manifest = catalog.appendingPathComponent("library-v1.json")
        let original = try Data(contentsOf: manifest)
        if name != "catalog-generation-v1" {
            do { _ = try await repository.load(); Issue.record("Damaged data accepted") } catch { }
        }
        let snapshot = try await repository.exportRecoverySnapshot(to: target)
        #expect(try Data(contentsOf: snapshot.appendingPathComponent(name)) == damaged)
        #expect(try Data(contentsOf: snapshot.appendingPathComponent("library-v1.json")) == original)
        #expect(try Data(contentsOf: source) == damaged)
        #expect(try Data(contentsOf: manifest) == original)
        #expect(!FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("Incoming").path))
        do { _ = try await repository.exportRecoverySnapshot(to: catalog); Issue.record("Snapshot inside the source accepted") } catch { }
    }

    @Test("A full export destination never changes the damaged source and can be retried")
    func recoverySnapshotOutOfSpace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = root.appendingPathComponent("Catalog")
        let target = root.appendingPathComponent("Export")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let repository = LibraryRepository(rootURL: catalog)
        try await repository.save(playlists: [Playlist(name: "Original")])
        let manifest = catalog.appendingPathComponent("library-v1.json")
        let bytes = try Data(contentsOf: manifest)
        let failing = LibraryRepository(rootURL: catalog, fileManager: FullDiskCopyFileManager(failingSource: manifest))
        do { _ = try await failing.exportRecoverySnapshot(to: target); Issue.record("Expected full disk") }
        catch let error as POSIXError { #expect(error.code == .ENOSPC) }
        #expect(try Data(contentsOf: manifest) == bytes)
        let contents = try FileManager.default.contentsOfDirectory(atPath: target.path)
        #expect(contents.count == 1 && contents[0].hasSuffix(".partial"))
        let snapshot = try await repository.exportRecoverySnapshot(to: target)
        #expect(try Data(contentsOf: snapshot.appendingPathComponent("library-v1.json")) == bytes)
    }

    @Test("Generation backup capacity failure retains the damaged original")
    func generationBackupOutOfSpace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        try await repository.save(playlists: [Playlist(name: "Keep")])
        let generation = root.appendingPathComponent("catalog-generation-v1")
        let damaged = Data("damaged".utf8)
        try damaged.write(to: generation, options: .atomic)
        let failing = LibraryRepository(rootURL: root, fileManager: FullDiskCopyFileManager(failingSource: generation))
        do { _ = try await failing.load(); Issue.record("Expected full disk") }
        catch let error as POSIXError { #expect(error.code == .ENOSPC) }
        #expect(try Data(contentsOf: generation) == damaged)
        #expect(try await LibraryRepository(rootURL: root).load().document.playlists.map(\.name) == ["Keep"])
    }

    @Test("Missing external originals do not commit a partially localized catalog")
    func missingExternalCopyPreservesCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("Media")
        let repository = LibraryRepository(rootURL: PortableLibraryStorage(mediaURL: media).rootURL, mediaURL: media)
        let song = Track(id: UUID(), title: "Missing", artist: "Artist", album: "Album", duration: 1,
                         fileSize: 1, managedPath: root.appendingPathComponent("missing.mp3").path,
                         sha256: "missing", addedAt: .now, health: .missing)
        try await repository.save(tracks: [song])
        do {
            try await repository.makeLibrarySelfContained()
            Issue.record("Missing originals must be reported")
        } catch {}
        #expect(try await repository.load().document.tracks.first?.managedPath == song.managedPath)
    }

    private func fixtureURL(_ name: String) -> URL {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "Fixtures"
        ) else {
            fatalError("Missing test fixture: \(name)")
        }
        return url
    }

    @Test("A copied portable library relinks managed tracks on the new Mac")
    func copiedPortableLibraryRelinksTracks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ongaku-Copied-Library-\(UUID().uuidString)")
        let oldMedia = root.appendingPathComponent("Old Mac/Ongaku Media", isDirectory: true)
        let oldCatalog = PortableLibraryStorage(mediaURL: oldMedia).rootURL
        let oldSong = oldMedia.appendingPathComponent("Artist/Album/Song.mp3")
        let newMedia = root.appendingPathComponent("New Mac/My Music", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: oldSong.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let audio = Data("portable audio fixture".utf8)
        try audio.write(to: oldSong)
        let track = Track(
            id: UUID(), title: "Song", artist: "Artist", album: "Album",
            duration: 10, fileSize: Int64(audio.count), managedPath: oldSong.path,
            sha256: try LibraryRepository.sha256(of: oldSong), addedAt: .now, health: .verified
        )
        try await LibraryRepository(rootURL: oldCatalog, mediaURL: oldMedia).save(tracks: [track])
        try FileManager.default.createDirectory(
            at: newMedia.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: oldMedia, to: newMedia)
        try FileManager.default.removeItem(at: oldMedia)

        let newCatalog = PortableLibraryStorage(mediaURL: newMedia).rootURL
        let loaded = try await LibraryRepository(rootURL: newCatalog, mediaURL: newMedia).load().document
        let restored = try #require(loaded.tracks.first)
        #expect(restored.fileURL == newMedia.appendingPathComponent("Artist/Album/Song.mp3"))
        #expect(restored.health == .verified)
    }

    @Test("Resolving duplicates transfers catalog references without deleting files")
    @MainActor
    func resolvesDuplicateRegistrations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let keep = Track(
            id: UUID(), title: "Song", artist: "Artist", album: "Album",
            duration: 120, fileSize: 10, managedPath: root.appendingPathComponent("keep.wav").path,
            sha256: "identical", addedAt: .distantPast, health: .verified
        )
        let remove = Track(
            id: UUID(), title: "Song Copy", artist: "Artist", album: "Album",
            duration: 120, fileSize: 10, managedPath: root.appendingPathComponent("remove.wav").path,
            sha256: "identical", addedAt: .now, health: .verified
        )
        let playlist = Playlist(
            name: "Both",
            entries: [PlaylistEntry(trackID: remove.id), PlaylistEntry(trackID: keep.id)]
        )
        let event = PlaybackEvent(trackID: remove.id, kind: .completed)
        let queue = PlaybackQueueState(
            trackIDs: [remove.id, keep.id],
            currentTrackID: remove.id,
            position: 42
        )
        let repository = LibraryRepository(rootURL: root)
        try await repository.save(document: LibraryDocument(
            tracks: [keep, remove],
            playlists: [playlist],
            playbackEvents: [event],
            playbackQueue: queue
        ))
        let store = LibraryStore(repository: repository)
        await store.load()
        let group = try #require(store.duplicateGroups.first)

        let result = try await store.resolveDuplicateGroup(
            group.id,
            keeping: keep.id,
            moveManagedFilesToTrash: false
        )

        #expect(result.removedCount == 1)
        #expect(result.trashedFileCount == 0)
        #expect(store.tracks.map(\.id) == [keep.id])
        #expect(store.playlists[0].entries.map(\.trackID) == [keep.id])
        #expect(store.playbackEvents.map(\.trackID) == [keep.id])
        #expect(store.playbackQueue?.trackIDs == [keep.id])
        #expect(store.playbackQueue?.currentTrackID == keep.id)

        let restored = try await LibraryRepository(rootURL: root).load().document
        #expect(restored.tracks.map(\.id) == [keep.id])
        #expect(restored.playlists[0].entries.map(\.trackID) == [keep.id])
        #expect(restored.playbackEvents.map(\.trackID) == [keep.id])
    }

    @Test("Playlist create, edit, artwork, duplicate, delete, and restart are transactional")
    @MainActor
    func managesPlaylists() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        let store = LibraryStore(repository: repository)
        await store.load()

        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 4, height: 4)).fill()
        image.unlockFocus()
        let artworkData = try #require(image.tiffRepresentation)

        let originalID = try await store.createPlaylist(
            name: "Road Trip",
            description: "Long drives",
            artworkData: artworkData
        )
        let original = try #require(store.playlists.first { $0.id == originalID })
        let originalArtworkPath = try #require(original.artworkPath)
        #expect(FileManager.default.fileExists(atPath: originalArtworkPath))
        #expect(store.selectedPlaylistID == originalID)

        let duplicatedID = try await store.duplicatePlaylist(originalID)
        let duplicateID = try #require(duplicatedID)
        let duplicate = try #require(store.playlists.first { $0.id == duplicateID })
        let duplicateArtworkPath = try #require(duplicate.artworkPath)
        #expect(duplicate.name == L10n.format("playlist.copyName", original.name))
        #expect(duplicateArtworkPath != originalArtworkPath)
        #expect(FileManager.default.fileExists(atPath: duplicateArtworkPath))

        try await store.updatePlaylist(
            id: originalID,
            name: "Highway",
            description: "Night driving",
            artworkData: nil,
            removesArtwork: true
        )
        let updated = try #require(store.playlists.first { $0.id == originalID })
        #expect(updated.name == "Highway")
        #expect(updated.description == "Night driving")
        #expect(updated.artworkPath == nil)
        #expect(!FileManager.default.fileExists(atPath: originalArtworkPath))

        try await store.deletePlaylist(duplicateID)
        #expect(!FileManager.default.fileExists(atPath: duplicateArtworkPath))
        #expect(store.playlists.map(\.id) == [originalID])

        let restored = try await LibraryRepository(rootURL: root).load().document
        #expect(restored.playlists.map(\.id) == [originalID])
        #expect(restored.playlists[0].name == "Highway")

        try await store.deletePlaylist(originalID)
        #expect(store.playlists.isEmpty)
        #expect(store.selectedPlaylistID == nil)
    }

    @Test("Playlist membership preserves order, ignores duplicates, removes, and persists")
    @MainActor
    func managesPlaylistMembership() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        let first = Track(
            id: UUID(), title: "First", artist: "Artist", album: "Album",
            duration: 10, fileSize: 1, managedPath: root.appendingPathComponent("1.wav").path,
            sha256: "1", addedAt: .now, lastVerifiedAt: .now, health: .verified
        )
        let second = Track(
            id: UUID(), title: "Second", artist: "Artist", album: "Album",
            duration: 20, fileSize: 1, managedPath: root.appendingPathComponent("2.wav").path,
            sha256: "2", addedAt: .now, lastVerifiedAt: .now, health: .verified
        )
        try await repository.save(tracks: [first, second])
        let store = LibraryStore(repository: repository)
        await store.load()
        let playlistID = try await store.createPlaylist(
            name: "Selection", description: "", artworkData: nil
        )

        let added = try await store.addTracks(
            [second.id, first.id, second.id], to: playlistID
        )
        #expect(added == 2)
        #expect(store.selectedPlaylist?.entries.map(\.trackID) == [second.id, first.id])
        #expect(store.playlistsContaining(trackIDs: [first.id]).map(\.id) == [playlistID])

        let duplicateCount = try await store.addTracks([first.id], to: playlistID)
        #expect(duplicateCount == 0)
        #expect(store.selectedPlaylist?.entries.count == 2)

        let removed = try await store.removeTracks([second.id], from: playlistID)
        #expect(removed == 1)
        #expect(store.selectedPlaylist?.entries.map(\.trackID) == [first.id])

        let restored = try await LibraryRepository(rootURL: root).load().document
        #expect(restored.playlists.first?.entries.map(\.trackID) == [first.id])
    }

    @Test("Playlist order can be changed and restored with Undo and Redo")
    @MainActor
    func reordersPlaylistWithUndo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        let tracks = (1...3).map { index in
            Track(
                id: UUID(), title: "Track \(index)", artist: "Artist", album: "Album",
                duration: 10, fileSize: 1,
                managedPath: root.appendingPathComponent("\(index).wav").path,
                sha256: "\(index)", addedAt: .now, lastVerifiedAt: .now,
                health: .verified
            )
        }
        try await repository.save(tracks: tracks)
        let store = LibraryStore(repository: repository)
        await store.load()
        let playlistID = try await store.createPlaylist(
            name: "Ordered", description: "", artworkData: nil
        )
        _ = try await store.addTracks(tracks.map(\.id), to: playlistID)

        let undoManager = UndoManager()
        store.undoManager = undoManager
        let moved = try await store.moveTracks(
            [tracks[2].id], before: tracks[0].id, in: playlistID
        )
        #expect(moved)
        #expect(store.selectedPlaylist?.entries.map(\.trackID) == [
            tracks[2].id, tracks[0].id, tracks[1].id
        ])

        undoManager.undo()
        try await waitUntil {
            store.selectedPlaylist?.entries.map(\.trackID) == tracks.map(\.id)
        }
        #expect(undoManager.canRedo)

        undoManager.redo()
        try await waitUntil {
            store.selectedPlaylist?.entries.map(\.trackID) == [
                tracks[2].id, tracks[0].id, tracks[1].id
            ]
        }
        let restored = try await LibraryRepository(rootURL: root).load().document
        #expect(restored.playlists.first?.entries.map(\.trackID) == [
            tracks[2].id, tracks[0].id, tracks[1].id
        ])
    }

    @Test("Playlist folders preserve membership and sidebar order")
    @MainActor
    func managesPlaylistFolders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(repository: LibraryRepository(rootURL: root))
        await store.load()
        let first = try await store.createPlaylist(name: "First", description: "", artworkData: nil)
        let second = try await store.createPlaylist(name: "Second", description: "", artworkData: nil)
        let third = try await store.createPlaylist(name: "Third", description: "", artworkData: nil)
        let favorites = try await store.createPlaylistFolder(name: "Favorites")
        let seasons = try await store.createPlaylistFolder(name: "Seasons")

        try await store.movePlaylist(first, to: favorites)
        try await store.movePlaylist(second, to: favorites, before: first)
        try await store.movePlaylist(third, to: seasons)
        #expect(store.playlists(in: favorites).map(\.id) == [second, first])

        try await store.movePlaylistFolder(seasons, before: favorites)
        #expect(store.sortedPlaylistFolders.map(\.id) == [seasons, favorites])

        let undoManager = UndoManager()
        store.undoManager = undoManager
        try await store.deletePlaylistFolder(favorites)
        #expect(store.playlistFolders.map(\.id) == [seasons])
        #expect(Set(store.playlists(in: nil).map(\.id)) == [first, second])

        undoManager.undo()
        try await waitUntil {
            store.playlistFolders.contains(where: { $0.id == favorites })
        }
        #expect(store.playlists(in: favorites).map(\.id) == [second, first])

        let restored = try await LibraryRepository(rootURL: root).load().document
        #expect(restored.playlistFolders.sorted { $0.sortOrder < $1.sortOrder }.map(\.id) == [
            seasons, favorites
        ])
        #expect(restored.playlists.filter { $0.folderID == favorites }
            .sorted { $0.sortOrder < $1.sortOrder }.map(\.id) == [second, first])
    }

    @MainActor
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for the asynchronous playlist operation")
    }

    @Test("Manifest round-trips atomically")
    func manifestRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = LibraryRepository(rootURL: root)
        var track = Track(
            id: UUID(),
            title: "Test",
            artist: "Artist",
            album: "Album",
            duration: 42,
            fileSize: 3,
            managedPath: root.appendingPathComponent("test.wav").path,
            sha256: "abc",
            addedAt: .now,
            lastVerifiedAt: .now,
            health: .verified
        )
        track.isPinned = true
        track.isFavorite = true
        track.rating = 4
        track.isExcludedFromPlayback = true

        try await repository.save(tracks: [track])
        let loaded = try await repository.load()
        #expect(loaded.document.tracks.count == 1)
        #expect(loaded.document.tracks[0].id == track.id)
        #expect(loaded.document.tracks[0].title == track.title)
        #expect(loaded.document.tracks[0].sha256 == track.sha256)
        #expect(loaded.document.tracks[0].health == .verified)
        #expect(loaded.document.tracks[0].isPinned)
        #expect(loaded.document.tracks[0].isFavorite)
        #expect(loaded.document.tracks[0].rating == 4)
        #expect(loaded.document.tracks[0].isExcludedFromPlayback)
        try? FileManager.default.removeItem(at: root)
    }

    @Test("Schema 1 migrates once with stable library, artist, and album IDs")
    func migratesSchemaOneCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(contentsOf: fixtureURL("library-schema-1.json"))
            .write(to: root.appendingPathComponent("library-v1.json"))

        let repository = LibraryRepository(rootURL: root)
        let migrated = try await repository.load()

        #expect(migrated.migratedFromSchemaVersion == 1)
        #expect(migrated.document.schemaVersion == LibraryDocument.currentSchema)
        #expect(migrated.document.tracks.count == 3)
        #expect(migrated.document.createdAt == migrated.document.tracks[0].addedAt)
        #expect(migrated.document.tracks[0].artistID == migrated.document.tracks[1].artistID)
        #expect(migrated.document.tracks[1].artistID == migrated.document.tracks[2].artistID)
        #expect(migrated.document.tracks[0].albumID == migrated.document.tracks[1].albumID)
        #expect(migrated.document.tracks[1].albumID != migrated.document.tracks[2].albumID)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("library-schema-1.migration-backup.json").path
        ))

        let firstLibraryID = migrated.document.libraryID
        let firstArtistID = migrated.document.tracks[0].artistID
        let firstAlbumID = migrated.document.tracks[0].albumID
        let reloaded = try await repository.load()
        #expect(reloaded.migratedFromSchemaVersion == nil)
        #expect(reloaded.document.libraryID == firstLibraryID)
        #expect(reloaded.document.tracks[0].artistID == firstArtistID)
        #expect(reloaded.document.tracks[0].albumID == firstAlbumID)

        try Data(contentsOf: fixtureURL("library-corrupt.json")).write(
            to: root.appendingPathComponent("library-v1.json"),
            options: .atomic
        )
        let savedAgain = try await LibraryRepository(rootURL: root).load()
        #expect(savedAgain.recoveredFromBackup)
        #expect(savedAgain.document.libraryID == firstLibraryID)
        #expect(savedAgain.document.tracks[0].artistID == firstArtistID)
        #expect(savedAgain.document.tracks[0].albumID == firstAlbumID)
    }

    @Test("An unversioned track-array fixture migrates to the current schema")
    func migratesUnversionedCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(contentsOf: fixtureURL("library-unversioned.json"))
            .write(to: root.appendingPathComponent("library-v1.json"))

        let loaded = try await LibraryRepository(rootURL: root).load()
        #expect(loaded.migratedFromSchemaVersion == 0)
        #expect(loaded.document.schemaVersion == LibraryDocument.currentSchema)
        #expect(loaded.document.tracks.map(\.title) == ["Early Track"])
    }

    @Test("Schema 2 preserves stable identities while adding playlists and playback events")
    func migratesSchemaTwoCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(contentsOf: fixtureURL("library-schema-2.json"))
            .write(to: root.appendingPathComponent("library-v1.json"))

        let loaded = try await LibraryRepository(rootURL: root).load()

        #expect(loaded.migratedFromSchemaVersion == 2)
        #expect(loaded.document.schemaVersion == LibraryDocument.currentSchema)
        #expect(loaded.document.libraryID.uuidString == "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        #expect(loaded.document.tracks[0].artistID.uuidString == "11111111-1111-1111-1111-111111111111")
        #expect(loaded.document.tracks[0].albumID.uuidString == "22222222-2222-2222-2222-222222222222")
        #expect(loaded.document.playlists.isEmpty)
        #expect(loaded.document.playbackEvents.isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("library-schema-2.migration-backup.json").path
        ))
    }

    @Test("Playlist entries and playback events survive track-only saves and restart")
    func persistsPlaylistAndPlaybackModels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        let track = Track(
            id: UUID(), title: "History", artist: "Artist", album: "Album", duration: 30,
            fileSize: 100, managedPath: "/tmp/history.m4a", sha256: "history",
            addedAt: .now, lastVerifiedAt: nil, health: .unchecked
        )
        try await repository.save(tracks: [track])

        let entry = PlaylistEntry(trackID: track.id)
        let playlist = Playlist(name: "Road Trip", entries: [entry])
        let sessionID = UUID()
        let event = PlaybackEvent(
            trackID: track.id,
            kind: .completed,
            position: track.duration,
            playbackSessionID: sessionID
        )
        try await repository.save(playlists: [playlist])
        try await repository.recordPlaybackEvent(event)

        var renamed = track
        renamed.title = "History Edited"
        try await repository.save(tracks: [renamed])

        let reloaded = try await LibraryRepository(rootURL: root).load().document
        #expect(reloaded.playlists.map(\.id) == [playlist.id])
        #expect(reloaded.playlists[0].entries.map(\.id) == [entry.id])
        #expect(reloaded.playlists[0].entries.map(\.trackID) == [track.id])
        #expect(reloaded.playbackEvents.map(\.id) == [event.id])
        #expect(reloaded.playbackEvents[0].trackID == track.id)
        #expect(reloaded.playbackEvents[0].kind == .completed)
        #expect(reloaded.playbackEvents[0].playbackSessionID == sessionID)
        #expect(reloaded.tracks[0].title == "History Edited")
    }

    @Test("Schema 3 migrates to a queue-capable catalog without inventing queue state")
    func migratesSchemaThreeCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = """
        {
          "schemaVersion": 3,
          "updatedAt": "2026-08-17T00:00:00Z",
          "tracks": [],
          "libraryID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
          "createdAt": "2026-08-16T00:00:00Z",
          "playlists": [],
          "playbackEvents": []
        }
        """
        try Data(manifest.utf8).write(to: root.appendingPathComponent("library-v1.json"))

        let loaded = try await LibraryRepository(rootURL: root).load()
        #expect(loaded.migratedFromSchemaVersion == 3)
        #expect(loaded.document.schemaVersion == LibraryDocument.currentSchema)
        #expect(loaded.document.playbackQueue == nil)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("library-schema-3.migration-backup.json").path
        ))
    }

    @Test("Schema 4 migrates playback attributes with safe defaults and preserves the queue")
    func migratesSchemaFourCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = """
        {
          "schemaVersion": 4,
          "updatedAt": "2026-08-18T00:00:00Z",
          "tracks": [],
          "libraryID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
          "createdAt": "2026-08-16T00:00:00Z",
          "playlists": [],
          "playbackEvents": [],
          "playbackQueue": { "trackIDs": [], "position": 12.5 }
        }
        """
        try Data(manifest.utf8).write(to: root.appendingPathComponent("library-v1.json"))

        let loaded = try await LibraryRepository(rootURL: root).load()
        #expect(loaded.migratedFromSchemaVersion == 4)
        #expect(loaded.document.schemaVersion == LibraryDocument.currentSchema)
        #expect(loaded.document.playbackQueue?.position == 12.5)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("library-schema-4.migration-backup.json").path
        ))
    }

    @Test("Schema 5 preserves playlist order while adding folders")
    func migratesSchemaFivePlaylistOrganization() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let firstID = UUID()
        let secondID = UUID()
        let libraryID = UUID()
        let json = """
        {
          "schemaVersion": 5,
          "updatedAt": "2026-08-19T00:00:00Z",
          "tracks": [],
          "libraryID": "\(libraryID.uuidString)",
          "createdAt": "2026-08-19T00:00:00Z",
          "playlists": [
            {"id":"\(firstID.uuidString)","name":"First","description":"","entries":[],"createdAt":"2026-08-19T00:00:00Z","updatedAt":"2026-08-19T00:00:00Z"},
            {"id":"\(secondID.uuidString)","name":"Second","description":"","entries":[],"createdAt":"2026-08-19T00:00:00Z","updatedAt":"2026-08-19T00:00:00Z"}
          ],
          "playbackEvents": []
        }
        """
        try Data(json.utf8).write(to: root.appendingPathComponent("library-v1.json"))

        let loaded = try await LibraryRepository(rootURL: root).load()
        #expect(loaded.migratedFromSchemaVersion == 5)
        #expect(loaded.document.schemaVersion == LibraryDocument.currentSchema)
        #expect(loaded.document.playlistFolders.isEmpty)
        #expect(loaded.document.playlists.map(\.id) == [firstID, secondID])
        #expect(loaded.document.playlists.map(\.sortOrder) == [0, 1])
    }

    @Test("Playback queue order, current track, and position survive restart")
    func persistsPlaybackQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Track(
            id: UUID(), title: "First", artist: "Artist", album: "Album", duration: 60,
            fileSize: 1, managedPath: "/tmp/first.m4a", sha256: "first",
            addedAt: .now, lastVerifiedAt: nil, health: .unchecked
        )
        let second = Track(
            id: UUID(), title: "Second", artist: "Artist", album: "Album", duration: 90,
            fileSize: 1, managedPath: "/tmp/second.m4a", sha256: "second",
            addedAt: .now, lastVerifiedAt: nil, health: .unchecked,
            artistID: first.artistID, albumID: first.albumID
        )
        let repository = LibraryRepository(rootURL: root)
        try await repository.save(tracks: [first, second])
        let state = PlaybackQueueState(
            trackIDs: [second.id, first.id],
            currentTrackID: second.id,
            position: 37.5
        )
        try await repository.save(playbackQueue: state)

        var renamed = first
        renamed.title = "First Edited"
        try await repository.save(tracks: [renamed, second])

        let reloaded = try await LibraryRepository(rootURL: root).load().document
        #expect(reloaded.playbackQueue == state)
        #expect(reloaded.tracks[0].title == "First Edited")
    }

    @Test("Queue positions and playback events do not rewrite the track catalog")
    func playbackSidecarsAvoidCatalogRewrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let track = Track(
            id: UUID(), title: "Sidecar", artist: "Artist", album: "Album", duration: 120,
            fileSize: 1, managedPath: "/tmp/sidecar.m4a", sha256: "sidecar",
            addedAt: .now, lastVerifiedAt: nil, health: .unchecked
        )
        let repository = LibraryRepository(rootURL: root)
        try await repository.save(tracks: [track])
        let manifestURL = root.appendingPathComponent("library-v1.json")
        let catalogBeforePlayback = try Data(contentsOf: manifestURL)

        let queue = PlaybackQueueState(
            trackIDs: [track.id],
            currentTrackID: track.id,
            position: 42.5
        )
        let event = PlaybackEvent(trackID: track.id, kind: .completed)
        try await repository.save(playbackQueue: queue)
        try await repository.recordPlaybackEvent(event)

        #expect(try Data(contentsOf: manifestURL) == catalogBeforePlayback)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("playback-queue-v1.json").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("playback-events-v1.json").path
        ))
        let reloaded = try await LibraryRepository(rootURL: root).load().document
        #expect(reloaded.playbackQueue == queue)
        #expect(reloaded.playbackEvents.map(\.id) == [event.id])
        #expect(reloaded.playbackEvents.map(\.kind) == [event.kind])
    }

    @Test("A playback sidecar is ignored when it belongs to another library")
    func playbackSidecarsRespectLibraryIdentity() async throws {
        let firstRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ongaku-Sidecar-First-\(UUID().uuidString)")
        let secondRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ongaku-Sidecar-Second-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }
        let firstTrack = Track(
            id: UUID(), title: "First", artist: "Artist", album: "Album", duration: 60,
            fileSize: 1, managedPath: "/tmp/first-sidecar.m4a", sha256: "first-sidecar",
            addedAt: .now, health: .unchecked
        )
        let secondTrack = Track(
            id: UUID(), title: "Second", artist: "Artist", album: "Album", duration: 60,
            fileSize: 1, managedPath: "/tmp/second-sidecar.m4a", sha256: "second-sidecar",
            addedAt: .now, health: .unchecked
        )
        let firstRepository = LibraryRepository(rootURL: firstRoot)
        let secondRepository = LibraryRepository(rootURL: secondRoot)
        try await firstRepository.save(tracks: [firstTrack])
        try await secondRepository.save(tracks: [secondTrack])
        try await firstRepository.save(playbackQueue: PlaybackQueueState(
            trackIDs: [firstTrack.id], currentTrackID: firstTrack.id, position: 30
        ))

        try FileManager.default.copyItem(
            at: firstRoot.appendingPathComponent("playback-queue-v1.json"),
            to: secondRoot.appendingPathComponent("foreign-playback-queue.json")
        )
        try FileManager.default.removeItem(
            at: secondRoot.appendingPathComponent("playback-queue-v1.json")
        )
        try FileManager.default.moveItem(
            at: secondRoot.appendingPathComponent("foreign-playback-queue.json"),
            to: secondRoot.appendingPathComponent("playback-queue-v1.json")
        )

        let firstLibraryID = try await firstRepository.load().document.libraryID
        let reloaded = try await LibraryRepository(rootURL: secondRoot).load().document
        #expect(reloaded.libraryID != firstLibraryID)
        #expect(reloaded.playbackQueue == nil)
    }

    @Test("A corrupt playback queue sidecar recovers its previous valid state")
    func playbackQueueSidecarRecoversBackup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let track = Track(
            id: UUID(), title: "Recovery", artist: "Artist", album: "Album", duration: 60,
            fileSize: 1, managedPath: "/tmp/recovery.m4a", sha256: "recovery",
            addedAt: .now, health: .unchecked
        )
        let repository = LibraryRepository(rootURL: root)
        try await repository.save(tracks: [track])
        let previous = PlaybackQueueState(
            trackIDs: [track.id], currentTrackID: track.id, position: 12
        )
        try await repository.save(playbackQueue: previous)
        try await repository.save(playbackQueue: PlaybackQueueState(
            trackIDs: [track.id], currentTrackID: track.id, position: 48
        ))
        try Data("corrupt".utf8).write(
            to: root.appendingPathComponent("playback-queue-v1.json"),
            options: .atomic
        )

        let recovered = try await LibraryRepository(rootURL: root).load().document
        #expect(recovered.playbackQueue == previous)
    }

    @Test("A future schema is never replaced with an older backup")
    func rejectsFutureSchemaWithoutDowngrade() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        try await repository.save(tracks: [])
        try await repository.save(tracks: [])
        try Data("{\"schemaVersion\":999,\"tracks\":[]}".utf8)
            .write(to: root.appendingPathComponent("library-v1.json"), options: .atomic)

        do {
            _ = try await LibraryRepository(rootURL: root).load()
            Issue.record("A catalog from a future schema was accepted")
        } catch LibraryRepository.RepositoryError.unsupportedSchema(let version) {
            #expect(version == 999)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Clearing registrations leaves every audio file untouched")
    func clearsRegistrationsWithoutTouchingAudioFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let catalog = root.appendingPathComponent("Catalog", isDirectory: true)
        let audioDirectory = root.appendingPathComponent("Media/Artist/Album", isDirectory: true)
        let audioFile = audioDirectory.appendingPathComponent("Track.m4a")
        try FileManager.default.createDirectory(
            at: audioDirectory, withIntermediateDirectories: true)
        let originalAudio = Data([0, 0, 0, 20, 21, 22, 23, 24])
        try originalAudio.write(to: audioFile)

        let track = Track(
            id: UUID(),
            title: "Track",
            artist: "Artist",
            album: "Album",
            duration: 12,
            fileSize: Int64(originalAudio.count),
            managedPath: audioFile.path,
            sha256: try LibraryRepository.sha256(of: audioFile),
            addedAt: .now,
            lastVerifiedAt: .now,
            health: .verified
        )
        let repository = LibraryRepository(
            rootURL: catalog,
            mediaURL: root.appendingPathComponent("Media")
        )
        try await repository.save(tracks: [track])
        let playlist = Playlist(
            name: "Temporary references",
            entries: [PlaylistEntry(trackID: track.id)]
        )
        let playbackEvent = PlaybackEvent(trackID: track.id, kind: .started)
        try await repository.save(playlists: [playlist])
        try await repository.recordPlaybackEvent(playbackEvent)

        try await repository.clearAllRegistrations()

        let cleared = try await repository.load()
        #expect(cleared.document.tracks.isEmpty)
        #expect(cleared.document.playlists.map(\.id) == [playlist.id])
        #expect(cleared.document.playlists[0].entries.isEmpty)
        #expect(cleared.document.playbackEvents.isEmpty)
        #expect(cleared.document.playbackQueue == PlaybackQueueState())
        #expect(FileManager.default.fileExists(atPath: audioFile.path))
        #expect(try Data(contentsOf: audioFile) == originalAudio)

        // Backup recovery must preserve the intentionally empty catalog too.
        try Data(contentsOf: fixtureURL("library-corrupt.json")).write(
            to: catalog.appendingPathComponent("library-v1.json")
        )
        let recovered = try await repository.load()
        #expect(recovered.recoveredFromBackup)
        #expect(recovered.document.tracks.isEmpty)
        #expect(recovered.document.playlists[0].entries.isEmpty)
        #expect(recovered.document.playbackEvents.isEmpty)
        #expect(recovered.document.playbackQueue == PlaybackQueueState())
        #expect(FileManager.default.fileExists(atPath: audioFile.path))
        #expect(try Data(contentsOf: audioFile) == originalAudio)

        // Recovery rewrites the primary without replacing the known-good backup.
        let healthyReload = try await repository.load()
        #expect(!healthyReload.recoveredFromBackup)
        #expect(healthyReload.document.tracks.isEmpty)
        try? FileManager.default.removeItem(at: root)
    }

    @Test("Verification detects changed content")
    func detectsChangedContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("sample.bin")
        try Data([1, 2, 3]).write(to: file)
        let hash = try LibraryRepository.sha256(of: file)
        var track = Track(
            id: UUID(), title: "Sample", artist: "A", album: "B", duration: 0,
            fileSize: 3, managedPath: file.path, sha256: hash, addedAt: .now,
            lastVerifiedAt: nil, health: .unchecked
        )
        let repository = LibraryRepository(rootURL: root.appendingPathComponent("Library"))
        let first = await repository.verify([track])
        #expect(first[0].health == .verified)

        try Data([9, 9, 9]).write(to: file)
        track.health = .unchecked
        let second = await repository.verify([track])
        #expect(second[0].health == .changed)
        try? FileManager.default.removeItem(at: root)
    }

    @Test("Missing files are automatically and manually relinked only by checksum")
    func safelyRelinksMissingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let searchRoot = root.appendingPathComponent("Search", isDirectory: true)
        let nested = searchRoot.appendingPathComponent("Artist/Album", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let recovered = nested.appendingPathComponent("Recovered.mp3")
        let originalData = Data([0x49, 0x44, 0x33, 1, 2, 3, 4, 5])
        try originalData.write(to: recovered)
        let hash = try LibraryRepository.sha256(of: recovered)
        let track = Track(
            id: UUID(), title: "Missing", artist: "Artist", album: "Album", duration: 1,
            fileSize: Int64(originalData.count),
            managedPath: root.appendingPathComponent("Old/Missing.mp3").path,
            sha256: hash, addedAt: .now, lastVerifiedAt: .now, health: .missing
        )
        let repository = LibraryRepository(rootURL: root.appendingPathComponent("Catalog"))

        let automatic = await repository.relinkMissingFiles(
            in: [track],
            searching: [searchRoot]
        )
        #expect(automatic.relinkedTrackCount == 1)
        #expect(automatic.scannedFileCount == 1)
        #expect(automatic.tracks[0].managedPath == recovered.standardizedFileURL.path)
        #expect(automatic.tracks[0].health == .verified)

        let wrong = root.appendingPathComponent("Wrong.mp3")
        try Data(repeating: 0xFF, count: originalData.count).write(to: wrong)
        do {
            _ = try await repository.relink(track, to: wrong)
            Issue.record("A mismatching checksum must not be relinked")
        } catch LibraryRepository.RepositoryError.relinkFingerprintMismatch {
            // Expected: the catalog path remains unchanged.
        }
        let manual = try await repository.relink(track, to: recovered)
        #expect(manual.managedPath == recovered.standardizedFileURL.path)
        #expect(manual.health == .verified)
    }

    @Test("Import copies data and rejects duplicate content")
    func importAndDeduplicate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("Artist - Track.mp3")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0x49, 0x44, 0x33, 1, 2, 3, 4]).write(to: source)
        let repository = LibraryRepository(rootURL: root.appendingPathComponent("Managed"))

        let first = await repository.importFiles([source], existing: [])
        #expect(first.imported.count == 1)
        #expect(first.issues.isEmpty)
        #expect(FileManager.default.fileExists(atPath: first.imported[0].managedPath))
        #expect(first.imported[0].sha256 == (try LibraryRepository.sha256(of: source)))

        let duplicate = await repository.importFiles([source], existing: first.imported)
        #expect(duplicate.imported.isEmpty)
        #expect(duplicate.issues.count == 1)
        try? FileManager.default.removeItem(at: root)
    }

    @Test("CD import metadata organizes verified copies by artist and album")
    func importsCDMetadataOverrides() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disc = root.appendingPathComponent("Audio CD")
        let source = disc.appendingPathComponent("1 Audio Track.aiff")
        try FileManager.default.createDirectory(at: disc, withIntermediateDirectories: true)
        try Data([0x46, 0x4F, 0x52, 0x4D, 1, 2, 3, 4]).write(to: source)
        let media = root.appendingPathComponent("Media")
        let repository = LibraryRepository(
            rootURL: root.appendingPathComponent("Catalog"),
            mediaURL: media
        )
        let request = AudioCDImportRequest(
            sourceURL: source,
            title: "Opening",
            artist: "Disc Artist",
            album: "Disc Album",
            albumArtist: "Album Artist",
            releaseYear: 2026,
            isrc: "JPAAA2600001",
            trackNumber: 1,
            trackCount: 12,
            discNumber: 1,
            discCount: 2,
            musicBrainzReference: MusicBrainzReference(
                recordingID: "recording-id",
                releaseID: "release-id",
                releaseGroupID: "release-group-id",
                artistIDs: ["artist-id"],
                isrc: "JPAAA2600001",
                country: "JP",
                mediaFormat: "CD",
                coverArtID: nil,
                coverArtTypes: [],
                fetchedAt: .now
            )
        )

        let result = await repository.importFiles(
            [source],
            existing: [],
            metadataOverrides: [source.standardizedFileURL.path: request]
        )
        let track = try #require(result.imported.first)

        #expect(result.issues.isEmpty)
        #expect(track.title == "Opening")
        #expect(track.artist == "Disc Artist")
        #expect(track.album == "Disc Album")
        #expect(track.trackNumber == 1)
        #expect(track.trackCount == 12)
        #expect(track.albumArtist == "Album Artist")
        #expect(track.releaseYear == 2026)
        #expect(track.isrc == "JPAAA2600001")
        #expect(track.discNumber == 1)
        #expect(track.discCount == 2)
        #expect(track.musicBrainzReference?.releaseID == "release-id")
        #expect(track.managedPath.hasPrefix(
            media.appendingPathComponent("Disc Artist/Disc Album").path + "/"
        ))
        #expect(try LibraryRepository.sha256(of: track.fileURL) == LibraryRepository.sha256(of: source))
    }

    @Test("MusicBrainz Disc ID and lookup URLs follow the CD TOC specification")
    func musicBrainzDiscID() {
        let toc = MusicBrainzDiscTOC(
            firstTrack: 1,
            lastTrack: 3,
            leadoutOffset: 45_000,
            trackOffsets: [150, 15_000, 30_000]
        )

        #expect(toc.discID == "ohhlX44vA82K1SAvWfO52oJ_ZxQ-")
        #expect(toc.queryValue == "1 3 45000 150 15000 30000")
        #expect(MusicBrainzService.discLookupURL(for: toc).path.hasSuffix("/discid/\(toc.discID)"))
        #expect(
            URLComponents(
                url: MusicBrainzService.tocLookupURL(for: toc),
                resolvingAgainstBaseURL: false
            )?.queryItems?.first(where: { $0.name == "toc" })?.value == toc.queryValue
        )
    }

    @Test("Secure CD reads require two consecutive matching checksums")
    func secureCDReadVerification() throws {
        var stableSequence = ["first", "second", "second"]
        let stable = try AudioCDRipper.verifiedSourceHash(
            URL(fileURLWithPath: "/tmp/test-track.aiff")
        ) { _ in stableSequence.removeFirst() }
        #expect(stable == "second")

        var unstableSequence = ["first", "second", "third"]
        #expect(throws: AudioCDRipError.unstableRead) {
            try AudioCDRipper.verifiedSourceHash(
                URL(fileURLWithPath: "/tmp/test-track.aiff")
            ) { _ in unstableSequence.removeFirst() }
        }
    }

    @Test("CD ripper creates verified AIFF, WAV, ALAC, and AAC files")
    func convertsCDImportFormats() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.aiff")
        let format = AVAudioFormat(
            standardFormatWithSampleRate: 44_100,
            channels: 2
        )!
        do {
            let sourceFile = try AVAudioFile(
                forWriting: source,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: true,
                ]
            )
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410)!
            buffer.frameLength = 4_410
            for channel in 0..<2 {
                let samples = buffer.floatChannelData![channel]
                for frame in 0..<4_410 {
                    samples[frame] = Float(
                        sin(2 * Double.pi * 440 * Double(frame) / 44_100) * 0.2
                    )
                }
            }
            try sourceFile.write(from: buffer)
        }

        for outputFormat in AudioCDImportFormat.allCases {
            let output = root.appendingPathComponent("output-\(outputFormat.rawValue)")
                .appendingPathExtension(outputFormat.pathExtension)
            try AudioCDRipper.rip(
                sourceURL: source,
                destinationURL: output,
                format: outputFormat,
                aacQuality: .high
            )
            let decoded = try AVAudioFile(forReading: output)
            let outputHash = try LibraryRepository.sha256(of: output)
            #expect(decoded.length > 0)
            #expect(!outputHash.isEmpty)
        }
    }

    @Test("An installed file is recovered when import was interrupted before catalog save")
    func recoversInterruptedImport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("Artist - Recovered.mp3")
        let managedRoot = root.appendingPathComponent("Managed")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0x49, 0x44, 0x33, 9, 8, 7, 6]).write(to: source)

        let importingRepository = LibraryRepository(rootURL: managedRoot)
        let imported = await importingRepository.importFiles([source], existing: [])
        #expect(imported.imported.count == 1)
        #expect(imported.issues.isEmpty)

        // Simulate termination after the managed file was installed but before Store.save().
        let restartedRepository = LibraryRepository(rootURL: managedRoot)
        let recovered = try await restartedRepository.load()
        #expect(recovered.recoveredImportCount == 1)
        #expect(recovered.unresolvedImportCount == 0)
        #expect(recovered.document.tracks.count == 1)
        #expect(recovered.document.tracks[0].sha256 == imported.imported[0].sha256)
        #expect(FileManager.default.fileExists(atPath: recovered.document.tracks[0].managedPath))

        let secondLoad = try await restartedRepository.load()
        #expect(secondLoad.recoveredImportCount == 0)
        #expect(secondLoad.document.tracks.count == 1)
        try? FileManager.default.removeItem(at: root)
    }

#if DEBUG
    @Test("Import journal recovers at each installation boundary", arguments: [0, 1, 2], [false, true])
    func importWriteRecoveryBoundaries(step: Int, diskFull: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.mp3")
        let bytes = Data([0x49, 0x44, 0x33, 2, 3, 4])
        try bytes.write(to: source)
        let catalog = root.appendingPathComponent("Catalog")
        let repository = LibraryRepository(rootURL: catalog)
        _ = try await repository.load()
        await repository.setImportWriteTestHook { stage in
            let match: Bool
            switch stage {
            case .copying: match = step == 0
            case .installing: match = step == 1
            case .installed: match = step == 2
            }
            if match {
                if diskFull { throw POSIXError(.ENOSPC) }
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let result = await repository.importFiles([source], existing: [])
        #expect(result.imported.isEmpty)
        #expect(result.issues.count == 1)
        #expect(try Data(contentsOf: source) == bytes)
        let recovered = try await LibraryRepository(rootURL: catalog).load()
        if step == 0 {
            #expect(recovered.document.tracks.isEmpty)
        } else {
            #expect(recovered.document.tracks.count == 1)
            let track = try #require(recovered.document.tracks.first)
            #expect(try Data(contentsOf: track.fileURL) == bytes)
        }
        #expect(!FileManager.default.fileExists(atPath: catalog.appendingPathComponent("import-journal-v1.json").path))
        let again = try await LibraryRepository(rootURL: catalog).load().document
        #expect(again.tracks.count == (step == 0 ? 0 : 1))
        #expect(try Data(contentsOf: source) == bytes)
    }
#endif

#if DEBUG
    @Test("External reference copying recovers new and existing tracks at each boundary", arguments: [false, true], [0, 1, 2])
    func referenceCopyRecoveryBoundaries(existing: Bool, step: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.mp3")
        let bytes = Data([0x49, 0x44, 0x33, 5, 6, 7])
        try bytes.write(to: source)
        let catalog = root.appendingPathComponent("Catalog")
        let media = root.appendingPathComponent("Media")
        let repository = LibraryRepository(rootURL: catalog, mediaURL: media)
        let original = Track(id: UUID(), title: "Existing", artist: "A", album: "B", duration: 1,
                             fileSize: Int64(bytes.count), managedPath: source.path,
                             sha256: try LibraryRepository.sha256(of: source), addedAt: .now, health: .verified)
        try await repository.save(tracks: existing ? [original] : [])
        await repository.setImportWriteTestHook { stage in
            let match: Bool
            switch stage {
            case .copying: match = step == 0
            case .installing: match = step == 1
            case .installed: match = step == 2
            }
            if match { throw CocoaError(.fileWriteUnknown) }
        }
        let result = await repository.referenceFilesInPlace([source], existing: existing ? [original] : [], copyExternalFiles: true)
        #expect(result.imported.isEmpty)
        #expect(result.issues.count == 1)
        #expect(try Data(contentsOf: source) == bytes)
        let recovered = try await LibraryRepository(rootURL: catalog, mediaURL: media).load()
        #expect(recovered.document.tracks.count == ((existing || step != 0) ? 1 : 0))
        if let track = recovered.document.tracks.first {
            if existing { #expect(track.id == original.id); #expect(track.title == original.title) }
            if step == 0 { #expect(track.managedPath == source.path) }
            else { #expect(track.managedPath != source.path); #expect(try Data(contentsOf: track.fileURL) == bytes) }
        }
        #expect(!FileManager.default.fileExists(atPath: catalog.appendingPathComponent("import-journal-v1.json").path))
        let again = try await LibraryRepository(rootURL: catalog, mediaURL: media).load().document
        #expect(again.tracks.count == recovered.document.tracks.count)
        #expect(try Data(contentsOf: source) == bytes)
    }

    @Test("Reference recovery retains the journal when the existing track was relinked elsewhere")
    func referenceCopyRecoveryPreservesNewerRelink() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.mp3")
        let alternative = root.appendingPathComponent("alternative.mp3")
        let bytes = Data([0x49, 0x44, 0x33, 5, 6, 7])
        try bytes.write(to: source); try bytes.write(to: alternative)
        let catalog = root.appendingPathComponent("Catalog")
        let media = root.appendingPathComponent("Media")
        let repository = LibraryRepository(rootURL: catalog, mediaURL: media)
        let original = Track(id: UUID(), title: "Existing", artist: "A", album: "B", duration: 1,
                             fileSize: Int64(bytes.count), managedPath: source.path,
                             sha256: try LibraryRepository.sha256(of: source), addedAt: .now, health: .verified)
        try await repository.save(tracks: [original])
        let baseline = try await repository.load().document
        await repository.setImportWriteTestHook { stage in
            if case .installed = stage { throw CocoaError(.fileWriteUnknown) }
        }
        _ = await repository.referenceFilesInPlace([source], existing: [original], copyExternalFiles: true)
        var changed = baseline
        changed.tracks[0].managedPath = alternative.path
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(changed).write(to: catalog.appendingPathComponent("library-v1.json"), options: .atomic)
        let recovered = try await LibraryRepository(rootURL: catalog, mediaURL: media).load()
        #expect(recovered.unresolvedImportCount == 1)
        #expect(recovered.document.tracks.first?.managedPath == alternative.path)
        #expect(FileManager.default.fileExists(atPath: catalog.appendingPathComponent("import-journal-v1.json").path))
        #expect(try Data(contentsOf: source) == bytes)
        #expect(try Data(contentsOf: alternative) == bytes)
    }
#endif

    @Test("A configured media directory receives new managed files")
    func importsIntoConfiguredMediaDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("Artist - Custom.mp3")
        let catalog = root.appendingPathComponent("Catalog")
        let media = root.appendingPathComponent("Selected/Ongaku Media")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0x49, 0x44, 0x33, 4, 5, 6]).write(to: source)

        let repository = LibraryRepository(rootURL: catalog, mediaURL: media)
        let imported = await repository.importFiles([source], existing: [])

        #expect(imported.imported.count == 1)
        #expect(imported.imported[0].fileURL.path.hasPrefix(media.path + "/"))
        #expect(FileManager.default.fileExists(atPath: imported.imported[0].managedPath))
        try? FileManager.default.removeItem(at: root)
    }

    @Test("Dropping files and folders imports supported audio into artist and album folders")
    @MainActor
    func importsDroppedFilesAndFoldersIntoManagedHierarchy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let droppedFolder = root.appendingPathComponent("Dropped Music", isDirectory: true)
        let nestedFolder = droppedFolder.appendingPathComponent("Nested", isDirectory: true)
        let first = droppedFolder.appendingPathComponent("Artist - First.mp3")
        let second = nestedFolder.appendingPathComponent("Artist - Second.flac")
        let ignored = nestedFolder.appendingPathComponent("Notes.txt")
        let media = root.appendingPathComponent("Managed Music", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedFolder, withIntermediateDirectories: true)
        try Data([0x49, 0x44, 0x33, 41, 42, 43]).write(to: first)
        try Data([0x66, 0x4C, 0x61, 0x43, 51, 52, 53]).write(to: second)
        try Data("not audio".utf8).write(to: ignored)
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = LibraryRepository(
            rootURL: root.appendingPathComponent("Catalog", isDirectory: true),
            mediaURL: media
        )
        let store = LibraryStore(repository: repository)

        // Files without embedded artist/album metadata must not be silently placed in
        // fallback folders, even when their filename looks descriptive.
        await store.importDroppedItems([droppedFolder, first, ignored])
        #expect(store.tracks.isEmpty)

        // The direct file overlaps with the folder and must still be imported only once.
        let sourceURLs = await store.audioFiles(inDroppedItems: [droppedFolder, first, ignored])
        let drafts = await store.requiredImportMetadata(for: sourceURLs)
        let completedDrafts = drafts.map { draft in
            var completed = draft
            completed.artist = "Artist"
            completed.album = "Drop Album"
            return completed
        }
        let overrides = Dictionary(uniqueKeysWithValues: completedDrafts.map { ($0.id, $0) })
        await store.importFiles(sourceURLs, requiredMetadataOverrides: overrides)

        #expect(store.tracks.count == 2)
        #expect(Set(store.tracks.map(\.title)) == Set(["First", "Second"]))
        for track in store.tracks {
            #expect(track.fileURL.path.hasPrefix(media.path + "/"))
            #expect(track.fileURL.deletingLastPathComponent().lastPathComponent == track.album)
            #expect(
                track.fileURL.deletingLastPathComponent().deletingLastPathComponent()
                    .lastPathComponent == track.artist)
            #expect(FileManager.default.fileExists(atPath: track.managedPath))
        }
        #expect(try Data(contentsOf: ignored) == Data("not audio".utf8))
    }

    @Test("The automatic Ongaku Media directory is created only by a managed import")
    func createsAutomaticMediaDirectoryOnFirstImport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let catalog = root.appendingPathComponent("Catalog", isDirectory: true)
        let automaticMedia = catalog.appendingPathComponent("Ongaku Media", isDirectory: true)
        let source = root.appendingPathComponent("First Track.mp3")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0x49, 0x44, 0x33, 31, 32, 33]).write(to: source)

        let repository = LibraryRepository(rootURL: catalog)
        _ = try await repository.load()
        #expect(!FileManager.default.fileExists(atPath: automaticMedia.path))

        let imported = await repository.importFiles([source], existing: [])
        #expect(imported.imported.count == 1)
        #expect(FileManager.default.fileExists(atPath: automaticMedia.path))
        #expect(imported.imported[0].fileURL.path.hasPrefix(automaticMedia.path + "/"))
        try? FileManager.default.removeItem(at: root)
    }

    @Test("Changing the media directory redirects the next import immediately")
    func changesMediaDirectoryAtRuntime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("Artist - Redirected.mp3")
        let catalog = root.appendingPathComponent("Catalog")
        let originalMedia = root.appendingPathComponent("Original/Ongaku Media")
        let changedMedia = root.appendingPathComponent("Changed/Ongaku Media")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0x49, 0x44, 0x33, 7, 8, 9]).write(to: source)

        let repository = LibraryRepository(rootURL: catalog, mediaURL: originalMedia)
        try await repository.setMediaDirectory(changedMedia)
        let imported = await repository.importFiles([source], existing: [])

        #expect(imported.imported.count == 1)
        #expect(imported.imported[0].fileURL.path.hasPrefix(changedMedia.path + "/"))
        #expect(!imported.imported[0].fileURL.path.hasPrefix(originalMedia.path + "/"))
        try? FileManager.default.removeItem(at: root)
    }

    @Test("Selecting an Apple Music library keeps originals and stores portable copies")
    @MainActor
    func importsAppleMusicMediaFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let media = root.appendingPathComponent("Media.localized", isDirectory: true)
        let managed = media.appendingPathComponent("Ongaku Media", isDirectory: true)
        let sourceDirectory = media.appendingPathComponent("Music/Artist/Album", isDirectory: true)
        let source = sourceDirectory.appendingPathComponent("Track.mp3")
        let secondSource = sourceDirectory.appendingPathComponent("Second Track.m4a")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try Data([0x49, 0x44, 0x33, 10, 11, 12]).write(to: source)
        try Data([0, 0, 0, 20, 21, 22]).write(to: secondSource)

        let repository = LibraryRepository(
            rootURL: root.appendingPathComponent("Catalog"),
            mediaURL: managed
        )
        let oldImport = await repository.importFiles([source], existing: [])
        #expect(oldImport.imported.count == 1)
        let oldManagedCopy = try #require(oldImport.imported.first?.fileURL)
        try await repository.save(tracks: oldImport.imported)

        let store = LibraryStore(repository: repository)
        await store.load()
        let first = await store.importAppleMusicMediaFolder(media, excluding: managed)
        #expect(first.discovered == 2)
        #expect(first.imported == 1)
        #expect(first.relinked == 0)
        #expect(store.tracks.count == 2)
        #expect(store.tracks.allSatisfy { $0.fileURL.path.hasPrefix(managed.path + "/") })
        #expect(Set(store.tracks.map(\.sha256)) == Set([
            try LibraryRepository.sha256(of: source), try LibraryRepository.sha256(of: secondSource)
        ]))
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: secondSource.path))
        #expect(FileManager.default.fileExists(atPath: oldManagedCopy.path))

        let second = await store.importAppleMusicMediaFolder(media, excluding: managed)
        #expect(second.discovered == 2)
        #expect(second.imported == 0)
        #expect(second.relinked == 0)
        #expect(store.tracks.count == 2)
        try? FileManager.default.removeItem(at: root)
    }

    @Test("Registering a dropped folder preserves its hierarchy and every audio file")
    @MainActor
    func registersDroppedFolderInPlace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let musicFolder = root.appendingPathComponent("Existing Music", isDirectory: true)
        let firstDirectory = musicFolder.appendingPathComponent(
            "Artist/First Album", isDirectory: true)
        let secondDirectory = musicFolder.appendingPathComponent(
            "Artist/Second Album/Disc 2", isDirectory: true)
        let first = firstDirectory.appendingPathComponent("First Track.mp3")
        let second = secondDirectory.appendingPathComponent("Second Track.flac")
        let firstData = Data([0x49, 0x44, 0x33, 31, 32, 33])
        let secondData = Data([0x66, 0x4C, 0x61, 0x43, 41, 42, 43])
        try FileManager.default.createDirectory(
            at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: secondDirectory, withIntermediateDirectories: true)
        try firstData.write(to: first)
        try secondData.write(to: second)
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = LibraryRepository(
            rootURL: root.appendingPathComponent("Catalog"),
            mediaURL: musicFolder
        )
        let store = LibraryStore(repository: repository)
        let summary = await store.registerMediaFolderInPlace(musicFolder)

        #expect(summary.discovered == 2)
        #expect(summary.imported == 2)
        #expect(summary.issues == 0)
        #expect(
            Set(store.tracks.map { $0.fileURL.standardizedFileURL })
                == Set([
                    first.standardizedFileURL,
                    second.standardizedFileURL,
                ]))
        #expect(try Data(contentsOf: first) == firstData)
        #expect(try Data(contentsOf: second) == secondData)
        #expect(
            !FileManager.default.fileExists(
                atPath: musicFolder.appendingPathComponent("Ongaku Media").path))
    }

    @Test("URL audio import accepts only public standard-port HTTPS URLs")
    func validatesAudioImportURLs() throws {
        let valid = try URLAudioImportPolicy.validatedURL(
            from: "https://cdn.example.com/releases/song.flac"
        )
        #expect(valid.host == "cdn.example.com")

        let blocked = [
            "http://cdn.example.com/song.flac",
            "https://localhost/song.flac",
            "https://127.0.0.1/song.flac",
            "https://10.1.2.3/song.flac",
            "https://172.20.1.2/song.flac",
            "https://192.168.1.2/song.flac",
            "https://user:password@cdn.example.com/song.flac",
            "https://cdn.example.com:8443/song.flac",
        ]
        for value in blocked {
            #expect(throws: URLAudioImportError.self) {
                try URLAudioImportPolicy.validatedURL(from: value)
            }
        }
    }

    @Test("URL audio response requires a compatible MIME type, extension, and size")
    func validatesAudioImportResponse() throws {
        let url = URL(string: "https://cdn.example.com/song.flac")!
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "audio/flac",
                "Content-Length": "1234",
            ]
        ))
        let descriptor = try URLAudioImportPolicy.descriptor(
            response: response,
            fallbackURL: url
        )
        #expect(descriptor.pathExtension == "flac")
        #expect(descriptor.mimeType == "audio/flac")
        #expect(descriptor.expectedSize == 1_234)

        let mismatched = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "audio/mpeg"]
        ))
        #expect(throws: URLAudioImportError.mismatchedFileType) {
            try URLAudioImportPolicy.descriptor(response: mismatched, fallbackURL: url)
        }

        let oversized = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "Content-Type": "audio/flac",
                "Content-Length": String(URLAudioImportPolicy.maximumFileSize + 1),
            ]
        ))
        #expect(throws: URLAudioImportError.fileTooLarge) {
            try URLAudioImportPolicy.descriptor(response: oversized, fallbackURL: url)
        }
    }

    @Test("URL audio import validates the downloaded audio contents")
    func validatesDownloadedAudioContents() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let audioURL = root.appendingPathComponent("valid.aiff")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
            buffer.frameLength = 64
            try file.write(from: buffer)
        }
        try URLAudioImportPolicy.validateDownloadedFile(audioURL)

        let fakeURL = root.appendingPathComponent("fake.mp3")
        try Data("not audio".utf8).write(to: fakeURL)
        #expect(throws: URLAudioImportError.invalidAudio) {
            try URLAudioImportPolicy.validateDownloadedFile(fakeURL)
        }
    }

    @Test("Music and iTunes XML migration previews songs, metadata, and user playlists")
    func previewsLegacyMusicLibrary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let registeredURL = root.appendingPathComponent("Registered.mp3")
        let readyURL = root.appendingPathComponent("Ready.flac")
        let unsupportedURL = root.appendingPathComponent("Notes.txt")
        try Data([0x49, 0x44, 0x33]).write(to: registeredURL)
        try Data([0x66, 0x4C, 0x61, 0x43]).write(to: readyURL)
        try Data("notes".utf8).write(to: unsupportedURL)
        let existing = Track(
            id: UUID(), title: "Registered", artist: "Artist", album: "Album",
            duration: 1, fileSize: 3, managedPath: registeredURL.path,
            sha256: "existing", addedAt: .now, health: .verified
        )
        let xmlURL = root.appendingPathComponent("Music Library.xml")
        let library: [String: Any] = [
            "Library Persistent ID": "LIBRARY123",
            "Tracks": [
                "1": [
                    "Track ID": 1, "Name": "Registered", "Artist": "Artist",
                    "Album": "Album", "Location": registeredURL.absoluteString,
                ],
                "2": [
                    "Track ID": 2, "Name": "Migration Song", "Artist": "Migration Artist",
                    "Sort Artist": "Artist, Migration", "Album": "Migration Album",
                    "Album Artist": "Various", "Composer": "Composer", "Genre": "Jazz",
                    "BPM": 123, "Copyright": "© Migration",
                    "Year": 1999, "Track Number": 3, "Track Count": 12,
                    "Disc Number": 1, "Disc Count": 2, "Rating": 80,
                    "Play Count": 7, "Loved": true, "Compilation": true,
                    "Comments": "From XML", "Location": readyURL.absoluteString,
                ],
                "3": [
                    "Track ID": 3, "Name": "Missing",
                    "Location": root.appendingPathComponent("Missing.mp3").absoluteString,
                ],
                "4": [
                    "Track ID": 4, "Name": "Unsupported",
                    "Location": unsupportedURL.absoluteString,
                ],
            ],
            "Playlists": [
                [
                    "Name": "Road Songs", "Playlist Persistent ID": "PLAYLIST1",
                    "Playlist Items": [["Track ID": 2], ["Track ID": 1]],
                ],
                ["Name": "Library", "Master": true, "Playlist Items": []],
                ["Name": "Smart", "Smart Info": Data([1]), "Playlist Items": []],
            ],
        ]
        try PropertyListSerialization.data(
            fromPropertyList: library,
            format: .xml,
            options: 0
        ).write(to: xmlURL)

        let preview = try LegacyLibraryMigrationService.preview(
            from: xmlURL,
            existingTracks: [existing]
        )

        #expect(preview.sourceName == "LIBRARY123")
        #expect(preview.readyCount == 1)
        #expect(preview.registeredCount == 1)
        #expect(preview.missingCount == 1)
        #expect(preview.unsupportedCount == 1)
        let track = try #require(preview.tracks.first { $0.id == 2 })
        #expect(track.artistSortName == "Artist, Migration")
        #expect(track.albumArtist == "Various")
        #expect(track.beatsPerMinute == 123)
        #expect(track.copyright == "© Migration")
        #expect(track.rating == 4)
        #expect(track.playCount == 7)
        #expect(track.isFavorite)
        #expect(track.isCompilation)
        #expect(preview.playlists.map(\.name) == ["Road Songs"])
        #expect(preview.playlists[0].trackIDs == [2, 1])
    }

    @Test("Music XML migration copies originals, restores metadata and playlists, and is idempotent")
    @MainActor
    func importsLegacyMusicLibrary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Original.aiff")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
            buffer.frameLength = 128
            try file.write(from: buffer)
        }
        let originalHash = try LibraryRepository.sha256(of: source)
        let addedAt = Date(timeIntervalSince1970: 1_000_000)
        let xmlURL = root.appendingPathComponent("Library.xml")
        let library: [String: Any] = [
            "Tracks": [
                "10": [
                    "Track ID": 10, "Name": "Imported Title", "Artist": "Imported Artist",
                    "Album": "Imported Album", "Composer": "Imported Composer",
                    "Genre": "Ambient", "Year": 2005, "Track Number": 2,
                    "Track Count": 8, "Rating": 100, "Play Count": 11,
                    "Loved": true, "Date Added": addedAt, "Location": source.absoluteString,
                ],
            ],
            "Playlists": [[
                "Name": "XML Favorites", "Playlist Persistent ID": "XMLFAVORITES",
                "Playlist Items": [["Track ID": 10]],
            ]],
        ]
        try PropertyListSerialization.data(
            fromPropertyList: library,
            format: .xml,
            options: 0
        ).write(to: xmlURL)
        let repository = LibraryRepository(
            rootURL: root.appendingPathComponent("Catalog"),
            mediaURL: root.appendingPathComponent("Managed Media")
        )
        let store = LibraryStore(repository: repository)
        await store.load()
        let preview = try LegacyLibraryMigrationService.preview(from: xmlURL, existingTracks: [])

        let first = try await store.importLegacyLibrary(preview)

        #expect(first.imported == 1)
        #expect(first.playlists == 1)
        let imported = try #require(store.tracks.first)
        #expect(imported.title == "Imported Title")
        #expect(imported.artist == "Imported Artist")
        #expect(imported.album == "Imported Album")
        #expect(imported.composer == "Imported Composer")
        #expect(imported.rating == 5)
        #expect(imported.playCount == 11)
        #expect(imported.isFavorite)
        #expect(imported.addedAt == addedAt)
        #expect(imported.fileURL.standardizedFileURL != source.standardizedFileURL)
        #expect(try LibraryRepository.sha256(of: source) == originalHash)
        #expect(store.playlists.first?.name == "XML Favorites")
        #expect(store.playlists.first?.entries.map(\.trackID) == [imported.id])

        let second = try await store.importLegacyLibrary(preview)
        #expect(second.imported == 0)
        #expect(second.playlists == 0)
        #expect(store.tracks.count == 1)
        #expect(store.playlists.count == 1)
    }

    @Test("Another Ongaku library merges metadata, smart playlists, folders, and audio non-destructively")
    @MainActor
    func importsAnotherOngakuLibrary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("Source Library", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let sourceAudio = sourceRoot.appendingPathComponent("Source Song.aiff")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: sourceAudio, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
            buffer.frameLength = 128
            try file.write(from: buffer)
        }
        let sourceAudioHash = try LibraryRepository.sha256(of: sourceAudio)
        let sourceTrack = Track(
            id: UUID(), title: "Ongaku Source", artist: "Source Artist",
            album: "Source Album", composer: "Source Composer", genre: "Electronic",
            playCount: 19, comments: "Preserved", lyrics: TrackLyrics(
                plainText: "Source lyrics", source: .manual, isManuallyEdited: true
            ), duration: 1, fileSize: 1, managedPath: sourceAudio.path,
            sha256: sourceAudioHash, addedAt: Date(timeIntervalSince1970: 2_000_000),
            lastVerifiedAt: .now, health: .verified, isPinned: true,
            isFavorite: true, rating: 5
        )
        let missingTrack = Track(
            id: UUID(), title: "Missing", artist: "Source Artist", album: "Source Album",
            duration: 1, fileSize: 1,
            managedPath: sourceRoot.appendingPathComponent("Missing.mp3").path,
            sha256: "missing-hash", addedAt: .now, health: .missing
        )
        let folder = PlaylistFolder(name: "Imported Folder", sortOrder: 0)
        let regular = Playlist(
            name: "Imported Regular", folderID: folder.id, sortOrder: 0,
            entries: [PlaylistEntry(trackID: sourceTrack.id)]
        )
        var smartDefinition = SmartPlaylistDefinition()
        smartDefinition.root.rules = [SmartPlaylistRule(
            field: .favorite,
            comparison: .isTrue,
            value: ""
        )]
        let smart = Playlist(
            name: "Imported Smart", sortOrder: 0,
            smartDefinition: smartDefinition
        )
        let sourceDocument = LibraryDocument(
            tracks: [sourceTrack, missingTrack],
            libraryID: UUID(),
            playlists: [regular, smart],
            playlistFolders: [folder]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let sourceManifest = sourceRoot.appendingPathComponent("library-v1.json")
        try encoder.encode(sourceDocument).write(to: sourceManifest, options: .atomic)
        let manifestBefore = try Data(contentsOf: sourceManifest)

        let repository = LibraryRepository(
            rootURL: destinationRoot,
            mediaURL: destinationRoot.appendingPathComponent("Ongaku Media")
        )
        let store = LibraryStore(repository: repository)
        await store.load()
        let preview = try await store.previewOngakuLibrary(at: sourceRoot)

        #expect(preview.readyCount == 1)
        #expect(preview.missingCount == 1)
        #expect(preview.document.playlists.count == 2)
        #expect(preview.document.playlistFolders.count == 1)

        let first = try await store.importOngakuLibrary(preview)

        #expect(first.imported == 1)
        #expect(first.playlists == 2)
        #expect(first.folders == 1)
        let imported = try #require(store.tracks.first)
        #expect(imported.title == "Ongaku Source")
        #expect(imported.composer == "Source Composer")
        #expect(imported.genre == "Electronic")
        #expect(imported.playCount == 19)
        #expect(imported.comments == "Preserved")
        #expect(imported.lyrics?.plainText == "Source lyrics")
        #expect(imported.isPinned)
        #expect(imported.isFavorite)
        #expect(imported.rating == 5)
        #expect(imported.fileURL.standardizedFileURL != sourceAudio.standardizedFileURL)
        #expect(try LibraryRepository.sha256(of: sourceAudio) == sourceAudioHash)
        #expect(try Data(contentsOf: sourceManifest) == manifestBefore)
        #expect(!FileManager.default.fileExists(
            atPath: sourceRoot.appendingPathComponent("library-schema-12.migration-backup.json").path
        ))
        let importedFolder = try #require(store.playlistFolders.first)
        let importedRegular = try #require(store.playlists.first { $0.name == "Imported Regular" })
        let importedSmart = try #require(store.playlists.first { $0.name == "Imported Smart" })
        #expect(importedRegular.folderID == importedFolder.id)
        #expect(importedRegular.entries.map(\.trackID) == [imported.id])
        #expect(importedSmart.smartDefinition == smartDefinition)

        let secondPreview = try await store.previewOngakuLibrary(at: sourceRoot)
        #expect(secondPreview.registeredCount == 1)
        let second = try await store.importOngakuLibrary(secondPreview)
        #expect(second.imported == 0)
        #expect(second.playlists == 0)
        #expect(second.folders == 0)
        #expect(store.tracks.count == 1)
        #expect(store.playlists.count == 2)
        #expect(store.playlistFolders.count == 1)
        #expect(try Data(contentsOf: sourceManifest) == manifestBefore)
    }

    @Test("Shared folder migration previews, verifies, copies, and remains idempotent")
    @MainActor
    func importsSharedFolderNonDestructively() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("Mounted Share", isDirectory: true)
        let nested = shared.appendingPathComponent("Artist/Album", isDirectory: true)
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let source = nested.appendingPathComponent("Shared Song.aiff")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
            buffer.frameLength = 128
            try file.write(from: buffer)
        }
        let sourceHash = try LibraryRepository.sha256(of: source)
        let sourceData = try Data(contentsOf: source)

        let repository = LibraryRepository(
            rootURL: destination,
            mediaURL: destination.appendingPathComponent("Ongaku Media")
        )
        let store = LibraryStore(repository: repository)
        await store.load()
        let preview = try await store.previewSharedFolder(at: shared)

        #expect(preview.readyCount == 1)
        #expect(preview.registeredCount == 0)
        #expect(preview.rows.first?.relativePath == "Artist/Album/Shared Song.aiff")
        #expect(preview.rows.first?.sha256 == sourceHash)

        let first = try await store.importSharedFolder(preview)
        #expect(first.imported == 1)
        #expect(first.issues == 0)
        #expect(store.tracks.count == 1)
        #expect(store.tracks[0].fileURL.standardizedFileURL != source.standardizedFileURL)
        #expect(try LibraryRepository.sha256(of: store.tracks[0].fileURL) == sourceHash)
        #expect(try Data(contentsOf: source) == sourceData)

        let secondPreview = try await store.previewSharedFolder(at: shared)
        #expect(secondPreview.readyCount == 0)
        #expect(secondPreview.registeredCount == 1)
        #expect(try Data(contentsOf: source) == sourceData)
    }

    @Test("Media organization dry-runs and transactionally moves only managed files")
    @MainActor
    func organizesManagedMediaWithDryRun() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = root.appendingPathComponent("Catalog", isDirectory: true)
        let oldMedia = root.appendingPathComponent("Old Media", isDirectory: true)
        let newMedia = root.appendingPathComponent("New Media", isDirectory: true)
        let externalRoot = root.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: oldMedia, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)

        func writeAudio(_ url: URL) throws {
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
            buffer.frameLength = 128
            try file.write(from: buffer)
        }
        let managedSource = oldMedia.appendingPathComponent("Loose.aiff")
        let externalSource = externalRoot.appendingPathComponent("Reference.aiff")
        try writeAudio(managedSource)
        try writeAudio(externalSource)
        let managedHash = try LibraryRepository.sha256(of: managedSource)
        let externalHash = try LibraryRepository.sha256(of: externalSource)
        let managed = Track(
            id: UUID(), title: "Managed", artist: "Artist", album: "Album", duration: 1,
            fileSize: 1, managedPath: managedSource.path, sha256: managedHash,
            addedAt: .now, health: .verified
        )
        let external = Track(
            id: UUID(), title: "External", artist: "Artist", album: "Album", duration: 1,
            fileSize: 1, managedPath: externalSource.path, sha256: externalHash,
            addedAt: .now, health: .verified
        )
        let repository = LibraryRepository(rootURL: catalog, mediaURL: oldMedia)
        try await repository.save(document: LibraryDocument(tracks: [managed, external]))
        let store = LibraryStore(repository: repository)
        await store.load()

        let preview = try await store.previewMediaOrganization(destination: newMedia)
        #expect(preview.moveCount == 1)
        #expect(preview.externalCount == 1)
        let planned = try #require(preview.items.first { $0.status == .move })
        #expect(planned.destinationURL.path.hasSuffix("Artist/Album/Loose.aiff"))
        #expect(FileManager.default.fileExists(atPath: managedSource.path))
        #expect(!FileManager.default.fileExists(atPath: planned.destinationURL.path))

        let summary = try await store.executeMediaOrganization(preview)
        #expect(summary.moved == 1)
        #expect(summary.updatedTracks == 1)
        #expect(!FileManager.default.fileExists(atPath: managedSource.path))
        #expect(FileManager.default.fileExists(atPath: planned.destinationURL.path))
        #expect(try LibraryRepository.sha256(of: planned.destinationURL) == managedHash)
        #expect(store.tracks.first { $0.id == managed.id }?.fileURL == planned.destinationURL)
        #expect(store.tracks.first { $0.id == external.id }?.fileURL == externalSource)
        #expect(!FileManager.default.fileExists(
            atPath: catalog.appendingPathComponent("media-organization-journal-v1.json").path
        ))
    }

    @Test("Media organization rolls back completed moves when a later checksum changes")
    @MainActor
    func rollsBackFailedMediaOrganization() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = root.appendingPathComponent("Catalog", isDirectory: true)
        let media = root.appendingPathComponent("Media", isDirectory: true)
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        var sourceURLs: [URL] = []
        var tracks: [Track] = []
        for name in ["A.aiff", "B.aiff"] {
            let url = media.appendingPathComponent(name)
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
                buffer.frameLength = 128
                try file.write(from: buffer)
            }
            let hash = try LibraryRepository.sha256(of: url)
            sourceURLs.append(url)
            tracks.append(Track(
                id: UUID(), title: name, artist: "Artist", album: "Album", duration: 1,
                fileSize: 1, managedPath: url.path, sha256: hash,
                addedAt: .now, health: .verified
            ))
        }
        let repository = LibraryRepository(rootURL: catalog, mediaURL: media)
        try await repository.save(document: LibraryDocument(tracks: tracks))
        let store = LibraryStore(repository: repository)
        await store.load()
        let preview = try await store.previewMediaOrganization(destination: destination)
        try Data("changed".utf8).write(to: sourceURLs[1])
        #expect(preview.moveCount == 2)
        #expect(try LibraryRepository.sha256(of: sourceURLs[1]) != tracks[1].sha256)

        do {
            _ = try await store.executeMediaOrganization(preview)
            Issue.record("Expected checksum verification to fail")
        } catch {}

        #expect(FileManager.default.fileExists(atPath: sourceURLs[0].path))
        #expect(FileManager.default.fileExists(atPath: sourceURLs[1].path))
        #expect(!FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("Artist/Album/A.aiff").path
        ))
        #expect(store.tracks.map(\.managedPath) == tracks.map(\.managedPath))
        #expect(!FileManager.default.fileExists(
            atPath: catalog.appendingPathComponent("media-organization-journal-v1.json").path
        ))
    }

    @Test("A failed replacement restores both source and overwritten destination files")
    @MainActor
    func rollsBackOverwrittenMediaOrganizationDestination() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = root.appendingPathComponent("Catalog", isDirectory: true)
        let media = root.appendingPathComponent("Media", isDirectory: true)
        let destinationDirectory = media.appendingPathComponent("Artist/Album")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )

        var tracks: [Track] = []
        var sources: [URL] = []
        var destinations: [URL] = []
        var existingDestinationData: [Data] = []
        for name in ["A.mp3", "B.mp3"] {
            let source = media.appendingPathComponent(name)
            let destination = destinationDirectory.appendingPathComponent(name)
            let sourceData = Data("source-\(name)".utf8)
            let destinationData = Data("destination-\(name)".utf8)
            try sourceData.write(to: source)
            try destinationData.write(to: destination)
            sources.append(source)
            destinations.append(destination)
            existingDestinationData.append(destinationData)
            tracks.append(Track(
                id: UUID(), title: name, artist: "Artist", album: "Album",
                duration: 1, fileSize: Int64(sourceData.count), managedPath: source.path,
                sha256: try LibraryRepository.sha256(of: source),
                addedAt: .now, health: .verified
            ))
        }
        let repository = LibraryRepository(rootURL: catalog, mediaURL: media)
        try await repository.save(document: LibraryDocument(tracks: tracks))
        let store = LibraryStore(repository: repository)
        await store.load()
        let preview = try await store.previewMediaOrganization(destination: media)
        #expect(preview.conflictCount == 2)

        try Data("changed after planning".utf8).write(to: sources[1])
        do {
            _ = try await store.executeMediaOrganization(
                preview,
                collisionPolicy: .replace
            )
            Issue.record("The changed source should fail checksum verification")
        } catch {}

        #expect(sources.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(try Data(contentsOf: sources[0]) == Data("source-A.mp3".utf8))
        #expect(try Data(contentsOf: destinations[0]) == existingDestinationData[0])
        #expect(try Data(contentsOf: destinations[1]) == existingDestinationData[1])
        #expect(store.tracks.map(\.managedPath) == tracks.map(\.managedPath))
        #expect(!FileManager.default.fileExists(
            atPath: catalog.appendingPathComponent("Media Organization Backups").path
        ))
    }

    @Test("An interrupted Media organization journal rolls files back on next launch")
    func recoversInterruptedMediaOrganization() async throws {
        struct Entry: Codable {
            var sourcePath: String
            var destinationPath: String
            var expectedSHA256: String
            var moved: Bool
        }
        struct Journal: Codable {
            var schemaVersion = 1
            var updatedAt = Date.now
            var entries: [Entry]
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = root.appendingPathComponent("Catalog", isDirectory: true)
        let media = root.appendingPathComponent("Media", isDirectory: true)
        let source = media.appendingPathComponent("Loose.aiff")
        let destination = media.appendingPathComponent("Artist/Album/Loose.aiff")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
            buffer.frameLength = 128
            try file.write(from: buffer)
        }
        let hash = try LibraryRepository.sha256(of: source)
        let track = Track(
            id: UUID(), title: "Loose", artist: "Artist", album: "Album",
            duration: 1, fileSize: 1, managedPath: source.path, sha256: hash,
            addedAt: .now, health: .verified
        )
        let repository = LibraryRepository(rootURL: catalog, mediaURL: media)
        try await repository.save(document: LibraryDocument(tracks: [track]))
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: source, to: destination)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Journal(entries: [Entry(
            sourcePath: source.path,
            destinationPath: destination.path,
            expectedSHA256: hash,
            moved: false
        )])).write(
            to: catalog.appendingPathComponent("media-organization-journal-v1.json"),
            options: .atomic
        )

        let relaunched = LibraryRepository(rootURL: catalog, mediaURL: media)
        let loaded = try await relaunched.load()
        #expect(loaded.document.tracks.first?.managedPath == source.path)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(
            atPath: catalog.appendingPathComponent("media-organization-journal-v1.json").path
        ))
    }

    @Test("Media organization preserves its journal and replacement backup when rollback is interrupted")
    func mediaOrganizationRollbackRetriesAfterStorageFailure() async throws {
        struct Entry: Codable {
            var sourcePath: String; var destinationPath: String; var expectedSHA256: String
            var moved: Bool; var replacedDestinationBackupPath: String?
        }
        struct Journal: Codable { var schemaVersion = 1; var updatedAt = Date.now; var entries: [Entry] }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = root.appendingPathComponent("Catalog")
        let media = root.appendingPathComponent("Media")
        let source = media.appendingPathComponent("source.wav")
        let destination = media.appendingPathComponent("Artist/destination.wav")
        let backup = catalog.appendingPathComponent("Media Organization Backups/backup.wav")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let audio = Data("source audio".utf8)
        try audio.write(to: destination)
        let hash = try LibraryRepository.sha256(of: destination)
        let track = Track(id: UUID(), title: "T", artist: "A", album: "B", duration: 1,
                          fileSize: Int64(audio.count), managedPath: source.path, sha256: hash, addedAt: .now, health: .verified)
        let repository = LibraryRepository(rootURL: catalog, mediaURL: media)
        try await repository.save(document: LibraryDocument(tracks: [track]))
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        let replacement = Data("original destination".utf8)
        try replacement.write(to: backup)
        let journalURL = catalog.appendingPathComponent("media-organization-journal-v1.json")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Journal(entries: [Entry(sourcePath: source.path, destinationPath: destination.path,
                    expectedSHA256: hash, moved: true, replacedDestinationBackupPath: backup.path)])).write(to: journalURL)
        let failing = LibraryRepository(rootURL: catalog, mediaURL: media,
                                        fileManager: FailingOrganizationMoveFileManager())
        do { _ = try await failing.load(); Issue.record("Recovery unexpectedly succeeded") } catch { }
        #expect(try Data(contentsOf: destination) == audio)
        #expect(try Data(contentsOf: backup) == replacement)
        #expect(FileManager.default.fileExists(atPath: journalURL.path))
        let recovered = try await LibraryRepository(rootURL: catalog, mediaURL: media).load()
        #expect(recovered.document.tracks.first?.managedPath == source.path)
        #expect(try Data(contentsOf: source) == audio)
        #expect(try Data(contentsOf: destination) == replacement)
        #expect(!FileManager.default.fileExists(atPath: journalURL.path))
    }

    @Test("A committed organization retains recovery data while the destination is missing")
    func committedOrganizationWaitsForDestination() async throws {
        struct Entry: Codable {
            var sourcePath: String; var destinationPath: String; var expectedSHA256: String
            var moved: Bool; var replacedDestinationBackupPath: String?
        }
        struct Journal: Codable { var schemaVersion = 1; var updatedAt = Date.now; var entries: [Entry] }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = root.appendingPathComponent("Catalog")
        let media = root.appendingPathComponent("Media")
        let source = media.appendingPathComponent("source.wav")
        let destination = media.appendingPathComponent("destination.wav")
        let backup = catalog.appendingPathComponent("Media Organization Backups/backup.wav")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let audio = Data("source audio".utf8)
        try audio.write(to: destination)
        let hash = try LibraryRepository.sha256(of: destination)
        let track = Track(id: UUID(), title: "T", artist: "A", album: "B", duration: 1,
                          fileSize: Int64(audio.count), managedPath: destination.path, sha256: hash, addedAt: .now, health: .verified)
        let repository = LibraryRepository(rootURL: catalog, mediaURL: media)
        try await repository.save(document: LibraryDocument(tracks: [track]))
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        let replacement = Data("old destination".utf8)
        try replacement.write(to: backup)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let journalURL = catalog.appendingPathComponent("media-organization-journal-v1.json")
        try encoder.encode(Journal(entries: [Entry(sourcePath: source.path, destinationPath: destination.path,
                expectedSHA256: hash, moved: true, replacedDestinationBackupPath: backup.path)])).write(to: journalURL)
        let disconnected = root.appendingPathComponent("disconnected.wav")
        try FileManager.default.moveItem(at: destination, to: disconnected)
        do { _ = try await LibraryRepository(rootURL: catalog, mediaURL: media).load(); Issue.record("Missing destination accepted") } catch { }
        #expect(try Data(contentsOf: backup) == replacement)
        #expect(FileManager.default.fileExists(atPath: journalURL.path))
        #expect(!FileManager.default.fileExists(atPath: source.path))
        try FileManager.default.moveItem(at: disconnected, to: destination)
        let recovered = try await LibraryRepository(rootURL: catalog, mediaURL: media).load()
        #expect(recovered.document.tracks.first?.managedPath == destination.path)
        #expect(try Data(contentsOf: destination) == audio)
        #expect(!FileManager.default.fileExists(atPath: journalURL.path))
    }

    @Test("Organization preserves a playlist written after the UI snapshot")
    func organizationPreservesConcurrentPlaylist() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.wav")
        try Data("audio".utf8).write(to: source)
        let hash = try LibraryRepository.sha256(of: source)
        let track = Track(id: UUID(), title: "T", artist: "A", album: "B", duration: 1,
                          fileSize: 5, managedPath: source.path, sha256: hash, addedAt: .now, health: .verified)
        let repository = LibraryRepository(rootURL: PortableLibraryStorage(mediaURL: root).rootURL, mediaURL: root)
        try await repository.save(tracks: [track])
        let snapshot = try await repository.load().document
        let preview = try await repository.planMediaOrganization(tracks: snapshot.tracks, destinationRootURL: root)
        let playlist = Playlist(name: "Concurrent", description: "")
        try await repository.save(playlists: [playlist])
        _ = try await repository.executeMediaOrganization(document: snapshot, preview: preview)
        let saved = try await repository.load().document
        #expect(saved.playlists.contains { $0.id == playlist.id })
        #expect(saved.tracks.first?.managedPath == preview.items.first?.destinationURL.path)
    }

    @Test("Apple Music media-folder-url is decoded")
    func decodesAppleMusicMediaFolder() {
        let expected = URL(fileURLWithPath: "/Volumes/Music/Media.localized", isDirectory: true)
        let preferences: [String: Any] = ["media-folder-url": expected.absoluteString]
        #expect(AppleMusicSettingsReader.mediaFolderURL(from: preferences) == expected.standardizedFileURL)
    }
}

private final class FailingOrganizationMoveFileManager: FileManager, @unchecked Sendable {
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

/// Stop a real repository write at its first directory preparation, then fail it.
private final class StorageWriteGate: @unchecked Sendable {
    let fails: Bool
    init(fails: Bool = true) { self.fails = fails }
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var armed = false
    func arm() { lock.withLock { armed = true } }
    func waitUntilEntered() -> Bool { entered.wait(timeout: .now() + 5) == .success }
    func waitUntilResumed() -> Bool { resume.wait(timeout: .now() + 10) == .success }
    func waitOffExecutor(_ wait: @escaping @Sendable () -> Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: wait())
            }
        }
    }
    func consume() -> Bool { lock.withLock { let value = armed; armed = false; return value } }
}

private final class DelayedStorageFailureFileManager: FileManager, @unchecked Sendable {
    private let gate: StorageWriteGate
    private let root: URL
    init(root: URL, gate: StorageWriteGate) {
        self.root = root.standardizedFileURL
        self.gate = gate
        super.init()
    }
    override func createDirectory(at url: URL, withIntermediateDirectories: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        if url.standardizedFileURL == root, gate.consume() {
            gate.entered.signal()
            guard gate.resume.wait(timeout: .now() + 10) == .success else {
                throw CocoaError(.fileWriteUnknown)
            }
            if gate.fails { throw CocoaError(.fileWriteNoPermission) }
        }
        try super.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories,
                                  attributes: attributes)
    }
}

@Suite("Storage delayed failure isolation", .serialized)
@MainActor
struct StorageDelayedFailureTests {
    @Test("Old favorite and missing-file writes cannot affect the new library", arguments: ["favorite", "missing"], [false, true])
    func oldTrackAttributeCompletion(operation: String, writeFails: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("First")
        let second = root.appendingPathComponent("Second")
        let firstCatalog = PortableLibraryStorage(mediaURL: first).rootURL
        let secondCatalog = PortableLibraryStorage(mediaURL: second).rootURL
        let gate = StorageWriteGate(fails: writeFails)
        defer { gate.resume.signal() }
        let oldRepository = LibraryRepository(rootURL: firstCatalog, mediaURL: first,
            fileManager: DelayedStorageFailureFileManager(root: firstCatalog, gate: gate))
        let newRepository = LibraryRepository(rootURL: secondCatalog, mediaURL: second)
        let old = Track(id: UUID(), title: "Old", artist: "A", album: "A", duration: 10,
                        fileSize: 1, managedPath: first.appendingPathComponent("old.mp3").path,
                        sha256: "old", addedAt: .now, health: .unchecked)
        let replacement = Track(id: UUID(), title: "New", artist: "B", album: "B", duration: 10,
                                fileSize: 1, managedPath: second.appendingPathComponent("new.mp3").path,
                                sha256: "new", addedAt: .now, health: .missing)
        try await oldRepository.save(tracks: [old])
        try await newRepository.save(tracks: [replacement])
        let store = LibraryStore(repository: oldRepository)
        await store.load()
        gate.arm()
        let operationTask = Task {
            if operation == "favorite" { await store.setFavorite(true, for: old.id) }
            else { await store.handleMissingPlaybackFile(id: old.id) }
        }
        let reached = await Task.detached { @Sendable [gate] in gate.waitUntilEntered() }.value
        #expect(reached)
        guard reached else { gate.resume.signal(); await operationTask.value; return }
        await store.switchLibrary(catalogURL: secondCatalog, mediaURL: second)
        #expect(store.tracks.map(\.id) == [replacement.id])
        gate.resume.signal()
        await operationTask.value
        #expect(store.tracks.map(\.id) == [replacement.id])
        #expect(try await newRepository.load().document.tracks.map(\.id) == [replacement.id])
        let saved = try #require(try await oldRepository.load().document.tracks.first)
        if operation == "favorite" { #expect(saved.isFavorite == !writeFails) }
        else { #expect(saved.health == (writeFails ? .unchecked : .missing)) }
    }

#if DEBUG
    @Test("CD import reloads one recovered song when another repository commits first")
    func cdImportRecoveryWinsTheHandoff() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("song.aiff")
        let bytes = Data("audio sample".utf8)
        try bytes.write(to: source)
        let media = root.appendingPathComponent("Media")
        let catalog = PortableLibraryStorage(mediaURL: media).rootURL
        let repository = LibraryRepository(rootURL: catalog, mediaURL: media)
        let store = LibraryStore(repository: repository)
        await store.load()
        let gate = StorageWriteGate(fails: false)
        defer { gate.resume.signal() }
        store.cdImportFinishedTestGate = {
            gate.entered.signal()
            _ = await Task.detached { @Sendable [gate] in gate.waitUntilResumed() }.value
        }
        let request = AudioCDImportRequest(sourceURL: source, title: "T", artist: "A", album: "B", trackNumber: 1, trackCount: 1)
        let importing = Task { await store.importAudioCD([request]) }
        let reached = await Task.detached { @Sendable [gate] in gate.waitUntilEntered() }.value
        #expect(reached)
        guard reached else { gate.resume.signal(); _ = await importing.value; return }
        let recovered = try await LibraryRepository(rootURL: catalog, mediaURL: media).load()
        #expect(recovered.recoveredImportCount == 1)
        gate.resume.signal()
        #expect(await importing.value == 0)
        store.cdImportFinishedTestGate = nil
        #expect(store.tracks.count == 1)
        #expect(store.tracks.first?.id == recovered.document.tracks.first?.id)
        let actual = try await LibraryRepository(rootURL: catalog, mediaURL: media).load().document
        #expect(actual.tracks.count == 1)
        #expect(try Data(contentsOf: try #require(actual.tracks.first?.fileURL)) == bytes)
        if case .failed = store.activity {} else { Issue.record("Expected a visible conflict") }
    }
#endif

    @Test("Unknown generation formats are retained without automatic repair")
    func futureGenerationRemainsUntouched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        try await repository.save(playlists: [Playlist(name: "Keep")])
        let generation = root.appendingPathComponent("catalog-generation-v1")
        let future = Data("v3:future:1".utf8)
        try future.write(to: generation, options: .atomic)
        do { _ = try await LibraryRepository(rootURL: root).load(); Issue.record("Future format accepted") }
        catch LibraryRepository.RepositoryError.unsupportedGenerationFormat { }
        #expect(try Data(contentsOf: generation) == future)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Recovery Backups").path))
    }


#if DEBUG
    @Test("Damaged generation is preserved and stale writers remain rejected after interrupted recovery", arguments: [0, 1], [false, true])
    func generationRecoveryInterruption(step: Int, priorEpoch: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = LibraryRepository(rootURL: root)
        try await writer.save(playlists: [Playlist(name: "Original")])
        let generation = root.appendingPathComponent("catalog-generation-v1")
        if priorEpoch { try Data("v2:\(UUID().uuidString):1".utf8).write(to: generation, options: .atomic) }
        let stale = LibraryRepository(rootURL: root)
        _ = try await stale.load()
        let damaged = Data("damaged".utf8)
        try damaged.write(to: generation, options: .atomic)
        let recovering = LibraryRepository(rootURL: root)
        await recovering.setGenerationRecoveryTestHook { stage in
            let matches: Bool
            switch stage {
            case .backup: matches = step == 0
            case .counter: matches = step == 1
            }
            if matches { throw POSIXError(.ENOSPC) }
        }
        do { _ = try await recovering.load(); Issue.record("Expected interrupted recovery") }
        catch let error as POSIXError { #expect(error.code == .ENOSPC) }
        let reopened = LibraryRepository(rootURL: root)
        #expect(try await reopened.load().document.playlists.map(\.name) == ["Original"])
        // Advance the reset counter back to the value the stale reader observed.
        try await reopened.save(playlists: [Playlist(name: "New")])
        do { try await stale.save(playlists: []); Issue.record("Stale writer accepted after generation reset") }
        catch LibraryRepository.RepositoryError.staleOrganizedTrack { }
        #expect(try await LibraryRepository(rootURL: root).load().document.playlists.map(\.name) == ["New"])
        let backups = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Recovery Backups"), includingPropertiesForKeys: nil)
        #expect(backups.contains { folder in
            let file = folder.appendingPathComponent("catalog-generation-v1")
            return (try? Data(contentsOf: file)) == damaged
        })
    }
#endif

    @Test("A lost established generation gets a new epoch and rejects stale saves")
    func missingEstablishedGenerationRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = LibraryRepository(rootURL: root)
        try await initial.save(playlists: [Playlist(name: "Original")])
        let generation = root.appendingPathComponent("catalog-generation-v1")
        let marker = root.appendingPathComponent("catalog-generation-established-v1")
        #expect(FileManager.default.fileExists(atPath: marker.path))
        let stale = LibraryRepository(rootURL: root)
        _ = try await stale.load()
        try FileManager.default.removeItem(at: generation)
        let recovered = LibraryRepository(rootURL: root)
        #expect(try await recovered.load().document.playlists.map(\.name) == ["Original"])
        try await recovered.save(playlists: [Playlist(name: "New")])
        do { try await stale.save(playlists: []); Issue.record("Stale save accepted") }
        catch LibraryRepository.RepositoryError.staleOrganizedTrack { }
        #expect(try await LibraryRepository(rootURL: root).load().document.playlists.map(\.name) == ["New"])
        #expect(try String(contentsOf: generation, encoding: .utf8).hasPrefix("v2:"))
        let backups = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Recovery Backups"), includingPropertiesForKeys: nil)
        #expect(backups.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent("catalog-generation-established-v1").path) })
    }

#if DEBUG
    @Test("Legacy catalog acquires a generation and interrupted reservation invalidates stale readers")
    func persistentGenerationMigrationAndInterruption() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = LibraryRepository(rootURL: root)
        try await initial.save(document: LibraryDocument(playlists: [Playlist(name: "Original", description: "")]))
        let generationURL = root.appendingPathComponent("catalog-generation-v1")
        // Produce an actual pre-witness catalog, rather than deleting metadata
        // from a modern catalog and accidentally testing simultaneous loss.
        let manifest = root.appendingPathComponent("library-v1.json")
        var legacy = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        legacy.removeValue(forKey: "catalogGenerationEstablished")
        try JSONSerialization.data(withJSONObject: legacy).write(to: manifest, options: .atomic)
        try FileManager.default.removeItem(at: generationURL)
        // A legacy catalog has neither a generation nor its establishment marker.
        try FileManager.default.removeItem(at: root.appendingPathComponent("catalog-generation-established-v1"))
        let writer = LibraryRepository(rootURL: root)
        let stale = LibraryRepository(rootURL: root)
        #expect(try await writer.load().document.playlists.map(\.name) == ["Original"])
        _ = try await stale.load()
        let beforeReservation = try #require(UInt64(try String(contentsOf: generationURL, encoding: .utf8)))
        await writer.setGenerationReservationTestHook { throw CocoaError(.fileWriteUnknown) }
        do { try await writer.save(playlists: []); Issue.record("Interrupted write succeeded") } catch { }
        #expect(String(data: try Data(contentsOf: generationURL), encoding: .utf8) == String(beforeReservation + 1))
        do { try await stale.save(playlists: []); Issue.record("Stale writer accepted") }
        catch LibraryRepository.RepositoryError.staleOrganizedTrack { }
        await writer.setGenerationReservationTestHook(nil)
        let recovered = try await writer.load().document
        #expect(recovered.playlists.map(\.name) == ["Original"])
        try await writer.save(playlists: [Playlist(name: "Next", description: "")])
        let final = try await LibraryRepository(rootURL: root).load().document
        #expect(final.playlists.map(\.name) == ["Next"])
        let generation = try #require(UInt64(try String(contentsOf: generationURL, encoding: .utf8)))
        #expect(generation > 1)
    }
#endif

    @Test("An older complete snapshot cannot replace a newer same-repository edit")
    func oldCompleteDocumentCannotOverwriteSameRepositoryEdit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        let baseline = try await repository.load().document
        var proposed = baseline
        proposed.playlists = [Playlist(name: "Older operation", description: "")]
        try await repository.save(playlists: [Playlist(name: "Newer edit", description: "")])
        do {
            try await repository.save(document: proposed, expectedDocument: baseline)
            Issue.record("Stale full document was accepted")
        } catch LibraryRepository.RepositoryError.staleOrganizedTrack { }
        let actual = try await repository.load().document
        #expect(actual.playlists.map(\.name) == ["Newer edit"])
        var refreshed = actual
        refreshed.playlists.append(Playlist(name: "Retried", description: ""))
        try await repository.save(document: refreshed, expectedDocument: actual)
        #expect(try await repository.load().document.playlists.map(\.name) == ["Newer edit", "Retried"])
    }

#if DEBUG
    @Test("Catalog, history and queue recover together at each write boundary", arguments: [0, 1, 2, 3], [false, true])
    func catalogWriteRecoveryBoundaries(step: Int, diskFull: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        let first = Track(id: UUID(), title: "Old", artist: "A", album: "B", duration: 1,
                          fileSize: 1, managedPath: root.appendingPathComponent("old.wav").path,
                          sha256: "old", addedAt: .now, health: .missing)
        let second = Track(id: UUID(), title: "New", artist: "A", album: "B", duration: 1,
                           fileSize: 1, managedPath: root.appendingPathComponent("new.wav").path,
                           sha256: "new", addedAt: .now, health: .missing)
        var initial = LibraryDocument(tracks: [first, second])
        initial.playbackEvents = [PlaybackEvent(trackID: first.id, kind: .started)]
        initial.playbackQueue = PlaybackQueueState(trackIDs: [first.id], currentTrackID: first.id, position: 1)
        try await repository.save(document: initial)
        let baseline = try await repository.load().document
        var updated = baseline
        updated.tracks = [second]
        updated.playbackEvents = [PlaybackEvent(trackID: second.id, kind: .completed)]
        updated.playbackQueue = PlaybackQueueState(trackIDs: [second.id], currentTrackID: second.id, position: 3)
        updated.playlists = [Playlist(name: "Updated", description: "")]
        await repository.setCatalogWriteTestHook { stage in
            let match: Bool
            switch stage {
            case .journal: match = step == 0
            case .queue: match = step == 1
            case .events: match = step == 2
            case .manifest: match = step == 3
            }
            if match {
                if diskFull { throw POSIXError(.ENOSPC) }
                throw CocoaError(.fileWriteUnknown)
            }
        }
        do { try await repository.save(document: updated, expectedDocument: baseline); Issue.record("Expected interruption") } catch { }
        let journal = root.appendingPathComponent("catalog-write-journal-v1.json")
        #expect(FileManager.default.fileExists(atPath: journal.path))
        let reopened = LibraryRepository(rootURL: root)
        do { try await reopened.save(playlists: []); Issue.record("Write bypassed recovery") } catch { }
        let actual = try await reopened.load().document
        #expect(actual.tracks.map(\.id) == [second.id])
        #expect(actual.playbackEvents.map(\.trackID) == [second.id])
        #expect(actual.playbackQueue?.currentTrackID == second.id)
        #expect(actual.playlists.map(\.name) == ["Updated"])
        #expect(!FileManager.default.fileExists(atPath: journal.path))
        let again = try await LibraryRepository(rootURL: root).load().document
        #expect(again.tracks.map(\.id) == [second.id])
        #expect(again.playbackEvents.map(\.trackID) == [second.id])
        #expect(again.playbackQueue?.currentTrackID == second.id)
    }
#endif

#if DEBUG
    @Test("Interrupted import recovery retains its journal until the catalog is durable")
    func importRecoveryInterruptedBeforeCatalogPublish() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.mp3")
        let bytes = Data([0x49, 0x44, 0x33, 1, 2, 3])
        try bytes.write(to: source)
        let catalog = root.appendingPathComponent("Catalog")
        let importer = LibraryRepository(rootURL: catalog)
        _ = try await importer.load()
        let imported = await importer.importFiles([source], existing: [])
        let track = try #require(imported.imported.first)
        let recovering = LibraryRepository(rootURL: catalog)
        await recovering.setCatalogWriteTestHook { stage in
            if case .journal = stage { throw CocoaError(.fileWriteUnknown) }
        }
        do { _ = try await recovering.load(); Issue.record("Expected interruption") } catch { }
        #expect(FileManager.default.fileExists(atPath: catalog.appendingPathComponent("import-journal-v1.json").path))
        #expect(FileManager.default.fileExists(atPath: catalog.appendingPathComponent("catalog-write-journal-v1.json").path))
        let recovered = try await LibraryRepository(rootURL: catalog).load().document
        #expect(recovered.tracks.map(\.id) == [track.id])
        #expect(try Data(contentsOf: track.fileURL) == bytes)
        #expect(!FileManager.default.fileExists(atPath: catalog.appendingPathComponent("import-journal-v1.json").path))
        #expect(try await LibraryRepository(rootURL: catalog).load().document.tracks.count == 1)
    }
#endif

#if DEBUG
    @Test("Recovery preserves an unexpected replacement catalog and the journal")
    func catalogRecoveryRejectsUnrelatedManifest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        try await repository.save(document: LibraryDocument(playlists: [Playlist(name: "Original", description: "")]))
        let baseline = try await repository.load().document
        var updated = baseline
        updated.playlists = [Playlist(name: "Pending", description: "")]
        await repository.setCatalogWriteTestHook { stage in if case .journal = stage { throw CocoaError(.fileWriteUnknown) } }
        do { try await repository.save(document: updated, expectedDocument: baseline); Issue.record("Expected interruption") } catch { }
        var unrelated = baseline
        unrelated.playlists = [Playlist(name: "External", description: "")]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(unrelated)
        let manifest = root.appendingPathComponent("library-v1.json")
        try bytes.write(to: manifest, options: .atomic)
        let reopened = LibraryRepository(rootURL: root)
        do { _ = try await reopened.load(); Issue.record("Unrelated catalog overwritten") }
        catch is LibraryRepository.CatalogWriteRecoveryRequired { }
        #expect(try Data(contentsOf: manifest) == bytes)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("catalog-write-journal-v1.json").path))
    }

    @Test("Nested catalog and sync journals recover their matching tracks and tags")
    func nestedOverlayAndCatalogRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        let track = Track(id: UUID(), title: "T", artist: "A", album: "B", duration: 1,
                          fileSize: 1, managedPath: root.appendingPathComponent("song.wav").path,
                          sha256: "hash", addedAt: .now, health: .missing)
        try await repository.save(tracks: [track])
        let previous = try await repository.load().document.tracks
        var updated = previous; updated[0].rating = 4
        await repository.setCatalogWriteTestHook { stage in if case .queue = stage { throw CocoaError(.fileWriteUnknown) } }
        do { try await repository.saveSynchronizedOverlay(previous: previous, updated: updated, tags: [track.id: ["new"]]); Issue.record("Expected interruption") } catch { }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("catalog-write-journal-v1.json").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("device-sync-overlay-journal-v1.json").path))
        let recovered = try await LibraryRepository(rootURL: root).load().document
        #expect(recovered.tracks.first?.rating == 4)
        let tags = try JSONDecoder().decode([UUID: [String]].self, from: Data(contentsOf: root.appendingPathComponent("device-sync-tags-v1.json")))
        #expect(tags[track.id] == ["new"])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("catalog-write-journal-v1.json").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("device-sync-overlay-journal-v1.json").path))
    }
#endif

#if DEBUG
    @Test("Clearing registrations recovers safely at every catalog write boundary", arguments: [0, 1, 2, 3])
    func clearRegistrationRecoveryBoundaries(step: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("pending.mp3")
        let pendingBytes = Data([0x49, 0x44, 0x33, 1, 2, 3])
        try pendingBytes.write(to: source)
        let catalog = root.appendingPathComponent("Catalog")
        let media = root.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let audio = media.appendingPathComponent("existing.mp3")
        let originalBytes = Data("existing".utf8)
        try originalBytes.write(to: audio)
        let track = Track(id: UUID(), title: "T", artist: "A", album: "B", duration: 1,
                          fileSize: Int64(originalBytes.count), managedPath: audio.path,
                          sha256: try LibraryRepository.sha256(of: audio), addedAt: .now, health: .verified)
        let repository = LibraryRepository(rootURL: catalog, mediaURL: media)
        var initial = LibraryDocument(tracks: [track])
        initial.playlists = [Playlist(name: "Keep", entries: [PlaylistEntry(trackID: track.id)])]
        initial.playbackEvents = [PlaybackEvent(trackID: track.id, kind: .started)]
        initial.playbackQueue = PlaybackQueueState(trackIDs: [track.id], currentTrackID: track.id, position: 1)
        try await repository.save(document: initial)
        let imported = await repository.importFiles([source], existing: [track])
        let pending = try #require(imported.imported.first)
        await repository.setCatalogWriteTestHook { stage in
            let match: Bool
            switch stage {
            case .journal: match = step == 0
            case .queue: match = step == 1
            case .events: match = step == 2
            case .manifest: match = step == 3
            }
            if match { throw CocoaError(.fileWriteUnknown) }
        }
        do { try await repository.clearAllRegistrations(); Issue.record("Expected interruption") } catch { }
        #expect(FileManager.default.fileExists(atPath: catalog.appendingPathComponent("catalog-write-journal-v1.json").path))
        let restarted = LibraryRepository(rootURL: catalog, mediaURL: media)
        let recovered = try await restarted.load().document
        #expect(recovered.tracks.isEmpty)
        #expect(recovered.playlists.first?.entries.isEmpty == true)
        #expect(recovered.playbackEvents.isEmpty)
        #expect(recovered.playbackQueue == PlaybackQueueState())
        #expect(try Data(contentsOf: audio) == originalBytes)
        #expect(try Data(contentsOf: pending.fileURL) == pendingBytes)
        #expect(!FileManager.default.fileExists(atPath: catalog.appendingPathComponent("import-journal-v1.json").path))
        #expect(!FileManager.default.fileExists(atPath: catalog.appendingPathComponent("catalog-write-journal-v1.json").path))
        try Data("corrupt".utf8).write(to: catalog.appendingPathComponent("library-v1.json"))
        let backup = try await LibraryRepository(rootURL: catalog, mediaURL: media).load()
        #expect(backup.recoveredFromBackup)
        #expect(backup.document.tracks.isEmpty)
        #expect(try Data(contentsOf: audio) == originalBytes)
    }
#endif

    @Test("Starting an import reserves a generation before catalog publication")
    func importReservationInvalidatesOlderRepository() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = root.appendingPathComponent("Catalog")
        let source = root.appendingPathComponent("source.mp3")
        let bytes = Data([0x49, 0x44, 0x33, 4, 5, 6])
        try bytes.write(to: source)
        let importer = LibraryRepository(rootURL: catalog)
        _ = try await importer.load()
        let stale = LibraryRepository(rootURL: catalog)
        _ = try await stale.load()
        let generationURL = catalog.appendingPathComponent("catalog-generation-v1")
        let before = try #require(UInt64(try String(contentsOf: generationURL, encoding: .utf8)))
        let result = await importer.importFiles([source], existing: [])
        let track = try #require(result.imported.first)
        let after = try #require(UInt64(try String(contentsOf: generationURL, encoding: .utf8)))
        #expect(after > before)
        do { try await stale.save(playlists: []); Issue.record("Stale writer accepted after import") }
        catch LibraryRepository.RepositoryError.staleOrganizedTrack { }
        let recovered = try await stale.load().document
        #expect(recovered.tracks.map(\.id) == [track.id])
        #expect(try Data(contentsOf: track.fileURL) == bytes)
    }

    @Test("An unobserved repository cannot replace an existing catalog")
    func fullReplacementRequiresBaseline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = LibraryRepository(rootURL: root)
        let original = LibraryDocument(playlists: [Playlist(name: "Original", description: "")])
        try await first.save(document: original)
        let second = LibraryRepository(rootURL: root)
        do {
            try await second.save(document: LibraryDocument())
            Issue.record("Unobserved replacement accepted")
        } catch LibraryRepository.RepositoryError.staleOrganizedTrack { }
        let loaded = try await second.load().document
        #expect(loaded.playlists.map(\.name) == ["Original"])
        var updated = loaded
        updated.playlists.append(Playlist(name: "Next", description: ""))
        try await second.save(document: updated)
        #expect(try await second.load().document.playlists.map(\.name) == ["Original", "Next"])
    }

    @Test("A stale repository cannot overwrite playlist, history, or queue updates", arguments: ["playlist", "history", "queue"])
    func staleSidecarAndPlaylistWriters(operation: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = LibraryRepository(rootURL: root)
        let track = Track(id: UUID(), title: "T", artist: "A", album: "B", duration: 1,
                          fileSize: 5, managedPath: root.appendingPathComponent("song.wav").path,
                          sha256: "hash", addedAt: .now, health: .missing)
        try await first.save(tracks: [track])
        _ = try await first.load()
        let second = LibraryRepository(rootURL: root)
        _ = try await second.load()
        switch operation {
        case "playlist": try await second.save(playlists: [Playlist(name: "New", description: "")])
        case "history": try await second.recordPlaybackEvent(PlaybackEvent(trackID: track.id, kind: .started))
        default: try await second.save(playbackQueue: PlaybackQueueState(trackIDs: [track.id], currentTrackID: track.id, position: 3))
        }
        do {
            switch operation {
            case "playlist": try await first.save(playlists: [])
            case "history": try await first.save(playbackEvents: [])
            default: try await first.save(playbackQueue: PlaybackQueueState())
            }
            Issue.record("A stale \(operation) writer was accepted")
        } catch LibraryRepository.RepositoryError.staleOrganizedTrack { }
        let actual = try await LibraryRepository(rootURL: root).load().document
        switch operation {
        case "playlist": #expect(actual.playlists.map(\.name) == ["New"])
        case "history": #expect(actual.playbackEvents.count == 1)
        default: #expect(actual.playbackQueue?.currentTrackID == track.id)
        }
    }

    @Test("Storage locks time out without modifying data and can be retried", arguments: [".catalog-transaction-v1.lock", ".import-transaction-v1.lock"])
    func storageLockTimeoutAndRetry(name: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = LibraryRepository(rootURL: root)
        try await seed.save(playlists: [Playlist(name: "Original", description: "")])
        let manifest = root.appendingPathComponent("library-v1.json")
        let original = try Data(contentsOf: manifest)
        let lockURL = root.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", "import fcntl,sys; f=open(sys.argv[1], 'a+'); fcntl.flock(f, fcntl.LOCK_EX); print('ready',flush=True); sys.stdin.buffer.read(1)", lockURL.path]
        let input = Pipe(); let output = Pipe()
        process.standardInput = input; process.standardOutput = output
        try process.run()
        defer { if process.isRunning { try? input.fileHandleForWriting.close(); process.terminate() } }
        let ready = try #require(try output.fileHandleForReading.read(upToCount: 6))
        #expect(String(data: ready, encoding: .utf8) == "ready\n")
        let blocked = LibraryRepository(rootURL: root, lockWaitTimeout: 0.15)
        do { _ = try await blocked.load(); Issue.record("Lock wait did not time out") }
        catch LibraryRepository.RepositoryError.storageLockTimedOut { }
        #expect(try Data(contentsOf: manifest) == original)
        try input.fileHandleForWriting.write(contentsOf: Data([1]))
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(try await blocked.load().document.playlists.map(\.name) == ["Original"])
    }

    @Test("Storage lock waits can be cancelled", arguments: [".catalog-transaction-v1.lock", ".import-transaction-v1.lock"])
    func storageLockCancellation(name: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = LibraryRepository(rootURL: root)
        _ = try await seed.load()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", "import fcntl,sys; f=open(sys.argv[1], 'a+'); fcntl.flock(f, fcntl.LOCK_EX); print('ready',flush=True); sys.stdin.buffer.read(1)", root.appendingPathComponent(name).path]
        let input = Pipe(); let output = Pipe()
        process.standardInput = input; process.standardOutput = output
        try process.run()
        defer { if process.isRunning { try? input.fileHandleForWriting.close(); process.terminate() } }
        let ready = try #require(try output.fileHandleForReading.read(upToCount: 6))
        #expect(String(data: ready, encoding: .utf8) == "ready\n")
        let blocked = LibraryRepository(rootURL: root, lockWaitTimeout: 3)
        let loading = Task { try await blocked.load() }
        try await Task.sleep(for: .milliseconds(100))
        loading.cancel()
        do { _ = try await loading.value; Issue.record("Cancelled lock wait succeeded") }
        catch is CancellationError { }
        try input.fileHandleForWriting.write(contentsOf: Data([1]))
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        _ = try await blocked.load()
    }

    @Test("A separate process holding the catalog lock blocks repository writes")
    func processLockProtectsRepository() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        try await repository.save(tracks: [])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", "import fcntl,sys; f=open(sys.argv[1], 'a+'); fcntl.flock(f, fcntl.LOCK_EX); print('ready',flush=True); sys.stdin.buffer.read(1)", root.appendingPathComponent(".catalog-transaction-v1.lock").path]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        defer { if process.isRunning { try? input.fileHandleForWriting.close(); process.terminate() } }
        let ready = try #require(try output.fileHandleForReading.read(upToCount: 6))
        #expect(String(data: ready, encoding: .utf8) == "ready\n")
        var finished = false
        let task = Task { @MainActor in
            try await repository.save(playlists: [Playlist(name: "After lock", description: "")])
            finished = true
        }
        try await Task.sleep(for: .milliseconds(250))
        #expect(!finished)
        try input.fileHandleForWriting.write(contentsOf: Data([1]))
        try await task.value
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(try await repository.load().document.playlists.map(\.name) == ["After lock"])
    }

    @Test("A process update under the lock invalidates a waiting stale writer")
    func processChangeInvalidatesWaitingWriter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        try await repository.save(tracks: [])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", "import fcntl,sys,os; f=open(sys.argv[1], 'a+'); fcntl.flock(f, fcntl.LOCK_EX); print('ready',flush=True); sys.stdin.buffer.read(1); p=sys.argv[2]; d=open(p,'rb').read(); t=p+'.test'; open(t,'wb').write(d); os.replace(t,p)", root.appendingPathComponent(".catalog-transaction-v1.lock").path, root.appendingPathComponent("playback-queue-v1.json").path]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        defer { if process.isRunning { try? input.fileHandleForWriting.close(); process.terminate() } }
        let ready = try #require(try output.fileHandleForReading.read(upToCount: 6))
        #expect(String(data: ready, encoding: .utf8) == "ready\n")
        let task = Task { () -> Bool in
            do {
                try await repository.save(playlists: [Playlist(name: "Stale", description: "")])
                return false
            } catch LibraryRepository.RepositoryError.staleOrganizedTrack { return true }
            catch { Issue.record("Unexpected error: \(error)"); return false }
        }
        try await Task.sleep(for: .milliseconds(250))
        try input.fileHandleForWriting.write(contentsOf: Data([1]))
        #expect(await task.value)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let document = try await repository.load().document
        #expect(document.playlists.isEmpty)
        try await repository.save(playlists: [Playlist(name: "Fresh", description: "")])
        #expect(try await repository.load().document.playlists.map(\.name) == ["Fresh"])
    }

#if DEBUG
    @Test("An active asynchronous import cannot be mistaken for interrupted recovery")
    func activeImportKeepsItsStagedFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("Media")
        let catalog = PortableLibraryStorage(mediaURL: media).rootURL
        let source = root.appendingPathComponent("source.wav")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("audio sample".utf8).write(to: source)
        let first = LibraryRepository(rootURL: catalog, mediaURL: media)
        _ = try await first.load()
        let gate = StorageWriteGate(fails: false)
        defer { gate.resume.signal() }
        await first.setImportStagedTestGate {
            gate.entered.signal()
            _ = await gate.waitOffExecutor { gate.waitUntilResumed() }
        }
        let importing = Task { await first.importFiles([source], existing: []) }
        let reached = await gate.waitOffExecutor { gate.waitUntilEntered() }
        #expect(reached)
        guard reached else { gate.resume.signal(); _ = await importing.value; return }
        do { _ = try await first.load(); Issue.record("Same actor recovered an active import") }
        catch LibraryRepository.RepositoryError.importInProgress { }
        let second = LibraryRepository(rootURL: catalog, mediaURL: media)
        var loaded = false
        let loading = Task { @MainActor in
            let result = try await second.load()
            loaded = true
            return result
        }
        try await Task.sleep(for: .milliseconds(250))
        #expect(!loaded)
        do { try await first.save(playlists: []); Issue.record("Same actor entered a conflicting write") }
        catch LibraryRepository.RepositoryError.importInProgress { }
        let competingReference = await first.referenceFilesInPlace([source], existing: [], copyExternalFiles: true)
        #expect(competingReference.imported.isEmpty)
        #expect(competingReference.issues.count == 1)
        let third = LibraryRepository(rootURL: catalog, mediaURL: media)
        var referenceFinished = false
        let referenceTask = Task { @MainActor in
            let result = await third.referenceFilesInPlace([source], existing: [], copyExternalFiles: true)
            referenceFinished = true
            return result
        }
        try await Task.sleep(for: .milliseconds(250))
        #expect(!referenceFinished)
        gate.resume.signal()
        let imported = await importing.value
        let recovered = try await loading.value
        let reference = await referenceTask.value
        #expect(reference.imported.count == 1)
        #expect(reference.issues.isEmpty)
        #expect(imported.imported.count == 1)
        let track = try #require(imported.imported.first)
        #expect(try Data(contentsOf: track.fileURL) == Data("audio sample".utf8))
        #expect(recovered.document.tracks.contains { $0.id == track.id })
    }
#endif

    @Test("An older repository rejects tracks after another repository organizes media")
    func staleTracksAcrossRepositories() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("song.wav")
        let bytes = Data("audio".utf8)
        try bytes.write(to: source)
        let track = Track(id: UUID(), title: "T", artist: "A", album: "B", duration: 1,
                          fileSize: 5, managedPath: source.path,
                          sha256: try LibraryRepository.sha256(of: source), addedAt: .now, health: .verified)
        let catalog = PortableLibraryStorage(mediaURL: root).rootURL
        let first = LibraryRepository(rootURL: catalog, mediaURL: root)
        try await first.save(tracks: [track])
        let stale = try await first.load().document.tracks
        let second = LibraryRepository(rootURL: catalog, mediaURL: root)
        let document = try await second.load().document
        let preview = try await second.planMediaOrganization(tracks: document.tracks, destinationRootURL: root)
        _ = try await second.executeMediaOrganization(document: document, preview: preview)
        let destination = try #require(preview.items.first?.destinationURL)
        var proposed = stale
        proposed[0].isFavorite = true
        do { try await first.save(tracks: proposed); Issue.record("Stale repository overwrote the moved path") }
        catch LibraryRepository.RepositoryError.staleOrganizedTrack { }
        let actual = try await LibraryRepository(rootURL: catalog, mediaURL: root).load().document
        #expect(actual.tracks.first?.managedPath == destination.path)
        #expect(try Data(contentsOf: destination) == bytes)
        var refreshed = try await first.load().document.tracks
        refreshed[0].isFavorite = true
        try await first.save(tracks: refreshed)
        let saved = try await LibraryRepository(rootURL: catalog, mediaURL: root).load().document
        #expect(saved.tracks.first?.managedPath == destination.path)
        #expect(saved.tracks.first?.isFavorite == true)
    }

    @Test("A rejected stale favorite save reloads the organized track path")
    func favoriteReloadsAfterOrganizedPathConflict() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("song.wav")
        try Data("audio".utf8).write(to: source)
        let track = Track(id: UUID(), title: "T", artist: "A", album: "B", duration: 1,
                          fileSize: 5, managedPath: source.path,
                          sha256: try LibraryRepository.sha256(of: source), addedAt: .now, health: .verified)
        let repository = LibraryRepository(rootURL: PortableLibraryStorage(mediaURL: root).rootURL, mediaURL: root)
        try await repository.save(tracks: [track])
        let store = LibraryStore(repository: repository)
        await store.load()
        let document = try await repository.load().document
        let preview = try await repository.planMediaOrganization(tracks: document.tracks, destinationRootURL: root)
        _ = try await repository.executeMediaOrganization(document: document, preview: preview)
        let destination = try #require(preview.items.first?.destinationURL)
        await store.setFavorite(true, for: track.id)
        #expect(store.tracks.first?.managedPath == destination.path)
        #expect(store.tracks.first?.isFavorite == false)
        if case .failed = store.activity {} else { Issue.record("Expected a visible conflict") }
        await store.setFavorite(true, for: track.id)
        #expect(store.tracks.first?.isFavorite == true)
        #expect(try await repository.load().document.tracks.first?.managedPath == destination.path)
    }

    @Test("An old history-clear failure cannot restore old events over the new library")
    func oldHistoryFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("First")
        let second = root.appendingPathComponent("Second")
        let firstCatalog = PortableLibraryStorage(mediaURL: first).rootURL
        let secondCatalog = PortableLibraryStorage(mediaURL: second).rootURL
        let gate = StorageWriteGate()
        let manager = DelayedStorageFailureFileManager(root: firstCatalog, gate: gate)
        defer { gate.resume.signal() }
        let oldRepository = LibraryRepository(rootURL: firstCatalog, mediaURL: first, fileManager: manager)
        let newRepository = LibraryRepository(rootURL: secondCatalog, mediaURL: second)
        let oldEvent = PlaybackEvent(trackID: UUID(), kind: .completed)
        let newEvent = PlaybackEvent(trackID: UUID(), kind: .started)
        let oldTrack = Track(id: oldEvent.trackID, title: "First", artist: "A", album: "A", duration: 10,
                             fileSize: 1, managedPath: first.appendingPathComponent("a.mp3").path,
                             sha256: "a", addedAt: .now, health: .missing)
        let newTrack = Track(id: newEvent.trackID, title: "Second", artist: "B", album: "B", duration: 10,
                             fileSize: 1, managedPath: second.appendingPathComponent("b.mp3").path,
                             sha256: "b", addedAt: .now, health: .missing)
        try await oldRepository.save(tracks: [oldTrack])
        try await newRepository.save(tracks: [newTrack])
        try await oldRepository.recordPlaybackEvent(oldEvent)
        try await newRepository.recordPlaybackEvent(newEvent)
        let newID = try await newRepository.load().document.libraryID
        let store = LibraryStore(repository: oldRepository)
        await store.load()
        gate.arm()
        let clear = Task { await store.clearPlaybackHistory() }
        let reached = await Task.detached { @Sendable [gate] in gate.waitUntilEntered() }.value
        #expect(reached)
        guard reached else { gate.resume.signal(); await clear.value; return }
        await store.switchLibrary(catalogURL: secondCatalog, mediaURL: second)
        #expect(store.isUsingCatalog(at: secondCatalog))
        #expect(try await newRepository.load().document.libraryID == newID)
        #expect(store.playbackEvents.map(\.id) == [newEvent.id])
        gate.resume.signal()
        await clear.value
        #expect(store.playbackEvents.map(\.id) == [newEvent.id])
        #expect(try await newRepository.load().document.playbackEvents.map(\.id) == [newEvent.id])
        #expect(try await oldRepository.load().document.playbackEvents.map(\.id) == [oldEvent.id])
    }
    @Test("An old successful edit cannot overwrite the new library", arguments: ["metadata", "playlist"])
    func oldEditCompletion(operation: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("First")
        let second = root.appendingPathComponent("Second")
        let firstCatalog = PortableLibraryStorage(mediaURL: first).rootURL
        let secondCatalog = PortableLibraryStorage(mediaURL: second).rootURL
        let gate = StorageWriteGate(fails: false)
        defer { gate.resume.signal() }
        let manager = DelayedStorageFailureFileManager(root: firstCatalog, gate: gate)
        let oldRepository = LibraryRepository(rootURL: firstCatalog, mediaURL: first, fileManager: manager)
        let newRepository = LibraryRepository(rootURL: secondCatalog, mediaURL: second)
        let oldTrack = Track(id: UUID(), title: "First", artist: "A", album: "A", duration: 10,
                             fileSize: 1, managedPath: first.appendingPathComponent("a.mp3").path,
                             sha256: "a", addedAt: .now, health: .missing)
        let newTrack = Track(id: UUID(), title: "Second", artist: "B", album: "B", duration: 10,
                             fileSize: 1, managedPath: second.appendingPathComponent("b.mp3").path,
                             sha256: "b", addedAt: .now, health: .missing)
        try await oldRepository.save(tracks: [oldTrack])
        try await newRepository.save(tracks: [newTrack])
        let store = LibraryStore(repository: oldRepository)
        await store.load()
        gate.arm()
        let edit = Task { () -> Bool in
            do {
                if operation == "metadata" { try await store.updateTrackLyrics(id: oldTrack.id, lyrics: nil) }
                else { _ = try await store.createPlaylist(name: "Old edit", description: "", artworkData: nil) }
                return false
            } catch is CancellationError { return true }
            catch { Issue.record("Unexpected edit error: \(error)"); return false }
        }
        let reached = await Task.detached { @Sendable [gate] in gate.waitUntilEntered() }.value
        #expect(reached)
        guard reached else { gate.resume.signal(); _ = await edit.value; return }
        await store.switchLibrary(catalogURL: secondCatalog, mediaURL: second)
        gate.resume.signal()
        #expect(await edit.value, "A stale caller must receive cancellation, not UI success")
        #expect(store.tracks.map(\.id) == [newTrack.id])
        #expect(store.playlists.isEmpty)
        let saved = try await newRepository.load().document
        #expect(saved.tracks.map(\.id) == [newTrack.id])
        #expect(saved.playlists.isEmpty)
        let oldSaved = try await oldRepository.load().document
        #expect(oldSaved.tracks.map(\.id) == [oldTrack.id])
        if operation == "playlist" { #expect(oldSaved.playlists.map(\.name) == ["Old edit"]) }
    }

    @Test("Old overlay completion and failure stay with their original library", arguments: [
        "apply-success", "apply-failure", "undo-success", "undo-failure"
    ])
    func oldOverlayCompletion(operation: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("First")
        let second = root.appendingPathComponent("Second")
        let firstCatalog = PortableLibraryStorage(mediaURL: first).rootURL
        let secondCatalog = PortableLibraryStorage(mediaURL: second).rootURL
        let fails = operation.hasSuffix("failure")
        let isUndo = operation.hasPrefix("undo")
        let gate = StorageWriteGate(fails: fails)
        defer { gate.resume.signal() }
        let manager = DelayedStorageFailureFileManager(root: firstCatalog, gate: gate)
        let oldRepository = LibraryRepository(rootURL: firstCatalog, mediaURL: first, fileManager: manager)
        let newRepository = LibraryRepository(rootURL: secondCatalog, mediaURL: second)
        let oldTrack = Track(id: UUID(), title: "First", artist: "A", album: "A", duration: 10,
                             fileSize: 1, managedPath: first.appendingPathComponent("a.mp3").path,
                             sha256: "a", addedAt: .now, health: .missing)
        let newTrack = Track(id: UUID(), title: "Second", artist: "B", album: "B", duration: 10,
                             fileSize: 1, managedPath: second.appendingPathComponent("b.mp3").path,
                             sha256: "b", addedAt: .now, health: .missing)
        try await oldRepository.save(tracks: [oldTrack])
        try await newRepository.save(tracks: [newTrack])
        let newTagsURL = secondCatalog.appendingPathComponent("device-sync-tags-v1.json")
        try JSONEncoder().encode([newTrack.id: ["New tag"]]).write(to: newTagsURL)
        let store = LibraryStore(repository: oldRepository)
        await store.load()
        let before = DeviceSyncTrackOverlay(
            sourceKey: "old", title: "First", artist: "A", album: "A", duration: 10,
            isFavorite: false, rating: 0, playCount: 0, skipCount: 0,
            lastPlayedAt: nil, displayTags: [], updatedAt: .now
        )
        var after = before
        after.rating = 4
        after.displayTags = ["Old tag"]
        let application = DeviceSyncOverlayApplication(
            trackID: oldTrack.id, overlay: after, fields: [.rating, .displayTags]
        )
        if isUndo { #expect(await store.applySyncedTrackOverlays([application]) == 1) }
        let change = DeviceSyncAuditChange(
            trackID: oldTrack.id, title: oldTrack.title, before: before,
            after: after, fields: [.rating, .displayTags]
        )
        gate.arm()
        let operationTask = Task {
            if isUndo { return await store.undoSyncedTrackOverlays([change]).restoredFieldCount }
            return await store.applySyncedTrackOverlays([application])
        }
        let reached = await Task.detached { @Sendable [gate] in gate.waitUntilEntered() }.value
        #expect(reached)
        guard reached else { gate.resume.signal(); _ = await operationTask.value; return }
        await store.switchLibrary(catalogURL: secondCatalog, mediaURL: second)
        #expect(store.tracks.map(\.id) == [newTrack.id])
        #expect(store.syncedDisplayTags[newTrack.id] == ["New tag"])
        gate.resume.signal()
        #expect(await operationTask.value == 0)
        #expect(store.tracks.map(\.id) == [newTrack.id])
        #expect(store.syncedDisplayTags == [newTrack.id: ["New tag"]])
        let savedNew = try await newRepository.load().document
        #expect(savedNew.tracks.map(\.id) == [newTrack.id])
        let newTags = try JSONDecoder().decode([UUID: [String]].self, from: Data(contentsOf: newTagsURL))
        #expect(newTags == [newTrack.id: ["New tag"]])
        let savedOld = try await oldRepository.load().document
        let expectedRating = (isUndo ? fails : !fails) ? 4 : 0
        #expect(savedOld.tracks.first?.rating == expectedRating)
        let oldTagsURL = firstCatalog.appendingPathComponent("device-sync-tags-v1.json")
        if isUndo || !fails {
            let oldTags = try JSONDecoder().decode([UUID: [String]].self, from: Data(contentsOf: oldTagsURL))
            #expect(oldTags[oldTrack.id] == (expectedRating == 4 ? ["Old tag"] : nil))
        }
    }

    @Test("Failed storage switch preserves the outcome of an in-flight overlay", arguments: [false, true])
    func failedSwitchDuringOverlay(writeFails: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = root.appendingPathComponent("catalog", isDirectory: true)
        let gate = StorageWriteGate(fails: writeFails)
        defer { gate.resume.signal() }
        let repository = LibraryRepository(rootURL: catalog, fileManager: DelayedStorageFailureFileManager(root: catalog, gate: gate))
        let track = Track(id: UUID(), title: "A", artist: "B", album: "C", duration: 10,
                          fileSize: 1, managedPath: root.appendingPathComponent("a.mp3").path,
                          sha256: "a", addedAt: .now, health: .missing)
        try await repository.save(tracks: [track])
        let store = LibraryStore(repository: repository)
        await store.load()
        let overlay = DeviceSyncTrackOverlay(sourceKey: "phone", title: "A", artist: "B", album: "C",
            duration: 10, isFavorite: false, rating: 4, playCount: 0, skipCount: 0,
            lastPlayedAt: nil, displayTags: ["tag"], updatedAt: .now)
        gate.arm()
        let operation = Task { await store.applySyncedTrackOverlays([
            DeviceSyncOverlayApplication(trackID: track.id, overlay: overlay, fields: [.rating, .displayTags])
        ]) }
        let reached = await Task.detached { @Sendable [gate] in gate.waitUntilEntered() }.value
        #expect(reached)
        guard reached else { gate.resume.signal(); _ = await operation.value; return }
        let blocker = root.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: blocker)
        await store.switchLibrary(catalogURL: blocker.appendingPathComponent("catalog"), mediaURL: blocker)
        #expect(store.isUsingCatalog(at: catalog))
        gate.resume.signal()
        #expect(await operation.value == (writeFails ? 0 : 1))
        #expect(store.tracks.first?.rating == (writeFails ? 0 : 4))
        #expect((try await repository.load().document.tracks.first?.rating) == (writeFails ? 0 : 4))
        #expect(store.syncedDisplayTags[track.id] == (writeFails ? nil : ["tag"]))
    }

    @Test("Unwritable tag destination does not commit the catalog", arguments: [false, true])
    func tagPreparationFails(isUndo: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        let track = Track(id: UUID(), title: "A", artist: "B", album: "C", duration: 10,
                          fileSize: 1, managedPath: root.appendingPathComponent("a.mp3").path,
                          sha256: "a", addedAt: .now, health: .missing)
        try await repository.save(tracks: [track])
        let store = LibraryStore(repository: repository)
        await store.load()
        let before = DeviceSyncTrackOverlay(sourceKey: "phone", title: "A", artist: "B", album: "C",
            duration: 10, isFavorite: false, rating: 0, playCount: 0, skipCount: 0,
            lastPlayedAt: nil, displayTags: [], updatedAt: .now)
        var after = before; after.rating = 4; after.displayTags = ["tag"]
        let application = DeviceSyncOverlayApplication(trackID: track.id, overlay: after, fields: [.rating, .displayTags])
        if isUndo { #expect(await store.applySyncedTrackOverlays([application]) == 1) }
        let tagURL = root.appendingPathComponent("device-sync-tags-v1.json")
        if FileManager.default.fileExists(atPath: tagURL.path) { try FileManager.default.removeItem(at: tagURL) }
        try FileManager.default.createDirectory(at: tagURL, withIntermediateDirectories: false)
        if isUndo {
            let change = DeviceSyncAuditChange(trackID: track.id, title: track.title, before: before, after: after, fields: [.rating, .displayTags])
            #expect(await store.undoSyncedTrackOverlays([change]).restoredFieldCount == 0)
        } else { #expect(await store.applySyncedTrackOverlays([application]) == 0) }
        let expected = isUndo ? 4 : 0
        #expect(store.tracks.first?.rating == expected)
        #expect((try await repository.load().document.tracks.first?.rating) == expected)
        #expect(store.syncedDisplayTags[track.id] == (isUndo ? ["tag"] : nil))
    }

    @Test("Failed final tag publication restores the prior catalog")
    func tagPublicationFailsAfterCatalogWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = StorageWriteGate(fails: false)
        defer { gate.resume.signal() }
        let manager = DelayedStorageFailureFileManager(root: root, gate: gate)
        let repository = LibraryRepository(rootURL: root, fileManager: manager)
        let track = Track(id: UUID(), title: "A", artist: "B", album: "C", duration: 10,
                          fileSize: 1, managedPath: root.appendingPathComponent("a.mp3").path,
                          sha256: "a", addedAt: .now, health: .missing)
        try await repository.save(tracks: [track])
        let store = LibraryStore(repository: repository)
        await store.load()
        let overlay = DeviceSyncTrackOverlay(sourceKey: "phone", title: "A", artist: "B", album: "C",
            duration: 10, isFavorite: false, rating: 4, playCount: 0, skipCount: 0,
            lastPlayedAt: nil, displayTags: ["tag"], updatedAt: .now)
        gate.arm()
        let operation = Task { await store.applySyncedTrackOverlays([
            DeviceSyncOverlayApplication(trackID: track.id, overlay: overlay, fields: [.rating, .displayTags])
        ]) }
        let reached = await Task.detached { @Sendable [gate] in gate.waitUntilEntered() }.value
        #expect(reached)
        guard reached else { gate.resume.signal(); _ = await operation.value; return }
        let target = root.appendingPathComponent("device-sync-tags-v1.json")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        gate.resume.signal()
        #expect(await operation.value == 0)
        #expect(store.tracks.first?.rating == 0)
        #expect(store.syncedDisplayTags[track.id] == nil)
        #expect((try await repository.load().document.tracks.first?.rating) == 0)
        #expect(!((try FileManager.default.contentsOfDirectory(atPath: root.path)).contains { $0.hasPrefix(".device-sync-tags-") }))
    }

    @Test("Overlay rollback does not overwrite a newer track edit")
    func rollbackRefusesNewerTrackEdit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        let original = Track(id: UUID(), title: "A", artist: "B", album: "C", duration: 10,
                             fileSize: 1, managedPath: root.appendingPathComponent("a.mp3").path,
                             sha256: "a", addedAt: .now, health: .missing)
        var overlay = original; overlay.rating = 4
        var newer = overlay; newer.title = "Newer edit"
        try await repository.save(tracks: [newer])
        #expect(try await !repository.restoreOverlayTracksIfUnchanged(expected: [overlay], previous: [original]))
        let saved = try await repository.load().document.tracks
        #expect(saved.first?.id == newer.id)
        #expect(saved.first?.title == "Newer edit")
        #expect(saved.first?.rating == 4)
    }

    @Test("Duplicate resolution completion stays with its starting library", arguments: [false, true])
    func duplicateResolutionAfterSwitch(writeFails: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("First", isDirectory: true)
        let second = root.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let firstCatalog = PortableLibraryStorage(mediaURL: first).rootURL
        let secondCatalog = PortableLibraryStorage(mediaURL: second).rootURL
        let gate = StorageWriteGate(fails: writeFails)
        defer { gate.resume.signal() }
        let manager = DelayedStorageFailureFileManager(root: firstCatalog, gate: gate)
        let oldRepository = LibraryRepository(rootURL: firstCatalog, mediaURL: first, fileManager: manager)
        let newRepository = LibraryRepository(rootURL: secondCatalog, mediaURL: second)
        let source = first.appendingPathComponent("keep.wav")
        let other = first.appendingPathComponent("remove.wav")
        try Data("identical".utf8).write(to: source)
        try Data("identical".utf8).write(to: other)
        let hash = try LibraryRepository.sha256(of: source)
        let keep = Track(id: UUID(), title: "Keep", artist: "A", album: "A", duration: 10,
                         fileSize: 9, managedPath: source.path, sha256: hash, addedAt: .now, health: .verified)
        let remove = Track(id: UUID(), title: "Copy", artist: "A", album: "A", duration: 10,
                           fileSize: 9, managedPath: other.path, sha256: hash, addedAt: .now, health: .verified)
        let replacement = Track(id: UUID(), title: "New", artist: "B", album: "B", duration: 10,
                                fileSize: 1, managedPath: second.appendingPathComponent("new.wav").path,
                                sha256: "new", addedAt: .now, health: .missing)
        try await oldRepository.save(tracks: [keep, remove])
        try await newRepository.save(tracks: [replacement])
        let store = LibraryStore(repository: oldRepository)
        await store.load()
        let group = try #require(store.duplicateGroups.first)
        gate.arm()
        let operation = Task { () -> Bool in
            do { _ = try await store.resolveDuplicateGroup(group.id, keeping: keep.id, moveManagedFilesToTrash: true); return false }
            catch is CancellationError { return true }
            catch { Issue.record("Unexpected error: \(error)"); return false }
        }
        let reached = await Task.detached { @Sendable [gate] in gate.waitUntilEntered() }.value
        #expect(reached)
        guard reached else { gate.resume.signal(); _ = await operation.value; return }
        await store.switchLibrary(catalogURL: secondCatalog, mediaURL: second)
        gate.resume.signal()
        #expect(await operation.value)
        #expect(store.tracks.map(\.id) == [replacement.id])
        #expect(try await newRepository.load().document.tracks.map(\.id) == [replacement.id])
        #expect(try await oldRepository.load().document.tracks.count == (writeFails ? 2 : 1))
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test("Media organization completion stays with its starting library", arguments: [false, true])
    func mediaOrganizationAfterSwitch(writeFails: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("First", isDirectory: true)
        let second = root.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let firstCatalog = PortableLibraryStorage(mediaURL: first).rootURL
        let secondCatalog = PortableLibraryStorage(mediaURL: second).rootURL
        let gate = StorageWriteGate(fails: writeFails)
        defer { gate.resume.signal() }
        let manager = DelayedStorageFailureFileManager(root: firstCatalog, gate: gate)
        let oldRepository = LibraryRepository(rootURL: firstCatalog, mediaURL: first, fileManager: manager)
        let newRepository = LibraryRepository(rootURL: secondCatalog, mediaURL: second)
        let source = first.appendingPathComponent("loose.wav")
        try Data("sample".utf8).write(to: source)
        let hash = try LibraryRepository.sha256(of: source)
        let oldTrack = Track(id: UUID(), title: "Old", artist: "A", album: "A", duration: 10,
                             fileSize: 6, managedPath: source.path, sha256: hash, addedAt: .now, health: .verified)
        let replacement = Track(id: UUID(), title: "New", artist: "B", album: "B", duration: 10,
                                fileSize: 1, managedPath: second.appendingPathComponent("new.wav").path,
                                sha256: "new", addedAt: .now, health: .missing)
        try await oldRepository.save(tracks: [oldTrack])
        try await newRepository.save(tracks: [replacement])
        let store = LibraryStore(repository: oldRepository)
        await store.load()
        let preview = try await store.previewMediaOrganization(destination: first)
        #expect(preview.moveCount == 1)
        let destination = try #require(preview.items.first?.destinationURL)
        gate.arm()
        let operation = Task { () -> Bool in
            do { _ = try await store.executeMediaOrganization(preview); return false }
            catch is CancellationError { return true }
            catch { Issue.record("Unexpected error: \(error)"); return false }
        }
        let reached = await Task.detached { @Sendable [gate] in gate.waitUntilEntered() }.value
        #expect(reached)
        guard reached else { gate.resume.signal(); _ = await operation.value; return }
        await store.switchLibrary(catalogURL: secondCatalog, mediaURL: second)
        gate.resume.signal()
        #expect(await operation.value)
        #expect(store.tracks.map(\.id) == [replacement.id])
        #expect(try await newRepository.load().document.tracks.map(\.id) == [replacement.id])
        let saved = try await oldRepository.load().document.tracks.first
        #expect(saved?.fileURL.standardizedFileURL == (writeFails ? source : destination).standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: (writeFails ? source : destination).path))
        #expect(try LibraryRepository.sha256(of: writeFails ? source : destination) == hash)
    }

    @Test("Playlist edit queued during organization keeps the new file path")
    func playlistEditDuringOrganization() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = PortableLibraryStorage(mediaURL: root).rootURL
        let gate = StorageWriteGate(fails: false)
        defer { gate.resume.signal() }
        let repository = LibraryRepository(rootURL: catalog, mediaURL: root,
            fileManager: DelayedStorageFailureFileManager(root: catalog, gate: gate))
        let source = root.appendingPathComponent("source.wav")
        try Data("audio".utf8).write(to: source)
        let track = Track(id: UUID(), title: "T", artist: "A", album: "B", duration: 1,
                          fileSize: 5, managedPath: source.path,
                          sha256: try LibraryRepository.sha256(of: source), addedAt: .now, health: .verified)
        try await repository.save(tracks: [track])
        let store = LibraryStore(repository: repository)
        await store.load()
        let preview = try await store.previewMediaOrganization(destination: root)
        let destination = try #require(preview.items.first?.destinationURL)
        gate.arm()
        let organizing = Task { try await store.executeMediaOrganization(preview) }
        let reached = await Task.detached { @Sendable [gate] in gate.waitUntilEntered() }.value
        #expect(reached)
        guard reached else { gate.resume.signal(); _ = try? await organizing.value; return }
        let editing = Task { try await store.createPlaylist(name: "During", description: "", artworkData: nil) }
        await Task.yield()
        gate.resume.signal()
        _ = try await organizing.value
        _ = try await editing.value
        let saved = try await repository.load().document
        #expect(saved.playlists.contains { $0.name == "During" })
        #expect(saved.tracks.first?.managedPath == destination.path)
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("Stale track snapshots cannot restore paths after organization")
    func staleTracksAfterOrganization() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.wav")
        try Data("audio".utf8).write(to: source)
        let track = Track(id: UUID(), title: "T", artist: "A", album: "B", duration: 1,
                          fileSize: 5, managedPath: source.path,
                          sha256: try LibraryRepository.sha256(of: source), addedAt: .now, health: .verified)
        let repository = LibraryRepository(rootURL: PortableLibraryStorage(mediaURL: root).rootURL, mediaURL: root)
        try await repository.save(tracks: [track])
        let snapshot = try await repository.load().document
        let preview = try await repository.planMediaOrganization(tracks: snapshot.tracks, destinationRootURL: root)
        _ = try await repository.executeMediaOrganization(document: snapshot, preview: preview)
        var stale = snapshot.tracks
        stale[0].title = "Edited"
        do { try await repository.save(tracks: stale); Issue.record("Stale path was saved") }
        catch LibraryRepository.RepositoryError.staleOrganizedTrack { }
        let saved = try await repository.load().document
        let destination = try #require(preview.items.first?.destinationURL)
        #expect(saved.tracks.first?.managedPath == destination.path)
        #expect(try Data(contentsOf: destination) == Data("audio".utf8))
        #expect(!FileManager.default.fileExists(atPath: source.path))
        var fresh = saved.tracks
        fresh[0].title = "Edited"
        try await repository.save(tracks: fresh)
        #expect(try await repository.load().document.tracks.first?.title == "Edited")
    }

    @Test("Metadata writing cannot start while organization is moving the same library")
    func metadataWaitsForOrganization() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = PortableLibraryStorage(mediaURL: root).rootURL
        let gate = StorageWriteGate(fails: false)
        defer { gate.resume.signal() }
        let repository = LibraryRepository(rootURL: catalog, mediaURL: root,
            fileManager: DelayedStorageFailureFileManager(root: catalog, gate: gate))
        let source = root.appendingPathComponent("source.wav")
        try Data("audio".utf8).write(to: source)
        let track = Track(id: UUID(), title: "T", artist: "A", album: "B", duration: 1,
                          fileSize: 5, managedPath: source.path,
                          sha256: try LibraryRepository.sha256(of: source), addedAt: .now, health: .verified)
        try await repository.save(tracks: [track])
        let store = LibraryStore(repository: repository)
        await store.load()
        let preview = try await store.previewMediaOrganization(destination: root)
        let destination = try #require(preview.items.first?.destinationURL)
        gate.arm()
        let organizing = Task { try await store.executeMediaOrganization(preview) }
        let reached = await Task.detached { @Sendable [gate] in gate.waitUntilEntered() }.value
        #expect(reached)
        guard reached else { gate.resume.signal(); _ = try? await organizing.value; return }
        do { try await store.updateTrackLyrics(id: track.id, lyrics: nil); Issue.record("Metadata write started") }
        catch LibraryStore.MetadataEditError.mediaOrganizationBusy { }
        gate.resume.signal()
        _ = try await organizing.value
        #expect(try await repository.load().document.tracks.first?.managedPath == destination.path)
        #expect(try Data(contentsOf: destination) == Data("audio".utf8))
    }

#if DEBUG
    @Test("Organization cannot start while metadata editing owns the same library")
    func organizationWaitsForMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.wav")
        try Data("audio".utf8).write(to: source)
        let track = Track(id: UUID(), title: "T", artist: "A", album: "B", duration: 1,
                          fileSize: 5, managedPath: source.path,
                          sha256: try LibraryRepository.sha256(of: source), addedAt: .now, health: .verified)
        let repository = LibraryRepository(rootURL: PortableLibraryStorage(mediaURL: root).rootURL, mediaURL: root)
        try await repository.save(tracks: [track])
        let store = LibraryStore(repository: repository)
        await store.load()
        let preview = try await store.previewMediaOrganization(destination: root)
        let gate = StorageWriteGate(fails: false)
        defer { gate.resume.signal() }
        store.metadataWriteTestGate = {
            gate.entered.signal()
            _ = await Task.detached { @Sendable [gate] in gate.waitUntilResumed() }.value
        }
        let editing = Task { try await store.updateTrackLyrics(id: track.id, lyrics: nil) }
        let reached = await Task.detached { @Sendable [gate] in gate.waitUntilEntered() }.value
        #expect(reached)
        guard reached else { gate.resume.signal(); _ = try? await editing.value; return }
        do { _ = try await store.executeMediaOrganization(preview); Issue.record("Organization started") }
        catch LibraryStore.MetadataEditError.mediaOrganizationBusy { }
        #expect(FileManager.default.fileExists(atPath: source.path))
        gate.resume.signal()
        try await editing.value
        store.metadataWriteTestGate = nil
        let fresh = try await store.previewMediaOrganization(destination: root)
        _ = try await store.executeMediaOrganization(fresh)
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

#endif

    @Test("Media organization refuses a preview from a previous library")
    func staleOrganizationPreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("First", isDirectory: true)
        let second = root.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let catalog = PortableLibraryStorage(mediaURL: first).rootURL
        let source = first.appendingPathComponent("loose.wav")
        try Data("sample".utf8).write(to: source)
        let hash = try LibraryRepository.sha256(of: source)
        let track = Track(id: UUID(), title: "Old", artist: "A", album: "A", duration: 10,
                          fileSize: 6, managedPath: source.path, sha256: hash, addedAt: .now, health: .verified)
        let repository = LibraryRepository(rootURL: catalog, mediaURL: first)
        try await repository.save(tracks: [track])
        let store = LibraryStore(repository: repository)
        await store.load()
        let preview = try await store.previewMediaOrganization(destination: first)
        let destination = try #require(preview.items.first?.destinationURL)
        await store.switchLibrary(catalogURL: PortableLibraryStorage(mediaURL: second).rootURL, mediaURL: second)
        do { _ = try await store.executeMediaOrganization(preview); Issue.record("Old preview accepted") }
        catch is CancellationError { }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try await repository.load().document.tracks.first?.id == track.id)
    }

    @Test("Media organization refuses a preview after the same library changes")
    func staleOrganizationPreviewAfterEdit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("loose.wav")
        let bytes = Data("sample".utf8)
        try bytes.write(to: source)
        let hash = try LibraryRepository.sha256(of: source)
        let track = Track(id: UUID(), title: "Old", artist: "A", album: "A", duration: 10,
                          fileSize: 6, managedPath: source.path, sha256: hash, addedAt: .now, health: .verified)
        let repository = LibraryRepository(rootURL: PortableLibraryStorage(mediaURL: root).rootURL, mediaURL: root)
        try await repository.save(tracks: [track])
        let store = LibraryStore(repository: repository)
        await store.load()
        let preview = try await store.previewMediaOrganization(destination: root)
        let restricted = preview.restricted(to: [track.id])
        let destination = try #require(preview.items.first?.destinationURL)
        _ = try await store.createPlaylist(name: "New playlist", description: "", artworkData: nil)
        for candidate in [preview, restricted] {
            do { _ = try await store.executeMediaOrganization(candidate); Issue.record("Stale preview accepted") }
            catch is CancellationError { }
        }
        #expect(try Data(contentsOf: source) == bytes)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let saved = try await repository.load().document
        #expect(saved.tracks.first?.fileURL.standardizedFileURL == source.standardizedFileURL)
        #expect(saved.playlists.contains { $0.name == "New playlist" })
        let refreshed = try await store.previewMediaOrganization(destination: root)
        _ = try await store.executeMediaOrganization(refreshed)
        #expect(try Data(contentsOf: destination) == bytes)
        let organized = try await repository.load().document
        #expect(organized.playlists.contains { $0.name == "New playlist" })
        #expect(organized.tracks.first?.fileURL.standardizedFileURL == destination.standardizedFileURL)
    }

    @Test("Successful library switch clears only the store's previous undo actions")
    func switchingDropsOldUndo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("First")
        let second = root.appendingPathComponent("Second")
        let firstCatalog = PortableLibraryStorage(mediaURL: first).rootURL
        let secondCatalog = PortableLibraryStorage(mediaURL: second).rootURL
        let repository = LibraryRepository(rootURL: firstCatalog, mediaURL: first)
        let store = LibraryStore(repository: repository)
        await store.load()
        let undo = UndoManager()
        store.undoManager = undo
        _ = try await store.createPlaylist(name: "First playlist", description: "", artworkData: nil)
        #expect(undo.canUndo)
        await store.switchLibrary(catalogURL: secondCatalog, mediaURL: second)
        #expect(!undo.canUndo)
        #expect(store.playlists.isEmpty)
        #expect(try await repository.load().document.playlists.map(\.name) == ["First playlist"])
    }

}
