import Foundation
import Testing
@testable import OngakuDesktop

struct ChunkReceiptBitmapTests {
    private func fixture(_ count: Int) -> (DeviceChunkTransferDescriptor,DeviceTransferCheckpoint) {
        let hash = String(repeating:"a",count:64)
        let size = count == 0 ? 0 : (count-1)*65536+7
        let item = DeviceSyncItem(id:UUID(),title:"Receipts",artist:"",album:"",fileName:"data",fileSize:Int64(size),sha256:hash,modifiedAt:.distantPast)
        let descriptor = DeviceChunkTransferDescriptor(transferID:UUID(),direction:.macToPhone,item:item,chunkSize:65536,chunkHashes:Array(repeating:hash,count:count),supportsCompactRequests:true)
        return (descriptor,.init(itemSHA256:hash,fileSize:item.fileSize,chunkSize:65536,chunkHashes:descriptor.chunkHashes,receivedIndexes:[],updatedAt:.distantPast))
    }

    @Test(arguments: [0,1,7,8,9,4096,16385,65537])
    func receiptModelAgreement(count: Int) throws {
        let (descriptor,empty) = fixture(count)
        var checkpoint = empty, model: Set<Int> = [], seed: UInt64 = 47
        for _ in 0..<64 {
            let previous = checkpoint
            let previousIndexes = previous.receivedIndexes
            if count > 0 {
                seed = seed &* 1664525 &+ 1013904223
                let index = Int(seed % UInt64(count))
                checkpoint.recordReceived(index); checkpoint.recordReceived(index)
                model.insert(index)
                #expect(previous.receivedCount <= checkpoint.receivedCount)
                #expect(previous.receivedIndexes == previousIndexes)
            }
            #expect(checkpoint.receivedIndexes == model)
            #expect(checkpoint.receivedCount == model.count)
            let bytes = model.reduce(Int64(0)) { $0 + min(Int64(descriptor.chunkSize),descriptor.item.fileSize-Int64($1*descriptor.chunkSize)) }
            #expect(checkpoint.completedBytes == bytes)
            #expect(checkpoint.isComplete == (model.count == count))
            var expected = Data(repeating:0,count:(count+7)/8)
            for index in model { expected[index/8] |= UInt8(1) << (index%8) }
            #expect(checkpoint.receivedBitmap == expected)
        }
        #expect(empty.receivedCount == 0)
        let decoded = try JSONDecoder().decode(DeviceTransferCheckpoint.self,from:JSONEncoder().encode(checkpoint))
        #expect(decoded == checkpoint)
    }

    @Test func copyIsolationAndRestoreValidation() throws {
        let (_,original) = fixture(3)
        var first = original
        first.recordReceived(2)
        var second = first
        second.recordReceived(0)
        #expect(original.receivedCount == 0)
        #expect(first.receivedIndexes == [2])
        #expect(first.completedBytes == 7)
        #expect(second.receivedIndexes == [0,2])
        #expect(second.completedBytes == 65543)
        let before = second
        #expect(throws: (any Error).self) { try second.restoreReceivedBitmap(Data([255])) }
        #expect(throws: (any Error).self) { try second.restoreReceivedBitmap(Data()) }
        #expect(second == before)
        let bytes = Data([0,3,0])
        try second.restoreReceivedBitmap(bytes[1..<2])
        #expect(second.receivedIndexes == [0,1])
        second.recordReceived(2)
        #expect(second.isComplete)
        #expect(first.receivedIndexes == [2])
    }

    @Test func legacyJSONAndInvalidIndexes() throws {
        struct Legacy: Codable {
            var itemSHA256: String; var fileSize: Int64; var chunkSize: Int
            var chunkHashes: [String]; var receivedIndexes: Set<Int>; var updatedAt: Date
        }
        let (descriptor,_) = fixture(3)
        let legacy = Legacy(itemSHA256:descriptor.item.sha256,fileSize:descriptor.item.fileSize,chunkSize:descriptor.chunkSize,chunkHashes:descriptor.chunkHashes,receivedIndexes:[0,2],updatedAt:.distantPast)
        let decoded = try JSONDecoder().decode(DeviceTransferCheckpoint.self,from:JSONEncoder().encode(legacy))
        #expect(decoded.receivedIndexes == [0,2])
        #expect(decoded.completedBytes == 65543)
        #expect(decoded.storageGeneration == nil)
        let data = try JSONEncoder().encode(decoded)
        let oldReader = try JSONDecoder().decode(Legacy.self,from:data)
        #expect(oldReader.receivedIndexes == legacy.receivedIndexes)
        let keys = try #require(JSONSerialization.jsonObject(with:data) as? [String:Any])
        #expect(keys["receipts"] == nil)
        var corrupt = decoded
        corrupt.receivedIndexes = [-1,Int.max,0]
        #expect(corrupt.hasInvalidReceivedIndexes)
        #expect(!corrupt.isComplete)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CorruptReceipts-\(UUID())")
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try JSONEncoder().encode(corrupt).write(to:root.appendingPathComponent("\(descriptor.item.sha256).json"))
        let fresh = try DeviceTransferCheckpointStore(directory:root).prepare(for:descriptor)
        #expect(fresh.receivedCount == 0)
        #expect(!fresh.hasInvalidReceivedIndexes)
    }

    @Test func projectionPreservesOrderAndTerminalUpdates() {
        let (descriptor,_) = fixture(3)
        var state = DeviceTransferState(id:descriptor.transferID,item:descriptor.item,direction:.macToPhone,phase:.transferring)
        var rows: [DeviceTransferState] = []
        state.applyProjection(to:&rows)
        let other = DeviceTransferState(id:UUID(),item:descriptor.item,direction:.macToPhone,phase:.paused)
        other.applyProjection(to:&rows)
        state.updateProgress(fraction:0.5,completedBytes:65536)
        state.applyProjection(to:&rows)
        #expect(rows.map(\.id) == [other.id,state.id])
        state.phase = .cancelled
        state.applyProjection(to:&rows)
        #expect(rows.count == 2)
        #expect(rows[1].phase == .cancelled)
        #expect(rows[1].bytesTransferred == 65536)
    }
}
