import Foundation

/// Common control-rate policy. This is not an audio-thread/sample-accurate ramp.
enum EffectTransitionPolicy {
    static let protectionFadeOut: TimeInterval = 0.008
    static let protectionFadeIn: TimeInterval = 0.016
    static let maximumSettle: TimeInterval = 0.060
    static let protectionWindow = protectionFadeOut + maximumSettle + protectionFadeIn

    /// Algorithmic latency only: intentional predelay/reverb is handled by the
    /// wet-path gate, never by shifting the dry timeline or muting for its duration.
    static func settleDuration(before: TimeInterval, after: TimeInterval) -> TimeInterval {
        guard before.isFinite, after.isFinite, before >= 0, after >= 0 else { return maximumSettle }
        guard abs(before - after) > 0.000001 else { return 0 }
        return min(maximumSettle, max(before, after) + 0.010)
    }

    static func envelopeSteps(duration: TimeInterval) -> Int { max(8, Int(duration / 0.005)) }

    static func envelopeGain(from start: Float, to target: Float, step: Int, steps: Int) -> Float {
        if step == steps { return target }
        let startDB = 20 * log10(max(0.0001, start))
        let targetDB = 20 * log10(max(0.0001, target))
        return pow(10, (startDB + (targetDB - startDB) * Float(step) / Float(steps)) / 20)
    }

    // Transport fades use smaller, bounded amplitude steps. Logarithmic bypass
    // fades would make their largest step immediately next to full volume.
    static let transportSteps = 48

    static func transportGain(from start: Float, to target: Float, step: Int) -> Float {
        if step >= transportSteps { return target }
        let progress = Float(step) / Float(transportSteps)
        let blend = (1 - cos(Float.pi * progress)) * 0.5
        return start + (target - start) * blend
    }

    /// Several modules internally bypass at zero strength even while their UI
    /// switch remains ON. Treat that boundary like a topology/latency change.
    static func effectiveEnabled(_ setting: RealtimeAudioEffectSetting?) -> Bool {
        guard let setting, setting.isEnabled else { return false }
        if setting.kind == .equalizer { return true }
        guard (setting.parameters["intensity"] ?? 1) > 0.001 else { return false }
        return setting.kind != .space || (setting.parameters["amount"] ?? 1) > 0.001
    }

    static let parameterSteps = 8
    static let parameterInterval: TimeInterval = 0.010

    static func interpolate(_ requested: RealtimeAudioEffectSetting,
                            from previous: RealtimeAudioEffectSetting?,
                            fraction: Float) -> RealtimeAudioEffectSetting {
        guard fraction < 1, requested.isEnabled, let previous else { return requested }
        var result = requested
        for (key, value) in requested.parameters {
            let start = previous.parameters[key] ?? value
            result.parameters[key] = start + (value - start) * Double(fraction)
        }
        return result
    }
}
