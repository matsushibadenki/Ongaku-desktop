import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Standard library views")
struct StandardLibraryResolverTests {
    @Test("Playback history updates do not restore the playing row over a new selection")
    @MainActor
    func preservesSelectionAfterPlaybackStarts() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(repository: LibraryRepository(rootURL: root))
        let playing = UUID()
        let newlySelected = UUID()

        store.selectedTrackID = playing
        await store.recordPlaybackEvent(PlaybackEvent(trackID: playing, kind: .started))
        store.updateTrackSelection([newlySelected], focusedID: newlySelected)

        #expect(store.selectedTrackID == newlySelected)
        #expect(store.selectedTrackIDs == [newlySelected])
    }

    @Test("A new row selection replaces the previous focused song")
    func resolvesFocusedRowSelection() {
        let previous = UUID()
        let newlySelected = UUID()

        #expect(TrackSelectionResolver.focusedTrackID(
            previousFocus: previous,
            previousSelection: [previous],
            newSelection: [newlySelected]
        ) == newlySelected)
        #expect(TrackSelectionResolver.focusedTrackID(
            previousFocus: previous,
            previousSelection: [previous],
            newSelection: []
        ) == nil)
    }

    @Test("Removing one row from a multiple selection keeps the focused song when possible")
    func preservesFocusWithinMultipleSelection() {
        let focused = UUID()
        let other = UUID()

        #expect(TrackSelectionResolver.focusedTrackID(
            previousFocus: focused,
            previousSelection: [focused, other],
            newSelection: [focused]
        ) == focused)
    }

    @Test("Pinned and favorite views include only matching songs")
    func resolvesManualCollections() {
        var pinned = makeTrack(title: "Pinned")
        pinned.isPinned = true
        var favorite = makeTrack(title: "Favorite")
        favorite.isFavorite = true
        let ordinary = makeTrack(title: "Ordinary")

        #expect(StandardLibraryResolver.tracks(
            for: .pinned,
            tracks: [ordinary, pinned, favorite],
            events: []
        ).map(\.id) == [pinned.id])
        #expect(StandardLibraryResolver.tracks(
            for: .favorites,
            tracks: [ordinary, pinned, favorite],
            events: []
        ).map(\.id) == [favorite.id])
    }

    @Test("Recently added and recently played views keep their newest-first order")
    func resolvesRecentCollections() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var older = makeTrack(title: "Older")
        older.addedAt = base
        var newer = makeTrack(title: "Newer")
        newer.addedAt = base.addingTimeInterval(60)
        let events = [
            PlaybackEvent(
                trackID: newer.id,
                kind: .started,
                occurredAt: base.addingTimeInterval(120)
            ),
            PlaybackEvent(
                trackID: older.id,
                kind: .skipped,
                occurredAt: base.addingTimeInterval(180)
            ),
        ]

        #expect(StandardLibraryResolver.tracks(
            for: .recentlyAdded,
            tracks: [older, newer],
            events: events
        ).map(\.id) == [newer.id, older.id])
        #expect(StandardLibraryResolver.tracks(
            for: .recentlyPlayed,
            tracks: [older, newer],
            events: events
        ).map(\.id) == [older.id, newer.id])
    }

    @Test("Frequently played ranks completed plays and catalog play counts")
    func resolvesFrequentlyPlayed() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var catalogLeader = makeTrack(title: "Catalog Leader")
        catalogLeader.playCount = 3
        let eventLeader = makeTrack(title: "Event Leader")
        let unplayed = makeTrack(title: "Unplayed")
        let events = (0..<2).map { offset in
            PlaybackEvent(
                trackID: eventLeader.id,
                kind: .completed,
                occurredAt: base.addingTimeInterval(TimeInterval(offset))
            )
        }

        let result = StandardLibraryResolver.tracks(
            for: .frequentlyPlayed,
            tracks: [unplayed, eventLeader, catalogLeader],
            events: events
        )

        #expect(result.map(\.id) == [catalogLeader.id, eventLeader.id])
    }

    @Test("Ongaku Mix favors matching genre and a nearby tempo")
    func ranksOngakuMixCandidates() throws {
        var seed = makeTrack(title: "Seed")
        seed.artist = "Seed Artist"
        seed.genre = "Jazz"
        seed.beatsPerMinute = 112
        var close = makeTrack(title: "Close")
        close.artist = "Another Artist"
        close.genre = "jazz"
        close.beatsPerMinute = 116
        var distant = makeTrack(title: "Distant")
        distant.artist = "Third Artist"
        distant.genre = "Metal"
        distant.beatsPerMinute = 190

        let candidates = OngakuMixResolver.candidates(
            tracks: [distant, close, seed],
            events: [],
            seedTrackID: seed.id
        )

        #expect(candidates.map(\.id) == [close.id, distant.id])
        let first = try #require(candidates.first)
        #expect(first.reasons.contains(.genre))
        #expect(first.reasons.contains(.tempo))
        #expect(StandardLibraryResolver.tracks(
            for: .ongakuMix,
            tracks: [distant, close, seed],
            events: [PlaybackEvent(trackID: seed.id, kind: .started)]
        ).first?.id == close.id)
    }

    @Test("Ongaku Mix excludes the seed and songs that cannot be played")
    func filtersOngakuMixCandidates() {
        let seed = makeTrack(title: "Seed")
        let playable = makeTrack(title: "Playable")
        var missing = makeTrack(title: "Missing")
        missing.health = .missing
        var excluded = makeTrack(title: "Excluded")
        excluded.isExcludedFromPlayback = true

        let candidates = OngakuMixResolver.candidates(
            tracks: [seed, missing, excluded, playable],
            events: [],
            seedTrackID: seed.id
        )

        #expect(candidates.map(\.id) == [playable.id])
    }

    @Test("Ongaku Mix uses the most recently played song as its seed")
    func resolvesOngakuMixSeedFromHistory() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let older = makeTrack(title: "Older")
        let latest = makeTrack(title: "Latest")
        let events = [
            PlaybackEvent(trackID: latest.id, kind: .started, occurredAt: base.addingTimeInterval(2)),
            PlaybackEvent(trackID: older.id, kind: .completed, occurredAt: base),
        ]

        #expect(OngakuMixResolver.seed(in: [older, latest], events: events)?.id == latest.id)
    }

    @Test("Ongaku Mix uses cached PCM loudness and timbre features")
    func ranksOngakuMixPCMFeatures() throws {
        var seed = makeTrack(title: "Seed")
        seed.artist = "Seed Artist"
        var similar = makeTrack(title: "Similar")
        similar.artist = "Similar Artist"
        var different = makeTrack(title: "Different")
        different.artist = "Different Artist"
        let features = [
            seed.id: makeFeatures(track: seed, loudness: -12, centroid: 1_500),
            similar.id: makeFeatures(track: similar, loudness: -13, centroid: 1_600),
            different.id: makeFeatures(track: different, loudness: -38, centroid: 7_000),
        ]

        let candidates = OngakuMixResolver.candidates(
            tracks: [different, similar, seed],
            events: [],
            seedTrackID: seed.id,
            audioFeatures: features
        )

        let first = try #require(candidates.first)
        #expect(first.id == similar.id)
        #expect(first.reasons.contains(.loudness))
        #expect(first.reasons.contains(.timbre))
    }

    @Test("Ongaku Mix recognizes relative, parallel, and fifth-related keys")
    func harmonicCompatibility() {
        #expect(OngakuMixHarmonicCompatibility.score(
            firstPitchClass: 0,
            firstMode: .major,
            secondPitchClass: 9,
            secondMode: .minor
        ) == 0.94)
        #expect(OngakuMixHarmonicCompatibility.score(
            firstPitchClass: 0,
            firstMode: .major,
            secondPitchClass: 7,
            secondMode: .major
        ) == 0.86)
        #expect(OngakuMixHarmonicCompatibility.score(
            firstPitchClass: 0,
            firstMode: .major,
            secondPitchClass: 0,
            secondMode: .minor
        ) == 0.72)
        #expect(OngakuMixHarmonicCompatibility.score(
            firstPitchClass: 0,
            firstMode: .major,
            secondPitchClass: 1,
            secondMode: .major
        ) == 0)
    }

    @Test("Ongaku Mix exposes compatible harmony as a selection reason")
    func harmonicCompatibilityReason() throws {
        let seed = makeTrack(title: "C Major")
        let compatible = makeTrack(title: "A Minor")
        let features = [
            seed.id: AudioFeatureAnalysis(
                trackID: seed.id,
                contentFingerprint: seed.sha256,
                averageLoudnessDBFS: -14,
                spectralCentroidHz: 1_500,
                estimatedTempoBPM: 120,
                tempoConfidence: 0.9,
                estimatedKeyPitchClass: 0,
                estimatedMode: .major,
                keyConfidence: 0.8
            ),
            compatible.id: AudioFeatureAnalysis(
                trackID: compatible.id,
                contentFingerprint: compatible.sha256,
                averageLoudnessDBFS: -14,
                spectralCentroidHz: 1_500,
                estimatedTempoBPM: 120,
                tempoConfidence: 0.9,
                estimatedKeyPitchClass: 9,
                estimatedMode: .minor,
                keyConfidence: 0.8
            ),
        ]

        let candidate = try #require(OngakuMixResolver.candidates(
            tracks: [seed, compatible],
            events: [],
            seedTrackID: seed.id,
            audioFeatures: features
        ).first)

        #expect(candidate.id == compatible.id)
        #expect(candidate.reasons.first == .harmony)
    }

    @Test("Duplicate analysis separates checksum matches from metadata candidates")
    func resolvesDuplicateGroups() throws {
        var exactA = makeTrack(title: "Original")
        exactA.sha256 = "same-content"
        var exactB = makeTrack(title: "Renamed Copy")
        exactB.sha256 = "same-content"

        var possibleA = makeTrack(title: "Café Song")
        possibleA.sha256 = "version-a"
        possibleA.duration = 180
        var possibleB = makeTrack(title: "CAFE SONG")
        possibleB.sha256 = "version-b"
        possibleB.duration = 182.5
        var different = makeTrack(title: "Cafe Song")
        different.sha256 = "version-c"
        different.duration = 190

        let groups = DuplicateTrackAnalyzer.groups(
            in: [exactA, exactB, possibleA, possibleB, different]
        )
        #expect(groups.count == 2)
        #expect(groups.first { $0.kind == .exact }?.tracks.count == 2)
        let possible = try #require(groups.first { $0.kind == .possible })
        #expect(Set(possible.tracks.map(\.id)) == [possibleA.id, possibleB.id])

        let duplicateTracks = StandardLibraryResolver.tracks(
            for: .duplicates,
            tracks: [exactA, exactB, possibleA, possibleB, different],
            events: []
        )
        #expect(!duplicateTracks.contains { $0.id == different.id })
    }

    @Test("Detailed filters combine metadata, rating, favorite, and file state")
    func appliesDetailedFilters() {
        var matching = makeTrack(title: "Matching")
        matching.artist = "Example Artist"
        matching.composer = "Claude Debussy"
        matching.genre = "Classical"
        matching.releaseYear = 1910
        matching.rating = 5
        matching.isFavorite = true
        var other = makeTrack(title: "Other")
        other.artist = "Example Artist"
        other.composer = "Someone Else"
        other.genre = "Jazz"
        other.releaseYear = 1960
        other.rating = 2
        other.health = .unchecked

        let criteria = LibraryFilterCriteria(
            artist: "example",
            composer: "debussy",
            genre: "class",
            minimumYear: 1900,
            maximumYear: 1920,
            minimumRating: 4,
            favoritesOnly: true,
            health: .verified
        )
        #expect(criteria.matches(matching))
        #expect(!criteria.matches(other))
        #expect(criteria.activeCount == 8)
    }

    @Test("Full metadata search includes lyrics, credits, work, and identifiers")
    func searchesAllMetadata() {
        var track = makeTrack(title: "Untitled")
        track.participantCredits = "Piano: Alice Example"
        track.workName = "Moonlit Suite"
        track.isrc = "JPAAA2600001"
        track.lyrics = TrackLyrics(plainText: "a hidden lyric phrase", source: .manual)

        #expect(CatalogSearch.matches(track, query: "alice"))
        #expect(CatalogSearch.matches(track, query: "moonlit"))
        #expect(CatalogSearch.matches(track, query: "hidden lyric"))
        #expect(CatalogSearch.matches(track, query: "jpaaa26"))
    }

    @Test("Playback starts from the selected track in the visible list")
    func startsPlaybackFromSelectedTrack() throws {
        let first = makeTrack(title: "First")
        let selected = makeTrack(title: "Selected")
        let last = makeTrack(title: "Last")

        let resolved = try #require(
            PlaybackStartResolver.startingTrack(
                in: [first, selected, last],
                selectedID: selected.id
            )
        )

        #expect(resolved.id == selected.id)
    }

    @Test("Playback falls back to the first track when the selection is outside the list")
    func fallsBackToFirstPlaybackTrack() throws {
        let first = makeTrack(title: "First")
        let second = makeTrack(title: "Second")

        let resolved = try #require(
            PlaybackStartResolver.startingTrack(
                in: [first, second],
                selectedID: UUID()
            )
        )

        #expect(resolved.id == first.id)
        #expect(PlaybackStartResolver.startingTrack(in: [], selectedID: first.id) == nil)
    }

    @Test("Player transport starts a newly selected track instead of resuming the loaded track")
    func playerTransportStartsNewSelection() throws {
        let loaded = makeTrack(title: "Loaded First")
        let selected = makeTrack(title: "Selected Later")

        let resolved = try #require(
            PlaybackStartResolver.selectedTrackToStart(
                currentTrackID: loaded.id,
                selectedTrack: selected
            )
        )

        #expect(resolved.id == selected.id)
        #expect(
            PlaybackStartResolver.selectedTrackToStart(
                currentTrackID: selected.id,
                selectedTrack: selected
            ) == nil
        )
    }

    private func makeTrack(title: String) -> Track {
        Track(
            id: UUID(),
            title: title,
            artist: "Artist",
            album: "Album",
            duration: 120,
            fileSize: 1,
            managedPath: "/tmp/\(UUID().uuidString).m4a",
            sha256: UUID().uuidString,
            addedAt: .now,
            health: .verified
        )
    }

    private func makeFeatures(
        track: Track,
        loudness: Double,
        centroid: Double
    ) -> AudioFeatureAnalysis {
        AudioFeatureAnalysis(
            trackID: track.id,
            contentFingerprint: track.sha256,
            averageLoudnessDBFS: loudness,
            spectralCentroidHz: centroid,
            estimatedTempoBPM: nil,
            tempoConfidence: 0
        )
    }
}
