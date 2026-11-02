import Combine
import Foundation
import Testing
@testable import OngakuDesktop

@MainActor private final class ProjectionProbe {
    @Published var values: [DeviceTransferState]
    var events = 0
    private var subscription: AnyCancellable?
    init(_ initial: [DeviceTransferState]) {
        values = initial
        subscription = $values.dropFirst().sink { [weak self] _ in self?.events += 1 }
    }
}

@Suite("Transfer history projection performance")
struct TransferProjectionPerformanceTests {
    @Test("Indexed projections preserve updates, ordering and invalidated lookups")
    func indexedProjectionMatchesReference() {
        let item = DeviceSyncItem(id: UUID(), title: "Fixture", artist: "Artist", album: "Album",
            fileName: "fixture.flac", fileSize: 100, sha256: String(repeating: "a", count: 64), modifiedAt: .now)
        var rows: [DeviceTransferState] = [], reference: [DeviceTransferState] = []
        var index = DeviceTransferProjectionIndex()
        let ids = (0..<80).map { _ in UUID() }
        for i in 0..<800 {
            var state = DeviceTransferState(id: ids[(i * 37) % ids.count], item: item,
                direction: .macToPhone, phase: i.isMultiple(of: 7) ? .cancelled : .transferring)
            state.updateProgress(fraction: Double(i % 100) / 100, completedBytes: Int64(i % 100))
            state.applyProjection(to: &reference)
            index.apply(state, to: &rows)
            #expect(rows == reference)
            #expect(index.index(of: state.id, in: rows) == rows.firstIndex { $0.id == state.id })
            if i == 300 || i == 600 {
                rows.reverse(); reference.reverse()
            }
            if i == 400 {
                rows.removeLast(); reference.removeLast()
            }
        }
        #expect(index.index(of: UUID(), in: rows) == nil)
    }

    @Test("Measure Published progress projection with large histories") @MainActor
    func measurePublishedProjection() throws {
        guard ProcessInfo.processInfo.environment["ONGAKU_TRANSFER_PROJECTION_COST"] == "1" else { return }
        let item = DeviceSyncItem(id: UUID(), title: "Fixture", artist: "Artist", album: "Album",
            fileName: "fixture.flac", fileSize: 1048576, sha256: String(repeating: "a", count: 64), modifiedAt: .now)
        func ms(_ duration: Duration) -> Double {
            let c = duration.components
            return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
        }
        for count in [50, 500, 5000] {
            let initial = (0..<count).map { _ in DeviceTransferState(id: UUID(), item: item, direction: .macToPhone, phase: .transferring) }
            var baseline: [Double] = [], indexed: [Double] = []
            var expected: [DeviceTransferState]?
            for round in 0..<7 {
                for fast in (round.isMultiple(of: 2) ? [false, true] : [true, false]) {
                    let probe = ProjectionProbe(initial)
                    var lookup = DeviceTransferProjectionIndex()
                    let start = ContinuousClock.now
                    for i in 0..<128 {
                        var state = initial[count - 1 - (i % min(4, count))]
                        state.updateProgress(fraction: Double(i) / 128, completedBytes: Int64(i))
                        if fast { lookup.apply(state, to: &probe.values) }
                        else { state.applyProjection(to: &probe.values) }
                    }
                    let elapsed = ms(start.duration(to: .now))
                    #expect(probe.events == 128)
                    #expect(probe.values.count == count)
                    if let expected { #expect(probe.values == expected) } else { expected = probe.values }
                    if fast { indexed.append(elapsed) } else { baseline.append(elapsed) }
                }
            }
            print("TRANSFER_PROJECTION rows=\(count) active=4 updates=128 baseline_ms=\(baseline.sorted()[3]) indexed_ms=\(indexed.sorted()[3])")
        }
    }
}
