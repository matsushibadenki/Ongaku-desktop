import AVFoundation
import Foundation
import OngakuAudioDSP
import Testing
@testable import OngakuDesktop

struct AudioMonitoringVolumeTests {
    @Test func olderOutputDocumentsRetainUnityAndRejectInvalidVolume() throws {
        let original = AudioRoutingDocument.recordingAndMonitoring
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String:Any])
        var nodes = try #require(json["nodes"] as? [[String:Any]])
        nodes[nodes.count-1]["parameters"] = []; json["nodes"] = nodes
        let migrated = try JSONDecoder().decode(AudioRoutingDocument.self,from: JSONSerialization.data(withJSONObject: json))
        #expect(migrated == original)
        var bad = migrated; bad.nodes[bad.nodes.count-1].parameters = [1.01]
        #expect(throws: AudioRoutingError.document) { try bad.validate() }
        var steps = try migrated.plan().nativeSteps
        steps[steps.count-1].p0 = -0.01
        #expect(!steps.withUnsafeBufferPointer { OngakuValidateAudioRoute($0.baseAddress!, UInt($0.count)) })
    }
    @Test func addingOtherSinkBranchesBeforeMonitorGainAndKeepsSettings() throws {
        var doc = AudioRoutingDocument.initial
        var settings = AudioRecordingSettings(); settings.title = "Keep my recording"
        doc.nodes[3].recording = settings
        let output = AudioRoutingNode(kind: .device,x: 744,y: 300)
        var editor = try AudioRoutingEditor(doc)
        try editor.execute(doc.addingNode(output),expectedRevision: 0)
        #expect(editor.document.nodes[3].recording == settings)
        #expect(editor.document.edges.last?.from == doc.nodes[2].id)
        #expect(try editor.document.plan().records && editor.document.plan().monitors)
        editor.undo(); #expect(editor.document == doc)
        var monitor = AudioRoutingDocument.monitoring
        monitor.nodes[3].parameters = [0]
        let recorder = AudioRoutingNode(kind: .recorder,x: 744,y: 300)
        try monitor.addingNode(recorder).apply(to: &monitor)
        #expect(monitor.edges.last?.from == monitor.nodes[2].id)
        #expect(try monitor.plan().records && monitor.plan().monitors)
    }
    @Test @MainActor func liveMonitorPreviewPersistsAndUndoRestoresOnlyVolume() throws {
        let name = "MonitorVolumeTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AudioRoutingStore(defaults: defaults)
        store.perform(.replace(.recordingAndMonitoring))
        let original = store.document, output = try #require(original.nodes.last)
        var received: AudioRoutingDocument?
        store.setLocked(true); store.setLiveUpdate { received = $0 }
        #expect(store.previewParameters(output.id,[0.25]))
        #expect(received?.nodes.last?.parameters == [0.25])
        #expect(store.document == original)
        store.finishParameterEdit()
        #expect(AudioRoutingStore(defaults: defaults).document.nodes.last?.parameters == [0.25])
        #expect(store.document.edges == original.edges)
        store.setLiveUpdate(nil); store.setLocked(false); store.undo()
        #expect(store.document == original)
    }
    @Test(arguments: [false,true])
    func liveVolumeAndMuteNeverAlterRecordingSamples(deviceFirst: Bool) throws {
        var doc = AudioRoutingDocument.recordingAndMonitoring
        if deviceFirst { doc.nodes.swapAt(3,4) }
        let index = try #require(doc.nodes.firstIndex { $0.kind == .device })
        let plan = try doc.plan(), steps = plan.nativeSteps
        let route = try steps.withUnsafeBufferPointer { try OngakuAudioRoute(steps: $0.baseAddress!,count: UInt($0.count),sampleRate: 48000) }
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,sampleRate: 48000,channels: 2,interleaved: true))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format,frameCapacity: 2048))
        let recording = try #require(AVAudioPCMBuffer(pcmFormat: format,frameCapacity: 2048))
        let monitor = try #require(AVAudioPCMBuffer(pcmFormat: format,frameCapacity: 2048))
        for b in [input,recording,monitor] { b.frameLength = 2048 }
        // Nonconstant stereo samples make branch corruption and channel swaps visible.
        for n in 0..<4096 { input.floatChannelData![0][n] = Float(n % 37 - 18) / 64 }
        for volume in [Float(1),0.25,0,0.7,1] {
            doc.nodes[index].parameters = [Double(volume)]
            let changed = try doc.plan().nativeSteps
            try changed.withUnsafeBufferPointer { try route.updateParameters($0.baseAddress!,count: UInt($0.count)) }
            #expect(route.processFrames(2048,input: input.audioBufferList,recording: recording.mutableAudioBufferList,monitor: monitor.mutableAudioBufferList) == noErr)
            for n in 0..<4096 { #expect(recording.floatChannelData![0][n] == input.floatChannelData![0][n]) }
            // A 20 ms ramp affects only monitoring. After 960 frames the target is exact.
            for n in 1920..<4096 { #expect(abs(monitor.floatChannelData![0][n] - input.floatChannelData![0][n]*volume) < 0.000001) }
        }
    }
}
