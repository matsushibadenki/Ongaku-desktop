import Foundation
import Darwin
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

    @Test("Pause and deferred request state changes atomically")
    func pauseCoordinatorIsAtomic() {
        let coordinator = DeviceChunkTransferPauseCoordinator()
        let transferID = UUID()
        let first = DeviceChunkRequest(transferID: transferID, missingIndexes: [1, 2])
        let latest = DeviceChunkRequest(transferID: transferID, missingIndexes: [2])

        #expect(!coordinator.deferIfPaused(first))
        coordinator.pause(transferID)
        #expect(coordinator.deferIfPaused(first))
        #expect(coordinator.deferIfPaused(latest))
        #expect(coordinator.resume(transferID) == latest)
        #expect(coordinator.resume(transferID) == nil)
        #expect(!coordinator.deferIfPaused(first))
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

        checkpoint.storageGeneration = UUID() // Replacement metadata invalidates the old progress sidecar.
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

    @Test("Received files become visible only after their manifest is durable")
    func receivedLibraryCommitIsDurable() throws {
        let fixture = try makeChunkFixture(byteCount: 180_000)
        defer { fixture.cleanUp() }
        let library = fixture.root.appendingPathComponent("library", isDirectory: true)
        let repository = DeviceReceivedLibraryRepository(directory: library)

        let commit = try repository.commitVerifiedFile(
            at: fixture.sourceURL,
            item: fixture.item
        )

        #expect(!commit.wasAlreadyStored)
        #expect(commit.snapshot.items == [commit.item])
        #expect(try DeviceSyncFileIntegrity.verified(commit.fileURL, matches: commit.item))
        let reloaded = try DeviceReceivedLibraryRepository(directory: library).load()
        #expect(reloaded.items == [commit.item])
        #expect(reloaded.fileURLs[commit.item.id] == commit.fileURL)
    }

    @Test("A manifest failure rolls back the received copy and remains retryable")
    func receivedLibraryCommitRollsBackOnPersistenceFailure() throws {
        enum ForcedFailure: Error { case persist }

        let fixture = try makeChunkFixture(byteCount: 90_000)
        defer { fixture.cleanUp() }
        let library = fixture.root.appendingPathComponent("library", isDirectory: true)
        let failing = DeviceReceivedLibraryRepository(
            directory: library,
            beforePersist: { throw ForcedFailure.persist }
        )

        #expect(throws: ForcedFailure.self) {
            try failing.commitVerifiedFile(at: fixture.sourceURL, item: fixture.item)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
        #expect(try DeviceReceivedLibraryRepository(directory: library).load().items.isEmpty)

        let files = try FileManager.default.contentsOfDirectory(
            at: library,
            includingPropertiesForKeys: nil
        )
        #expect(files.isEmpty)
        let retried = try DeviceReceivedLibraryRepository(directory: library)
            .commitVerifiedFile(at: fixture.sourceURL, item: fixture.item)
        #expect(retried.snapshot.items.count == 1)
    }

    @Test("Retry after a durable commit does not create a duplicate")
    func receivedLibraryCommitIsIdempotent() throws {
        let fixture = try makeChunkFixture(byteCount: 120_000)
        defer { fixture.cleanUp() }
        let library = fixture.root.appendingPathComponent("library", isDirectory: true)
        let repository = DeviceReceivedLibraryRepository(directory: library)

        let first = try repository.commitVerifiedFile(at: fixture.sourceURL, item: fixture.item)
        let retry = try repository.commitVerifiedFile(at: fixture.sourceURL, item: fixture.item)

        #expect(!first.wasAlreadyStored)
        #expect(retry.wasAlreadyStored)
        #expect(retry.item.id == first.item.id)
        #expect(retry.snapshot.items.count == 1)
        #expect(retry.fileURL == first.fileURL)
    }

    @Test("A corrupt primary manifest is preserved and restored from its backup")
    func receivedLibraryRecoversManifestBackup() throws {
        let first = try makeChunkFixture(byteCount: 70_000)
        defer { first.cleanUp() }
        let library = first.root.appendingPathComponent("library", isDirectory: true)
        let repository = DeviceReceivedLibraryRepository(directory: library)
        let firstCommit = try repository.commitVerifiedFile(at: first.sourceURL, item: first.item)

        let secondURL = first.root.appendingPathComponent("second.flac")
        try Data(repeating: 0xA5, count: 80_000).write(to: secondURL)
        let secondItem = DeviceSyncItem(
            id: UUID(),
            title: "Second",
            artist: "Ongaku",
            album: "M8",
            fileName: secondURL.lastPathComponent,
            fileSize: 80_000,
            sha256: try DeviceSyncFileIntegrity.sha256(of: secondURL),
            modifiedAt: .now
        )
        _ = try repository.commitVerifiedFile(at: secondURL, item: secondItem)

        let manifest = library.appendingPathComponent("ongaku-mobile-manifest.json")
        try Data("corrupt".utf8).write(to: manifest, options: .atomic)
        let restored = try DeviceReceivedLibraryRepository(directory: library).load()

        #expect(restored.items == [firstCommit.item])
        #expect(try JSONDecoder().decode(
            [DeviceSyncItem].self,
            from: Data(contentsOf: manifest)
        ) == [firstCommit.item])
        let names = try FileManager.default.contentsOfDirectory(atPath: library.path)
        #expect(names.contains { $0.hasPrefix("ongaku-mobile-manifest.json.corrupt-") })
    }

    @Test("Validated chunk snapshots preserve wire values and byte-exact payloads")
    func validatedSnapshotRoundTrip() throws {
        let fixture = try makeChunkFixture(byteCount: 150_123); defer { fixture.cleanUp() }
        let validated = try DeviceChunkTransfer.validatedDescriptor(for: fixture.item, at: fixture.sourceURL,
            direction: .macToPhone, chunkSize: 65_536)
        let raw = validated.descriptor
        let message = DeviceSyncMessage.chunkOffer(raw)
        let decoded = try JSONDecoder().decode(DeviceSyncMessage.self, from: JSONEncoder().encode(message))
        guard case .chunkOffer(let decodedDescriptor) = decoded else {
            Issue.record("Expected the unchanged chunk offer wire message"); return
        }
        #expect(decodedDescriptor == raw)
        let originalHash = raw.chunkHashes[0]
        let originalSize = raw.item.fileSize
        var edited = validated.descriptor
        edited.chunkHashes[0] = String(repeating: "f", count: 64)
        edited.item.fileSize = 0
        #expect(edited.chunkHashes[0] != originalHash)
        #expect(edited.item.fileSize == 0)
        #expect(validated.descriptor.chunkHashes[0] == originalHash)
        #expect(validated.descriptor.item.fileSize == originalSize)
        #expect(validated.descriptor == raw)
        let store = DeviceTransferCheckpointStore(directory: fixture.checkpointDirectory)
        var checkpoint = try store.prepare(validatedDescriptor: validated)
        for index in raw.chunkHashes.indices {
            let payload = try DeviceChunkTransfer.payload(validatedDescriptor: validated, index: index, fileURL: fixture.sourceURL)
            #expect(payload == (try DeviceChunkTransfer.payload(descriptor: raw, index: index, fileURL: fixture.sourceURL)))
            try store.accept(payload, validatedDescriptor: validated, checkpoint: &checkpoint)
        }
        #expect(checkpoint.isComplete)
        #expect(try Data(contentsOf: store.finalizedFile(descriptor: raw, checkpoint: checkpoint))
            == Data(contentsOf: fixture.sourceURL))
    }

    @Test("Untrusted or edited descriptors cannot acquire validated status")
    func validatedAdmissionRejectsMalformedMetadata() throws {
        let fixture = try makeChunkFixture(byteCount: 100_000); defer { fixture.cleanUp() }
        let raw = try DeviceChunkTransfer.descriptor(for: fixture.item, at: fixture.sourceURL,
            direction: .macToPhone, chunkSize: 65_536)
        let store = DeviceTransferCheckpointStore(directory: fixture.checkpointDirectory)
        var checkpoint = try store.prepare(for: raw)
        let payload = try DeviceChunkTransfer.payload(descriptor: raw, index: 0, fileURL: fixture.sourceURL)
        for field in 0..<5 {
            var invalid = raw
            switch field {
            case 0: invalid.chunkSize = 1
            case 1: invalid.chunkHashes.removeLast()
            case 2: invalid.chunkHashes[0] = "not-a-hash"
            case 3: invalid.item.fileSize = -1
            default: invalid.item.sha256 = "invalid"
            }
            #expect(throws: DeviceChunkTransferError.invalidDescriptor) {
                try ValidatedDeviceChunkTransferDescriptor(invalid)
            }
            #expect(throws: DeviceChunkTransferError.checkpointMismatch) {
                try store.accept(payload, descriptor: invalid, checkpoint: &checkpoint)
            }
        }
    }

    @Test("Validated receive still rejects corruption, wrong sessions and checkpoint shape")
    func validatedReceiveKeepsIntegrityGuards() throws {
        let fixture = try makeChunkFixture(byteCount: 100_000); defer { fixture.cleanUp() }
        let validated = try DeviceChunkTransfer.validatedDescriptor(for: fixture.item, at: fixture.sourceURL,
            direction: .macToPhone, chunkSize: 65_536)
        let store = DeviceTransferCheckpointStore(directory: fixture.checkpointDirectory)
        var checkpoint = try store.prepare(validatedDescriptor: validated)
        let payload = try DeviceChunkTransfer.payload(validatedDescriptor: validated, index: 0, fileURL: fixture.sourceURL)
        var wrongSession = payload; wrongSession.transferID = UUID()
        #expect(throws: DeviceChunkTransferError.checkpointMismatch) {
            try store.accept(wrongSession, validatedDescriptor: validated, checkpoint: &checkpoint)
        }
        var corrupt = payload; corrupt.data[0] ^= 1
        #expect(throws: DeviceChunkTransferError.chunkHashMismatch) {
            try store.accept(corrupt, validatedDescriptor: validated, checkpoint: &checkpoint)
        }
        var short = payload; short.data.removeLast()
        #expect(throws: DeviceChunkTransferError.invalidChunkSize) {
            try store.accept(short, validatedDescriptor: validated, checkpoint: &checkpoint)
        }
        for field in 0..<3 {
            var invalid = checkpoint
            if field == 0 { invalid.fileSize += 1 }
            else if field == 1 { invalid.chunkSize += 1 }
            else { invalid.chunkHashes[0] = String(repeating: "f", count: 64) }
            #expect(throws: DeviceChunkTransferError.checkpointMismatch) {
                try store.accept(payload, validatedDescriptor: validated, checkpoint: &invalid)
            }
        }
        #expect(checkpoint.receivedIndexes.isEmpty)
        #expect(throws: DeviceChunkTransferError.invalidChunkIndex) {
            try DeviceChunkTransfer.payload(validatedDescriptor: validated, index: -1, fileURL: fixture.sourceURL)
        }
        // The file can change after admission; every read still hashes its bytes.
        let handle = try FileHandle(forWritingTo: fixture.sourceURL)
        try handle.write(contentsOf: Data([255])); try handle.close()
        #expect(throws: DeviceChunkTransferError.chunkHashMismatch) {
            try DeviceChunkTransfer.payload(validatedDescriptor: validated, index: 0, fileURL: fixture.sourceURL)
        }
    }

    @Test("Validated resumed sessions retain chunks but reject an old transfer ID")
    func validatedResumeAndEmptyFiles() throws {
        for count in [0, 150_123] {
            let fixture = try makeChunkFixture(byteCount: count); defer { fixture.cleanUp() }
            let first = try DeviceChunkTransfer.validatedDescriptor(for: fixture.item, at: fixture.sourceURL,
                direction: .macToPhone, chunkSize: 65_536)
            let store = DeviceTransferCheckpointStore(directory: fixture.checkpointDirectory)
            var checkpoint = try store.prepare(validatedDescriptor: first)
            if count > 0 {
                let payload = try DeviceChunkTransfer.payload(validatedDescriptor: first, index: 0, fileURL: fixture.sourceURL)
                try store.accept(payload, validatedDescriptor: first, checkpoint: &checkpoint)
            }
            var resumedRaw = first.descriptor; resumedRaw.transferID = UUID()
            let resumed = try ValidatedDeviceChunkTransferDescriptor(resumedRaw)
            checkpoint = try store.prepare(validatedDescriptor: resumed)
            if count > 0 {
                #expect(checkpoint.receivedIndexes == [0])
                let old = try DeviceChunkTransfer.payload(validatedDescriptor: first, index: 0, fileURL: fixture.sourceURL)
                #expect(throws: DeviceChunkTransferError.checkpointMismatch) {
                    try store.accept(old, validatedDescriptor: resumed, checkpoint: &checkpoint)
                }
            }
            for index in checkpoint.missingIndexes {
                let payload = try DeviceChunkTransfer.payload(validatedDescriptor: resumed, index: index, fileURL: fixture.sourceURL)
                try store.accept(payload, validatedDescriptor: resumed, checkpoint: &checkpoint)
            }
            #expect(checkpoint.isComplete)
            let partial = try store.finalizedFile(descriptor: resumedRaw, checkpoint: checkpoint)
            #expect(try DeviceSyncFileIntegrity.verified(partial, matches: fixture.item))
            if count > 0 {
                // Per-chunk success never substitutes for final whole-file verification.
                let handle = try FileHandle(forWritingTo: partial)
                try handle.write(contentsOf: Data([255])); try handle.close()
                #expect(throws: DeviceChunkTransferError.finalHashMismatch) {
                    try store.finalizedFile(descriptor: resumedRaw, checkpoint: checkpoint)
                }
            }
        }
    }

    @Test("Opt-in repeated chunk preparation comparison")
    func validatedChunkPreparationBenchmark() throws {
        guard ProcessInfo.processInfo.environment["ONGAKU_RUN_CHUNK_PREPARATION_BENCHMARK"] == "1" else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OngakuChunkPerf-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sparse.caf")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let chunkSize = DeviceChunkTransfer.defaultChunkSize, chunkCount = 4096, requests = 64
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(chunkSize * chunkCount)); try handle.close()
        var item = makeItem(fileSize: Int64(chunkSize * chunkCount))
        item.sha256 = try DeviceSyncFileIntegrity.sha256(of: url)
        let raw = DeviceChunkTransferDescriptor(transferID: UUID(), direction: .macToPhone,
            item: item, chunkSize: chunkSize,
            chunkHashes: Array(repeating: DeviceChunkTransfer.sha256(Data(repeating: 0, count: chunkSize)), count: chunkCount))
        func cpu() -> Double {
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
        }
        for round in 0..<3 {
            for fast in (round == 1 ? [true, false] : [false, true]) {
                let start = ContinuousClock.now, cpuStart = cpu()
                // Include the reusable path's one admission validation in timing.
                let validated = fast ? try ValidatedDeviceChunkTransferDescriptor(raw) : nil
                var bytes = 0
                for request in 0..<requests {
                    let index = (request * 61) % chunkCount
                    let payload = try validated.map {
                        try DeviceChunkTransfer.payload(validatedDescriptor: $0, index: index, fileURL: url)
                    } ?? DeviceChunkTransfer.payload(descriptor: raw, index: index, fileURL: url)
                    bytes += payload.data.count
                }
                let elapsed = start.duration(to: ContinuousClock.now).components
                let wall = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
                #expect(bytes == requests * chunkSize)
                print("ONGAKU_CHUNK_PREPARATION round=\(round) validated=\(fast) chunk_size=\(chunkSize) chunks=\(chunkCount) requests=\(requests) wall_ms=\(wall) cpu_ms=\(cpu()-cpuStart) bytes=\(bytes)")
            }
        }
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
