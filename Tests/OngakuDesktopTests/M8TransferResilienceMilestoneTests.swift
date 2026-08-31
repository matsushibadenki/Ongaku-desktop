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
}
