import SwiftUI
import Testing
@testable import OngakuDesktop

@Suite("Effect rack rendering boundaries", .serialized)
@MainActor
struct EffectRackRenderingTests {
    @Test("Unchanged cards ignore unrelated controller changes; parameter and enable edits propagate")
    func cardBoundary() {
        let player = PlaybackController()
        let otherPlayer = PlaybackController()
        defer { player.clearCurrentTrack(); otherPlayer.clearCurrentTrack() }
        let original = RealtimeAudioEffectSetting(kind: .spectralTransient)
        let first = EffectModuleCard(setting: original, player: player)
        player.volume = 0.45
        #expect(first == EffectModuleCard(setting: original, player: player))
        var edited = original
        edited.parameters["intensity"] = 0.75
        #expect(first != EffectModuleCard(setting: edited, player: player))
        edited = original
        edited.isEnabled.toggle()
        #expect(first != EffectModuleCard(setting: edited, player: player))
        #expect(first != EffectModuleCard(setting: original, player: otherPlayer))
    }

    @Test("Repeated size/place proposals reuse exact geometry; resize and invalidation remeasure")
    func layoutReuse() {
        var cache = EffectLayoutMeasurementCache<CGSize>()
        var measurements = 0
        func measure(_ width: CGFloat) -> CGSize {
            measurements += 1
            return CGSize(width: width, height: 123 + width / 7)
        }
        for _ in 0..<100 {
            #expect(cache.value(width: 420, configuration: [16]) { measure(420) } == CGSize(width: 420, height: 183))
            #expect(cache.value(width: 900, configuration: [16]) { measure(900) } == CGSize(width: 900, height: 123 + 900.0 / 7))
        }
        #expect(measurements == 2)
        cache.invalidate() // Same hook both production Layouts call on child updates.
        _ = cache.value(width: 420, configuration: [16]) { measure(420) }
        #expect(measurements == 3)
        _ = cache.value(width: 420, configuration: [20]) { measure(420) }
        #expect(measurements == 4)
        // Window probes must remain bounded and correct even with many widths.
        for width in 0..<100 {
            let w = CGFloat(width)
            #expect(cache.value(width: w, configuration: [20]) { measure(w) } == CGSize(width: w, height: 123 + w / 7))
        }
        #expect(measurements == 104)
    }
}
