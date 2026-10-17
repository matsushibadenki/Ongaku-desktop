import Foundation

/// Shared verbatim with the desktop host. The effect rack's supported format
/// is independent of the file rate and the negotiated hardware output rate.
nonisolated enum AudioProcessingPolicy {
    static let effectSampleRate: Double = 96_000

    static func processingSampleRate(for sourceRate: Double) -> Double {
        // A stable graph also avoids reconnecting the rack when effects toggle.
        effectSampleRate
    }
}
