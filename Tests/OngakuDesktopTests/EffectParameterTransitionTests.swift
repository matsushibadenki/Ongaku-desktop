import Foundation
import Testing
@testable import OngakuDesktop

@MainActor
private final class EffectClock {
    var now = 0.0
    var events: [(Double, @MainActor () -> Void)] = []
    func schedule(_ delay: Double, _ action: @escaping @MainActor () -> Void) { events.append((now + delay, action)) }
    func advance(_ target: Double) {
        while let next = events.enumerated().filter({ $0.element.0 <= target }).min(by: { $0.element.0 < $1.element.0 }) {
            let event = events.remove(at: next.offset); now = event.0; event.1()
        }
        now = target
    }
}

@Suite("Effect parameter continuity", .serialized)
@MainActor
struct EffectParameterTransitionTests {
    private func setting(_ value: Double, enabled: Bool = true) -> RealtimeAudioEffectSetting {
        var s = RealtimeAudioEffectSetting(kind: .equalizer, isEnabled: enabled)
        s.parameters["trim"] = value
        return s
    }

    @Test("Continuous changes coalesce into eight steps and settle at the latest target")
    func coalescing() {
        let clock = EffectClock()
        var commits: [[RealtimeAudioEffectSetting]] = []
        let ramp = EffectParameterTransition(isAudible: { true }, shouldDefer: { false }, schedule: clock.schedule) { commits.append($0) }
        ramp.apply([setting(0)], immediately: true)
        commits.removeAll()
        ramp.apply([setting(1)])
        #expect(commits.isEmpty)
        clock.advance(0.0101)
        #expect(abs(commits[0][0].parameters["trim"]! - 0.125) < 0.000001)
        for n in 0..<40 { ramp.apply([setting(Double(n) / 40)]) }
        #expect(clock.events.count == 1)
        clock.advance(0.081)
        #expect(commits.count == 8)
        #expect(ramp.applied[.equalizer] == setting(0.975))
        #expect(clock.events.isEmpty)
        ramp.apply([setting(0.975)])
        #expect(clock.events.isEmpty)
        #expect(commits.count == 8)
    }

    @Test("OFF, restart and graph rebuild reject older queued writes")
    func cancellation() {
        let clock = EffectClock()
        var commits: [RealtimeAudioEffectSetting] = []
        let ramp = EffectParameterTransition(isAudible: { true }, shouldDefer: { false }, schedule: clock.schedule) { commits += $0 }
        ramp.apply([setting(0)], immediately: true)
        ramp.apply([setting(1)])
        clock.advance(0.005)
        ramp.apply([setting(1, enabled: false)])
        clock.advance(0.05)
        #expect(ramp.applied[.equalizer] == setting(1, enabled: false))
        #expect(commits.count == 2)
        ramp.apply([setting(0)])
        ramp.apply([setting(1)])
        clock.advance(0.055)
        ramp.apply([setting(0.2)], immediately: true)
        let cancelledCount = commits.count
        ramp.apply([setting(0.8)]) // Old callback fires before the new one.
        clock.advance(0.061)
        #expect(commits.count == cancelledCount)
        clock.advance(0.14)
        #expect(commits.count == cancelledCount + 8)
        #expect(ramp.applied[.equalizer] == setting(0.8))
        ramp.apply([setting(0.8)], immediately: true, force: true)
        #expect(commits.count == cancelledCount + 9)
    }

    @Test("Disabled-only edits never rewrite unchanged audible modules")
    func inactiveEdits() {
        let clock = EffectClock()
        var writes: [[RealtimeAudioEffectSetting]] = []
        let ramp = EffectParameterTransition(isAudible: { true }, shouldDefer: { false }, schedule: clock.schedule) { writes.append($0) }
        let active = RealtimeAudioEffectSetting(kind: .body, isEnabled: true)
        ramp.apply([active, setting(0, enabled: false)], immediately: true)
        writes.removeAll()
        ramp.apply([active, setting(1, enabled: false)])
        #expect(writes == [[setting(1, enabled: false)]])
        #expect(clock.events.isEmpty)
    }

    @Test("Continuous changes hold during overlap, retain the newest target and settle after pause")
    func crossfadeAndPause() {
        let clock = EffectClock()
        var audible = true, deferred = true
        var writes = 0
        let ramp = EffectParameterTransition(isAudible: { audible }, shouldDefer: { deferred }, schedule: clock.schedule) { _ in writes += 1 }
        ramp.apply([setting(0)], immediately: true)
        ramp.apply([setting(1)])
        clock.advance(0.2)
        ramp.apply([setting(0.7)])
        #expect(writes == 1)
        #expect(clock.events.count == 1)
        deferred = false
        clock.advance(0.231)
        #expect(ramp.applied[.equalizer]!.parameters["trim"]! > 0)
        #expect(ramp.applied[.equalizer]!.parameters["trim"]! < 0.7)
        audible = false
        clock.advance(0.3)
        #expect(ramp.applied[.equalizer] == setting(0.7))
        #expect(clock.events.isEmpty)
    }
}
