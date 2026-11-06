import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Storage restore recovery copy", .serialized)
struct StorageRestoreRecordTests {
    private let journalName = "storage-restore-journal-v1.json"
    private let mirrorName = "storage-restore-journal-v1.recovery.json"
    private struct Fixture {
        let media: URL
        let root: URL
        let document: LibraryDocument
        let manifest: Data
        let queue: Data
        let archived: Data
    }
    private func seed(_ media: URL) async throws -> Fixture {
        let root = PortableLibraryStorage(mediaURL: media).rootURL
        let repository = LibraryRepository(rootURL: root, mediaURL: media)
        let doc = try await repository.load().document
        let source = root.appendingPathComponent("Legacy Imports/original")
        try await LibraryRepository(rootURL: source, mediaURL: media).save(playlists: [Playlist(name: "Preserved")])
        return Fixture(media: media, root: root, document: doc,
            manifest: try Data(contentsOf: root.appendingPathComponent("library-v1.json")),
            queue: try Data(contentsOf: root.appendingPathComponent("playback-queue-v1.json")),
            archived: try Data(contentsOf: source.appendingPathComponent("library-v1.json")))
    }
    private func interrupt(_ f: Fixture, step: Int) async throws {
        let repository = LibraryRepository(rootURL: f.root, mediaURL: f.media)
        await repository.setStorageRestoreTestHook { point in
            let stop: Bool
            switch point {
            case .afterBackup(let name): stop = (step == 0 && name == "playback-queue-v1.json") || (step == 2 && name == "library-v1.json")
            case .afterInstall(let name): stop = (step == 1 && name == "playback-queue-v1.json") || (step == 3 && name == "library-v1.json")
            case .beforeRollbackCopy: stop = false
            }
            if stop { throw LibraryRepository.StorageRestoreInterruption() }
        }
        do { try await repository.restorePreservedLibraryIfEmpty(); Issue.record("Expected interruption") }
        catch is LibraryRepository.StorageRestoreInterruption { }
    }
    private func assertOriginal(_ f: Fixture) async throws {
        let result = try await LibraryRepository(rootURL: f.root, mediaURL: f.media).load().document
        #expect(result.libraryID == f.document.libraryID)
        #expect(result.playlists.isEmpty)
        #expect(try Data(contentsOf: f.root.appendingPathComponent("library-v1.json")) == f.manifest)
        #expect(try Data(contentsOf: f.root.appendingPathComponent("playback-queue-v1.json")) == f.queue)
        #expect(try Data(contentsOf: f.root.appendingPathComponent("Legacy Imports/original/library-v1.json")) == f.archived)
    }
    @Test("Malformed or decodable altered primary is recovered at every move boundary", arguments: [0, 1, 2, 3], [false, true])
    func corruptedPrimary(step: Int, decodable: Bool) async throws {
        let media = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: media) }
        let f = try await seed(media); try await interrupt(f, step: step)
        let journal = f.root.appendingPathComponent(journalName)
        let goodCopy = try Data(contentsOf: f.root.appendingPathComponent(mirrorName))
        let bad: Data
        if decodable {
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
            object["transactionID"] = UUID().uuidString
            bad = try JSONSerialization.data(withJSONObject: object)
        } else { bad = Data("damaged journal".utf8) }
        try bad.write(to: journal)
        try await assertOriginal(f)
        try await assertOriginal(f)
        #expect(!FileManager.default.fileExists(atPath: journal.path))
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent(mirrorName).path))
        let saved = try FileManager.default.contentsOfDirectory(at: f.root.appendingPathComponent("Recovery Backups"), includingPropertiesForKeys: nil)
        #expect(saved.contains { (try? Data(contentsOf: $0.appendingPathComponent(journalName))) == bad
            && (try? Data(contentsOf: $0.appendingPathComponent(mirrorName))) == goodCopy })
    }
    @Test("Recovery record publication failure occurs before any catalog move", arguments: [false, true])
    func publicationFailure(afterPrimary: Bool) async throws {
        let media = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: media) }
        let f = try await seed(media)
        let repository = LibraryRepository(rootURL: f.root, mediaURL: f.media)
        await repository.setStorageRestoreRecordTestHook { point in
            switch point {
            case .mirror: if !afterPrimary { throw POSIXError(.ENOSPC) }
            case .primary: if afterPrimary { throw POSIXError(.ENOSPC) }
            }
        }
        do { try await repository.restorePreservedLibraryIfEmpty(); Issue.record("Expected full disk") }
        catch let error as POSIXError { #expect(error.code == .ENOSPC) }
        #expect(try Data(contentsOf: f.root.appendingPathComponent("library-v1.json")) == f.manifest)
        #expect(try Data(contentsOf: f.root.appendingPathComponent("playback-queue-v1.json")) == f.queue)
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(journalName).path) == afterPrimary)
        try await assertOriginal(f)
    }
    @Test("A recovery copy without an active journal cannot roll back a completed restore")
    func orphanIsInert() async throws {
        let media = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: media) }
        let f = try await seed(media); try await interrupt(f, step: 3)
        let bytes = try Data(contentsOf: f.root.appendingPathComponent(mirrorName))
        try await assertOriginal(f)
        let repository = LibraryRepository(rootURL: f.root, mediaURL: f.media)
        try await repository.restorePreservedLibraryIfEmpty()
        let expected = try await repository.load().document
        #expect(expected.playlists.map(\.name) == ["Preserved"])
        try bytes.write(to: f.root.appendingPathComponent(mirrorName))
        let actual = try await LibraryRepository(rootURL: f.root, mediaURL: f.media).load().document
        #expect(actual.libraryID == expected.libraryID)
        #expect(actual.playlists.map(\.name) == ["Preserved"])
    }
    @Test("Wrong generation, damaged copy and future version retain all recovery inputs", arguments: [0, 1, 2])
    func invalidCopy(kind: Int) async throws {
        let media = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: media) }
        let f = try await seed(media); try await interrupt(f, step: 3)
        let journal = f.root.appendingPathComponent(journalName)
        var bad = Data("broken".utf8)
        if kind == 0 {
            try Data("999".utf8).write(to: f.root.appendingPathComponent("catalog-generation-v1"))
            var altered = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
            altered["transactionID"] = UUID().uuidString
            bad = try JSONSerialization.data(withJSONObject: altered)
        }
        if kind == 1 {
            let mirror = f.root.appendingPathComponent(mirrorName)
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: mirror)) as? [String: Any])
            object["sha256"] = "damaged"
            try JSONSerialization.data(withJSONObject: object).write(to: mirror)
        }
        if kind == 2 { bad = Data(#"{"version":2}"#.utf8) }
        try bad.write(to: journal)
        let primary = f.root.appendingPathComponent("library-v1.json")
        let before = try Data(contentsOf: primary)
        do { _ = try await LibraryRepository(rootURL: f.root, mediaURL: f.media).load(); Issue.record("Invalid fallback accepted") }
        catch is LibraryRepository.CatalogWriteRecoveryRequired { }
        #expect(try Data(contentsOf: journal) == bad)
        #expect(try Data(contentsOf: primary) == before)
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(mirrorName).path))
    }
    private final class FullBackup: FileManager, @unchecked Sendable {
        let failingName: String
        init(failingName: String) { self.failingName = failingName; super.init() }
        override func copyItem(at src: URL, to dst: URL) throws {
            if src.lastPathComponent == failingName { throw POSIXError(.ENOSPC) }
            try super.copyItem(at: src, to: dst)
        }
    }
    @Test("A failed backup of either damaged bytes or the good copy preserves inputs and retries", arguments: [false, true])
    func fullBackup(failingCopy: Bool) async throws {
        let media = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: media) }
        let f = try await seed(media); try await interrupt(f, step: 3)
        let journal = f.root.appendingPathComponent(journalName)
        let bad = Data("damaged record".utf8); try bad.write(to: journal)
        do { _ = try await LibraryRepository(rootURL: f.root, mediaURL: f.media, fileManager: FullBackup(failingName: failingCopy ? mirrorName : journalName)).load(); Issue.record("Backup failure ignored") }
        catch let error as POSIXError { #expect(error.code == .ENOSPC) }
        #expect(try Data(contentsOf: journal) == bad)
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(mirrorName).path))
        try await assertOriginal(f)
    }
    @Test("A second interruption after primary repair preserves the copy for another restart")
    func interruptedRollback() async throws {
        let media = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: media) }
        let f = try await seed(media); try await interrupt(f, step: 3)
        try Data("broken".utf8).write(to: f.root.appendingPathComponent(journalName))
        let repository = LibraryRepository(rootURL: f.root, mediaURL: f.media)
        await repository.setStorageRestoreTestHook { point in
            if case .beforeRollbackCopy("library-v1.json") = point { throw LibraryRepository.StorageRestoreInterruption() }
        }
        do { _ = try await repository.load(); Issue.record("Expected interruption") }
        catch is LibraryRepository.StorageRestoreInterruption { }
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(mirrorName).path))
        try await assertOriginal(f)
    }
    @Test("An empty legacy restore plan cannot discard a partially completed restore")
    func emptyLegacyRecord() async throws {
        let media = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: media) }
        let f = try await seed(media); try await interrupt(f, step: 3)
        try FileManager.default.removeItem(at: f.root.appendingPathComponent(mirrorName))
        let journal = f.root.appendingPathComponent(journalName)
        let bad = try JSONSerialization.data(withJSONObject: ["version": 1, "transactionID": UUID().uuidString, "entries": []])
        try bad.write(to: journal)
        do { _ = try await LibraryRepository(rootURL: f.root, mediaURL: f.media).load(); Issue.record("Empty restore plan accepted") }
        catch is LibraryRepository.CatalogWriteRecoveryRequired { }
        #expect(try Data(contentsOf: journal) == bad)
    }
    @Test("Legacy records without a recovery copy still roll back")
    func legacyRecord() async throws {
        let media = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: media) }
        let f = try await seed(media); try await interrupt(f, step: 3)
        try FileManager.default.removeItem(at: f.root.appendingPathComponent(mirrorName))
        try await assertOriginal(f)
    }
}
