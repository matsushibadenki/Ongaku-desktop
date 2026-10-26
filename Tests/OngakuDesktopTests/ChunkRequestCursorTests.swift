import Foundation
import Testing
@testable import OngakuDesktop

struct ChunkRequestCursorTests {
    private func fixture(_ count: Int = 16_385) -> (DeviceChunkTransferDescriptor, DeviceTransferCheckpoint) {
        let hash = String(repeating: "a",count: 64)
        let item = DeviceSyncItem(id: UUID(),title: "Cursor",artist: "",album: "",fileName: "cursor",fileSize: Int64(count*65536),sha256: hash,modifiedAt: .distantPast)
        let descriptor = DeviceChunkTransferDescriptor(transferID: UUID(),direction: .macToPhone,item: item,chunkSize: 65536,chunkHashes: Array(repeating: hash,count: count),supportsCompactRequests: true)
        let checkpoint = DeviceTransferCheckpoint(itemSHA256: hash,fileSize: item.fileSize,chunkSize: 65536,chunkHashes: descriptor.chunkHashes,receivedIndexes: [],updatedAt: .distantPast)
        return (descriptor,checkpoint)
    }

    @Test func sparseResumeAndRepeatedRequests() {
        let (descriptor, original) = fixture()
        var checkpoint = original, cursor = DeviceChunkRequestCursor()
        checkpoint.receivedIndexes = Set(descriptor.chunkHashes.indices).subtracting([1,8192,16384])
        for (index,remaining) in [(1,3),(8192,2),(16384,1)] {
            let request = cursor.request(descriptor: descriptor,checkpoint: checkpoint)
            #expect(request.missingIndexes == [index])
            #expect(request.remainingChunkCount == remaining)
            #expect(cursor.request(descriptor: descriptor,checkpoint: checkpoint) == request)
            checkpoint.receivedIndexes.insert(index)
        }
        #expect(cursor.request(descriptor: descriptor,checkpoint: checkpoint).missingIndexes.isEmpty)
        // A recreated session must scan its own checkpoint, never inherit the old cursor.
        var restarted = DeviceChunkRequestCursor()
        #expect(restarted.request(descriptor: descriptor,checkpoint: original).missingIndexes == [0])
    }

    @Test func legacyCapabilitiesPreserveFullLists() {
        var (descriptor,checkpoint) = fixture(9)
        checkpoint.receivedIndexes = [0,2,8]
        for capability in [nil,false] as [Bool?] {
            descriptor.supportsCompactRequests = capability
            var cursor = DeviceChunkRequestCursor()
            let request = cursor.request(descriptor: descriptor,checkpoint: checkpoint)
            #expect(request.missingIndexes == [1,3,4,5,6,7])
            #expect(request.remainingChunkCount == nil)
        }
    }

    @Test func optionalWireFieldsRemainCompatible() throws {
        struct LegacyRequest: Codable { var transferID: UUID; var missingIndexes: [Int] }
        var (descriptor,_) = fixture(3)
        descriptor.supportsCompactRequests = nil
        let data = try JSONEncoder().encode(descriptor)
        #expect(try JSONDecoder().decode(DeviceChunkTransferDescriptor.self,from:data).supportsCompactRequests == nil)
        let legacy = LegacyRequest(transferID:descriptor.transferID,missingIndexes:[0,1,2])
        let decoded = try JSONDecoder().decode(DeviceChunkRequest.self,from: JSONEncoder().encode(legacy))
        #expect(decoded.remainingChunkCount == nil)
        let compact = DeviceChunkRequest(transferID:descriptor.transferID,missingIndexes:[0],remainingChunkCount:3)
        let oldReader = try JSONDecoder().decode(LegacyRequest.self,from:JSONEncoder().encode(compact))
        #expect(oldReader.missingIndexes == [0])
        #expect(try JSONDecoder().decode(DeviceChunkRequest.self,from: JSONEncoder().encode(compact)) == compact)
    }
}
