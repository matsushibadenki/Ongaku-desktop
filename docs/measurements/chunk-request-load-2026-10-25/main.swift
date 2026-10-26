import Foundation
import Darwin
enum Track { typealias ID = UUID }
struct Playlist: Codable, Equatable, Sendable {}
func timed(_ body: () throws -> Void) rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    try body()
    return Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000
}
func ipc(_ data: Data, _ sockets: [Int32]) throws {
    try data.withUnsafeBytes { raw in
        var offset = 0
        var scratch = [UInt8](repeating: 0, count: 4096)
        while offset < raw.count {
            let n = Darwin.write(sockets[0], raw.baseAddress!.advanced(by: offset), min(4096,raw.count-offset))
            guard n > 0 else { throw POSIXError(.EIO) }
            var drained = 0
            while drained < n {
                let r = Darwin.read(sockets[1], &scratch, min(scratch.count,n-drained))
                guard r > 0 else { throw POSIXError(.EIO) }
                drained += r
            }
            offset += n
        }
    }
}
for count in [4096,16384] {
    for run in 0..<3 {
        let hash = String(repeating: "a", count: 64)
        let item = DeviceSyncItem(id: UUID(), title: "Request load", artist: "", album: "", fileName: "load", fileSize: Int64(count*262144), sha256: hash, modifiedAt: .distantPast)
        var descriptor = DeviceChunkTransferDescriptor(transferID: UUID(), direction: .macToPhone, item: item, chunkSize: 262144, chunkHashes: Array(repeating: hash, count: count))
        #if COMPACT
        descriptor.supportsCompactRequests = true
        var cursor = DeviceChunkRequestCursor()
        #endif
        var checkpoint = DeviceTransferCheckpoint(itemSHA256: hash, fileSize: item.fileSize, chunkSize: descriptor.chunkSize, chunkHashes: descriptor.chunkHashes, receivedIndexes: Set(0..<(count/2)), updatedAt: .distantPast)
        var requests: [DeviceChunkRequest] = [], packets: [Data] = []
        var checksum = 0
        let scan = timed {
            for _ in 0..<64 {
                #if COMPACT
                let request = cursor.request(descriptor: descriptor, checkpoint: checkpoint)
                #else
                let request = DeviceChunkRequest(transferID: descriptor.transferID, missingIndexes: checkpoint.missingIndexes)
                #endif
                requests.append(request)
                let index = request.missingIndexes.first!
                checksum += index
                checkpoint.receivedIndexes.insert(index)
            }
        }
        let encoding = try timed { for request in requests { packets.append(try JSONEncoder().encode(DeviceSyncMessage.chunkRequest(request))) } }
        var sockets = [Int32](repeating: 0,count: 2)
        guard socketpair(AF_UNIX,SOCK_STREAM,0,&sockets) == 0 else { throw POSIXError(.EIO) }
        let sending: Double
        do { sending = try timed { for packet in packets { try ipc(packet,sockets) } } }
        catch { close(sockets[0]);close(sockets[1]);throw error }
        close(sockets[0]);close(sockets[1])
        print("REQUEST_LOAD count=\(count) run=\(run) scan64_ms=\(scan) encode64_ms=\(encoding) ipc64_ms=\(sending) bytes64=\(packets.reduce(0){$0+$1.count}) checksum=\(checksum)")
    }
}
