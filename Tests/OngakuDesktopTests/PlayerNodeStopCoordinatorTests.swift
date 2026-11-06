import AVFoundation
import Foundation
import Testing
import os
@testable import OngakuDesktop

@MainActor
@Suite("Player node asynchronous retirement", .serialized)
struct PlayerNodeStopCoordinatorTests {
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw CocoaError(.userCancelled) }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test("A blocked stop runs off MainActor without blocking another UI operation")
    func blockedStopDoesNotBlockUI() async throws {
        let engine = AVAudioEngine(), node = AVAudioPlayerNode()
        let release = DispatchSemaphore(value: 0)
        let state = OSAllocatedUnfairLock(initialState: (started: false, main: false))
        let coordinator = PlayerNodeStopCoordinator(nodes: [node], stopNode: { _ in
            state.withLock { $0 = (true, Thread.isMainThread) }
            _ = release.wait(timeout: .now() + 5)
        })
        defer { release.signal() }
        coordinator.willSchedule(node)
        var completed = false
        coordinator.stop([node], engine: engine, retaining: []) { completed = true }
        try await waitUntil { state.withLock { $0.started } }
        #expect(!state.withLock { $0.main })
        #expect(coordinator.isBusy && !completed && !coordinator.areStopped([node]))
        var uiTurn = false
        let ui = Task { @MainActor in uiTurn = true }
        await ui.value
        #expect(uiTurn && !completed)
        release.signal()
        try await waitUntil { completed }
        #expect(!coordinator.isBusy && coordinator.areStopped([node]))
    }

    @Test("Overlapping stop requests coalesce per node and await all required stops")
    func overlappingStops() async throws {
        let engine = AVAudioEngine(), first = AVAudioPlayerNode(), second = AVAudioPlayerNode()
        var work: [@Sendable () -> Void] = []
        let coordinator = PlayerNodeStopCoordinator(nodes: [first, second], execute: { work.append($0) }, stopNode: { _ in })
        coordinator.willSchedule(first); coordinator.willSchedule(second)
        var firstDone = false, bothDone = 0
        coordinator.stop([first], engine: engine, retaining: []) { firstDone = true }
        coordinator.stop([first, second], engine: engine, retaining: []) { bothDone += 1 }
        coordinator.stop([first, second], engine: engine, retaining: []) { bothDone += 1 }
        #expect(work.count == 2)
        work.removeFirst()()
        try await waitUntil { firstDone }
        #expect(bothDone == 0 && coordinator.isBusy)
        #expect(coordinator.areStopped([first]) && !coordinator.areStopped([second]))
        work.removeFirst()()
        try await waitUntil { bothDone == 2 }
        #expect(!coordinator.isBusy && coordinator.areStopped([first, second]))
        coordinator.stop([first, second], engine: engine, retaining: []) { bothDone += 1 }
        #expect(work.isEmpty && bothDone == 3)
        coordinator.willSchedule(first)
        #expect(!coordinator.areStopped([first]))
    }

    @Test("Transport stays busy through asynchronous resource retirement")
    func envelopeTracksRetirement() {
        let envelope = TransportOutputEnvelope(setGain: { _ in })
        envelope.beginResourceRetirement()
        var committed = false
        envelope.stop(running: false, drain: 0) { committed = true }
        #expect(committed && !envelope.isStopping && envelope.isBusy)
        envelope.endResourceRetirement()
        #expect(!envelope.isBusy)
    }
}
