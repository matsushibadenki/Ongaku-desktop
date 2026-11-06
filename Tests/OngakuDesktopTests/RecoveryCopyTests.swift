import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Read-only legacy recovery copies", .serialized)
struct RecoveryCopyTests {
    private struct Fixture: Sendable {
        let root: URL
        let media: URL
        let catalog: URL
        let repository: LibraryRepository
        let document: LibraryDocument
        let output: URL
    }
    private func seed() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OngakuRecoveryCopy-\(UUID())")
        let media = root.appendingPathComponent("original")
        let catalog = PortableLibraryStorage(mediaURL: media).rootURL
        let output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        var tracks: [Track] = []
        for i in 0..<3 {
            let url = media.appendingPathComponent("track-\(i).flac")
            let bytes = Data(repeating: UInt8(31 + i), count: 4096 + i)
            try bytes.write(to: url)
            tracks.append(Track(id: UUID(), title: "Track \(i)", artist: "Artist", album: "Album", duration: 100,
                fileSize: Int64(bytes.count), managedPath: url.path, sha256: try LibraryRepository.sha256(of: url),
                addedAt: .distantPast, health: .verified, rating: i))
        }
        let repository = LibraryRepository(rootURL: catalog, mediaURL: media)
        try await repository.save(tracks: tracks)
        var document = try await repository.load().document
        let image = catalog.appendingPathComponent("Playlist Artwork/original.png")
        try FileManager.default.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture image bytes".utf8).write(to: image)
        document.playlists = [Playlist(name: "Saved", artworkPath: image.path)]
        document.playbackQueue = PlaybackQueueState(trackIDs: tracks.map(\.id), currentTrackID: tracks[1].id, position: 17)
        document.playbackEvents = [PlaybackEvent(trackID: tracks[0].id, kind: .completed, occurredAt: .distantPast,
            position: 100, playbackSessionID: UUID())]
        try await repository.save(document: document)
        document = try await repository.load().document
        try JSONEncoder().encode([tracks[0].id: ["kept"]]).write(to: catalog.appendingPathComponent("device-sync-tags-v1.json"))
        return Fixture(root: root, media: media, catalog: catalog, repository: repository, document: document, output: output)
    }
    private func snapshot(_ root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let file as URL in walk where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            // LibraryStore's independent derived index may finish concurrently.
            // It is not source catalog/audio/recovery data.
            if file.lastPathComponent.contains(".sqlite") { continue }
            result[String(file.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: file)
        }
        return result
    }
    private func target(_ media: URL) -> LibraryRepository {
        LibraryRepository(rootURL: PortableLibraryStorage(mediaURL: media).rootURL, mediaURL: media)
    }
    private func assertCopy(_ media: URL, expected: LibraryDocument) async throws {
        let actual = try await target(media).load().document
        #expect(actual.libraryID != expected.libraryID)
        #expect(actual.tracks.map(\.id) == expected.tracks.map(\.id))
        var normalized = actual.tracks
        for i in normalized.indices {
            normalized[i].managedPath = expected.tracks[i].managedPath
            normalized[i].health = expected.tracks[i].health
            normalized[i].lastVerifiedAt = expected.tracks[i].lastVerifiedAt
        }
        #expect(normalized == expected.tracks)
        #expect(actual.playbackQueue == expected.playbackQueue)
        #expect(actual.playbackEvents == expected.playbackEvents)
        var playlists = actual.playlists
        for i in playlists.indices { playlists[i].artworkPath = expected.playlists[i].artworkPath }
        #expect(playlists == expected.playlists)
        for track in actual.tracks {
            #expect(track.managedPath.hasPrefix(media.path + "/"))
            #expect(try LibraryRepository.sha256(of: track.fileURL) == track.sha256)
        }
        let image = try #require(actual.playlists.first?.artworkPath)
        #expect(image.hasPrefix(media.path + "/"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: image)) == Data("fixture image bytes".utf8))
        let tags = try JSONDecoder().decode([UUID: [String]].self, from: Data(contentsOf: PortableLibraryStorage(mediaURL: media).rootURL.appendingPathComponent("device-sync-tags-v1.json")))
        #expect(tags[expected.tracks[0].id] == ["kept"])
    }
    @Test("All old broken journal types can be escaped without source mutation", arguments: ["storage-restore-journal-v1.json", "device-sync-overlay-journal-v1.json", "media-organization-journal-v1.json", "catalog-write-journal-v1.json", "import-journal-v1.json"])
    func legacyDamagedJournal(name: String) async throws {
        let f = try await seed(); defer { try? FileManager.default.removeItem(at: f.root) }
        try Data("broken old record".utf8).write(to: f.catalog.appendingPathComponent(name))
        let before = try snapshot(f.media)
        let media = try await f.repository.prepareRecoveryCopy(from: f.catalog.appendingPathComponent("library-v1.json"), in: f.output)
        do { _ = try await target(media).load(); Issue.record("Incomplete copy opened as a library") }
        catch is LibraryRepository.RecoveryCopyIncomplete { }
        let result = try await target(media).resumeRecoveryCopy()
        #expect(result.trackCount == 3)
        try await assertCopy(media, expected: f.document)
        #expect(try snapshot(f.media) == before)
    }
    @Test("Moved media is recovered by hash when an old organization record cannot be decoded")
    func movedMedia() async throws {
        let f = try await seed(); defer { try? FileManager.default.removeItem(at: f.root) }
        let moved = f.media.appendingPathComponent("renamed")
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        for track in f.document.tracks {
            try FileManager.default.moveItem(at: track.fileURL, to: moved.appendingPathComponent(UUID().uuidString + ".flac"))
        }
        try Data("broken".utf8).write(to: f.catalog.appendingPathComponent("media-organization-journal-v1.json"))
        let before = try snapshot(f.media)
        let media = try await f.repository.prepareRecoveryCopy(from: f.catalog.appendingPathComponent("library-v1.json"), in: f.output)
        _ = try await target(media).resumeRecoveryCopy()
        try await assertCopy(media, expected: f.document)
        #expect(try snapshot(f.media) == before)
    }
#if DEBUG
    @Test("Restart and ENOSPC at copy, catalog and final marker preserve retryability", arguments: [0, 1, 2], [false, true])
    func interrupted(step: Int, diskFull: Bool) async throws {
        let f = try await seed(); defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try snapshot(f.media)
        let media = try await f.repository.prepareRecoveryCopy(from: f.catalog.appendingPathComponent("library-v1.json"), in: f.output)
        let copying = target(media)
        await copying.setRecoveryCopyTestHook { phase in
            let hit: Bool
            switch phase { case .installed(let i): hit = step == 0 && i == 0; case .catalog: hit = step == 1; case .ready: hit = step == 2 }
            if hit { if diskFull { throw POSIXError(.ENOSPC) }; throw CocoaError(.userCancelled) }
        }
        do { _ = try await copying.resumeRecoveryCopy(); Issue.record("Expected interruption") } catch { }
        if step == 2 { try await assertCopy(media, expected: f.document) }
        else { _ = try await target(media).resumeRecoveryCopy(); try await assertCopy(media, expected: f.document) }
        #expect(try snapshot(f.media) == before)
    }
    @Test("Already verified copies finish without the original medium after a crash")
    func sourceDisconnectedAfterCopy() async throws {
        let f = try await seed(); defer { try? FileManager.default.removeItem(at: f.root) }
        let media = try await f.repository.prepareRecoveryCopy(from: f.catalog.appendingPathComponent("library-v1.json"), in: f.output)
        let copying = target(media)
        await copying.setRecoveryCopyTestHook { phase in
            if case .installed(2) = phase { throw CocoaError(.userCancelled) }
        }
        do { _ = try await copying.resumeRecoveryCopy() } catch { }
        let disconnected = f.root.appendingPathComponent("disconnected")
        try FileManager.default.moveItem(at: f.media, to: disconnected)
        _ = try await target(media).resumeRecoveryCopy()
        try await assertCopy(media, expected: f.document)
    }
#endif
#if DEBUG
    @Test("Moving an unfinished copy stops old-path writes and resumes at its new location", arguments: [0, 1, 2])
    func movedCopy(step: Int) async throws {
        let f = try await seed(); defer { try? FileManager.default.removeItem(at: f.root) }
        let media = try await f.repository.prepareRecoveryCopy(from: f.catalog.appendingPathComponent("library-v1.json"), in: f.output)
        let parent = f.root.appendingPathComponent("new-parent")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let moved = parent.appendingPathComponent(media.lastPathComponent)
        let copying = target(media)
        await copying.setRecoveryCopyTestHook { phase in
            let hit: Bool
            switch phase { case .installed(let i): hit = step == 0 && i == 0; case .catalog: hit = step == 1; case .ready: hit = step == 2 }
            if hit { try FileManager.default.moveItem(at: media, to: moved) }
        }
        do { _ = try await copying.resumeRecoveryCopy(); Issue.record("Copy kept writing after relocation") } catch { }
        #expect(!FileManager.default.fileExists(atPath: media.path))
        _ = try await target(moved).resumeRecoveryCopy()
        try await assertCopy(moved, expected: f.document)
        #expect(!FileManager.default.fileExists(atPath: media.path))
    }
#endif
    @Test("A completed recovery library can move and rename with audio and playlist artwork intact")
    func completedCopyMove() async throws {
        let f = try await seed(); defer { try? FileManager.default.removeItem(at: f.root) }
        let media = try await f.repository.prepareRecoveryCopy(from: f.catalog.appendingPathComponent("library-v1.json"), in: f.output)
        _ = try await target(media).resumeRecoveryCopy()
        let renamed = f.root.appendingPathComponent("Chosen library name")
        try FileManager.default.moveItem(at: media, to: renamed)
        try await assertCopy(renamed, expected: f.document)
        #expect(!FileManager.default.fileExists(atPath: media.path))
    }
    @Test("A missing or wrong-identity recovery target cannot open as an empty library") @MainActor
    func missingTarget() async throws {
        let f = try await seed(); defer { try? FileManager.default.removeItem(at: f.root) }
        let store = LibraryStore(repository: f.repository); await store.load()
        let absent = f.output.appendingPathComponent("absent")
        do { try await store.openRecoveryCopy(absent); Issue.record("Missing target became an empty library") }
        catch is LibraryRepository.RecoveryCopyIncomplete { }
        #expect(!FileManager.default.fileExists(atPath: absent.path))
        let media = try await f.repository.prepareRecoveryCopy(from: f.catalog.appendingPathComponent("library-v1.json"), in: f.output)
        _ = try await target(media).resumeRecoveryCopy()
        do { try await store.openRecoveryCopy(media, expectedLibraryID: UUID()); Issue.record("Wrong library identity opened") }
        catch is LibraryRepository.RecoveryCopyIncomplete { }
        #expect(store.isUsingCatalog(at: f.catalog))
    }
    private final class FullCopy: FileManager, @unchecked Sendable {
        override func copyItem(at src: URL, to dst: URL) throws {
            if dst.deletingLastPathComponent().path.contains("/Incoming/") { throw POSIXError(.ENOSPC) }
            try super.copyItem(at: src, to: dst)
        }
    }
    @Test("Actual audio-copy failure keeps originals and an identifiable resumable copy")
    func fullDiskCopy() async throws {
        let f = try await seed(); defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try snapshot(f.media)
        let media = try await f.repository.prepareRecoveryCopy(from: f.catalog.appendingPathComponent("library-v1.json"), in: f.output)
        let limited = LibraryRepository(rootURL: PortableLibraryStorage(mediaURL: media).rootURL,
            mediaURL: media, fileManager: FullCopy())
        do { _ = try await limited.resumeRecoveryCopy(); Issue.record("Expected disk full") }
        catch let error as POSIXError { #expect(error.code == .ENOSPC) }
        do { _ = try await target(media).load(); Issue.record("Partial library became active") }
        catch is LibraryRepository.RecoveryCopyIncomplete { }
        _ = try await target(media).resumeRecoveryCopy()
        try await assertCopy(media, expected: f.document)
        #expect(try snapshot(f.media) == before)
    }
    @Test("An explicitly selected Previous catalog works even when the primary has been moved away")
    func previousCatalog() async throws {
        let f = try await seed(); defer { try? FileManager.default.removeItem(at: f.root) }
        let previous = f.catalog.appendingPathComponent("Recovery Backups/old-transaction/Previous")
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
        let manifest = previous.appendingPathComponent("library-v1.json")
        try FileManager.default.moveItem(at: f.catalog.appendingPathComponent("library-v1.json"), to: manifest)
        try Data("broken restore".utf8).write(to: f.catalog.appendingPathComponent("storage-restore-journal-v1.json"))
        let before = try snapshot(f.media)
        let media = try await f.repository.prepareRecoveryCopy(from: manifest, in: f.output)
        _ = try await target(media).resumeRecoveryCopy()
        try await assertCopy(media, expected: f.document)
        #expect(try snapshot(f.media) == before)
    }
    @Test("Changed original bytes cannot be copied under their old fingerprint")
    func changedSource() async throws {
        let f = try await seed(); defer { try? FileManager.default.removeItem(at: f.root) }
        let media = try await f.repository.prepareRecoveryCopy(from: f.catalog.appendingPathComponent("library-v1.json"), in: f.output)
        try Data("different".utf8).write(to: f.document.tracks[0].fileURL)
        do { _ = try await target(media).resumeRecoveryCopy(); Issue.record("Wrong audio accepted") }
        catch is LibraryRepository.RecoveryCopyIncomplete { }
        do { _ = try await target(media).load(); Issue.record("Incomplete copy opened") }
        catch is LibraryRepository.RecoveryCopyIncomplete { }
    }
    @Test("Unknown old fingerprints are derived only from an existing exact file path")
    func missingFingerprint() async throws {
        let f = try await seed(); defer { try? FileManager.default.removeItem(at: f.root) }
        var doc = f.document; doc.tracks[0].sha256 = ""
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let chosen = f.catalog.appendingPathComponent("selected.json"); try encoder.encode(doc).write(to: chosen)
        let media = try await f.repository.prepareRecoveryCopy(from: chosen, in: f.output)
        let result = try await target(media).resumeRecoveryCopy()
        #expect(result.derivedHashCount == 1)
        try await assertCopy(media, expected: f.document)
    }
    @Test("A tampered plan and an unsupported catalog fail without modifying the source", arguments: [false, true])
    func badInput(future: Bool) async throws {
        let f = try await seed(); defer { try? FileManager.default.removeItem(at: f.root) }
        if future {
            var doc = f.document; doc.schemaVersion = 999
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let selected = f.catalog.appendingPathComponent("future.json"); try encoder.encode(doc).write(to: selected)
            do { _ = try await f.repository.prepareRecoveryCopy(from: selected, in: f.output); Issue.record("Future catalog accepted") }
            catch LibraryRepository.RepositoryError.unsupportedSchema(999) { }
            #expect(try FileManager.default.contentsOfDirectory(atPath: f.output.path).isEmpty)
        } else {
            let media = try await f.repository.prepareRecoveryCopy(from: f.catalog.appendingPathComponent("library-v1.json"), in: f.output)
            let marker = PortableLibraryStorage(mediaURL: media).rootURL.appendingPathComponent("recovery-copy-v1.json")
            var wrapper = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any])
            wrapper["sha256"] = "bad"
            try JSONSerialization.data(withJSONObject: wrapper).write(to: marker)
            do { _ = try await target(media).resumeRecoveryCopy(); Issue.record("Bad plan accepted") }
            catch is LibraryRepository.RecoveryCopyIncomplete { }
        }
    }
    @Test("A client ignoring the pending marker still cannot read an unfinished copy as an empty catalog")
    func pendingCompatibilityHeader() async throws {
        let f = try await seed(); defer { try? FileManager.default.removeItem(at: f.root) }
        let media = try await f.repository.prepareRecoveryCopy(from: f.catalog.appendingPathComponent("library-v1.json"), in: f.output)
        let manifest = PortableLibraryStorage(mediaURL: media).rootURL.appendingPathComponent("library-v1.json")
        do { _ = try await target(media).readExternalLibraryDocument(at: manifest); Issue.record("Incomplete catalog looked like a valid library") }
        catch LibraryRepository.RepositoryError.unsupportedSchema(let version) { #expect(version == LibraryDocument.currentSchema + 1) }
        _ = try await target(media).resumeRecoveryCopy()
        let complete = try await target(media).readExternalLibraryDocument(at: manifest)
        #expect(complete.schemaVersion == LibraryDocument.currentSchema)
        try await assertCopy(media, expected: f.document)
    }
    @Test("A cancelled creation never publishes a recovery folder")
    func cancelledPreparation() async throws {
        let f = try await seed(); defer { try? FileManager.default.removeItem(at: f.root) }
        let task = Task { @MainActor in try await f.repository.prepareRecoveryCopy(from: f.catalog.appendingPathComponent("library-v1.json"), in: f.output) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled preparation was published") }
        catch is CancellationError { }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.output.path).isEmpty)
    }
    @Test("Audio retained only in organization backups is rescued without replaying its broken journal")
    func organizationBackupAudio() async throws {
        let f = try await seed(); defer { try? FileManager.default.removeItem(at: f.root) }
        let backup = f.catalog.appendingPathComponent("Media Organization Backups/old-operation")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: f.document.tracks[0].fileURL, to: backup.appendingPathComponent("saved.flac"))
        try Data("bad".utf8).write(to: f.catalog.appendingPathComponent("media-organization-journal-v1.json"))
        let before = try snapshot(f.media)
        let media = try await f.repository.prepareRecoveryCopy(from: f.catalog.appendingPathComponent("library-v1.json"), in: f.output)
        _ = try await target(media).resumeRecoveryCopy()
        try await assertCopy(media, expected: f.document)
        #expect(try snapshot(f.media) == before)
    }
    @Test("Missing audio stays as explicit unavailable metadata only with opt-in", arguments: [false, true])
    func allowMissingAudio(unknownHash: Bool) async throws {
        let f = try await seed(); defer { try? FileManager.default.removeItem(at: f.root) }
        try FileManager.default.removeItem(at: f.document.tracks[0].fileURL)
        var doc = f.document
        if unknownHash { doc.tracks[0].sha256 = "" }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let selected = f.catalog.appendingPathComponent("selected.json"); try encoder.encode(doc).write(to: selected)
        let before = try snapshot(f.media)
        let media = try await f.repository.prepareRecoveryCopy(from: selected, in: f.output, allowMissing: true)
        let result = try await target(media).resumeRecoveryCopy()
        #expect(result.trackCount == 3 && result.missingTrackCount == 1)
        let actual = try await target(media).load().document
        #expect(actual.tracks.map(\.id) == doc.tracks.map(\.id))
        #expect(actual.tracks[0].health == .missing)
        #expect(actual.tracks[0].managedPath.hasPrefix(media.path + "/Unavailable/"))
        #expect(!FileManager.default.fileExists(atPath: actual.tracks[0].managedPath))
        for track in actual.tracks.dropFirst() { #expect(try LibraryRepository.sha256(of: track.fileURL) == track.sha256) }
        #expect(try snapshot(f.media) == before)
    }
    @Test("Unreadable audio can remain metadata only after explicit consent")
    func unreadableSource() async throws {
        let f = try await seed(); defer { try? FileManager.default.removeItem(at: f.root) }
        let source = f.document.tracks[0].fileURL
        let original = try Data(contentsOf: source)
        let manifest = f.catalog.appendingPathComponent("library-v1.json")
        let before = try Data(contentsOf: manifest)
        let media = try await f.repository.prepareRecoveryCopy(from: manifest, in: f.output, allowMissing: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: source.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path) }
        guard !FileManager.default.isReadableFile(atPath: source.path) else {
            print("SKIP: host permissions cannot model an unreadable owned file")
            return
        }
        let result = try await target(media).resumeRecoveryCopy()
        #expect(result.missingTrackCount == 1)
        #expect(try Data(contentsOf: manifest) == before)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
        #expect(try Data(contentsOf: source) == original)
    }
    @Test("Strict failed copies can resume with explicit missing-audio consent")
    func optInOnResume() async throws {
        let f = try await seed(); defer { try? FileManager.default.removeItem(at: f.root) }
        let media = try await f.repository.prepareRecoveryCopy(from: f.catalog.appendingPathComponent("library-v1.json"), in: f.output)
        try FileManager.default.removeItem(at: f.document.tracks[1].fileURL)
        do { _ = try await target(media).resumeRecoveryCopy(); Issue.record("Strict mode silently omitted audio") }
        catch is LibraryRepository.RecoveryCopyIncomplete { }
        let result = try await target(media).resumeRecoveryCopy(allowMissing: true)
        #expect(result.missingTrackCount == 1)
        let actual = try await target(media).load().document
        #expect(actual.tracks.filter { $0.health == .missing }.map(\.id) == [f.document.tracks[1].id])
    }
    @Test("Readable read-only audio is copied without changing original permissions")
    func readOnlyAudio() async throws {
        let f = try await seed(); defer { try? FileManager.default.removeItem(at: f.root) }
        let source = f.document.tracks[0].fileURL
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: source.path)
        let before = try snapshot(f.media)
        let media = try await f.repository.prepareRecoveryCopy(from: f.catalog.appendingPathComponent("library-v1.json"), in: f.output)
        _ = try await target(media).resumeRecoveryCopy()
        try await assertCopy(media, expected: f.document)
        #expect(try snapshot(f.media) == before)
        let mode = try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o444)
    }

    @Test("Unknown files appearing at a copy destination are never overwritten")
    func targetCollision() async throws {
        let f = try await seed(); defer { try? FileManager.default.removeItem(at: f.root) }
        let media = try await f.repository.prepareRecoveryCopy(from: f.catalog.appendingPathComponent("library-v1.json"), in: f.output)
        let unexpected = media.appendingPathComponent("Artist/Album/track-0.flac")
        try FileManager.default.createDirectory(at: unexpected.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("unrelated user bytes".utf8); try bytes.write(to: unexpected)
        _ = try await target(media).resumeRecoveryCopy()
        try await assertCopy(media, expected: f.document)
        #expect(try Data(contentsOf: unexpected) == bytes)
    }
#if DEBUG
    private final class AsyncGate: Sendable {
        let entered = AsyncStream<Void>.makeStream()
        let released = AsyncStream<Void>.makeStream()
        func block() async { entered.continuation.yield(()); for await _ in released.stream { break } }
        func wait() async { for await _ in entered.stream { break } }
        func open() { released.continuation.yield(()) }
    }
    @Test("A later profile switch wins over an in-flight recovery-copy open") @MainActor
    func newerSwitchWins() async throws {
        let f = try await seed(); defer { try? FileManager.default.removeItem(at: f.root) }
        let media = try await f.repository.prepareRecoveryCopy(from: f.catalog.appendingPathComponent("library-v1.json"), in: f.output)
        _ = try await target(media).resumeRecoveryCopy()
        let other = f.root.appendingPathComponent("other")
        let latest = LibraryRepository(rootURL: other)
        try await latest.save(playlists: [Playlist(name: "Latest selection")])
        let loaded = try await latest.load()
        let store = LibraryStore(repository: f.repository); await store.load()
        let gate = AsyncGate(); defer { gate.open() }
        store.recoveryCopyLoadTestGate = { await gate.block() }
        let pending = Task { @MainActor in try await store.openRecoveryCopy(media) }
        await gate.wait()
        await store.switchLibrary(catalogURL: other, mediaURL: other.appendingPathComponent("Ongaku Media"), preparedResult: loaded)
        gate.open()
        do { try await pending.value; Issue.record("Old recovery open replaced the latest selection") }
        catch is CancellationError { }
        #expect(store.isUsingCatalog(at: other))
        #expect(store.playlists.map(\.name) == ["Latest selection"])
        #expect(!store.isSwitchingLibrary)
    }
#endif
    @Test("Opening a recovered library does not flush the broken original's pending queue") @MainActor
    func storeOpening() async throws {
        let f = try await seed(); defer { try? FileManager.default.removeItem(at: f.root) }
        let store = LibraryStore(repository: f.repository)
        await store.load()
        try Data("broken".utf8).write(to: f.catalog.appendingPathComponent("storage-restore-journal-v1.json"))
        let before = try snapshot(f.media)
        let media = try await f.repository.prepareRecoveryCopy(from: f.catalog.appendingPathComponent("library-v1.json"), in: f.output)
        _ = try await target(media).resumeRecoveryCopy()
        store.schedulePlaybackQueueSave(PlaybackQueueState(position: 88))
        try await store.openRecoveryCopy(media)
        #expect(store.playbackQueue == f.document.playbackQueue)
        #expect(store.tracks.allSatisfy { $0.managedPath.hasPrefix(media.path + "/") })
        #expect(!store.isSwitchingLibrary)
        #expect(try snapshot(f.media) == before)
    }
}
