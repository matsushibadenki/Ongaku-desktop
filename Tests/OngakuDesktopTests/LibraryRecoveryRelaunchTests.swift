import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Library recovery relaunch")
@MainActor
struct LibraryRecoveryRelaunchTests {
    @Test("Exit waits for replacement launch and duplicate requests are ignored")
    func replacementBeforeExit() async {
        var events: [String] = []
        var continuation: CheckedContinuation<Void, Never>?
        let relauncher = LibraryRecoveryRelauncher(launch: {
            events.append("launch")
            await withCheckedContinuation { continuation = $0 }
            events.append("ready")
        }, terminate: { events.append("exit") })
        let first = Task { await relauncher.restart() }
        while continuation == nil { await Task.yield() }
        #expect(relauncher.isRelaunching)
        #expect(events == ["launch"])
        await relauncher.restart()
        #expect(events == ["launch"])
        continuation?.resume()
        await first.value
        #expect(events == ["launch", "ready", "exit"])
        await relauncher.restart()
        #expect(events == ["launch", "ready", "exit"])
    }

    @Test("Failed launch keeps current app alive and allows retry without repairing again")
    func failedLaunchCanRetry() async {
        var launches = 0
        var exits = 0
        let relauncher = LibraryRecoveryRelauncher(launch: {
            launches += 1
            if launches == 1 { throw NSError(domain: "TestLaunch", code: 1) }
        }, terminate: { exits += 1 })
        await relauncher.restart()
        #expect(exits == 0 && launches == 1)
        #expect(!relauncher.isRelaunching && relauncher.errorMessage != nil)
        await relauncher.restart()
        #expect(exits == 1 && launches == 2)
        #expect(relauncher.errorMessage == nil)
    }
}
