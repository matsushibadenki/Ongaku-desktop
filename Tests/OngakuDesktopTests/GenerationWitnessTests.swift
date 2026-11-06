import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Catalog generation witness", .serialized)
struct GenerationWitnessTests {
    private func removeSidecars(_ root: URL) throws {
        for name in ["catalog-generation-v1", "catalog-generation-established-v1"] {
            let url = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    private func removeWitness(_ root: URL) throws {
        for name in ["library-v1.json", "library-v1.backup.json"] {
            let url = root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            object.removeValue(forKey: "catalogGenerationEstablished")
            try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
        }
    }

    @Test("Catalog or backup survives simultaneous generation-sidecar loss", arguments: [false, true])
    func simultaneousLoss(backupOnly: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = LibraryRepository(rootURL: root)
        let playlist = Playlist(name: "Original")
        try await seed.save(playlists: [playlist])
        try await seed.save(playlists: [playlist])
        let baseline = try await seed.load().document
        let stale = LibraryRepository(rootURL: root)
        _ = try await stale.load()
        try removeSidecars(root)
        if backupOnly { try FileManager.default.removeItem(at: root.appendingPathComponent("library-v1.json")) }
        let recovered = LibraryRepository(rootURL: root)
        let result = try await recovered.load().document
        #expect(result.libraryID == baseline.libraryID)
        #expect(result.playlists.map(\.id) == [playlist.id])
        #expect(result.catalogGenerationEstablished == true)
        #expect(try String(contentsOf: root.appendingPathComponent("catalog-generation-v1"), encoding: .utf8).hasPrefix("v2:"))
        do { try await stale.save(playlists: []); Issue.record("Old writer overwrote repaired catalog") }
        catch LibraryRepository.RepositoryError.staleOrganizedTrack { }
        let bytes = try Data(contentsOf: root.appendingPathComponent("library-v1.json"))
        _ = try await recovered.load()
        #expect(try Data(contentsOf: root.appendingPathComponent("library-v1.json")) == bytes)
    }

    @Test("A legacy schema-12 catalog gains a witness exactly once")
    func legacyMigration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = LibraryRepository(rootURL: root)
        try await seed.save(playlists: [Playlist(name: "Legacy")])
        try removeWitness(root)
        try removeSidecars(root)
        let recovered = LibraryRepository(rootURL: root)
        let result = try await recovered.load().document
        #expect(result.catalogGenerationEstablished == true)
        #expect(result.playlists.map(\.name) == ["Legacy"])
        #expect(result.schemaVersion == LibraryDocument.currentSchema)
        let manifest = root.appendingPathComponent("library-v1.json")
        let bytes = try Data(contentsOf: manifest)
        let generation = try Data(contentsOf: root.appendingPathComponent("catalog-generation-v1"))
        _ = try await recovered.load()
        #expect(try Data(contentsOf: manifest) == bytes)
        #expect(try Data(contentsOf: root.appendingPathComponent("catalog-generation-v1")) == generation)
    }

#if DEBUG
    @Test("Witness migration recovers after ENOSPC and simultaneous sidecar loss", arguments: [false, true])
    func interruptedMigration(afterQueue: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = LibraryRepository(rootURL: root)
        try await seed.save(playlists: [Playlist(name: "Legacy")])
        let libraryID = try await seed.load().document.libraryID
        try removeWitness(root)
        try removeSidecars(root)
        let migrating = LibraryRepository(rootURL: root)
        await migrating.setCatalogWriteTestHook { step in
            if case .journal = step, !afterQueue { throw POSIXError(.ENOSPC) }
            if case .queue = step, afterQueue { throw POSIXError(.ENOSPC) }
        }
        do { _ = try await migrating.load(); Issue.record("Expected interrupted migration") }
        catch let error as POSIXError { #expect(error.code == .ENOSPC) }
        try removeSidecars(root)
        let recovered = LibraryRepository(rootURL: root)
        let result = try await recovered.load().document
        #expect(result.libraryID == libraryID)
        #expect(result.playlists.map(\.name) == ["Legacy"])
        #expect(result.catalogGenerationEstablished == true)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("catalog-write-journal-v1.json").path))
        _ = try await recovered.load()
    }
#endif
}
