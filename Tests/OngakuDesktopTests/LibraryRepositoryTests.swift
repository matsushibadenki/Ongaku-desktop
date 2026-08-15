import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Library repository integrity")
struct LibraryRepositoryTests {
    @Test("Manifest round-trips atomically")
    func manifestRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = LibraryRepository(rootURL: root)
        let track = Track(
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

        try await repository.save(tracks: [track])
        let loaded = try await repository.load()
        #expect(loaded.document.tracks.count == 1)
        #expect(loaded.document.tracks[0].id == track.id)
        #expect(loaded.document.tracks[0].title == track.title)
        #expect(loaded.document.tracks[0].sha256 == track.sha256)
        #expect(loaded.document.tracks[0].health == .verified)
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

    @Test("Selecting an Apple Music library references originals and relinks old managed copies")
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
        #expect(first.relinked == 1)
        #expect(store.tracks.count == 2)
        #expect(Set(store.tracks.map { $0.fileURL.standardizedFileURL }) == Set([
            source.standardizedFileURL,
            secondSource.standardizedFileURL
        ]))
        #expect(FileManager.default.fileExists(atPath: oldManagedCopy.path))

        let second = await store.importAppleMusicMediaFolder(media, excluding: managed)
        #expect(second.discovered == 2)
        #expect(second.imported == 0)
        #expect(second.relinked == 0)
        #expect(store.tracks.count == 2)
        try? FileManager.default.removeItem(at: root)
    }

    @Test("Apple Music media-folder-url is decoded")
    func decodesAppleMusicMediaFolder() {
        let expected = URL(fileURLWithPath: "/Volumes/Music/Media.localized", isDirectory: true)
        let preferences: [String: Any] = ["media-folder-url": expected.absoluteString]
        #expect(AppleMusicSettingsReader.mediaFolderURL(from: preferences) == expected.standardizedFileURL)
    }
}
