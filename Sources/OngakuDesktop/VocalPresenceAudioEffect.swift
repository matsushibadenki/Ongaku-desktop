import AVFoundation

/// A gentle, full-mix presence contour; it does not isolate a vocal stem.
final class VocalPresenceAudioEffect: AudioEffectNode {
    let kind: RealtimeAudioEffectKind = .vocalPresence
    private(set) var isEnabled = false
    private let equalizer = AVAudioUnitEQ(numberOfBands: 1)
    private(set) var estimatedGainBoostDB = 0.0

    var nodes: [AVAudioNode] { [equalizer] }
    var inputNode: AVAudioNode { equalizer }
    var outputNode: AVAudioNode { equalizer }

    func attach(to engine: AVAudioEngine) {
        engine.attach(equalizer)
        let band = equalizer.bands[0]
        band.filterType = .parametric
        band.frequency = 2_800
        band.bandwidth = 1.2
        band.gain = 0
        band.bypass = false
        equalizer.globalGain = 0
        equalizer.bypass = false
    }

    func connectInternalNodes(engine: AVAudioEngine, format: AVAudioFormat?) {}
    func detach(from engine: AVAudioEngine) { engine.detach(equalizer) }

    func apply(setting: RealtimeAudioEffectSetting) {
        let value = setting.parameters["intensity"] ?? 0.35
        let amount = value.isFinite ? min(1, max(0, value)) : 0
        isEnabled = setting.isEnabled && amount > 0.001
        let gain = isEnabled ? 1.2 * amount : 0
        // A flat band stays in the graph when OFF. The hosts protect enable
        // transitions and interpolate parameter gestures; the final limiter
        // remains responsible for measured peaks.
        equalizer.bands[0].gain = Float(gain)
        estimatedGainBoostDB = gain
    }
}
