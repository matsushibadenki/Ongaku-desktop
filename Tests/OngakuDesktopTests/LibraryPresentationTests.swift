import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Asynchronous library presentation", .serialized)
struct LibraryPresentationTests {
    @Test("Album and artist snapshots retain grouping, ordering, and durations")
    func grouping() async throws {
        let tracks = LargeLibraryFixture.makeDocument(trackCount: 40).tracks
        let worker = LibraryPresentationWorker()
        let albums = try await worker.resolve(request(tracks, section: .albums))
        #expect(albums.albums.count == 4)
        #expect(albums.albumSections.flatMap(\.albums).map(\.id) == albums.albums.map(\.id))
        #expect(albums.albums[0].totalDuration == tracks.prefix(10).reduce(0) { $0 + $1.duration })
        let artists = try await worker.resolve(request(tracks, section: .artists))
        #expect(artists.artists.count == 2)
        #expect(artists.artists.allSatisfy { $0.tracks.count == 20 && $0.albumCount == 2 })
        #expect(artists.totalBytes == tracks.reduce(0) { $0 + $1.fileSize })
        #expect(artists.attentionCount == tracks.filter { $0.health != .verified }.count)
    }

    @Test("Same-size edits and removed history invalidate cached aggregates")
    func invalidation() async throws {
        var tracks = LargeLibraryFixture.makeDocument(trackCount: 3).tracks
        let worker = LibraryPresentationWorker()
        let event = PlaybackEvent(trackID: tracks[1].id, kind: .completed)
        let first = try await worker.resolve(request(tracks, events: [event], section: .frequentlyPlayed))
        #expect(first.tracks.map(\.id) == [tracks[1].id])
        #expect(first.statistics[tracks[1].id]?.playCount == 1)
        tracks[0].playCount = 5
        tracks[0].fileSize = 17
        let edited = try await worker.resolve(request(
            tracks, events: [event], tracksRevision: 2, section: .frequentlyPlayed
        ))
        #expect(edited.tracks.map(\.id) == [tracks[0].id, tracks[1].id])
        #expect(edited.totalBytes == tracks.reduce(0) { $0 + $1.fileSize })
        let cleared = try await worker.resolve(request(
            tracks, tracksRevision: 2, eventsRevision: 2, section: .frequentlyPlayed
        ))
        #expect(cleared.tracks.map(\.id) == [tracks[0].id])
        #expect(cleared.statistics[tracks[1].id]?.lastPlayedAt == nil)
    }

    @Test("Cancelled work does not poison the next worker request")
    @MainActor
    func cancellation() async throws {
        let tracks = LargeLibraryFixture.makeDocument(trackCount: 40).tracks
        let worker = LibraryPresentationWorker()
        let input = request(tracks, section: .artists)
        let cancelled = Task { try await worker.resolve(input) }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let result = try await worker.resolve(input)
        #expect(result.artists.count == 2)
    }

    @Test("Rapid section and filter changes publish only the last request and preserve selection")
    @MainActor
    func rapidChanges() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let tracks = LargeLibraryFixture.makeDocument(trackCount: 200).tracks
        let repository = LibraryRepository(rootURL: root)
        try await repository.save(tracks: tracks)
        let store = LibraryStore(repository: repository)
        await store.load()
        let selected = tracks[21].id
        store.updateTrackSelection([selected], focusedID: selected)
        store.selectedSection = .albums
        await Task.yield()
        store.selectedSection = .favorites
        store.searchText = "楽曲"
        store.searchText = "曲目"
        store.searchText = ""
        store.filterCriteria.artist = "nonexistent"
        store.selectedSection = .artists
        store.filterCriteria.artist = tracks[21].artist
        #expect(store.isPresentationUpdating)
        #expect(store.filteredTracks.isEmpty)
        await store.waitForPresentation()
        #expect(!store.isPresentationUpdating)
        #expect(store.presentation.artists.map(\.name) == [tracks[21].artist])
        #expect(store.filteredTracks.count == 20)
        #expect(store.selectedTrackID == selected)
        #expect(store.selectedTrackIDs == [selected])
    }

    @Test("Switching libraries rejects an old pending presentation")
    @MainActor
    func librarySwitch() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = LibraryRepository(rootURL: root.appendingPathComponent("First"))
        let second = LibraryRepository(rootURL: root.appendingPathComponent("Second"))
        let oldTracks = LargeLibraryFixture.makeDocument(trackCount: 200).tracks
        var newTrack = oldTracks[0]
        newTrack.title = "New library"
        try await first.save(tracks: oldTracks)
        try await second.save(tracks: [newTrack])
        let store = LibraryStore(repository: first)
        await store.load()
        store.selectedSection = .artists
        await Task.yield()
        await store.switchLibrary(catalogURL: second.rootURL, mediaURL: second.rootURL.appendingPathComponent("Media"))
        await store.waitForPresentation()
        #expect(store.filteredTracks.map(\.title) == ["New library"])
        #expect(store.presentation.artists.isEmpty)
        #expect(store.totalBytes == newTrack.fileSize)
    }

    private func request(
        _ tracks: [Track], events: [PlaybackEvent] = [], tracksRevision: Int = 1,
        eventsRevision: Int = 1, section: LibrarySection
    ) -> LibraryPresentationRequest {
        LibraryPresentationRequest(
            tracks: tracks, events: events, tracksRevision: tracksRevision,
            eventsRevision: eventsRevision, section: section, playlist: nil,
            filter: LibraryFilterCriteria(), searchIDs: nil, audioFeatures: [:]
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Presentation-\(UUID())")
    }
}
