import Foundation
import AVFoundation

/// Shared verbatim with the desktop host. The effect rack's supported format
/// is independent of the file rate and the negotiated hardware output rate.
nonisolated enum AudioProcessingPolicy {
    static let effectSampleRate: Double = 96_000

    static func processingSampleRate(for sourceRate: Double) -> Double {
        // A stable graph also avoids reconnecting the rack when effects toggle.
        effectSampleRate
    }
}

/// Immutable format/route identity shared by both hosts. Retain the complete
/// AVAudioFormat (including channel layout), not only sample rate/channels.
nonisolated struct AudioGraphConfiguration: Equatable {
    let source: AVAudioFormat?
    let processing: AVAudioFormat
    let output: AVAudioFormat
    let routeIdentifier: String

    init?(source: AVAudioFormat? = nil, processing: AVAudioFormat,
          output: AVAudioFormat, routeIdentifier: String?) {
        guard let routeIdentifier, !routeIdentifier.isEmpty,
              [processing, output].allSatisfy({ $0.sampleRate.isFinite && $0.sampleRate > 0 && $0.channelCount > 0 }),
              source.map({ $0.sampleRate.isFinite && $0.sampleRate > 0 && $0.channelCount > 0 }) ?? true else { return nil }
        self.source = source; self.processing = processing
        self.output = output; self.routeIdentifier = routeIdentifier
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        let sourceMatches: Bool
        switch (lhs.source, rhs.source) {
        case (nil, nil): sourceMatches = true
        case let (a?, b?): sourceMatches = a.isEqual(b)
        default: sourceMatches = false
        }
        return sourceMatches && lhs.processing.isEqual(rhs.processing)
            && lhs.output.isEqual(rhs.output) && lhs.routeIdentifier == rhs.routeIdentifier
    }
}

/// Retain allocated render resources, but never carry a retired track's filter,
/// SRC or lookahead history into its replacement. Do not call for live FX OFF.
@MainActor enum AudioGraphLifecycle {
    @discardableResult
    static func resetWhilePaused(_ engine: AVAudioEngine) -> Bool {
        precondition(!engine.isRunning)
#if ONGAKU_STARTUP_AUDIT
        let audit = StartupCostAudit.begin()
        defer { StartupCostAudit.end("graph.resetState", audit) }
#endif
        let reverbs = engine.attachedNodes.compactMap { node -> (AVAudioUnitReverb, AVAudioUnitReverbPreset?, Float, Bool)? in
            guard let reverb = node as? AVAudioUnitReverb else { return nil }
            let preset = reverb.auAudioUnit.currentPreset.flatMap { AVAudioUnitReverbPreset(rawValue: $0.number) }
            return (reverb, preset, reverb.wetDryMix, reverb.bypass)
        }
        engine.reset()
        var reusable = true
        for (reverb, preset, mix, bypass) in reverbs {
            guard let preset else { reusable = false; continue }
            // The stock reverb retains measurable late history after reset.
            // Change away and back while silent to rebuild the same room kernel.
            reverb.loadFactoryPreset(preset == .smallRoom ? .largeRoom : .smallRoom)
            reverb.loadFactoryPreset(preset)
            reverb.wetDryMix = mix
            reverb.bypass = bypass
        }
        // An unknown/custom preset must never be replaced with a guessed voice.
        return reusable
    }
}
