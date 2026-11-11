import AVFoundation
import Foundation
import OngakuAudioDSP
import Testing
@testable import OngakuDesktop

struct AudioInputBoostTests {
    @Test func legacySourceRetainsUnityAndRejectsInvalidBoost() throws {
        let original = AudioRoutingDocument.recordingAndMonitoring
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var nodes = try #require(json["nodes"] as? [[String: Any]])
        nodes[0]["parameters"] = []; json["nodes"] = nodes
        let migrated = try JSONDecoder().decode(AudioRoutingDocument.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(migrated == original)
        for value in [0.99, 10.01, Double.infinity, Double.nan] {
            var bad = migrated; bad.nodes[0].parameters = [value]
            #expect(throws: AudioRoutingError.document) { try bad.validate() }
            var steps = try original.plan().nativeSteps; steps[0].p0 = Float(value)
            #expect(!steps.withUnsafeBufferPointer { OngakuValidateAudioRoute($0.baseAddress!, UInt($0.count)) })
        }
    }

    @Test @MainActor func liveSourceBoostPersistsAndUndoesWithoutChangingMonitorVolume() throws {
        let name = "InputBoostTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AudioRoutingStore(defaults: defaults)
        store.perform(.replace(.recordingAndMonitoring))
        let original = store.document
        var received: AudioRoutingDocument?
        store.setLocked(true); store.setLiveUpdate { received = $0 }
        #expect(store.previewParameters(original.nodes[0].id, [5]))
        #expect(received?.nodes[0].parameters == [5])
        store.finishParameterEdit()
        #expect(AudioRoutingStore(defaults: defaults).document.nodes[0].parameters == [5])
        #expect(store.document.nodes.last == original.nodes.last)
        #expect(store.document.edges == original.edges)
        store.setLiveUpdate(nil); store.setLocked(false); store.undo()
        #expect(store.document == original)
    }

    @Test(arguments: [false, true])
    func boostReachesBothPortsWithAccurateMeterAndSmoothLiveChanges(planar: Bool) throws {
        var doc = AudioRoutingDocument.recordingAndMonitoring
        doc.nodes[4].parameters = [0.25]
        let steps = try doc.plan().nativeSteps
        let route = try steps.withUnsafeBufferPointer { try OngakuAudioRoute(steps: $0.baseAddress!, count: UInt($0.count), sampleRate: 48000) }
        let inputFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: !planar))
        let outputFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 2048))
        let recording = try #require(AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 2048))
        let monitor = try #require(AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 2048))
        for b in [input, recording, monitor] { b.frameLength = 2048 }
        // Above-unity boosted samples verify float headroom isn't silently clipped.
        for frame in 0..<2048 {
            if planar { input.floatChannelData![0][frame] = 0.3; input.floatChannelData![1][frame] = -0.2 }
            else { input.floatChannelData![0][frame*2] = 0.3; input.floatChannelData![0][frame*2+1] = -0.2 }
        }
        var previous: Float = 1
        for target in [Float(1), 2, 3, 4, 5, 10, 1] {
            doc.nodes[0].parameters = [Double(target)]
            let changed = try doc.plan().nativeSteps
            try changed.withUnsafeBufferPointer { try route.updateParameters($0.baseAddress!, count: UInt($0.count)) }
            #expect(route.processFrames(2048, input: input.audioBufferList, recording: recording.mutableAudioBufferList, monitor: monitor.mutableAudioBufferList) == noErr)
            for frame in 0..<2048 {
                let gain = previous + (target-previous) * min(Float(frame+1)/960, 1)
                let tolerance: Float = frame < 960 ? 0.00005 : 0.00002
                for channel in 0..<2 {
                    let sample: Float = channel == 0 ? 0.3 : -0.2
                    let index = frame*2+channel
                    #expect(abs(recording.floatChannelData![0][index] - sample*gain) < tolerance)
                    #expect(abs(monitor.floatChannelData![0][index] - sample*gain*0.25) < 0.00002)
                }
            }
            let firstGain = previous + (target-previous)/960
            #expect(abs(route.peak(atStep: 0) - max(firstGain,target)*0.3) < 0.00002)
            previous = target
        }
    }
}
