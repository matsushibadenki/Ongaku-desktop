import Foundation

/// Common control-rate policy. This is not an audio-thread/sample-accurate ramp.
enum EffectTransitionPolicy {
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
