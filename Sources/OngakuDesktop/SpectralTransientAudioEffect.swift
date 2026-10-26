import AVFoundation
#if canImport(OngakuAudioDSP)
import OngakuAudioDSP
#endif

/// Gentle band-selective prototype. No analysis window, lookahead or reverb.
final class SpectralTransientAudioEffect: AudioEffectNode {
    let kind: RealtimeAudioEffectKind = .spectralTransient
    private(set) var isEnabled = false
    private let node = OngakuSpectralTransientAudioUnit.makeNode()
    private var unit: OngakuSpectralTransientAudioUnit { node.auAudioUnit as! OngakuSpectralTransientAudioUnit }
    var nodes: [AVAudioNode] { [node] }
    var inputNode: AVAudioNode { node }
    var outputNode: AVAudioNode { node }
    private(set) var estimatedGainBoostDB = 0.0
    var estimatedLatencyFrames: AVAudioFramePosition { 0 }
    var transitionLatency: TimeInterval { 0 }
    func attach(to engine: AVAudioEngine) { engine.attach(node) }
    func connectInternalNodes(engine: AVAudioEngine, format: AVAudioFormat?) {}
    func detach(from engine: AVAudioEngine) { engine.detach(node) }
    func apply(setting: RealtimeAudioEffectSetting) {
        let value = setting.parameters["intensity"] ?? 0.20
        let amount = value.isFinite ? min(1, max(0, value)) : 0
        isEnabled = setting.isEnabled && amount > 0.001
        // Conservative bound for complementary causal branches; final output
        // protection remains authoritative, including during OFF ramp-down.
        estimatedGainBoostDB = isEnabled ? 1.5 * amount : 0
        unit.setAmount(isEnabled ? Float(amount) : 0)
    }
    // Transport calls this behind its existing mute/drain boundary. The render
    // thread consumes the reset request; control never mutates live DSP state.
    func resetTailState() { unit.reset() }
}
