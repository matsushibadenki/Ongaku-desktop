import Combine
import Darwin
import Foundation
import Testing
@testable import OngakuDesktop

private final class DeliveryResponder: @unchecked Sendable {
    private let lock = NSLock()
    private var client: DeviceChunkTransferClient?
    private let payloads: [UUID: Data]
    private var timestamps: [UUID: [Int: UInt64]] = [:]
    init(_ payloads: [UUID: Data]) { self.payloads = payloads }
    func connect(_ client: DeviceChunkTransferClient) { lock.withLock { self.client = client } }
    func timestamp(id: UUID, index: Int) -> UInt64? { lock.withLock { timestamps[id]?[index] } }
    func send(_ message: DeviceSyncMessage) throws {
        // Match the wire encode/decode boundary, but deliberately exclude MCSession.
        let requestMessage = try JSONDecoder().decode(DeviceSyncMessage.self, from: JSONEncoder().encode(message))
        guard case .chunkRequest(let request) = requestMessage, let index = request.missingIndexes.first,
              let data = payloads[request.transferID], let target = lock.withLock({ client }) else { return }
        let response = DeviceSyncMessage.chunkPayload(.init(transferID: request.transferID, index: index, data: data))
        let decoded = try JSONDecoder().decode(DeviceSyncMessage.self, from: JSONEncoder().encode(response))
        if case .chunkPayload(let value) = decoded {
            lock.withLock { timestamps[request.transferID, default: [:]][index] = DispatchTime.now().uptimeNanoseconds }
            target.submit(.payload(value))
        }
    }
}

@Suite("Actual worker to Published delivery", .serialized)
struct WorkerDeliveryPerformanceTests {
    private static func cpuMS() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
    }
    @Test("Measure actual checkpoint, mailbox and controller publication") @MainActor
    func measureWorkerPublished() async throws {
        guard ProcessInfo.processInfo.environment["ONGAKU_WORKER_DELIVERY_COST"] == "1" else { return }
        let rows = Int(ProcessInfo.processInfo.environment["ONGAKU_WORKER_HISTORY_ROWS"] ?? "50") ?? 50
        try #require((0...5000).contains(rows))
        for round in 0..<3 {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("OngakuWorkerDelivery-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            var offers: [DeviceChunkTransferDescriptor] = []
            var payloads: [UUID: Data] = [:]
            for file in 0..<4 {
                let chunk = Data(repeating: UInt8(37 + file), count: 65536)
                let full = Data(repeating: UInt8(37 + file), count: chunk.count * 64)
                let item = DeviceSyncItem(id: UUID(), title: "Worker fixture", artist: "Test", album: "Test", fileName: "fixture-\(file).raw",
                    fileSize: Int64(full.count), sha256: DeviceChunkTransfer.sha256(full), modifiedAt: .distantPast)
                let descriptor = DeviceChunkTransferDescriptor(transferID: UUID(), direction: .phoneToMac, item: item,
                    chunkSize: chunk.count, chunkHashes: Array(repeating: DeviceChunkTransfer.sha256(chunk), count: 64), supportsCompactRequests: true)
                offers.append(descriptor); payloads[descriptor.transferID] = chunk
            }
            let responder = DeliveryResponder(payloads)
            let worker = DeviceChunkTransferWorker(checkpointDirectory: root.appendingPathComponent("checkpoints"),
                destination: .directory(root.appendingPathComponent("received")), canReceive: { _ in true }, send: responder.send)
            responder.connect(worker.client)
            defer { worker.client.shutdown() }
            let suite = "OngakuWorkerDelivery-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let controller = PhoneSyncController(defaults: defaults, chunkWorker: worker)
            for _ in 0..<rows {
                controller.applyChunkEvent(.state(worker.client.connection,
                    DeviceTransferState(id: UUID(), item: offers[0].item, direction: .macToPhone, phase: .completed)))
            }
            await withCheckedContinuation { continuation in
                worker.client.submit(.flush { continuation.resume() })
            }
            var lastBytes: [UUID: Int64] = [:]
            var deliveries: [Double] = []
            var publicationCount = 0
            let ids = Set(offers.map(\.transferID))
            let subscription = controller.$transfers.dropFirst().sink { values in
                publicationCount += 1
                let now = DispatchTime.now().uptimeNanoseconds
                for value in values.prefix(4) where ids.contains(value.id) {
                    guard value.bytesTransferred > (lastBytes[value.id] ?? 0),
                          let stamp = responder.timestamp(id: value.id, index: Int(value.bytesTransferred / 65536) - 1) else { continue }
                    lastBytes[value.id] = value.bytesTransferred
                    deliveries.append(Double(now - stamp) / 1_000_000)
                }
            }
            defer { subscription.cancel() }
            let start = DispatchTime.now().uptimeNanoseconds, cpu = Self.cpuMS()
            for offer in offers {
                let wire = try JSONEncoder().encode(DeviceSyncMessage.chunkOffer(offer))
                if case .chunkOffer(let decoded) = try JSONDecoder().decode(DeviceSyncMessage.self, from: wire) {
                    worker.client.submit(.offer(decoded))
                }
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(45))
            while !ids.allSatisfy({ id in controller.transfers.first(where: { $0.id == id })?.phase == .completed }) {
                try #require(ContinuousClock.now < deadline, "Worker delivery benchmark timed out")
                try await Task.sleep(for: .milliseconds(2))
            }
            await withCheckedContinuation { continuation in
                worker.client.submit(.flush { continuation.resume() })
            }
            let wall = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            let cpuDelta = Self.cpuMS() - cpu
            try #require(deliveries.count == 256)
            #expect(controller.transfers.count == rows + 4)
            for offer in offers {
                #expect(controller.transfers.first { $0.id == offer.transferID }?.bytesTransferred == offer.item.fileSize)
            }
            let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("received"), includingPropertiesForKeys: nil)
            #expect(files.count == 4)
            #expect(Set(try files.map { try DeviceSyncFileIntegrity.sha256(of: $0) }) == Set(offers.map { $0.item.sha256 }))
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            let sorted = deliveries.sorted()
            print("WORKER_DELIVERY rows=\(rows) round=\(round) files=4 bytes=16777216 chunks=256 publications=\(publicationCount) wall_ms=\(wall) cpu_ms=\(cpuDelta) receipt_to_published_p50_ms=\(sorted[127]) receipt_to_published_p95_ms=\(sorted[243]) max_ms=\(sorted.last!) process_peak_rss_bytes=\(usage.ru_maxrss)")
        }
    }
}
