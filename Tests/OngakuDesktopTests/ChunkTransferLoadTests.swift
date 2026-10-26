import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Large chunk transfer load", .serialized)
struct ChunkTransferLoadTests {
    @Test func measureLoad() throws {
        guard ProcessInfo.processInfo.environment["ONGAKU_CHUNK_LOAD"] == "1" else { return }
        for count in [4096, 16384] {
            for run in 0..<3 {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChunkLoad-\(UUID())")
                defer { try? FileManager.default.removeItem(at: root) }
                let data = Data(repeating: 37, count: 65536)
                let hash = DeviceChunkTransfer.sha256(data)
                let item = DeviceSyncItem(id: UUID(), title: "Load", artist: "", album: "", fileName: "load.raw", fileSize: Int64(count * data.count), sha256: hash, modifiedAt: .now)
                let dto = DeviceChunkTransferDescriptor(transferID: UUID(), direction: .macToPhone, item: item, chunkSize: data.count, chunkHashes: Array(repeating: hash, count: count))
                let validated = try ValidatedDeviceChunkTransferDescriptor(dto)
                let store = DeviceTransferCheckpointStore(directory: root)
                var checkpoint = try store.prepare(validatedDescriptor: validated)
                // Synthetic half-received metadata isolates bookkeeping; no final-file integrity claim.
                checkpoint.receivedIndexes = Set(0..<(count/2))
                var checksum: Int64 = 0
                func timed(_ work: () throws -> Void) rethrows -> Double {
                    let start = DispatchTime.now().uptimeNanoseconds
                    try work()
                    return Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000
                }
                let scan = timed { for _ in 0..<64 { checksum += Int64(checkpoint.missingIndexes.count) } }
                let progress = timed { for _ in 0..<64 { checksum += checkpoint.completedBytes } }
                let accept = try timed {
                    for index in (count/2)..<(count/2+64) {
                        try store.accept(.init(transferID: dto.transferID, index: index, data: data), validatedDescriptor: validated, checkpoint: &checkpoint)
                    }
                }
                let bytes = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey]).filter { $0.pathExtension != "part" }.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
                print("CHUNK_LOAD count=\(count) run=\(run) scan64_ms=\(scan) progress64_ms=\(progress) accept64_ms=\(accept) metadata_bytes=\(bytes) checksum=\(checksum)")
            }
        }
    }

    @Test func compactProgressRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChunkProgress-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data(repeating: 91, count: 65536)
        let hash = DeviceChunkTransfer.sha256(bytes)
        let item = DeviceSyncItem(id: UUID(), title: "Resume", artist: "", album: "", fileName: "resume.raw", fileSize: Int64(bytes.count * 9), sha256: hash, modifiedAt: .now)
        let descriptor = DeviceChunkTransferDescriptor(transferID: UUID(), direction: .macToPhone, item: item, chunkSize: bytes.count, chunkHashes: Array(repeating: hash, count: 9))
        let store = DeviceTransferCheckpointStore(directory: root)
        var checkpoint = try store.prepare(for: descriptor)
        let metadata = root.appendingPathComponent("\(hash).json")
        let progress = root.appendingPathComponent("\(hash).progress")
        let initial = try Data(contentsOf: metadata)
        for index in [8, 0, 5, 0] {
            try store.accept(.init(transferID: descriptor.transferID, index: index, data: bytes), descriptor: descriptor, checkpoint: &checkpoint)
        }
        #expect(try Data(contentsOf: metadata) == initial)
        let resumed = try store.prepare(for: descriptor)
        #expect(resumed.receivedIndexes == [0, 5, 8])
        #expect(resumed.completedBytes == Int64(bytes.count * 3))
        #expect(try store.summaries().first?.completedBytes == resumed.completedBytes)

        // A failed atomic progress write cannot publish an in-memory acknowledgement.
        try FileManager.default.removeItem(at: progress)
        try FileManager.default.createDirectory(at: progress, withIntermediateDirectories: false)
        let before = checkpoint
        #expect(throws: (any Error).self) {
            try store.accept(.init(transferID: descriptor.transferID, index: 1, data: bytes), descriptor: descriptor, checkpoint: &checkpoint)
        }
        #expect(checkpoint == before)
        try FileManager.default.removeItem(at: progress)

        // Old JSON checkpoints migrate once. Reopening never trusts replacement generations.
        checkpoint.storageGeneration = nil
        try JSONEncoder().encode(checkpoint).write(to: metadata, options: .atomic)
        var legacy = try store.prepare(for: descriptor)
        #expect(legacy.receivedIndexes == [0, 5, 8])
        try store.accept(.init(transferID: descriptor.transferID, index: 2, data: bytes), descriptor: descriptor, checkpoint: &legacy)
        #expect(legacy.storageGeneration != nil)
        #expect(try store.load(forSHA256: hash)?.receivedIndexes == [0, 2, 5, 8])
        var replacement = legacy
        replacement.storageGeneration = UUID()
        replacement.receivedIndexes = []
        try JSONEncoder().encode(replacement).write(to: metadata, options: .atomic)
        #expect(try store.load(forSHA256: hash)?.receivedIndexes.isEmpty == true)
        try store.remove(forSHA256: hash)
        #expect(!FileManager.default.fileExists(atPath: progress.path))
        #expect(try store.summaries().isEmpty)
    }

    @Test func corruptProgressIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChunkCorruptProgress-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data(repeating: 1, count: 65536), hash = DeviceChunkTransfer.sha256(bytes)
        let item = DeviceSyncItem(id: UUID(), title: "Corrupt", artist: "", album: "", fileName: "data", fileSize: Int64(bytes.count), sha256: hash, modifiedAt: .now)
        let descriptor = DeviceChunkTransferDescriptor(transferID: UUID(), direction: .phoneToMac, item: item, chunkSize: bytes.count, chunkHashes: [hash])
        let store = DeviceTransferCheckpointStore(directory: root)
        var checkpoint = try store.prepare(for: descriptor)
        try store.accept(.init(transferID: descriptor.transferID, index: 0, data: bytes), descriptor: descriptor, checkpoint: &checkpoint)
        let url = root.appendingPathComponent("\(hash).progress")
        let original = try Data(contentsOf: url)
        var object = try #require(PropertyListSerialization.propertyList(from: original, format: nil) as? [String: Any])
        object["bitmap"] = Data()
        try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0).write(to: url)
        #expect(throws: (any Error).self) { try store.load(forSHA256: hash) }
        try Data([1, 2, 3]).write(to: url)
        #expect(throws: (any Error).self) { try store.load(forSHA256: hash) }
        try store.removeAll()
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }


    @Test func largeSparseCheckpointResumesShortFinalChunk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChunkLargeResume-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data(repeating: 47, count: 65536), tail = Data(repeating: 48, count: 7)
        let hash = DeviceChunkTransfer.sha256(bytes), tailHash = DeviceChunkTransfer.sha256(tail)
        let item = DeviceSyncItem(id: UUID(), title: "Large resume", artist: "", album: "", fileName: "sparse", fileSize: Int64(16384 * bytes.count + tail.count), sha256: hash, modifiedAt: .now)
        var descriptor = DeviceChunkTransferDescriptor(transferID: UUID(), direction: .macToPhone, item: item, chunkSize: bytes.count, chunkHashes: Array(repeating: hash, count: 16384) + [tailHash])
        let store = DeviceTransferCheckpointStore(directory: root)
        var checkpoint = try store.prepare(for: descriptor)
        for index in [16384, 0, 8192] {
            try store.accept(.init(transferID: descriptor.transferID, index: index, data: index == 16384 ? tail : bytes), descriptor: descriptor, checkpoint: &checkpoint)
        }
        descriptor.transferID = UUID()
        let resumed = try store.prepare(for: descriptor)
        #expect(resumed.receivedIndexes == [0, 8192, 16384])
        #expect(resumed.completedBytes == Int64(2 * bytes.count + tail.count))
        #expect(resumed.missingIndexes.count == 16382)
        #expect(!resumed.isComplete)
        #expect(try store.summaries().first?.completedBytes == resumed.completedBytes)
    }
}
