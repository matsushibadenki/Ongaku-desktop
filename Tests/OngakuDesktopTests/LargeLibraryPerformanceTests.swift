import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Large library performance fixture", .serialized)
struct LargeLibraryPerformanceTests {
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
