import AVFoundation
#if canImport(OngakuAudioDSP)
import OngakuAudioDSP
#endif

/// The final SRC/channel mapping and user volume precede the linked protector.
/// Ordinary builds keep the stock output path until live-device qualification.
final class FinalOutputProtection {
    static var enabledForBuild: Bool {
        #if ONGAKU_ENABLE_TRUE_PEAK
        true
        #else
        false
        #endif
    }

    private var userVolume: Float = 1
    private var transitionGain: Float = 1
    private var transportGain: Float = 1
    private let conversionMixer = AVAudioMixerNode()
    let protector: AVAudioUnitEffect?
    var isEnabled: Bool { protector != nil }
    var latency: TimeInterval { protector?.auAudioUnit.latency ?? 0 }
    var nodes: [AVAudioNode] {
        guard let protector else { return [] }
        return [conversionMixer, protector]
    }

    init(enabled: Bool = FinalOutputProtection.enabledForBuild) {
        protector = enabled ? OngakuTruePeakAudioUnit.makeNode() : nil
    }

    func attach(to engine: AVAudioEngine) {
        nodes.forEach { engine.attach($0) }
    }

    func inputNode(in engine: AVAudioEngine) -> AVAudioNode {
        isEnabled ? conversionMixer : engine.mainMixerNode
    }

    func setVolume(_ volume: Double, engine: AVAudioEngine) {
        userVolume = Float(volume.isFinite ? min(1, max(0, volume)) : 0)
        updateGain(engine: engine)
    }

    func setTransitionGain(_ gain: Float, engine: AVAudioEngine) {
        transitionGain = gain.isFinite ? min(1, max(0, gain)) : 0
        updateGain(engine: engine)
    }

    func setTransportGain(_ gain: Float, engine: AVAudioEngine) {
        transportGain = gain.isFinite ? min(1, max(0, gain)) : 0
        updateGain(engine: engine)
    }

    private func updateGain(engine: AVAudioEngine) {
        let gain = userVolume * transitionGain * transportGain
        if isEnabled {
            conversionMixer.outputVolume = gain
            engine.mainMixerNode.outputVolume = 1
        } else {
            engine.mainMixerNode.outputVolume = gain
        }
    }

    /// Call after stopping the engine, on every initial connection or route rebuild.
    /// Reject unsupported device formats rather than silently omitting protection.
    func connect(engine: AVAudioEngine, outputFormat: AVAudioFormat) throws {
        if let protector {
            guard outputFormat.sampleRate.isFinite,
                  (8_000...384_000).contains(outputFormat.sampleRate),
                  (1...8).contains(outputFormat.channelCount),
                  let format = AVAudioFormat(standardFormatWithSampleRate: outputFormat.sampleRate,
                                             channels: outputFormat.channelCount) else {
                throw NSError(domain: NSOSStatusErrorDomain,
                              code: Int(kAudioUnitErr_FormatNotSupported))
            }
            engine.connect(conversionMixer, to: protector, format: format)
            engine.connect(protector, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 1
        }
        // Pin the main mixer to the same actual rate and channel count: no later SRC.
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: outputFormat)
    }

    /// Only abrupt transport changes reset the lookahead. Continuous handoffs do not.
    func resetWhileStopped(engine: AVAudioEngine) {
        precondition(!engine.isRunning)
        guard let protector else { return }
        conversionMixer.reset()
        protector.auAudioUnit.reset()
    }
}
