import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Damaged catalog journal rescue", .serialized)
struct CatalogRescueTests {
    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
    private func seed(_ root: URL) async throws -> LibraryDocument {
        let repository = LibraryRepository(rootURL: root)
        let track = Track(id: UUID(), title: "Retained", artist: "Artist", album: "Album", duration: 90,
            fileSize: 5, managedPath: root.appendingPathComponent("audio.m4a").path,
            sha256: "audio", addedAt: .distantPast, health: .unchecked)
        try Data("audio".utf8).write(to: root.appendingPathComponent("audio.m4a"), options: .atomic)
        try await repository.save(tracks: [track])
        var doc = try await repository.load().document
        doc.playlists = [Playlist(name: "Published")]
        doc.playbackQueue = PlaybackQueueState(trackIDs: [track.id], currentTrackID: track.id, position: 17)
        doc.playbackEvents = [PlaybackEvent(trackID: track.id, kind: .started, occurredAt: .distantPast,
            position: 4, playbackSessionID: UUID())]
        try await repository.save(document: doc)
        return try await repository.load().document
    }
    private func prepare(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    private func damage(_ root: URL) throws {
        try Data("broken catalog journal".utf8).write(to: root.appendingPathComponent("catalog-write-journal-v1.json"))
        // These are deliberately newer/unrelated to the selected primary.
        try Data("partial sidecar".utf8).write(to: root.appendingPathComponent("playback-queue-v1.json"))
        try Data("partial events".utf8).write(to: root.appendingPathComponent("playback-events-v1.json"))
    }
    private func assertRestored(_ root: URL, _ expected: LibraryDocument) async throws {
        let actual = try await LibraryRepository(rootURL: root).load().document
        #expect(actual.libraryID == expected.libraryID)
        #expect(actual.tracks == expected.tracks)
        #expect(actual.playlists == expected.playlists)
        #expect(actual.playbackQueue == expected.playbackQueue)
        #expect(actual.playbackEvents == expected.playbackEvents)
        #expect(try Data(contentsOf: root.appendingPathComponent("audio.m4a")) == Data("audio".utf8))
    }
    @Test("Explicit rescue backs up all bytes and restores a coherent primary, invalidating stale writers")
    func preservesAndRestores() async throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try prepare(root); let expected = try await seed(root)
        let stale = LibraryRepository(rootURL: root); _ = try await stale.load()
        try damage(root)
        let names = ["library-v1.json", "library-v1.backup.json", "catalog-write-journal-v1.json",
            "catalog-generation-v1", "catalog-generation-established-v1", "playback-queue-v1.json", "playback-events-v1.json"]
        let bytes = try names.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        let saved = try await LibraryRepository(rootURL: root).rescueDamagedCatalogWriteJournal()
        for (name, old) in zip(names, bytes) { #expect(try Data(contentsOf: saved.appendingPathComponent(name)) == old) }
        try await assertRestored(root, expected)
        do { try await stale.save(playlists: []); Issue.record("Stale writer accepted") }
        catch LibraryRepository.RepositoryError.staleOrganizedTrack { }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("catalog-write-journal-v1.json").path))
    }
#if DEBUG
    @Test("Rescue interruption and disk exhaustion retain a retryable transaction", arguments: [0, 1, 2], [false, true])
    func interrupted(step: Int, diskFull: Bool) async throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try prepare(root); let expected = try await seed(root); try damage(root)
        let original = try Data(contentsOf: root.appendingPathComponent("library-v1.json"))
        let repository = LibraryRepository(rootURL: root)
        await repository.setCatalogRescueTestHook { phase in
            let hit: Bool
            switch phase { case .backup: hit = step == 0; case .generation: hit = step == 1; case .journal: hit = step == 2 }
            if hit { if diskFull { throw POSIXError(.ENOSPC) }; throw CocoaError(.userCancelled) }
        }
        do { _ = try await repository.rescueDamagedCatalogWriteJournal(); Issue.record("Expected interruption") } catch { }
        #expect(try Data(contentsOf: root.appendingPathComponent("library-v1.json")) == original)
        let reopened = LibraryRepository(rootURL: root)
        if step < 2 { _ = try await reopened.rescueDamagedCatalogWriteJournal() }
        try await assertRestored(root, expected)
        try await assertRestored(root, expected)
    }
    @Test("A failed sidecar write after rescue journal publication can recover on restart")
    func retrySidecarWrite() async throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try prepare(root); let expected = try await seed(root); try damage(root)
        let repository = LibraryRepository(rootURL: root)
        await repository.setCatalogRescueTestHook { phase in
            if case .journal = phase { throw CocoaError(.userCancelled) }
        }
        do { _ = try await repository.rescueDamagedCatalogWriteJournal() } catch { }
        let queue = root.appendingPathComponent("playback-queue-v1.json")
        try FileManager.default.removeItem(at: queue)
        try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: false)
        let reopened = LibraryRepository(rootURL: root)
        do { _ = try await reopened.load(); Issue.record("Expected sidecar error") } catch { }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("catalog-write-journal-v1.json").path))
        try FileManager.default.removeItem(at: queue)
        try await assertRestored(root, expected)
    }
    @Test("A healthy interrupted transaction is never discarded by rescue")
    func validJournalRefused() async throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try prepare(root); _ = try await seed(root)
        let repository = LibraryRepository(rootURL: root); _ = try await repository.load()
        await repository.setCatalogWriteTestHook { if case .journal = $0 { throw CocoaError(.userCancelled) } }
        do { try await repository.save(playlists: [Playlist(name: "Pending")]) } catch { }
        let journal = root.appendingPathComponent("catalog-write-journal-v1.json"); let bytes = try Data(contentsOf: journal)
        do { _ = try await LibraryRepository(rootURL: root).rescueDamagedCatalogWriteJournal(); Issue.record("Healthy journal discarded") }
        catch is LibraryRepository.CatalogRescueUnavailable { }
        #expect(try Data(contentsOf: journal) == bytes)
        #expect(try await LibraryRepository(rootURL: root).load().document.playlists.map(\.name) == ["Pending"])
    }
#endif
    @Test("Other pending recovery prevents rescue without changing any catalog", arguments: ["import-journal-v1.json", "storage-restore-journal-v1.json", "device-sync-overlay-journal-v1.json", "media-organization-journal-v1.json", "self-containment-journal-v1.json"])
    func overlappingRecoveryRefused(name: String) async throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try prepare(root); _ = try await seed(root); try damage(root)
        try Data("pending".utf8).write(to: root.appendingPathComponent(name))
        let journal = root.appendingPathComponent("catalog-write-journal-v1.json"); let before = try Data(contentsOf: journal)
        do { _ = try await LibraryRepository(rootURL: root).rescueDamagedCatalogWriteJournal(); Issue.record("Overlapping recovery ignored") }
        catch is LibraryRepository.CatalogRescueUnavailable { }
        #expect(try Data(contentsOf: journal) == before)
    }
    @Test("No primary, invalid primary, future journal, and future primary fail closed", arguments: [0, 1, 2, 3, 4])
    func unsupportedRefused(kind: Int) async throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try prepare(root); _ = try await seed(root); try damage(root)
        let primary = root.appendingPathComponent("library-v1.json")
        let journal = root.appendingPathComponent("catalog-write-journal-v1.json")
        switch kind {
        case 0: try FileManager.default.removeItem(at: primary)
        case 1: try Data("bad primary".utf8).write(to: primary)
        case 2: try Data(#"{"version":2}"#.utf8).write(to: journal)
        case 3:
            var obj = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: primary)) as? [String: Any])
            obj["schemaVersion"] = 999
            try JSONSerialization.data(withJSONObject: obj).write(to: primary)
        default: try FileManager.default.removeItem(at: journal)
        }
        let before = try? Data(contentsOf: primary)
        do { _ = try await LibraryRepository(rootURL: root).rescueDamagedCatalogWriteJournal(); Issue.record("Unsafe rescue accepted") } catch { }
        #expect((try? Data(contentsOf: primary)) == before)
    }
    @Test("Store rescue reloads published metadata and discards queued in-memory edits")
    @MainActor
    func storeReloads() async throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try prepare(root); let expected = try await seed(root)
        let oldRepository = LibraryRepository(rootURL: root)
        let store = LibraryStore(repository: oldRepository)
        await store.load()
        store.schedulePlaybackQueueSave(PlaybackQueueState(position: 88))
        try damage(root)
        _ = try await store.rescueDamagedLibraryJournal()
        #expect(store.tracks == expected.tracks)
        #expect(store.playlists == expected.playlists)
        #expect(store.playbackQueue == expected.playbackQueue)
        #expect(store.playbackEvents == expected.playbackEvents)
        #expect(!store.isSwitchingLibrary)
        do { try await oldRepository.save(playlists: []); Issue.record("An old queued editor accepted") }
        catch LibraryRepository.RepositoryError.staleOrganizedTrack { }
        try await assertRestored(root, expected)
    }
#if DEBUG
    @Test("Damaged import rescue retains staging and resumes after every publication boundary", arguments: [0, 1, 2], [false, true])
    func importInterrupted(step: Int, diskFull: Bool) async throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try prepare(root); let expected = try await seed(root)
        let incoming = root.appendingPathComponent("Incoming/manual-copy")
        try Data("unregistered audio".utf8).write(to: incoming)
        let orphan = root.appendingPathComponent("Ongaku Media/orphan.m4a")
        try FileManager.default.createDirectory(at: orphan.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("installed audio".utf8).write(to: orphan)
        let broken = Data("broken import journal".utf8)
        let importURL = root.appendingPathComponent("import-journal-v1.json")
        try broken.write(to: importURL)
        let repository = LibraryRepository(rootURL: root)
        await repository.setCatalogRescueTestHook { phase in
            let hit: Bool
            switch phase { case .backup: hit = step == 0; case .generation: hit = step == 1; case .journal: hit = step == 2 }
            if hit { if diskFull { throw POSIXError(.ENOSPC) }; throw CocoaError(.userCancelled) }
        }
        do { _ = try await repository.rescueDamagedImportJournal(); Issue.record("Expected import rescue interruption") } catch { }
        #expect(try Data(contentsOf: importURL) == broken)
        let reopened = LibraryRepository(rootURL: root)
        if step < 2 { _ = try await reopened.rescueDamagedLibraryJournal() }
        try await assertRestored(root, expected)
        try await assertRestored(root, expected)
        #expect(try Data(contentsOf: incoming) == Data("unregistered audio".utf8))
        #expect(try Data(contentsOf: orphan) == Data("installed audio".utf8))
        let backupFolders = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Recovery Backups"), includingPropertiesForKeys: nil)
        #expect(backupFolders.contains { (try? Data(contentsOf: $0.appendingPathComponent("import-journal-v1.json"))) == broken })
    }
    @Test("Recovery refuses a replaced import record instead of deleting another transaction")
    func replacedImportRecord() async throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try prepare(root); let expected = try await seed(root)
        let importURL = root.appendingPathComponent("import-journal-v1.json")
        let original = Data("broken original".utf8); try original.write(to: importURL)
        let repository = LibraryRepository(rootURL: root)
        await repository.setCatalogRescueTestHook { if case .journal = $0 { throw CocoaError(.userCancelled) } }
        do { _ = try await repository.rescueDamagedImportJournal() } catch { }
        let replacement = Data("different record".utf8); try replacement.write(to: importURL)
        do { _ = try await LibraryRepository(rootURL: root).load(); Issue.record("Replaced record discarded") }
        catch is LibraryRepository.CatalogWriteRecoveryRequired { }
        #expect(try Data(contentsOf: importURL) == replacement)
        try original.write(to: importURL)
        try await assertRestored(root, expected)
    }
    @Test("Invalid rescue flags or future target schema cannot mutate any recovery input", arguments: [false, true])
    func invalidRescueRecord(futureSchema: Bool) async throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try prepare(root); _ = try await seed(root)
        let importURL = root.appendingPathComponent("import-journal-v1.json")
        let original = Data("broken original".utf8); try original.write(to: importURL)
        let repository = LibraryRepository(rootURL: root)
        await repository.setCatalogRescueTestHook { if case .journal = $0 { throw CocoaError(.userCancelled) } }
        do { _ = try await repository.rescueDamagedImportJournal() } catch { }
        let journalURL = root.appendingPathComponent("catalog-write-journal-v1.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any])
        if futureSchema {
            let encodedPayload = try #require(object["manifest"] as? String)
            let payload = try #require(Data(base64Encoded: encodedPayload))
            var document = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            document["schemaVersion"] = 999
            object["manifest"] = try JSONSerialization.data(withJSONObject: document).base64EncodedString()
            object.removeValue(forKey: "manifestDigest")
        } else { object["clearsRegistrations"] = true }
        try JSONSerialization.data(withJSONObject: object).write(to: journalURL)
        let primaryURL = root.appendingPathComponent("library-v1.json")
        let before = try Data(contentsOf: primaryURL)
        do { _ = try await LibraryRepository(rootURL: root).load(); Issue.record("Invalid rescue accepted") }
        catch is LibraryRepository.CatalogWriteRecoveryRequired { }
        #expect(try Data(contentsOf: importURL) == original)
        #expect(try Data(contentsOf: primaryURL) == before)
    }
    @Test("Checksum damage can restore primary without trusting the altered target")
    func checksumDamage() async throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try prepare(root); let expected = try await seed(root)
        let repository = LibraryRepository(rootURL: root); _ = try await repository.load()
        await repository.setCatalogWriteTestHook { if case .journal = $0 { throw CocoaError(.userCancelled) } }
        do { try await repository.save(playlists: [Playlist(name: "Not Published")]) } catch { }
        let url = root.appendingPathComponent("catalog-write-journal-v1.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["manifestDigest"] = "damaged digest"
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        _ = try await LibraryRepository(rootURL: root).rescueDamagedCatalogWriteJournal()
        try await assertRestored(root, expected)
    }
#endif
    @Test("Valid and future import records cannot be discarded", arguments: [1, 2])
    func validImportRefused(version: Int) async throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try prepare(root); _ = try await seed(root)
        let bytes = try JSONSerialization.data(withJSONObject: ["schemaVersion": version, "updatedAt": "2026-11-06T00:00:00Z", "entries": []])
        let url = root.appendingPathComponent("import-journal-v1.json"); try bytes.write(to: url)
        do { _ = try await LibraryRepository(rootURL: root).rescueDamagedImportJournal(); Issue.record("Valid/future import discarded") }
        catch is LibraryRepository.CatalogRescueUnavailable { }
        #expect(try Data(contentsOf: url) == bytes)
    }
    private final class FullBackup: FileManager, @unchecked Sendable {
        override func copyItem(at src: URL, to dst: URL) throws {
            if src.lastPathComponent == "catalog-write-journal-v1.json" { throw POSIXError(.ENOSPC) }
            try super.copyItem(at: src, to: dst)
        }
    }
    @Test("Actual backup copy failure retains source bytes and can retry")
    func backupFails() async throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try prepare(root); let expected = try await seed(root); try damage(root)
        let journal = root.appendingPathComponent("catalog-write-journal-v1.json"); let before = try Data(contentsOf: journal)
        do { _ = try await LibraryRepository(rootURL: root, fileManager: FullBackup()).rescueDamagedCatalogWriteJournal(); Issue.record("Full backup accepted") }
        catch let error as POSIXError { #expect(error.code == .ENOSPC) }
        #expect(try Data(contentsOf: journal) == before)
        _ = try await LibraryRepository(rootURL: root).rescueDamagedCatalogWriteJournal()
        try await assertRestored(root, expected)
    }
}
