import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Overlay journal recovery", .serialized)
struct OverlayJournalTests {
    @Test("Restart recovers each write boundary", arguments: [0, 1, 2, 3])
    func recoveryBoundary(step: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        let track = Track(id: UUID(), title: "A", artist: "B", album: "C", duration: 10,
                          fileSize: 1, managedPath: root.appendingPathComponent("a.mp3").path,
                          sha256: "a", addedAt: .distantPast, health: .missing)
        try await repository.save(tracks: [track])
        let previous = try await repository.load().document.tracks
        var updated = previous
        if step != 3 { updated[0].rating = 4 }
        let tagURL = root.appendingPathComponent("device-sync-tags-v1.json")
        try JSONEncoder().encode([track.id: ["old"]]).write(to: tagURL)
        do {
            try await repository.saveSynchronizedOverlay(previous: previous, updated: updated, tags: [track.id: ["new"]]) { phase in
                let hit: Bool
                switch phase {
                case .journalWritten: hit = step == 0
                case .catalogWritten: hit = step == 1 || step == 3
                case .tagsWritten: hit = step == 2
                }
                if hit { throw LibraryRepository.OverlayJournalInterruption() }
            }
            Issue.record("Expected interruption")
        } catch is LibraryRepository.OverlayJournalInterruption { }
        let journalURL = root.appendingPathComponent("device-sync-overlay-journal-v1.json")
        #expect(FileManager.default.fileExists(atPath: journalURL.path))
        let reopened = LibraryRepository(rootURL: root)
        let first = try await reopened.load().document
        let expectedRating = step == 0 || step == 3 ? 0 : 4
        #expect(first.tracks.first?.rating == expectedRating)
        let tags = try JSONDecoder().decode([UUID: [String]].self, from: Data(contentsOf: tagURL))
        #expect(tags[track.id] == (step == 0 ? ["old"] : ["new"]))
        #expect(!FileManager.default.fileExists(atPath: journalURL.path))
        let second = try await LibraryRepository(rootURL: root).load().document
        #expect(second.tracks.first?.rating == expectedRating)
    }

    @Test("Full disk during overlay publication keeps a recoverable consistent state", arguments: [0, 1, 2])
    func fullDiskDuringOverlay(step: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        let track = Track(id: UUID(), title: "A", artist: "B", album: "C", duration: 10,
                          fileSize: 1, managedPath: root.appendingPathComponent("a.mp3").path,
                          sha256: "a", addedAt: .distantPast, health: .missing)
        try await repository.save(tracks: [track])
        let previous = try await repository.load().document.tracks
        var updated = previous
        updated[0].rating = 4
        let tagsURL = root.appendingPathComponent("device-sync-tags-v1.json")
        try JSONEncoder().encode([track.id: ["old"]]).write(to: tagsURL)
        do {
            try await repository.saveSynchronizedOverlay(previous: previous, updated: updated, tags: [track.id: ["new"]]) { phase in
                let hit: Bool
                switch phase {
                case .journalWritten: hit = step == 0
                case .catalogWritten: hit = step == 1
                case .tagsWritten: hit = step == 2
                }
                if hit { throw POSIXError(.ENOSPC) }
            }
            Issue.record("Expected full disk")
        } catch { }
        let reopened = try await LibraryRepository(rootURL: root).load().document
        let tags = try JSONDecoder().decode([UUID: [String]].self, from: Data(contentsOf: tagsURL))
        #expect(reopened.tracks.first?.rating == (step == 2 ? 4 : 0))
        #expect(tags[track.id] == (step == 2 ? ["new"] : ["old"]))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("device-sync-overlay-journal-v1.json").path))
        let again = try await LibraryRepository(rootURL: root).load().document
        #expect(again.tracks.first?.rating == reopened.tracks.first?.rating)
    }

    @Test("Failed recovery retains journal, blocks writes and retries")
    func unavailableDuringRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        let track = Track(id: UUID(), title: "A", artist: "B", album: "C", duration: 10,
                          fileSize: 1, managedPath: root.appendingPathComponent("a.mp3").path,
                          sha256: "a", addedAt: .distantPast, health: .missing)
        try await repository.save(tracks: [track])
        let previous = try await repository.load().document.tracks
        var updated = previous; updated[0].rating = 4
        do {
            try await repository.saveSynchronizedOverlay(previous: previous, updated: updated, tags: [track.id: ["new"]]) { phase in
                if case .catalogWritten = phase { throw LibraryRepository.OverlayJournalInterruption() }
            }
            Issue.record("Expected interruption")
        } catch is LibraryRepository.OverlayJournalInterruption { }
        let tagURL = root.appendingPathComponent("device-sync-tags-v1.json")
        try FileManager.default.createDirectory(at: tagURL, withIntermediateDirectories: false)
        let reopened = LibraryRepository(rootURL: root)
        do { _ = try await reopened.load(); Issue.record("Recovery unexpectedly succeeded") } catch { }
        let journalURL = root.appendingPathComponent("device-sync-overlay-journal-v1.json")
        #expect(FileManager.default.fileExists(atPath: journalURL.path))
        do { try await reopened.save(tracks: previous); Issue.record("Write bypassed recovery") } catch { }
        try FileManager.default.removeItem(at: tagURL)
        let recovered = try await reopened.load().document
        #expect(recovered.tracks.first?.rating == 4)
        let tags = try JSONDecoder().decode([UUID: [String]].self, from: Data(contentsOf: tagURL))
        #expect(tags[track.id] == ["new"])
        #expect(!FileManager.default.fileExists(atPath: journalURL.path))
        try await reopened.save(tracks: recovered.tracks)
    }
    @Test("Ambiguous backup never consumes the journal")
    func backupAmbiguity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        let track = Track(id: UUID(), title: "A", artist: "B", album: "C", duration: 10,
                          fileSize: 1, managedPath: root.appendingPathComponent("a.mp3").path,
                          sha256: "a", addedAt: .distantPast, health: .missing)
        try await repository.save(tracks: [track])
        let previous = try await repository.load().document.tracks
        var updated = previous; updated[0].rating = 4
        do {
            try await repository.saveSynchronizedOverlay(previous: previous, updated: updated, tags: [track.id: ["new"]]) { phase in
                if case .tagsWritten = phase { throw LibraryRepository.OverlayJournalInterruption() }
            }
            Issue.record("Expected interruption")
        } catch is LibraryRepository.OverlayJournalInterruption { }
        let primary = root.appendingPathComponent("library-v1.json")
        let primaryData = try Data(contentsOf: primary)
        try Data("corrupt".utf8).write(to: primary, options: .atomic)
        let reopened = LibraryRepository(rootURL: root)
        do { _ = try await reopened.load(); Issue.record("Ambiguous backup accepted") } catch { }
        let journal = root.appendingPathComponent("device-sync-overlay-journal-v1.json")
        #expect(FileManager.default.fileExists(atPath: journal.path))
        try primaryData.write(to: primary, options: .atomic)
        #expect(try await reopened.load().document.tracks.first?.rating == 4)
        #expect(!FileManager.default.fileExists(atPath: journal.path))
    }

}
