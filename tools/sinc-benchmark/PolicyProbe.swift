import Foundation
import AVFoundation

// Timing probe of the complete shipping file reader + throttle policy on this Mac.
// Not an iPhone performance prediction; decoded fixture is retained by the test.
@main
struct PolicyProbe {
    static func main() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let target = AVAudioFormat(standardFormatWithSampleRate: 96_000, channels: 2)!
        let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 132_300)!
        source.frameLength = source.frameCapacity
        for ch in 0..<2 { for i in 0..<132_300 {
            source.floatChannelData![ch][i] = Float(0.3 * sin(2 * .pi * 997 * Double(i) / 44_100)) * (ch == 0 ? 1 : -0.6)
        } }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SincPolicy-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: source) }
        for phase in [PrecisionSincPhaseMode.linear, .minimumPhase] {
            // Warm the same kernel cache before measuring file preparation.
            let reference = try ShippingSincMeasurement.absolutePositionReference(source, target: target, phase: phase, quality: .master)
            var times: [Double] = []
            var largest = 0.0
            for _ in 0..<5 {
                let start = DispatchTime.now().uptimeNanoseconds
                let result = try ShippingSincMeasurement.makeChunkedPrecisionSincPlaybackBuffer(from: AVAudioFile(forReading: url),
                    sourceFrameCount: source.frameLength, sourceFormat: format, targetFormat: target, phaseMode: phase, qualityMode: .master)
                times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                for ch in 0..<2 { for i in 0..<Int(result.frameLength) {
                    largest = max(largest, abs(Double(result.floatChannelData![ch][i] - reference.floatChannelData![ch][i])))
                } }
            }
            precondition(largest < 2e-6)
            let row: [String: Any] = ["phase": phase.rawValue, "quality": "master", "source_rate": 44100,
                "target_rate": 96000, "duration_seconds": 3, "all_policy_ms": times, "median_policy_ms": times.sorted()[2],
                "max_difference_from_unthrottled": largest]
            print(String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
        }
    }
}
