import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Checkpoint persistence cost")
struct CheckpointPersistenceCostTests {
    private struct Progress: Codable {
        var version = 1
        var generation: UUID
        var count: Int
        var bitmap: Data
        var updatedAt: Date
    }

    @Test("Split checkpoint encoding and atomic replacement cost")
    func measurePersistence() throws {
        guard ProcessInfo.processInfo.environment["ONGAKU_CHECKPOINT_COST"] == "1" else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("OngakuCheckpointCost-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("progress")
        let generation = UUID()
        func milliseconds(_ duration: Duration) -> Double {
            let c = duration.components
            return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
        }
        for count in [4096, 16384, 65536] {
            let bitmap = Data(repeating: 0xaa, count: (count + 7) / 8)
            let progress = Progress(generation: generation, count: count, bitmap: bitmap, updatedAt: .now)
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            let data = try encoder.encode(progress)
            let decoded = try PropertyListDecoder().decode(Progress.self, from: data)
            #expect(decoded.bitmap == bitmap && decoded.count == count && decoded.generation == generation)
            let sha = String(repeating: "a", count: 64)
            let checkpoint = DeviceTransferCheckpoint(
                itemSHA256: sha, fileSize: Int64(count * 2), chunkSize: 2,
                chunkHashes: Array(repeating: String(repeating: "b", count: 64), count: count),
                receivedIndexes: Set(stride(from: 1, to: count, by: 2)),
                updatedAt: progress.updatedAt, storageGeneration: generation
            )
            try DeviceTransferCheckpointStore(directory: dir).saveProgress(checkpoint)
            let actual = try Data(contentsOf: dir.appendingPathComponent("\(sha).progress"))
            let actualProgress = try PropertyListDecoder().decode(Progress.self, from: actual)
            #expect(actualProgress.bitmap == bitmap && actualProgress.count == count && actualProgress.generation == generation)
            #expect(actualProgress.updatedAt == progress.updatedAt)
            var encodeSamples: [Double] = [], writeSamples: [Double] = []
            for round in 0..<9 {
                for stage in (round.isMultiple(of: 2) ? [0, 1] : [1, 0]) {
                    let start = ContinuousClock.now
                    for _ in 0..<64 {
                        if stage == 0 {
                            let e = PropertyListEncoder(); e.outputFormat = .binary
                            _ = try e.encode(progress)
                        } else {
                            try data.write(to: url, options: .atomic)
                        }
                    }
                    let elapsed = milliseconds(start.duration(to: .now))
                    if stage == 0 { encodeSamples.append(elapsed) } else { writeSamples.append(elapsed) }
                }
            }
            print("CHECKPOINT_COST chunks=\(count) iterations=64 encode_ms=\(encodeSamples.sorted()[4]) atomic_write_ms=\(writeSamples.sorted()[4]) bytes=\(data.count)")
        }
    }
    @Test("Pruning keeps fresh summaries and removes only stale files")
    func pruningKeepsFreshSummaries() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("OngakuPruneTest-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DeviceTransferCheckpointStore(directory: dir)
        let cutoff = Date(timeIntervalSince1970: 2000)
        for (index, seconds) in [1000.0, 2000.0, 3000.0].enumerated() {
            let sha = String(format: "%064x", index + 1)
            let checkpoint = DeviceTransferCheckpoint(itemSHA256: sha, fileSize: 4, chunkSize: 2,
                chunkHashes: Array(repeating: String(repeating: "a", count: 64), count: 2),
                receivedIndexes: [0], updatedAt: Date(timeIntervalSince1970: seconds), storageGeneration: UUID())
            try JSONEncoder().encode(checkpoint).write(to: dir.appendingPathComponent("\(sha).json"))
            try store.saveProgress(checkpoint)
            try Data([1]).write(to: dir.appendingPathComponent("\(sha).part"))
        }
        let expected = try store.summaries().filter { $0.updatedAt >= cutoff }
        let result = try store.pruneStaleAndSummarize(before: cutoff)
        #expect(result.removed == 1)
        #expect(result.summaries == expected)
        #expect(try store.summaries() == expected)
        let staleSHA = String(format: "%064x", 1)
        for ext in ["json", "progress", "part"] {
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(staleSHA).\(ext)").path))
        }
    }

    @Test("Measure checkpoint resume and summary loading")
    func measureResumeMetadata() throws {
        guard ProcessInfo.processInfo.environment["ONGAKU_CHECKPOINT_RESUME_COST"] == "1" else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("OngakuCheckpointResume-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func ms(_ duration: Duration) -> Double {
            let c = duration.components
            return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
        }
        for count in [4096, 16384, 65536] {
            let runDir = dir.appendingPathComponent("\(count)")
            try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
            let runStore = DeviceTransferCheckpointStore(directory: runDir)
            let hashes = Array(repeating: String(repeating: "b", count: 64), count: count)
            let received = Set(stride(from: 1, to: count, by: 2))
            for index in 0..<8 {
                let sha = String(format: "%064x", index + 1)
                var checkpoint = DeviceTransferCheckpoint(itemSHA256: sha,
                    itemTitle: "Fixture \(index)", fileSize: Int64(count * 2), chunkSize: 2,
                    chunkHashes: hashes, receivedIndexes: [], updatedAt: .now,
                    storageGeneration: UUID())
                try JSONEncoder().encode(checkpoint).write(to: runDir.appendingPathComponent("\(sha).json"), options: .atomic)
                checkpoint.receivedIndexes = received
                try runStore.saveProgress(checkpoint)
            }
            let sha = String(format: "%064x", 1)
            #expect(try runStore.load(forSHA256: sha)?.receivedCount == count / 2)
            #expect(try runStore.summaries().count == 8)
            var single: [Double] = [], summaries: [Double] = []
            for round in 0..<7 {
                for stage in (round.isMultiple(of: 2) ? [0, 1] : [1, 0]) {
                    let start = ContinuousClock.now
                    if stage == 0 { _ = try runStore.load(forSHA256: sha) }
                    else { _ = try runStore.summaries() }
                    let elapsed = ms(start.duration(to: .now))
                    if stage == 0 { single.append(elapsed) } else { summaries.append(elapsed) }
                }
            }
            let cutoff = Date(timeIntervalSince1970: 0)
            var baseline: [Double] = [], optimized: [Double] = []
            for round in 0..<7 {
                for fast in (round.isMultiple(of: 2) ? [false, true] : [true, false]) {
                    let start = ContinuousClock.now
                    let values: [DeviceTransferCheckpointSummary]
                    if fast {
                        values = try runStore.pruneStaleAndSummarize(before: cutoff).summaries
                    } else {
                        _ = try runStore.removeStale(before: cutoff)
                        values = try runStore.summaries()
                    }
                    let elapsed = ms(start.duration(to: .now))
                    #expect(values.count == 8 && values.allSatisfy { $0.completedBytes == Int64(count) })
                    if fast { optimized.append(elapsed) } else { baseline.append(elapsed) }
                }
            }
            print("CHECKPOINT_RESUME chunks=\(count) fixtures=8 single_ms=\(single.sorted()[3]) summaries_ms=\(summaries.sorted()[3]) prior_prune_ms=\(baseline.sorted()[3]) one_pass_prune_ms=\(optimized.sorted()[3])")
        }
    }

}
