import Foundation
import Testing
@testable import OngakuDesktop

@Suite("M8 transfer resilience milestone")
struct M8TransferResilienceMilestoneTests {
    @Test("Pause, resume, cancel, and capacity controls survive protocol encoding")
    func transferControlsRoundTrip() throws {
        for action in [
            DeviceTransferControlAction.pause,
            .resume,
            .cancel,
            .insufficientStorage,
        ] {
            let transferID = UUID()
            let message = DeviceSyncMessage.transferControl(.init(
                transferID: transferID,
                action: action
            ))
            let decoded = try JSONDecoder().decode(
                DeviceSyncMessage.self,
                from: JSONEncoder().encode(message)
            )
            guard case .transferControl(let control) = decoded else {
                Issue.record("Expected a transfer control message")
                continue
            }
            #expect(control.transferID == transferID)
            #expect(control.action == action)
        }
    }

    @Test("Capacity preflight keeps a safety reserve")
    func capacityPreflight() {
        let reserve: Int64 = 256 * 1_024 * 1_024
        let fileSize: Int64 = 512 * 1_024 * 1_024
        let available: Int64 = 768 * 1_024 * 1_024
        #expect(DeviceTransferCapacity.canReceive(
            fileSize: fileSize,
            availableBytes: available,
            reserveBytes: reserve
        ))
        #expect(!DeviceTransferCapacity.canReceive(
            fileSize: fileSize + 1,
            availableBytes: available,
            reserveBytes: reserve
        ))
        #expect(!DeviceTransferCapacity.canReceive(
            fileSize: -1,
            availableBytes: 1_024,
            reserveBytes: 0
        ))
    }

    @Test("Reported transfer progress is bounded by the file size")
    func progressBounds() {
        var state = DeviceTransferState(
            id: UUID(),
            item: makeItem(fileSize: 1_000),
            direction: .macToPhone,
            phase: .transferring
        )
        state.updateProgress(fraction: 1.4, completedBytes: 1_400)
        #expect(state.fractionCompleted == 1)
        #expect(state.bytesTransferred == 1_000)

        state.updateProgress(fraction: -0.2, completedBytes: -10)
        #expect(state.fractionCompleted == 0)
        #expect(state.bytesTransferred == 0)
    }

    @Test("Only resumable in-session phases remain active")
    func activePhaseClassification() {
        let item = makeItem(fileSize: 1_000)
        for phase in [
            DeviceTransferState.Phase.preparing,
            .transferring,
            .paused,
            .verifying,
        ] {
            #expect(DeviceTransferState(
                id: UUID(),
                item: item,
                direction: .phoneToMac,
                phase: phase
            ).isActive)
        }
        for phase in [
            DeviceTransferState.Phase.completed,
            .cancelled,
            .interrupted,
            .insufficientStorage,
            .failed("fixture"),
        ] {
            #expect(!DeviceTransferState(
                id: UUID(),
                item: item,
                direction: .phoneToMac,
                phase: phase
            ).isActive)
        }
    }

    @Test("A persisted checkpoint requests only missing chunks after restart")
    func checkpointResume() throws {
        let fixture = try makeChunkFixture(byteCount: 700_000)
        defer { fixture.cleanUp() }
        let descriptor = try DeviceChunkTransfer.descriptor(
            for: fixture.item,
            at: fixture.sourceURL,
            direction: .macToPhone
        )
        let store = DeviceTransferCheckpointStore(directory: fixture.checkpointDirectory)
        var checkpoint = try store.prepare(for: descriptor)
        let first = try DeviceChunkTransfer.payload(
            descriptor: descriptor,
            index: 0,
            fileURL: fixture.sourceURL
        )
        try store.accept(first, descriptor: descriptor, checkpoint: &checkpoint)
        #expect(checkpoint.receivedIndexes == [0])

        let loaded = try store.load(forSHA256: fixture.item.sha256)
        let restored = try #require(loaded)
        #expect(restored.receivedIndexes == [0])
        #expect(restored.missingIndexes == Array(1..<descriptor.chunkCount))

        let resumedDescriptor = try DeviceChunkTransfer.descriptor(
            for: fixture.item,
            at: fixture.sourceURL,
            transferID: UUID(),
            direction: .macToPhone
        )
        #expect(resumedDescriptor.transferID != descriptor.transferID)
        var resumed = try store.prepare(for: resumedDescriptor)
        for index in resumed.missingIndexes.reversed() {
            let payload = try DeviceChunkTransfer.payload(
                descriptor: resumedDescriptor,
                index: index,
                fileURL: fixture.sourceURL
            )
            try store.accept(payload, descriptor: resumedDescriptor, checkpoint: &resumed)
        }
        let duplicate = try DeviceChunkTransfer.payload(
            descriptor: resumedDescriptor,
            index: resumedDescriptor.chunkCount - 1,
            fileURL: fixture.sourceURL
        )
        try store.accept(duplicate, descriptor: resumedDescriptor, checkpoint: &resumed)
        let finalized = try store.finalizedFile(
            descriptor: resumedDescriptor,
            checkpoint: resumed
        )
        #expect(try Data(contentsOf: finalized) == Data(contentsOf: fixture.sourceURL))
    }

    @Test("A corrupt chunk is rejected without advancing the checkpoint")
    func corruptChunkRejected() throws {
        let fixture = try makeChunkFixture(byteCount: 300_000)
        defer { fixture.cleanUp() }
        let descriptor = try DeviceChunkTransfer.descriptor(
            for: fixture.item,
            at: fixture.sourceURL,
            direction: .phoneToMac
        )
        let store = DeviceTransferCheckpointStore(directory: fixture.checkpointDirectory)
        var checkpoint = try store.prepare(for: descriptor)
        let valid = try DeviceChunkTransfer.payload(
            descriptor: descriptor,
            index: 0,
            fileURL: fixture.sourceURL
        )
        let corrupt = DeviceChunkPayload(
            transferID: valid.transferID,
            index: valid.index,
            data: Data(repeating: 0xFF, count: valid.data.count)
        )
        #expect(throws: DeviceChunkTransferError.chunkHashMismatch) {
            try store.accept(corrupt, descriptor: descriptor, checkpoint: &checkpoint)
        }
        #expect(checkpoint.receivedIndexes.isEmpty)
    }

    @Test("Chunk offer, request, payload, and completion survive protocol encoding")
    func chunkProtocolRoundTrip() throws {
        let fixture = try makeChunkFixture(byteCount: 100_000)
        defer { fixture.cleanUp() }
        let descriptor = try DeviceChunkTransfer.descriptor(
            for: fixture.item,
            at: fixture.sourceURL,
            direction: .macToPhone
        )
        let payload = try DeviceChunkTransfer.payload(
            descriptor: descriptor,
            index: 0,
            fileURL: fixture.sourceURL
        )
        let messages: [DeviceSyncMessage] = [
            .chunkOffer(descriptor),
            .chunkRequest(.init(transferID: descriptor.transferID, missingIndexes: [0])),
            .chunkPayload(payload),
            .chunkCompletion(.init(
                transferID: descriptor.transferID,
                sha256: descriptor.item.sha256
            )),
        ]
        for message in messages {
            let data = try JSONEncoder().encode(message)
            let decoded = try JSONDecoder().decode(DeviceSyncMessage.self, from: data)
            switch (message, decoded) {
            case (.chunkOffer(let expected), .chunkOffer(let actual)):
                #expect(actual == expected)
            case (.chunkRequest(let expected), .chunkRequest(let actual)):
                #expect(actual == expected)
            case (.chunkPayload(let expected), .chunkPayload(let actual)):
                #expect(actual == expected)
            case (.chunkCompletion(let expected), .chunkCompletion(let actual)):
                #expect(actual == expected)
            default:
                Issue.record("Chunk protocol message changed kind during encoding")
            }
        }
    }

    @Test("Checkpoint summaries report retained bytes and stale data is removable")
    func checkpointManagement() throws {
        let fixture = try makeChunkFixture(byteCount: 300_000)
        defer { fixture.cleanUp() }
        let descriptor = try DeviceChunkTransfer.descriptor(
            for: fixture.item,
            at: fixture.sourceURL,
            direction: .macToPhone
        )
        let store = DeviceTransferCheckpointStore(directory: fixture.checkpointDirectory)
        var checkpoint = try store.prepare(for: descriptor)
        let payload = try DeviceChunkTransfer.payload(
            descriptor: descriptor,
            index: 0,
            fileURL: fixture.sourceURL
        )
        try store.accept(payload, descriptor: descriptor, checkpoint: &checkpoint)

        let summaries = try store.summaries()
        let summary = try #require(summaries.first)
        #expect(summary.title == fixture.item.title)
        #expect(summary.completedBytes == Int64(payload.data.count))
        #expect(summary.fractionCompleted > 0)
        #expect(summary.fractionCompleted < 1)

        checkpoint.updatedAt = Date(timeIntervalSince1970: 1_000)
        let checkpointURL = fixture.checkpointDirectory
            .appendingPathComponent("\(fixture.item.sha256).json")
        try JSONEncoder().encode(checkpoint).write(to: checkpointURL, options: .atomic)
        #expect(try store.removeStale(before: Date(timeIntervalSince1970: 2_000)) == 1)
        #expect(try store.summaries().isEmpty)

        _ = try store.prepare(for: descriptor)
        try store.removeAll()
        #expect(try store.summaries().isEmpty)
    }

    private func makeItem(fileSize: Int64) -> DeviceSyncItem {
        DeviceSyncItem(
            id: UUID(),
            title: "Transfer Fixture",
            artist: "Ongaku",
            album: "M8",
            fileName: "fixture.flac",
            fileSize: fileSize,
            sha256: String(repeating: "a", count: 64),
            modifiedAt: Date(timeIntervalSince1970: 1_725_000_000)
        )
    }

    private func makeChunkFixture(byteCount: Int) throws -> ChunkFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OngakuM8ChunkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("source.flac")
        let bytes = Data((0..<byteCount).map { UInt8($0 % 251) })
        try bytes.write(to: sourceURL)
        let item = DeviceSyncItem(
            id: UUID(),
            title: "Chunk Fixture",
            artist: "Ongaku",
            album: "M8",
            fileName: sourceURL.lastPathComponent,
            fileSize: Int64(bytes.count),
            sha256: try DeviceSyncFileIntegrity.sha256(of: sourceURL),
            modifiedAt: Date(timeIntervalSince1970: 1_725_000_000)
        )
        return ChunkFixture(
            root: root,
            sourceURL: sourceURL,
            checkpointDirectory: root.appendingPathComponent("checkpoints", isDirectory: true),
            item: item
        )
    }

    private struct ChunkFixture {
        var root: URL
        var sourceURL: URL
        var checkpointDirectory: URL
        var item: DeviceSyncItem

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
