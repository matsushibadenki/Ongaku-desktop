import Foundation

struct AudioSignalPathSnapshot: Equatable, Sendable {
    let sourceSampleRate: Double
    let sourceChannelCount: UInt32
    let processingSampleRate: Double
    let processingChannelCount: UInt32
    let outputSampleRate: Double
    let outputChannelCount: UInt32
    let enabledEffects: [RealtimeAudioEffectKind]
    let effectsBypassed: Bool
    let normalizationMode: LoudnessNormalizationMode
    let normalizationGainDB: Double
    let normalizationLimitedByPeak: Bool

    var sourceIsUnmodified: Bool { true }

    var diagnosticLine: String {
        let effects = effectsBypassed
            ? "bypassed"
            : (enabledEffects.isEmpty ? "none" : enabledEffects.map(\.rawValue).joined(separator: ","))
        let normalization = normalizationMode == .off
            ? "off"
            : String(
                format: "%@:%+.2fdB%@",
                normalizationMode.rawValue,
                normalizationGainDB,
                normalizationLimitedByPeak ? ":peak-limited" : ""
            )
        return [
            "source=\(Self.format(sourceSampleRate, sourceChannelCount))",
            "processing=\(Self.format(processingSampleRate, processingChannelCount))",
            "dsp=\(effects)",
            "normalization=\(normalization)",
            "output=\(Self.format(outputSampleRate, outputChannelCount))",
            "sourceMutation=none",
        ].joined(separator: " ")
    }

    static func format(_ sampleRate: Double, _ channelCount: UInt32) -> String {
        "\(Int(sampleRate.rounded()))Hz/\(channelCount)ch"
    }
}
