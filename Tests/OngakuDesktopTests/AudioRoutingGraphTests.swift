import AVFoundation
import Foundation
import OngakuAudioDSP
import Testing
@testable import OngakuDesktop

struct AudioRoutingGraphTests {
    @Test func portDragsNormalizeDirectionAndPreserveMixerTerminal() throws {
        let doc = AudioRoutingDocument.parallel
        let output = AudioRoutingPort(nodeID: doc.nodes[2].id,isOutput: true,name: "out")
        let input = AudioRoutingPort(nodeID: doc.nodes[3].id,isOutput: false,name: "b")
        let edge = try output.connection(to: input)
        #expect(try edge == input.connection(to: output))
        #expect(edge.from == output.nodeID && edge.to == input.nodeID && edge.port == "b")
        #expect(throws: AudioRoutingError.port) { try output.connection(to: .init(nodeID: doc.nodes[1].id,isOutput: true,name: "out")) }
        #expect(throws: AudioRoutingError.port) { try input.connection(to: .init(nodeID: input.nodeID,isOutput: true,name: "out")) }
        var editor = try AudioRoutingEditor(doc)
        #expect(throws: AudioRoutingError.occupied) { try editor.execute(.connect(edge),expectedRevision: 0) }
        #expect(editor.document == doc)
        try editor.execute(.disconnect(edge.id),expectedRevision: 0)
        try editor.execute(.connect(input.connection(to: output)),expectedRevision: 1)
        #expect(try editor.document.plan() == doc.plan())
    }
    @Test func portContextDisconnectTargetsOneInputOrOneOutputFanout() throws {
        let doc = AudioRoutingDocument.parallel
        let inputB = AudioRoutingPort(nodeID: doc.nodes[3].id,isOutput: false,name: "b")
        let source = AudioRoutingPort(nodeID: doc.nodes[0].id,isOutput: true,name: "out")
        #expect(inputB.connections(in: doc).count == 1)
        #expect(inputB.connections(in: doc).first?.from == doc.nodes[2].id)
        #expect(source.connections(in: doc).count == 2)
        var editor = try AudioRoutingEditor(doc)
        try editor.execute(.batch(source.connections(in: doc).map { .disconnect($0.id) }),expectedRevision: 0)
        #expect(editor.document.edges.count == doc.edges.count-2)
        #expect(inputB.connections(in: editor.document) == inputB.connections(in: doc))
        editor.undo(); #expect(editor.document == doc)
    }
    @Test @MainActor func canvasPortHitTestChoosesOppositeDirectionAndExactMixerInput() throws {
        let doc = AudioRoutingDocument.parallel
        let source = AudioRoutingPort(nodeID: doc.nodes[2].id,isOutput: true,name: "out")
        let mixer = doc.nodes[3]
        let center = RoutingNodeLayout.port(mixer,output: false,name: "b")
        let input = RoutingNodeLayout.target(from: source,at: center,in: doc,radius: 18)
        #expect(input == AudioRoutingPort(nodeID: mixer.id,isOutput: false,name: "b"))
        let reverse = RoutingNodeLayout.target(from: try #require(input),at: RoutingNodeLayout.port(doc.nodes[2],output: true),in: doc,radius: 18)
        #expect(reverse == source)
        #expect(RoutingNodeLayout.target(from: source,at: .init(x: 0,y: 0),in: doc,radius: 18) == nil)
        #expect(RoutingNodeLayout.target(from: source,at: RoutingNodeLayout.port(doc.nodes[2],output: false),in: doc,radius: 18) == nil)
        // At 50% zoom, a 12pt screen miss is 24pt in canvas coordinates.
        let near = CGPoint(x: center.x-24,y: center.y)
        #expect(RoutingNodeLayout.target(from: source,at: near,in: doc,radius: 18/0.5) == input)
        #expect(RoutingNodeLayout.target(from: source,at: near,in: doc,radius: 18) == nil)
    }
    @Test @MainActor func liveNodeMovePersistsWithoutPublishingDSPAndKeepsTopologyLocked() throws {
        let name = "OngakuLiveMoveTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AudioRoutingStore(defaults: defaults), initial = store.document
        let gain = initial.nodes[1]
        var publications = 0
        store.setLocked(true)
        store.setLiveUpdate { _ in publications += 1 }
        store.perform(.move(gain.id,400,200), revision: 0)
        #expect(store.document.nodes[1].x == 400 && store.document.nodes[1].y == 200)
        #expect(store.editor.revision == 1 && store.editor.canUndo)
        #expect(try store.document.plan() == initial.plan())
        #expect(store.hasCompleteRoute && publications == 0)
        #expect(AudioRoutingStore(defaults: defaults).document == store.document)
        let moved = store.document
        store.perform(.disconnect(initial.edges[0].id)); store.undo()
        store.perform(.batch([.move(gain.id,450,200),.disconnect(initial.edges[0].id)]))
        #expect(store.document == moved && publications == 0)
        store.perform(.move(gain.id,500,200), revision: 0)
        #expect(store.document == moved && publications == 0)
        store.perform(.parameters(gain.id,[0.5]))
        #expect(publications == 1 && store.document.nodes[1].parameters == [0.5])
        store.setLiveUpdate(nil); store.setLocked(false)
        store.undo(); store.undo()
        #expect(store.document == initial)
    }
    @Test @MainActor func layoutCanMoveWhilePreparingSessionButParametersRemainLocked() throws {
        let name = "OngakuPreparingMoveTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AudioRoutingStore(defaults: defaults), initial = store.document
        store.setLocked(true)
        store.perform(.move(initial.nodes[0].id,100,120))
        #expect(store.document.nodes[0].x == 100 && store.document.nodes[0].y == 120)
        store.perform(.parameters(initial.nodes[1].id,[0.5]))
        #expect(store.document.nodes[1].parameters == [1])
        #expect(try store.document.plan() == initial.plan())
    }
    @Test @MainActor func livePreviewCommitsOnceAndStillLocksTopology() throws {
        let name = "OngakuLiveTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AudioRoutingStore(defaults: defaults), initial = store.document
        let gain = initial.nodes[1]
        var delivered = initial
        store.setLocked(true)
        store.setLiveUpdate { delivered = $0 }
        for value in [0.8,0.6,0.25] { #expect(store.previewParameters(gain.id,[value])) }
        #expect(delivered.nodes[1].parameters == [0.25])
        #expect(store.document == initial && store.editor.revision == 0)
        #expect(AudioRoutingStore(defaults: defaults).document.nodes[1].parameters == [1])
        store.finishParameterEdit()
        #expect(store.editor.revision == 1 && store.document.nodes[1].parameters == [0.25])
        let committed = store.document
        store.perform(.disconnect(initial.edges[0].id))
        #expect(store.document == committed && delivered == committed)
        store.perform(.bypass(gain.id,true))
        #expect(delivered.nodes[1].bypassed && store.document.nodes[1].bypassed)
        #expect(!store.previewParameters(gain.id,[.nan]))
        #expect(store.previewParameters(gain.id,[0.7]))
        store.setLiveUpdate(nil) // stopping during an edit saves the last preview
        store.setLocked(false)
        #expect(store.document.nodes[1].parameters == [0.7])
        store.undo()
        #expect(store.document.nodes[1].parameters == [0.25])
        store.undo(); store.undo()
        #expect(store.document == initial)
    }
    @Test @MainActor func rejectedLiveUpdateDoesNotPersistOrAdvanceHistory() throws {
        let name = "OngakuLiveTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AudioRoutingStore(defaults: defaults), initial = store.document
        store.setLocked(true)
        store.setLiveUpdate { _ in throw AudioRoutingError.document }
        #expect(!store.previewParameters(initial.nodes[1].id,[0.4]))
        store.perform(.bypass(initial.nodes[1].id,true))
        #expect(store.document == initial && store.editor.revision == 0)
        #expect(!store.editor.canUndo)
        #expect(defaults.data(forKey: "applicationAudio.routing.v1") == nil)
    }

    @Test @MainActor func cachedRouteValidityFollowsEditsHistoryAndReload() throws {
        let suite = "OngakuRoutingCacheTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AudioRoutingStore(defaults: defaults)
        #expect(store.hasCompleteRoute)
        let edge = try #require(store.document.edges.first)
        store.perform(.disconnect(edge.id))
        #expect(!store.hasCompleteRoute)
        #expect(!AudioRoutingStore(defaults: defaults).hasCompleteRoute)
        store.undo()
        #expect(store.hasCompleteRoute)
        store.redo()
        #expect(!store.hasCompleteRoute)
        store.perform(.replace(.monitoring))
        #expect(store.hasCompleteRoute)
        let revision = store.editor.revision
        store.perform(.disconnect(edge.id), revision: revision - 1)
        #expect(store.editor.revision == revision)
        #expect(store.hasCompleteRoute)
        #expect(AudioRoutingStore(defaults: defaults).hasCompleteRoute)
    }
    @Test func transactionalEditsRejectCycleAndPreserveHistory() throws {
        let initial = AudioRoutingDocument.initial
        var editor = try AudioRoutingEditor(initial)
        let gain = initial.nodes[1], meter = initial.nodes[2]
        #expect(throws: AudioRoutingError.cycle) {
            try editor.execute(.batch([
                .disconnect(initial.edges[0].id), .connect(.init(from: meter.id, to: gain.id, port: "in"))
            ]), expectedRevision: 0)
        }
        #expect(editor.document == initial)
        #expect(editor.revision == 0)
        #expect(!editor.canUndo)
        try editor.execute(.move(gain.id, 400, 200), expectedRevision: 0)
        #expect(throws: AudioRoutingError.revision) { try editor.execute(.move(gain.id, 500, 200), expectedRevision: 0) }
        editor.undo(); #expect(editor.document == initial)
        editor.redo(); #expect(editor.document.nodes[1].x == 400)
    }
    @Test func portOccupancyAndDirectionsAreEnforced() throws {
        let doc = AudioRoutingDocument.initial
        var editor = try AudioRoutingEditor(doc)
        #expect(throws: AudioRoutingError.occupied) { try editor.execute(.connect(doc.edges[0]), expectedRevision: 0) }
        #expect(throws: AudioRoutingError.port) {
            try editor.execute(.connect(.init(from: doc.nodes[3].id, to: doc.nodes[0].id, port: "in")), expectedRevision: 0)
        }
        #expect(editor.document == doc)
    }
    @Test func incompleteRouteCannotRecordAndUnusedNodesAreNotRendered() throws {
        var doc = AudioRoutingDocument.initial
        doc.nodes.append(.init(kind: .delay, x: 0, y: 300))
        #expect(try doc.plan().steps.count == 4)
        doc.edges.removeLast()
        try doc.validate() // disconnected edits can be saved / undone
        #expect(throws: AudioRoutingError.disconnected) { try doc.plan() }
    }
    @Test func duplicateIDsMalformedParametersAndUnknownVersionAreRejected() throws {
        var doc = AudioRoutingDocument.initial
        doc.nodes.append(doc.nodes[0])
        #expect(throws: AudioRoutingError.document) { try doc.validate() }
        #expect(throws: AudioRoutingError.document) { try doc.orderedIDs() }
        doc = .initial; doc.nodes[1].parameters = [.nan]
        #expect(throws: AudioRoutingError.document) { try doc.validate() }
        doc = .initial; doc.version = 42
        #expect(throws: AudioRoutingError.document) { try doc.validate() }
    }
    @Test func serializedParallelDocumentKeepsExactRouting() throws {
        let doc = AudioRoutingDocument.parallel
        let restored = try JSONDecoder().decode(AudioRoutingDocument.self, from: JSONEncoder().encode(doc))
        #expect(doc == restored)
        #expect(try doc.plan() == restored.plan())
        #expect(try doc.plan().steps.map(\.kind) == [.application, .gain, .delay, .mixer, .meter, .recorder])
    }
    @Test @MainActor func savedSessionRestoresAndRecordingLockRejectsEdits() throws {
        let name = "OngakuRoutingTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AudioRoutingStore(defaults: defaults)
        store.perform(.replace(.parallel))
        let before = store.document
        store.setLocked(true); store.perform(.replace(.initial)); store.undo()
        #expect(store.document == before)
        #expect(AudioRoutingStore(defaults: defaults).document == before)
        store.setLocked(false); store.undo()
        #expect(store.document.nodes.count == 4)
    }
    @Test @MainActor func corruptSavedGraphIsNotOverwrittenOnRead() throws {
        let name = "OngakuRoutingTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let bytes = Data("invalid saved graph".utf8)
        defaults.set(bytes, forKey: "applicationAudio.routing.v1")
        let store = AudioRoutingStore(defaults: defaults)
        #expect(store.error != nil)
        #expect(defaults.data(forKey: "applicationAudio.routing.v1") == bytes)
        #expect(try store.document.plan().steps.count == 4)
    }
    @Test func nodeRemovalDisconnectsItsCablesAndUndoRestoresThem() throws {
        let doc = AudioRoutingDocument.parallel
        var editor = try AudioRoutingEditor(doc)
        let delay = doc.nodes.first { $0.kind == .delay }!
        try editor.execute(.remove(delay.id), expectedRevision: 0)
        #expect(editor.document.edges.allSatisfy { $0.from != delay.id && $0.to != delay.id })
        #expect(throws: AudioRoutingError.disconnected) { try editor.document.plan() }
        editor.undo(); #expect(editor.document == doc)
    }
}

struct AudioRoutingDSPTests {
    @Test func liveGainAndBypassRampWithoutRestartingRoute() throws {
        var doc = AudioRoutingDocument.initial
        let route = try engine(doc)
        let (input, output) = buffers(frames: 1024)
        for f in 0..<2048 { input.floatChannelData![0][f] = 0.8 }
        doc.nodes[1].parameters = [0.25]
        var steps = try doc.plan().nativeSteps
        try steps.withUnsafeBufferPointer { try route.updateParameters($0.baseAddress!, count: UInt($0.count)) }
        #expect(route.processFrames(1024,input: input.audioBufferList,output: output.mutableAudioBufferList) == noErr)
        let samples = (0..<1024).map { output.floatChannelData![0][2*$0] }
        #expect(samples[0] > 0.79 && abs(samples.last! - 0.2) < 0.00001)
        #expect(zip(samples,samples.dropFirst()).allSatisfy { $0 >= $1 && abs($0-$1) < 0.001 })
        doc.nodes[1].bypassed = true
        steps = try doc.plan().nativeSteps
        try steps.withUnsafeBufferPointer { try route.updateParameters($0.baseAddress!, count: UInt($0.count)) }
        #expect(route.processFrames(1024,input: input.audioBufferList,output: output.mutableAudioBufferList) == noErr)
        #expect(output.floatChannelData![0][0] < 0.21)
        #expect(abs(output.floatChannelData![0][2046] - 0.8) < 0.00001)
    }
    @Test func liveUpdateRejectsTopologyAndInvalidValuesAtomically() throws {
        let parallel = AudioRoutingDocument.parallel
        let branchedRoute = try engine(parallel)
        var swapped = try parallel.plan().nativeSteps
        swapped[3].inputA = 2; swapped[3].inputB = 1
        #expect(swapped.withUnsafeBufferPointer { OngakuValidateAudioRoute($0.baseAddress!,UInt($0.count)) })
        #expect(throws: (any Error).self) { try swapped.withUnsafeBufferPointer { try branchedRoute.updateParameters($0.baseAddress!,count: UInt($0.count)) } }
        var doc = AudioRoutingDocument.initial; doc.nodes[1].parameters = [0.25]
        let route = try engine(doc)
        var steps = try doc.plan().nativeSteps
        steps[1].p0 = 1; steps[2].inputA = 0 // disconnected gain must also be rejected
        #expect(throws: (any Error).self) { try steps.withUnsafeBufferPointer { try route.updateParameters($0.baseAddress!,count: UInt($0.count)) } }
        steps = try doc.plan().nativeSteps; steps[1].p0 = .nan
        #expect(throws: (any Error).self) { try steps.withUnsafeBufferPointer { try route.updateParameters($0.baseAddress!,count: UInt($0.count)) } }
        let (input,output) = buffers(frames: 1024)
        for f in 0..<2048 { input.floatChannelData![0][f] = 0.8 }
        #expect(route.processFrames(1024,input: input.audioBufferList,output: output.mutableAudioBufferList) == noErr)
        #expect((0..<2048).allSatisfy { abs(output.floatChannelData![0][$0]-0.2) < 0.00001 })
    }
    @Test func liveDelayChangesPreserveBufferedTail() throws {
        let source = AudioRoutingNode(kind: .application,x: 0,y: 0)
        var delay = AudioRoutingNode(kind: .delay,x: 200,y: 0); delay.parameters = [1,0.25,1]
        let sink = AudioRoutingNode(kind: .recorder,x: 400,y: 0)
        var doc = AudioRoutingDocument(nodes: [source,delay,sink],edges: [.init(from: source.id,to: delay.id,port: "in"),.init(from: delay.id,to: sink.id,port: "in")])
        let route = try engine(doc)
        let (input,output) = buffers(frames: 32)
        input.floatChannelData![0][0] = 1
        #expect(route.processFrames(32,input: input.audioBufferList,output: output.mutableAudioBufferList) == noErr)
        doc.nodes[1].parameters = [1,0.5,0.5]
        let steps = try doc.plan().nativeSteps
        try steps.withUnsafeBufferPointer { try route.updateParameters($0.baseAddress!,count: UInt($0.count)) }
        input.floatChannelData![0][0] = 0
        #expect(route.processFrames(32,input: input.audioBufferList,output: output.mutableAudioBufferList) == noErr)
        #expect(output.floatChannelData![0][32] > 0.98) // impulse survives at frame 48
    }
    @Test func liveCutoffUpdateChangesFilterResponse() throws {
        let source = AudioRoutingNode(kind: .application,x: 0,y: 0)
        var filter = AudioRoutingNode(kind: .lowpass,x: 200,y: 0); filter.parameters = [100]
        let sink = AudioRoutingNode(kind: .recorder,x: 400,y: 0)
        var doc = AudioRoutingDocument(nodes: [source,filter,sink],edges: [.init(from: source.id,to: filter.id,port: "in"),.init(from: filter.id,to: sink.id,port: "in")])
        let route = try engine(doc)
        let (input,output) = buffers(frames: 2048)
        for f in 0..<2048 { input.floatChannelData![0][2*f] = f.isMultiple(of: 2) ? 1 : -1 }
        #expect(route.processFrames(2048,input: input.audioBufferList,output: output.mutableAudioBufferList) == noErr)
        #expect(abs(output.floatChannelData![0][4094]) < 0.01)
        doc.nodes[1].parameters = [20000]
        let steps = try doc.plan().nativeSteps
        try steps.withUnsafeBufferPointer { try route.updateParameters($0.baseAddress!,count: UInt($0.count)) }
        #expect(route.processFrames(2048,input: input.audioBufferList,output: output.mutableAudioBufferList) == noErr)
        #expect(abs(output.floatChannelData![0][4094]) > 0.8)
    }
    private final class ConcurrentRoute: @unchecked Sendable {
        let route: OngakuAudioRoute
        init(_ route: OngakuAudioRoute) { self.route = route }
    }
    @Test func concurrentLivePublicationAndAudioProcessingRemainBounded() throws {
        let doc = AudioRoutingDocument.parallel
        let shared = ConcurrentRoute(try engine(doc))
        let work = DispatchGroup()
        work.enter()
        DispatchQueue.global().async {
            defer { work.leave() }
            for index in 0..<2000 {
                var updated = doc
                updated.nodes[1].parameters = [index.isMultiple(of: 2) ? 0.25 : 1.5]
                updated.nodes[2].parameters = [Double(1+index%100),0.4,0.5]
                updated.nodes[3].parameters = [0.25,0.75]
                do {
                    let steps = try updated.plan().nativeSteps
                    try steps.withUnsafeBufferPointer { try shared.route.updateParameters($0.baseAddress!,count: UInt($0.count)) }
                } catch { Issue.record(error) }
            }
        }
        let (input,output) = buffers(frames: 128)
        for f in 0..<256 { input.floatChannelData![0][f] = 0.1 }
        for _ in 0..<2000 {
            #expect(shared.route.processFrames(128,input: input.audioBufferList,output: output.mutableAudioBufferList) == noErr)
            #expect((0..<256).allSatisfy { output.floatChannelData![0][$0].isFinite && abs(output.floatChannelData![0][$0]) < 1 })
        }
        #expect(work.wait(timeout: .now()+10) == .success)
    }

    private func engine(_ doc: AudioRoutingDocument, rate: Double = 48000) throws -> OngakuAudioRoute {
        let steps = try doc.plan().nativeSteps
        return try steps.withUnsafeBufferPointer {
            try OngakuAudioRoute(steps: $0.baseAddress!, count: UInt($0.count), sampleRate: rate)
        }
    }
    private func buffers(frames: UInt32, planar: Bool = false) -> (AVAudioPCMBuffer, AVAudioPCMBuffer) {
        let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: !planar)!
        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true)!
        let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames)!
        let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frames)!
        input.frameLength = frames; output.frameLength = frames
        for buffer in UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList) {
            memset(buffer.mData!, 0, Int(buffer.mDataByteSize))
        }
        return (input, output)
    }
    @Test(arguments: [false, true], [0.5, 10.0]) func gainAndMeterUseConnectedPCM(planar: Bool, gain: Double) throws {
        var doc = AudioRoutingDocument.initial
        doc.nodes[1].parameters = [gain]
        let multiplier = Float(gain)
        let route = try engine(doc)
        let (input, output) = buffers(frames: 128, planar: planar)
        if planar {
            for f in 0..<128 { input.floatChannelData![0][f] = 0.8; input.floatChannelData![1][f] = -0.4 }
        } else {
            for f in 0..<128 { input.floatChannelData![0][2*f] = 0.8; input.floatChannelData![0][2*f+1] = -0.4 }
        }
        #expect(route.processFrames(128, input: input.audioBufferList, output: output.mutableAudioBufferList) == noErr)
        for f in 0..<128 {
            #expect(abs(output.floatChannelData![0][2*f] - 0.8 * multiplier) < 0.00001)
            #expect(abs(output.floatChannelData![0][2*f+1] + 0.4 * multiplier) < 0.00001)
        }
        #expect(abs(route.peak(atStep: 0) - 0.8) < 0.00001)
        #expect(abs(route.peak(atStep: 2) - 0.8 * multiplier) < 0.00001)
    }
    @Test func limiterCatchesFirstPeakAndReleasesWithoutChangingStereoBalance() throws {
        let source = AudioRoutingNode(kind: .application, x: 0, y: 0)
        let limiter = AudioRoutingNode(kind: .limiter, x: 240, y: 0)
        let recorder = AudioRoutingNode(kind: .recorder, x: 480, y: 0)
        let doc = AudioRoutingDocument(nodes: [source, limiter, recorder], edges: [
            .init(from: source.id, to: limiter.id, port: "in"),
            .init(from: limiter.id, to: recorder.id, port: "in")
        ])
        let route = try engine(doc)
        let (input, output) = buffers(frames: 2048)
        let samples = input.floatChannelData![0]
        samples[0] = 4
        samples[1] = -2
        for frame in 1..<2048 { samples[2 * frame] = 0.5 }
        #expect(route.processFrames(2048, input: input.audioBufferList, output: output.mutableAudioBufferList) == noErr)
        let result = output.floatChannelData![0]
        let ceiling = Float(pow(10.0, -1.0 / 20))
        #expect(abs(result[0] - ceiling) < 0.000001)
        #expect(abs(result[1] + ceiling / 2) < 0.000001)
        #expect(result[2] < result[4094])
        #expect(result[4094] < 0.5)
    }

    @Test func compressorAttenuatesLinkedStereoAndCanBeBypassed() throws {
        let source = AudioRoutingNode(kind: .application, x: 0, y: 0)
        var compressor = AudioRoutingNode(kind: .compressor, x: 240, y: 0)
        compressor.parameters = [-20, 2, 1, 100, 0]
        let recorder = AudioRoutingNode(kind: .recorder, x: 480, y: 0)
        var doc = AudioRoutingDocument(nodes: [source, compressor, recorder], edges: [
            .init(from: source.id, to: compressor.id, port: "in"),
            .init(from: compressor.id, to: recorder.id, port: "in")
        ])
        let route = try engine(doc)
        let (input, output) = buffers(frames: 2048)
        for frame in 0..<2048 {
            input.floatChannelData![0][2 * frame] = 1
            input.floatChannelData![0][2 * frame + 1] = -0.5
        }
        #expect(route.processFrames(2048, input: input.audioBufferList, output: output.mutableAudioBufferList) == noErr)
        let expected = Float(pow(10.0, -10.0 / 20))
        #expect(abs(output.floatChannelData![0][4094] - expected) < 0.0001)
        #expect(abs(output.floatChannelData![0][4095] + expected / 2) < 0.0001)
        doc.nodes[1].bypassed = true
        let steps = try doc.plan().nativeSteps
        try steps.withUnsafeBufferPointer { try route.updateParameters($0.baseAddress!, count: UInt($0.count)) }
        #expect(route.processFrames(2048, input: input.audioBufferList, output: output.mutableAudioBufferList) == noErr)
        #expect(output.floatChannelData![0][4094] == 1)
        #expect(output.floatChannelData![0][4095] == -0.5)
    }

    @Test(arguments: [-6.0, 0, 6.0], [false, true])
    func equalizerChangesCenterFrequencyGain(decibels: Double, bypassed: Bool) throws {
        let source = AudioRoutingNode(kind: .application, x: 0, y: 0)
        var equalizer = AudioRoutingNode(kind: .equalizer, x: 240, y: 0)
        equalizer.parameters[5] = decibels
        equalizer.bypassed = bypassed
        let recorder = AudioRoutingNode(kind: .recorder, x: 480, y: 0)
        let doc = AudioRoutingDocument(nodes: [source, equalizer, recorder], edges: [
            .init(from: source.id, to: equalizer.id, port: "in"),
            .init(from: equalizer.id, to: recorder.id, port: "in")
        ])
        let route = try engine(doc)
        let (input, output) = buffers(frames: 3840)
        for frame in 0..<3840 {
            let sample = Float(sin(Double(frame) * 2 * .pi / 48) * 0.25)
            input.floatChannelData![0][2 * frame] = sample
            input.floatChannelData![0][2 * frame + 1] = -sample
        }
        #expect(route.processFrames(3840, input: input.audioBufferList, output: output.mutableAudioBufferList) == noErr)
        let expected = Float(0.25 * pow(10, (bypassed ? 0 : decibels) / 20))
        #expect(abs(output.floatChannelData![0][2 * 3804] - expected) < 0.0005)
        #expect(abs(output.floatChannelData![0][2 * 3804 + 1] + expected) < 0.0005)
    }

    @Test func waveformKeepsStereoExtremaAndPassesThroughPCM() throws {
        var doc = AudioRoutingDocument.initial
        let old = doc.nodes[2]
        let wave = AudioRoutingNode(kind: .waveform, x: old.x, y: old.y)
        doc.nodes[2] = wave
        doc.edges = doc.edges.map {
            .init(from: $0.from == old.id ? wave.id : $0.from,
                  to: $0.to == old.id ? wave.id : $0.to, port: $0.port)
        }
        let route = try engine(doc)
        let (input, output) = buffers(frames: 96)
        let samples = input.floatChannelData![0]
        samples[1] = -0.75
        samples[2] = 0.5
        samples[96] = 0.25
        #expect(route.processFrames(96, input: input.audioBufferList, output: output.mutableAudioBufferList) == noErr)
        let rendered = output.floatChannelData![0]
        #expect((0..<192).allSatisfy { rendered[$0] == samples[$0] })
        var pairs = [Float](repeating: 0, count: 4)
        pairs.withUnsafeMutableBufferPointer {
            route.copyWaveform(atStep: 2, into: $0.baseAddress!, count: 2)
        }
        #expect(pairs == [-0.75, 0.5, 0, 0.25])
    }

    @Test func parallelMixHasIndependentBranches() throws {
        var doc = AudioRoutingDocument.parallel
        doc.nodes[1].parameters = [0.25]
        doc.nodes[2].bypassed = true
        let route = try engine(doc)
        let (input, output) = buffers(frames: 1)
        input.floatChannelData![0][0] = 0.8; input.floatChannelData![0][1] = -0.8
        #expect(route.processFrames(1, input: input.audioBufferList, output: output.mutableAudioBufferList) == noErr)
        #expect(abs(output.floatChannelData![0][0] - 0.5) < 0.00001) // .8 * (.25*.5 + 1*.5)
        #expect(abs(output.floatChannelData![0][1] + 0.5) < 0.00001)
    }
    @Test func delayImpulseAndFeedbackPersistAcrossBlocks() throws {
        let source = AudioRoutingNode(kind: .application, x: 0, y: 0)
        var delay = AudioRoutingNode(kind: .delay, x: 200, y: 0); delay.parameters = [1, 0.25, 1]
        let sink = AudioRoutingNode(kind: .recorder, x: 400, y: 0)
        let doc = AudioRoutingDocument(nodes: [source, delay, sink], edges: [.init(from: source.id,to: delay.id,port: "in"), .init(from: delay.id,to: sink.id,port: "in")])
        let route = try engine(doc)
        let (input, output) = buffers(frames: 32)
        var samples: [Float] = []
        for block in 0..<4 {
            memset(input.mutableAudioBufferList.pointee.mBuffers.mData!,0,Int(input.mutableAudioBufferList.pointee.mBuffers.mDataByteSize))
            if block == 0 { input.floatChannelData![0][0] = 1 }
            #expect(route.processFrames(32, input: input.audioBufferList, output: output.mutableAudioBufferList) == noErr)
            samples += (0..<32).map { output.floatChannelData![0][2*$0] }
        }
        #expect(samples[0] == 0); #expect(samples[47] == 0)
        #expect(samples[48] == 1); #expect(samples[96] == 0.25)
        #expect(samples.enumerated().allSatisfy { $0.offset == 48 || $0.offset == 96 || $0.element == 0 })
    }
    @Test func nativeValidationRejectsForwardReferencesAndNonfiniteControls() throws {
        var steps = try AudioRoutingDocument.initial.plan().nativeSteps
        steps[1].inputA = 2
        #expect(!steps.withUnsafeBufferPointer { OngakuValidateAudioRoute($0.baseAddress!, UInt($0.count)) })
        steps[1].inputA = 0; steps[1].p0 = .nan
        #expect(!steps.withUnsafeBufferPointer { OngakuValidateAudioRoute($0.baseAddress!, UInt($0.count)) })
    }
    @Test func lowpassAttenuatesAlternatingSignalAndBypassIsExact() throws {
        let source = AudioRoutingNode(kind: .application, x: 0, y: 0)
        var filter = AudioRoutingNode(kind: .lowpass, x: 200, y: 0); filter.parameters = [1000]
        let sink = AudioRoutingNode(kind: .recorder, x: 400, y: 0)
        var doc = AudioRoutingDocument(nodes: [source,filter,sink], edges: [.init(from: source.id,to: filter.id,port: "in"),.init(from: filter.id,to: sink.id,port: "in")])
        let (input,output) = buffers(frames: 256)
        for f in 0..<256 { input.floatChannelData![0][2*f] = f.isMultiple(of: 2) ? 1 : -1 }
        let route = try engine(doc)
        #expect(route.processFrames(256,input: input.audioBufferList,output: output.mutableAudioBufferList) == noErr)
        #expect(abs(output.floatChannelData![0][510]) < 0.1)
        doc.nodes[1].bypassed = true
        let bypass = try engine(doc)
        #expect(bypass.processFrames(256,input: input.audioBufferList,output: output.mutableAudioBufferList) == noErr)
        #expect(output.floatChannelData![0][510] == -1)
    }
    @Test func processedPCMIsWhatTheRecorderSaves() throws {
        var doc = AudioRoutingDocument.initial; doc.nodes[1].parameters = [0.25]
        let route = try engine(doc)
        let (input, output) = buffers(frames: 512)
        for f in 0..<512 { input.floatChannelData![0][2*f] = 0.8; input.floatChannelData![0][2*f+1] = -0.4 }
        #expect(route.processFrames(512,input: input.audioBufferList,output: output.mutableAudioBufferList) == noErr)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try OngakuCaptureWriter(url: url, format: output.format.streamDescription.pointee)
        writer.appendFrames(512, buffers: output.audioBufferList); #expect(writer.finish() == noErr)
        let file = try AVAudioFile(forReading: url)
        let read = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 512)!
        try file.read(into: read)
        #expect(file.length == 512)
        #expect(abs(read.floatChannelData![0][256] - 0.2) < 0.00001)
        #expect(abs(read.floatChannelData![1][256] + 0.1) < 0.00001)
    }
}

struct AudioRoutingOutputTests {
    @Test func outputOnlyAndDualDestinationsPreserveTheirOwnBranches() throws {
        let source = AudioRoutingNode(kind: .application, x: 0, y: 0)
        var gain = AudioRoutingNode(kind: .gain, x: 220, y: 0); gain.parameters = [0.25]
        let record = AudioRoutingNode(kind: .recorder, x: 440, y: 0)
        var device = AudioRoutingNode(kind: .device, x: 440, y: 180); device.deviceUID = "test-device"
        let doc = AudioRoutingDocument(nodes: [source,gain,record,device], edges: [
            .init(from: source.id,to: gain.id,port: "in"),
            .init(from: gain.id,to: record.id,port: "in"),
            .init(from: source.id,to: device.id,port: "in")])
        let plan = try doc.plan()
        #expect(plan.records && plan.monitors)
        let restored = try JSONDecoder().decode(AudioRoutingDocument.self,from: JSONEncoder().encode(doc))
        #expect(restored == doc)
        let steps = plan.nativeSteps
        let route = try steps.withUnsafeBufferPointer { try OngakuAudioRoute(steps: $0.baseAddress!,count: UInt($0.count),sampleRate: 48000) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,sampleRate: 48000,channels: 2,interleaved: true)!
        let input = AVAudioPCMBuffer(pcmFormat: format,frameCapacity: 64)!
        let recordPCM = AVAudioPCMBuffer(pcmFormat: format,frameCapacity: 64)!
        let monitorPCM = AVAudioPCMBuffer(pcmFormat: format,frameCapacity: 64)!
        for b in [input,recordPCM,monitorPCM] { b.frameLength = 64 }
        for i in 0..<128 { input.floatChannelData![0][i] = 0.8 }
        #expect(route.processFrames(64,input: input.audioBufferList,recording: recordPCM.mutableAudioBufferList,monitor: monitorPCM.mutableAudioBufferList) == noErr)
        #expect(abs(recordPCM.floatChannelData![0][0]-0.2) < 0.00001)
        #expect(abs(monitorPCM.floatChannelData![0][0]-0.8) < 0.00001)
        var editor = try AudioRoutingEditor(doc)
        try editor.execute(.remove(record.id),expectedRevision: 0)
        let outputOnly = try editor.document.plan()
        #expect(!outputOnly.records && outputOnly.monitors)
        #expect(outputOnly.steps.count == 2) // unused gain isn't processed
        #expect(throws: AudioRoutingError.document) { try editor.execute(.remove(device.id),expectedRevision: 1) }
        #expect(try editor.document.plan() == outputOnly)
    }
    @Test func outputPortsAreTerminalAndAllDestinationsMustBeConnected() throws {
        var doc = AudioRoutingDocument.monitoring
        #expect(try doc.plan().monitors)
        #expect(try !doc.plan().records)
        doc.nodes.append(.init(kind: .recorder,x: 744,y: 250))
        #expect(throws: AudioRoutingError.disconnected) { try doc.plan() }
        doc.edges.append(.init(from: doc.nodes[3].id,to: doc.nodes[4].id,port: "in"))
        #expect(throws: AudioRoutingError.port) { try doc.validate() }
    }
    @Test func monitorResamples48kTo192k() {
        let bridge = OngakuMonitorBuffer(sampleRate: 48000, renderRate: 192000)
        let source = (0..<1504).flatMap { frame -> [Float] in
            let value = Float(frame) / 4096
            return [value, -value]
        }
        #expect(source.withUnsafeBufferPointer { bridge.appendFrames(1504, samples: $0.baseAddress!) })
        var output = [Float](repeating: 0, count: 512)
        output.withUnsafeMutableBufferPointer { bridge.renderFrames(256, samples: $0.baseAddress!) }
        #expect(output[256] == 32.0 / 4096)
        #expect(output[257] == -32.0 / 4096)
        #expect(bridge.renderedFrames == 256)
        #expect(bridge.underruns == 0)
    }

    @Test func monitorBufferPrimesBoundsAndRecoversWithoutReplayingStaleAudio() {
        let bridge = OngakuMonitorBuffer(sampleRate: 48000)
        var output = [Float](repeating: 99,count: 4096)
        output.withUnsafeMutableBufferPointer { bridge.renderFrames(2048,samples: $0.baseAddress!) }
        #expect(output.allSatisfy { $0 == 0 })
        var input = [Float](repeating: 0.25,count: 8192)
        #expect(input.withUnsafeBufferPointer { bridge.appendFrames(4096,samples: $0.baseAddress!) })
        output.withUnsafeMutableBufferPointer { bridge.renderFrames(2048,samples: $0.baseAddress!) }
        #expect(output.allSatisfy { abs($0-0.25) < 0.00001 })
        #expect(bridge.renderedFrames == 2048)
        for _ in 0..<3 { output.withUnsafeMutableBufferPointer { bridge.renderFrames(2048,samples: $0.baseAddress!) } }
        #expect(bridge.underruns == 1)
        #expect(output.allSatisfy { $0 == 0 })
        input = [Float](repeating: 2,count: 8192)
        #expect(input.withUnsafeBufferPointer { bridge.appendFrames(4096,samples: $0.baseAddress!) })
        output.withUnsafeMutableBufferPointer { bridge.renderFrames(2048,samples: $0.baseAddress!) }
        #expect(output.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(output.last == 1) // output guard; recording retains Float32 headroom
        let bounded = OngakuMonitorBuffer(sampleRate: 48000)
        for _ in 0..<8 { #expect(input.withUnsafeBufferPointer { bounded.appendFrames(4096,samples: $0.baseAddress!) }) }
        #expect(!input.withUnsafeBufferPointer { bounded.appendFrames(4096,samples: $0.baseAddress!) })
    }
    @Test func deviceSelectionUsesPersistentUIDAndCanBeUndone() throws {
        var editor = try AudioRoutingEditor(.monitoring)
        let node = editor.document.nodes.last!
        try editor.execute(.device(node.id,"headphones-uid"),expectedRevision: 0)
        #expect(editor.document.nodes.last?.deviceUID == "headphones-uid")
        editor.undo(); #expect(editor.document.nodes.last?.deviceUID == nil)
        editor.redo(); #expect(editor.document.nodes.last?.deviceUID == "headphones-uid")
    }
}

struct ApplicationAudioOutputDeviceTests {
    @Test func invalidOutputUIDFailsBeforeStartingTap() throws {
        guard #available(macOS 14.2, *) else { return }
        let capture = OngakuApplicationAudioCapture()
        do {
            try capture.setOutputDeviceUID("Ongaku-Nonexistent-\(UUID())")
            Issue.record("Nonexistent device was accepted")
        } catch {
            #expect((error as NSError).code == Int(kAudioHardwareBadDeviceError))
        }
        #expect(capture.duration == 0)
        #expect(capture.monitoredFrames == 0)
    }
    @Test func enumeratedOutputUIDResolvesWithCoreAudioQualifier() throws {
        guard #available(macOS 14.2, *), let device = ApplicationAudioOutputs.list().first else { return }
        let capture = OngakuApplicationAudioCapture()
        try capture.setOutputDeviceUID(device.id) // read-only resolution; no tap or output starts
        #expect(capture.monitoredFrames == 0)
    }
}
