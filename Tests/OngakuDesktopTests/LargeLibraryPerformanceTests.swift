import AVFoundation
import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Large library performance fixture", .serialized)
struct LargeLibraryPerformanceTests {
    @Test("Opt-in 100,000-track search during real playback and index updates")
    @MainActor
    func searchWorkloadBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["ONGAKU_RUN_SEARCH_WORKLOAD_BENCHMARK"] == "1"
        else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ongaku-Search-Workload-100k-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audioURL = root.appendingPathComponent("Playback.caf")
        try writePlaybackFixture(to: audioURL)
        var document = LargeLibraryFixture.makeDocument()
        document.tracks[0].managedPath = audioURL.path
        document.tracks[0].duration = 180
        document.tracks[0].fileSize = Int64(try audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let repository = LibraryRepository(rootURL: root)
        try await repository.save(document: document)
        let index = SQLiteCatalogPrototype(rootURL: root)
        let store = LibraryStore(repository: repository, searchIndex: index)
        await store.load()
        try await waitForWorkloadState { store.searchBackendStatus == .sqlite && !store.isPresentationUpdating }

        // Include SQLite result comparison in both measurements. The baseline
        // reproduces the previous per-query normalization without changing disk.
        let parityQueries = ["a", "1", "夜", "音", "T", "Tra", "A", "Art", "Alb", "楽", "楽曲", "曲", "曲目"]
        let clock = ContinuousClock()
        var started = clock.now
        for query in parityQueries {
            let expected = Set(document.tracks.filter { CatalogSearch.matches($0, query: query) }.map(\.id))
            #expect(Set(try await index.search(query, limit: document.tracks.count)) == expected)
        }
        let legacyParity = seconds(started.duration(to: clock.now))
        started = clock.now
        #expect(try await index.verifySearchParity(document: document, queries: parityQueries).isMatch)
        let batchedParity = seconds(started.duration(to: clock.now))
        print("ONGAKU_PARITY_100K queries=\(parityQueries.count) legacy=\(legacyParity)s batched=\(batchedParity)s")

        let player = PlaybackController()
        player.volume = 0
        defer { player.pauseForExternalPlayback() }
        for condition in ["playback", "index-update", "playback-and-index-update"] {
            let playsAudio = condition != "index-update"
            let updatesIndex = condition != "playback"
            if playsAudio {
                player.play(document.tracks[0], queue: [document.tracks[0]])
                try #require(player.isPlaying, "Real audio playback did not start: \(player.errorMessage ?? "unknown")")
                try await waitForWorkloadState { player.elapsed > 0 }
            } else {
                player.pauseForExternalPlayback()
            }
            let initialElapsed = player.elapsed
            var samples: [Double] = []
            for sample in 0..<10 {
                let target = store.tracks[sample * 3 + 3]
                let title: String
                if updatesIndex {
                    title = "Updated \(condition) \(sample)"
                    try await store.updateTrackMetadata(
                        id: target.id, title: title, artist: target.artist, album: target.album
                    )
                    // The query starts while the production store has invalidated
                    // its index, exercising JSON fallback and the later handoff.
                    try #require(store.searchBackendStatus == .synchronizing)
                } else {
                    title = target.title
                }
                let start = clock.now
                store.searchText = title
                try await waitForWorkloadState {
                    !store.isPresentationUpdating && !store.isLocalSearchPending
                        && store.filteredTracks.map(\.id) == [target.id]
                }
                samples.append(seconds(start.duration(to: clock.now)))
                #expect(player.isPlaying == playsAudio)
                if updatesIndex {
                    try await waitForWorkloadState { store.searchBackendStatus == .sqlite }
                    await store.waitForPresentation()
                    #expect(store.filteredTracks.map(\.id) == [target.id])
                }
            }
            if playsAudio { #expect(player.elapsed > initialElapsed) }
            print("ONGAKU_SEARCH_WORKLOAD_100K condition=\(condition) samples=10 resultP95=\(percentile95(samples))s "
                + "audioElapsed=\(player.elapsed)s outputRate=\(player.outputSampleRate)Hz")
        }
    }

    @MainActor
    private func waitForWorkloadState(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(180))
        while !condition() {
            try #require(ContinuousClock.now < deadline, "Timed out waiting for the production search/audio state")
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func writePlaybackFixture(to url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
        buffer.frameLength = buffer.frameCapacity
        let channels = try #require(buffer.floatChannelData)
        for frame in 0..<Int(buffer.frameLength) {
            let sample = Float(0.1 * sin(2 * .pi * 440 * Double(frame) / format.sampleRate))
            channels[0][frame] = sample
            channels[1][frame] = sample
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        // Fixed 180-second PCM fixture, generated with a 35 KiB working buffer.
        for _ in 0..<1_800 { try file.write(from: buffer) }
    }

    @Test("The 100,000-track fixture is deterministic and relationally consistent")
    func fullFixtureIntegrity() {
        let document = LargeLibraryFixture.makeDocument()

        #expect(document.tracks.count == 100_000)
        #expect(Set(document.tracks.map(\.id)).count == 100_000)
        #expect(Set(document.tracks.map(\.artistID)).count == 5_000)
        #expect(Set(document.tracks.map(\.albumID)).count == 10_000)
        #expect(document.tracks.first?.title == "Track 000000")
        #expect(document.tracks.last?.title == "Track 099999")
        #expect(document.tracks[0].albumID == document.tracks[9].albumID)
        #expect(document.tracks[9].albumID != document.tracks[10].albumID)
        #expect(document.tracks[0].artistID == document.tracks[19].artistID)
        #expect(document.tracks[19].artistID != document.tracks[20].artistID)
    }

    @Test("M3 loads a 100,000-track catalog and searches its index within CI budgets")
    func m3PerformanceGate() async throws {
        let document = LargeLibraryFixture.makeDocument()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ongaku-M3-Performance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(rootURL: root)
        try await repository.save(tracks: document.tracks)
        let clock = ContinuousClock()

        let presentationStart = clock.now
        let loaded = try await LibraryRepository(rootURL: root).load().document
        let visibleTracks = StandardLibraryResolver.tracks(
            for: .songs,
            tracks: loaded.tracks,
            events: loaded.playbackEvents
        )
        let firstPage = Array(visibleTracks.prefix(100))
        let presentationSeconds = seconds(presentationStart.duration(to: clock.now))

        #expect(firstPage.count == 100)
        #expect(firstPage.first?.id == document.tracks.first?.id)
        let enforcesPerformanceBudget =
            ProcessInfo.processInfo.environment["ONGAKU_ENFORCE_M3_PERFORMANCE"] == "1"
        // The qualification benchmark separately records a 10-run p95 against
        // the 2-second product goal. CI uses a wider cold-I/O regression ceiling
        // because shared macOS runners have variable filesystem contention.
        let presentationBudget = enforcesPerformanceBudget ? 4.0 : 10.0
        #expect(
            presentationSeconds < presentationBudget,
            "Initial presentation took \(presentationSeconds)s"
        )

        let index = SQLiteCatalogPrototype(rootURL: root)
        _ = try await index.migrate(document: document)

        let queries = ["099999", "artist 0042", "album 00042", "楽曲 000100"]
        var searchSamples: [Double] = []
        for query in queries {
            let start = clock.now
            _ = try await index.search(query, limit: 200)
            searchSamples.append(seconds(start.duration(to: clock.now)))
        }
        let searchP95 = percentile95(searchSamples)
        let searchBudget = enforcesPerformanceBudget ? 0.300 : 2.0
        #expect(searchP95 < searchBudget, "General search p95 took \(searchP95)s")
        print("ONGAKU_M3_CI coldLoadAndFirstPage=\(presentationSeconds)s indexedSearchP95=\(searchP95)s")
    }

    @Test("Opt-in 100,000-track cold fallback preparation benchmark")
    func fallbackPreparationBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["ONGAKU_RUN_FALLBACK_BENCHMARK"] == "1"
        else { return }
        let tracks = LargeLibraryFixture.makeDocument().tracks
        let libraryID = UUID()
        let clock = ContinuousClock()
        var coldSamples: [Double] = []
        var warmSamples: [Double] = []
        var urlPreparationSamples: [Double] = []
        var directPreparationSamples: [Double] = []
        for sample in 0..<3 {
            func prepare(_ legacy: Bool) -> [String] {
                let start = clock.now
                let text = legacy
                    ? tracks.map { CatalogSearch.searchableText(for: $0, fileName: $0.fileURL.lastPathComponent) }
                    : tracks.map(CatalogSearch.searchableText)
                let elapsed = seconds(start.duration(to: clock.now))
                if legacy { urlPreparationSamples.append(elapsed) }
                else { directPreparationSamples.append(elapsed) }
                return text
            }
            // Alternate order to reduce the effect of cache warming.
            let first = prepare(sample.isMultiple(of: 2))
            let second = prepare(!sample.isMultiple(of: 2))
            #expect(first == second)
        }
        print("ONGAKU_FILENAME_PREPARATION_100K samples=3 urlMax=\(urlPreparationSamples.max()!)s "
            + "directMax=\(directPreparationSamples.max()!)s")
        let expected: Set<Track.ID>
        do {
            let preparationStart = clock.now
            let prepared = tracks.map(CatalogSearch.searchableText)
            let preparationSeconds = seconds(preparationStart.duration(to: clock.now))
            let scanStart = clock.now
            expected = Set(tracks.indices.filter { prepared[$0].contains("track") }.map { tracks[$0].id })
            let scanSeconds = seconds(scanStart.duration(to: clock.now))
            print("ONGAKU_FALLBACK_PHASES_100K textPreparation=\(preparationSeconds)s "
                + "scanAndIDs=\(scanSeconds)s textBytes=\(prepared.reduce(0) { $0 + $1.utf8.count })")
        }
        for _ in 0..<3 {
            let worker = CatalogFallbackSearchWorker()
            var start = clock.now
            let cold = try await worker.search(
                tracks: tracks, libraryID: libraryID, revision: 1, query: "Track"
            )
            coldSamples.append(seconds(start.duration(to: clock.now)))
            #expect(cold == expected)
            #expect(await worker.cachedTextBytes > 0)
            start = clock.now
            let warm = try await worker.search(
                tracks: tracks, libraryID: libraryID, revision: 1, query: "Track"
            )
            warmSamples.append(seconds(start.duration(to: clock.now)))
            #expect(warm == expected)
        }
        let ascii = tracks.map { "\($0.artist)\u{1f}\($0.album)" }
        let legacyStart = clock.now
        let legacy = ascii.map { $0.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ) }
        let legacySeconds = seconds(legacyStart.duration(to: clock.now))
        let optimizedStart = clock.now
        let optimized = ascii.map(CatalogSearch.normalize)
        let optimizedSeconds = seconds(optimizedStart.duration(to: clock.now))
        #expect(optimized == legacy)
        print("ONGAKU_FALLBACK_100K samples=3 coldMax=\(coldSamples.max()!)s "
            + "warmMax=\(warmSamples.max()!)s asciiLegacy=\(legacySeconds)s "
            + "asciiOptimized=\(optimizedSeconds)s")
    }

    @Test("Opt-in 100,000-track fallback cache retirement benchmark")
    func fallbackCacheRetirementBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["ONGAKU_RUN_CACHE_RETIREMENT_BENCHMARK"] == "1"
        else { return }
        let tracks = LargeLibraryFixture.makeDocument().tracks
        let libraryID = UUID()
        let worker = CatalogFallbackSearchWorker()
        for round in 0..<3 {
            let start = ContinuousClock.now
            let ids = try await worker.search(tracks: tracks, libraryID: libraryID,
                revision: round, query: "track")
            let cold = seconds(start.duration(to: ContinuousClock.now))
            let retainedBytes = await worker.cachedTextBytes
            #expect(retainedBytes > 0 && ids.count > 0)
            #expect(await worker.cachedTrackCount == tracks.count)
            let release = ContinuousClock.now
            await worker.releaseCache(libraryID: libraryID, throughRevision: round)
            let releaseSeconds = seconds(release.duration(to: ContinuousClock.now))
            #expect(await worker.cachedTextBytes == 0)
            #expect(await worker.cachedTrackCount == 0)
            // Rebuilding is required if SQLite later fails; no result may be lost.
            for query in ["Track 000000", "楽曲 000001", "曲目 000002"] {
                let actual = try await worker.search(tracks: tracks, libraryID: libraryID,
                    revision: round, query: query)
                #expect(actual == Set(tracks.filter { CatalogSearch.matches($0, query: query) }.map(\.id)))
            }
            print("ONGAKU_CACHE_RETIREMENT round=\(round) tracks=\(tracks.count) retainedTextBytes=\(retainedBytes) "
                + "afterReleaseTextBytes=0 afterReleaseTrackReferences=0 coldSeconds=\(cold) releaseSeconds=\(releaseSeconds)")
            await worker.releaseCache(libraryID: libraryID, throughRevision: round)
        }
    }

    @Test("Opt-in 100,000-track asynchronous presentation benchmark")
    func presentationBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["ONGAKU_RUN_PRESENTATION_BENCHMARK"] == "1"
        else { return }
        let tracks = LargeLibraryFixture.makeDocument().tracks
        let worker = LibraryPresentationWorker()
        func request(_ section: LibrarySection, searchIDs: Set<Track.ID>? = nil) -> LibraryPresentationRequest {
            LibraryPresentationRequest(
                tracks: tracks, events: [], tracksRevision: 1, eventsRevision: 1,
                section: section, playlist: nil, filter: LibraryFilterCriteria(),
                searchIDs: searchIDs, audioFeatures: [:]
            )
        }
        let clock = ContinuousClock()
        let start = clock.now
        let initial = try await worker.resolve(request(.songs))
        let initialSeconds = seconds(start.duration(to: clock.now))
        #expect(initial.tracks.count == 100_000)
        var albumSamples: [Double] = []
        var artistSamples: [Double] = []
        var searchSamples: [Double] = []
        for _ in 0..<10 {
            var start = clock.now
            let albums = try await worker.resolve(request(.albums))
            albumSamples.append(seconds(start.duration(to: clock.now)))
            #expect(albums.albums.count == 10_000)
            start = clock.now
            let artists = try await worker.resolve(request(.artists))
            artistSamples.append(seconds(start.duration(to: clock.now)))
            #expect(artists.artists.count == 5_000)
            start = clock.now
            let search = try await worker.resolve(request(.songs, searchIDs: [tracks[99_999].id]))
            searchSamples.append(seconds(start.duration(to: clock.now)))
            #expect(search.tracks.map(\.id) == [tracks[99_999].id])
        }
        // Include edits with a large, unchanged playback history. This exercises
        // cache invalidation that section-only samples intentionally avoid.
        var editedTracks = tracks
        let history = tracks.map { PlaybackEvent(trackID: $0.id, kind: .completed) }
        let historyWorker = LibraryPresentationWorker()
        func historyRequest(_ revision: Int) -> LibraryPresentationRequest {
            LibraryPresentationRequest(
                tracks: editedTracks, events: history, tracksRevision: revision, eventsRevision: 1,
                section: .songs, playlist: nil, filter: LibraryFilterCriteria(),
                searchIDs: [tracks[0].id], audioFeatures: [:]
            )
        }
        _ = try await historyWorker.resolve(historyRequest(1))
        var editSamples: [Double] = []
        for sample in 0..<10 {
            editedTracks[0].comments = "Metadata edit \(sample)"
            editedTracks[0].playCount = sample
            let start = clock.now
            let snapshot = try await historyWorker.resolve(historyRequest(sample + 2))
            editSamples.append(seconds(start.duration(to: clock.now)))
            #expect(snapshot.tracks.map(\.id) == [tracks[0].id])
            #expect(snapshot.statistics[tracks[0].id]?.playCount == sample + 1)
        }
        print("ONGAKU_PRESENTATION_HISTORY_100K events=\(history.count) samples=10 "
            + "metadataEditP95=\(percentile95(editSamples))s")
        // This measures worker computation, not SwiftUI rendering or index I/O.
        print("ONGAKU_PRESENTATION_100K samples=10 initial=\(initialSeconds)s "
            + "albumP95=\(percentile95(albumSamples))s artistP95=\(percentile95(artistSamples))s "
            + "searchProjectionP95=\(percentile95(searchSamples))s")
    }

    @Test("Opt-in JSON persistence, cold-load, search, and grouping benchmark")
    func catalogBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["ONGAKU_RUN_LARGE_LIBRARY_BENCHMARK"] == "1"
        else { return }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ongaku-100k-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = LargeLibraryFixture.makeDocument()
        let sampleCount = 10

        let writer = LibraryRepository(rootURL: root)
        try await writer.save(tracks: document.tracks)
        let saveSamples = try await measureAsync(iterations: sampleCount) {
            try await writer.save(tracks: document.tracks)
        }

        _ = try await LibraryRepository(rootURL: root).load()
        var loaded = document
        let loadSamples = try await measureAsync(iterations: sampleCount) {
            loaded = try await LibraryRepository(rootURL: root).load().document
        }

        var searchResults: [Track] = []
        _ = search(in: loaded.tracks, query: "099999")
        let searchSamples = measure(iterations: sampleCount) {
            searchResults = search(in: loaded.tracks, query: "099999")
        }

        var albums: [UUID: [Track]] = [:]
        var artists: [UUID: [Track]] = [:]
        _ = Dictionary(grouping: loaded.tracks, by: \.albumID)
        _ = Dictionary(grouping: loaded.tracks, by: \.artistID)
        let groupingSamples = measure(iterations: sampleCount) {
            albums = Dictionary(grouping: loaded.tracks, by: \.albumID)
            artists = Dictionary(grouping: loaded.tracks, by: \.artistID)
        }
        let manifestBytes = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent("library-v1.json").path
        )[.size] as? NSNumber

        print(
            "ONGAKU_100K_BENCHMARK "
                + "samples=\(sampleCount) "
                + "saveP95=\(format(percentile95(saveSamples)))s "
                + "coldLoadP95=\(format(percentile95(loadSamples)))s "
                + "searchP95=\(format(percentile95(searchSamples)))s "
                + "groupingP95=\(format(percentile95(groupingSamples)))s "
                + "manifestBytes=\(manifestBytes?.int64Value ?? 0)"
        )

        #expect(loaded.tracks.count == LargeLibraryFixture.fullTrackCount)
        #expect(searchResults.map(\.title) == ["Track 099999"])
        #expect(albums.count == 10_000)
        #expect(artists.count == 5_000)
    }

    @Test("Opt-in SQLite migration and indexed-search benchmark")
    func sqliteCatalogBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["ONGAKU_RUN_SQLITE_CATALOG_BENCHMARK"] == "1"
        else { return }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ongaku-SQLite-100k-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = LargeLibraryFixture.makeDocument()
        let prototype = SQLiteCatalogPrototype(rootURL: root)
        let clock = ContinuousClock()

        let migrationStart = clock.now
        let report = try await prototype.migrate(document: document)
        let migrationSeconds = seconds(migrationStart.duration(to: clock.now))

        _ = try await prototype.search("099999")
        var result: [Track.ID] = []
        let searchSamples = try await measureAsync(iterations: 10) {
            result = try await prototype.search("099999")
        }
        let databaseBytes = try FileManager.default.attributesOfItem(
            atPath: report.databaseURL.path
        )[.size] as? NSNumber

        print(
            "ONGAKU_SQLITE_100K_BENCHMARK "
                + "migration=\(format(migrationSeconds))s "
                + "searchP95=\(formatMilliseconds(percentile95(searchSamples)))ms "
                + "databaseBytes=\(databaseBytes?.int64Value ?? 0)"
        )

        #expect(report.trackCount == 100_000)
        #expect(result == [document.tracks[99_999].id])
    }

    @Test("Opt-in 100,000-track playback sidecar persistence benchmark")
    func playbackSidecarBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["ONGAKU_RUN_PLAYBACK_SIDECAR_BENCHMARK"] == "1"
        else { return }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ongaku-Playback-Sidecar-100k-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = LargeLibraryFixture.makeDocument()
        let repository = LibraryRepository(rootURL: root)
        try await repository.save(document: document)
        let manifestURL = root.appendingPathComponent("library-v1.json")
        let queueURL = root.appendingPathComponent("playback-queue-v1.json")
        let manifestBefore = try Data(contentsOf: manifestURL)
        let currentID = try #require(document.tracks.first?.id)
        var position = 0.0

        let samples = try await measureAsync(iterations: 10) {
            position += 5
            try await repository.save(playbackQueue: PlaybackQueueState(
                trackIDs: [currentID],
                currentTrackID: currentID,
                position: position
            ))
        }
        let manifestAfter = try Data(contentsOf: manifestURL)
        let queueBytes = try FileManager.default.attributesOfItem(atPath: queueURL.path)[.size]
            as? NSNumber

        print(
            "ONGAKU_PLAYBACK_SIDECAR_100K_BENCHMARK "
                + "samples=10 "
                + "saveP95=\(formatMilliseconds(percentile95(samples)))ms "
                + "manifestBytesWritten=\(manifestBefore == manifestAfter ? 0 : manifestAfter.count) "
                + "queueSidecarBytes=\(queueBytes?.int64Value ?? 0)"
        )

        #expect(manifestAfter == manifestBefore)
        #expect((queueBytes?.int64Value ?? .max) < 4_096)
        let restored = try await LibraryRepository(rootURL: root).load().document
        #expect(restored.playbackQueue?.position == 50)
    }

    private func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func formatMilliseconds(_ seconds: Double) -> String {
        String(format: "%.3f", seconds * 1_000)
    }

    private func search(in tracks: [Track], query: String) -> [Track] {
        tracks.filter {
            $0.title.localizedStandardContains(query)
                || $0.artist.localizedStandardContains(query)
                || $0.album.localizedStandardContains(query)
        }
    }

    private func measure(iterations: Int, operation: () -> Void) -> [Double] {
        let clock = ContinuousClock()
        return (0..<iterations).map { _ in
            let start = clock.now
            operation()
            return seconds(start.duration(to: clock.now))
        }
    }

    private func measureAsync(
        iterations: Int,
        operation: () async throws -> Void
    ) async rethrows -> [Double] {
        let clock = ContinuousClock()
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let start = clock.now
            try await operation()
            samples.append(seconds(start.duration(to: clock.now)))
        }
        return samples
    }

    private func percentile95(_ samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        return sorted[index]
    }
}
