import Foundation
import Combine
enum Track { typealias ID = UUID }
struct Playlist: Codable, Equatable, Sendable {}
func timed(_ body: () throws -> Void) rethrows -> Double {
    let t = DispatchTime.now().uptimeNanoseconds; try body()
    return Double(DispatchTime.now().uptimeNanoseconds-t)/1_000_000
}
@MainActor final class Projection: ObservableObject {
    @Published var transfers: [DeviceTransferState] = []
    @Published var checkpoints: [DeviceTransferCheckpointSummary] = []
    var notifications = 0
    var token: AnyCancellable?
    init(item: DeviceSyncItem, id: UUID) {
        transfers = (0..<100).map { _ in .init(id:UUID(),item:item,direction:.macToPhone,phase:.completed) }
        transfers.append(.init(id:id,item:item,direction:.macToPhone,phase:.transferring))
        token = objectWillChange.sink { [weak self] in self?.notifications += 1 }
    }
    func apply(_ state: DeviceTransferState, _ checkpoint: DeviceTransferCheckpointSummary) {
        #if RECEIPTS
        state.applyProjection(to: &transfers)
        #else
        if let index = transfers.firstIndex(where:{$0.id == state.id}) { transfers[index] = state }
        else { transfers.insert(state,at:0) }
        #endif
        checkpoints = [checkpoint]
    }
}
try await Task.detached {
for count in [4096,16384,65536] {
 for run in 0..<3 {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReceiveLoad-\(UUID())")
    defer { try? FileManager.default.removeItem(at:root) }
    let payload = Data(repeating:31,count:65536), hash = DeviceChunkTransfer.sha256(payload)
    let item = DeviceSyncItem(id:UUID(),title:"Receive load",artist:"",album:"",fileName:"load",fileSize:Int64(count*payload.count),sha256:hash,modifiedAt:.distantPast)
    let descriptor = DeviceChunkTransferDescriptor(transferID:UUID(),direction:.macToPhone,item:item,chunkSize:payload.count,chunkHashes:Array(repeating:hash,count:count),supportsCompactRequests:true)
    let validated = try ValidatedDeviceChunkTransferDescriptor(descriptor)
    let store = DeviceTransferCheckpointStore(directory:root)
    var checkpoint = try store.prepare(validatedDescriptor:validated)
    checkpoint.receivedIndexes = Set(0..<(count/2))
    var checksum:Int64 = 0
    var snapshots:[DeviceTransferCheckpoint] = []
    var copying = checkpoint
    let copyTime = timed {
        for index in (count/2)..<(count/2+64) {
            snapshots.append(copying)
            #if RECEIPTS
            copying.recordReceived(index)
            #else
            copying.receivedIndexes.insert(index)
            #endif
        }
    }
    let progressTime = timed { for snapshot in snapshots { for _ in 0..<4 { checksum += snapshot.completedBytes } } }
    let persistTime = try timed { for snapshot in snapshots { try store.saveProgress(snapshot) } }
    let states = snapshots.map { value -> DeviceTransferState in
        var state = DeviceTransferState(id:descriptor.transferID,item:item,direction:.macToPhone,phase:.transferring)
        state.updateProgress(fraction:Double(value.completedBytes)/Double(item.fileSize),completedBytes:value.completedBytes)
        return state
    }
    let summaries = snapshots.map { DeviceTransferCheckpointSummary(itemSHA256:hash,title:item.title,fileSize:item.fileSize,completedBytes:$0.completedBytes,updatedAt:$0.updatedAt) }
    let model = await MainActor.run { Projection(item:item,id:descriptor.transferID) }
    let start = DispatchTime.now().uptimeNanoseconds
    for index in states.indices { await MainActor.run { model.apply(states[index],summaries[index]) } }
    let uiTime = Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000
    let notices = await MainActor.run { model.notifications }
    let pipeline = try timed {
        for index in (count/2)..<(count/2+64) {
            try store.accept(.init(transferID:descriptor.transferID,index:index,data:payload),validatedDescriptor:validated,checkpoint:&checkpoint)
            for _ in 0..<4 { checksum += checkpoint.completedBytes }
        }
    }
    var joined = checkpoint, cursor = DeviceChunkRequestCursor()
    let joinedModel = await MainActor.run { Projection(item:item,id:descriptor.transferID) }
    var requestBytes = 0
    let joinedStart = DispatchTime.now().uptimeNanoseconds
    for index in (count/2+64)..<(count/2+128) {
        try store.accept(.init(transferID:descriptor.transferID,index:index,data:payload),validatedDescriptor:validated,checkpoint:&joined)
        var state = DeviceTransferState(id:descriptor.transferID,item:item,direction:.macToPhone,phase:.transferring)
        state.updateProgress(fraction:Double(joined.completedBytes)/Double(item.fileSize),completedBytes:joined.completedBytes)
        let summary = DeviceTransferCheckpointSummary(itemSHA256:hash,title:item.title,fileSize:item.fileSize,completedBytes:joined.completedBytes,updatedAt:joined.updatedAt)
        checksum += joined.completedBytes
        let request = cursor.request(descriptor:descriptor,checkpoint:joined)
        requestBytes += try JSONEncoder().encode(DeviceSyncMessage.chunkRequest(request)).count
        let projectedState = state
        await MainActor.run { joinedModel.apply(projectedState,summary) }
    }
    let joinedTime = Double(DispatchTime.now().uptimeNanoseconds-joinedStart)/1_000_000
    let joinedNotices = await MainActor.run { joinedModel.notifications }
    print("RECEIVE_LOAD count=\(count) run=\(run) copy64_ms=\(copyTime) progress256_ms=\(progressTime) persist64_ms=\(persistTime) main64_ms=\(uiTime) acceptProgress64_ms=\(pipeline) joined64_ms=\(joinedTime) requestBytes=\(requestBytes) joinedNotifications=\(joinedNotices) notifications=\(notices) checksum=\(checksum)")
 }
}

}.value
