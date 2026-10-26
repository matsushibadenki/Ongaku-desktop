import Foundation
enum Track { typealias ID = UUID }
struct Playlist: Codable, Equatable, Sendable {}

struct ChunkTransferLoadTests {
    func measureLoad() throws {
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
}

try ChunkTransferLoadTests().measureLoad()
