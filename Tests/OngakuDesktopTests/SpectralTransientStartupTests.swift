import AVFoundation
import Testing
@testable import OngakuDesktop

@Suite("Spectral Transient startup fallback")
struct SpectralTransientStartupTests {
    @Test("Unavailable custom audio unit remains a connectable bypass")
    func unavailableAudioUnitUsesBypass() throws {
        let effect = SpectralTransientAudioEffect(makeNode: { nil })
        effect.apply(setting: RealtimeAudioEffectSetting(kind: .spectralTransient, isEnabled: true))
        #expect(!effect.isEnabled)
        #expect(effect.estimatedGainBoostDB == 0)
        let engine = AVAudioEngine()
        effect.attach(to: engine)
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        engine.connect(player, to: effect.inputNode, format: format)
        engine.connect(effect.outputNode, to: engine.mainMixerNode, format: format)
        effect.resetTailState()
        effect.detach(from: engine)
    }
}
