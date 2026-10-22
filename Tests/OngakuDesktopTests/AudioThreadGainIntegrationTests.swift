import AVFoundation
import Foundation
import Testing
import os
@testable import OngakuDesktop

@MainActor private final class GainGraph {
    let engine = AVAudioEngine()
    let effect = AudioThreadGainStage(gain: 1), transport = AudioThreadGainStage(gain: 1)
    let source: AVAudioSourceNode
    let format: AVAudioFormat
    let space: SpaceAudioEffect?
    let input: OSAllocatedUnfairLock<Float>
    var lastSample: Float = 0
    init(rate: Double, withSpace: Bool = false) throws {
        let signal = OSAllocatedUnfairLock(initialState: Float(0.05))
        input = signal
        space = withSpace ? SpaceAudioEffect() : nil
        format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        source = AVAudioSourceNode { _, _, count, list in
            let amplitude = signal.withLock { $0 }
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            for buffer in buffers {
                let samples = buffer.mData!.assumingMemoryBound(to: Float.self)
                for i in 0..<Int(count) { samples[i] = amplitude }
            }
            return noErr
        }
        engine.attach(source); engine.attach(effect.node); engine.attach(transport.node)
        if let space {
            space.attach(to: engine)
            space.connectInternalNodes(engine: engine, format: format)
            engine.connect(source, to: space.inputNode, format: format)
            engine.connect(space.outputNode, to: effect.node, format: format)
            space.apply(setting: RealtimeAudioEffectSetting(kind: .space, isEnabled: true))
        } else {
            engine.connect(source, to: effect.node, format: format)
        }
        engine.connect(effect.node, to: transport.node, format: format)
        engine.connect(transport.node, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        try engine.start()
        effect.synchronizeAfterStart(); transport.synchronizeAfterStart()
        try render(32)
    }
    func render(_ frames: Int) throws {
        var left = frames
        while left > 0 {
            let n = AVAudioFrameCount(min(512, left))
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
            let result = try engine.renderOffline(n, to: pcm)
            #expect(result == .success)
            #expect(pcm.frameLength == n)
            #expect(pcm.floatChannelData![0][0].isFinite)
            lastSample = pcm.floatChannelData![0][Int(n)-1]
            left -= Int(n)
        }
    }
}

@Suite("Connected audio-thread gain", .serialized)
@MainActor struct AudioThreadGainIntegrationTests {
    @Test("Effect topology commit waits for rendered zero and transport drain preserves resources")
    func renderedEndpointOwnership() async throws {
        for rate in [44100.0, 48000, 96000] {
            let graph = try GainGraph(rate: rate)
            defer { graph.engine.stop() }
            var commits = 0, mutedCommit = false
            let transition = EffectParameterTransition(isAudible: { true }, shouldDefer: { false },
                setEnvelope: { graph.effect.setImmediate($0) },
                audioRamp: { target, seconds, current, done in
                    graph.effect.ramp(to: target, duration: seconds, isRunning: { graph.engine.isRunning },
                        isCurrent: current, stalled: { graph.engine.pause() }, completion: done)
                }, commit: { _ in
                    commits += 1
                    if commits > 1 { mutedCommit = graph.lastSample == 0 }
                })
            let on = RealtimeAudioEffectSetting(kind: .equalizer, isEnabled: true)
            let off = RealtimeAudioEffectSetting(kind: .equalizer, isEnabled: false)
            transition.apply([on], immediately: true)
            try graph.render(32)
            transition.apply([off])
            try await Task.sleep(for: .milliseconds(20)) // UI time alone is not an endpoint.
            #expect(commits == 1)
            let outFrames = Int((rate * 0.008).rounded())
            try graph.render(outFrames - 1)
            try await Task.sleep(for: .milliseconds(12))
            #expect(commits == 1)
            try graph.render(1)
            try await Task.sleep(for: .milliseconds(20))
            #expect(commits == 2 && mutedCommit)
            try graph.render(Int((rate * 0.016).rounded()) + 32)
            try await Task.sleep(for: .milliseconds(12))
            #expect(!transition.isProtectingOutput)
            #expect(abs(graph.lastSample - 0.05) < 0.000001)

            var stopped = false
            let transport = TransportOutputEnvelope(audioRamp: { target, seconds, current, done in
                graph.transport.ramp(to: target, duration: seconds, isRunning: { graph.engine.isRunning },
                    isCurrent: current, stalled: { graph.engine.pause() }, completion: done)
            }, setGain: { graph.transport.setImmediate($0) })
            transport.stop(running: true, drain: 0.012) { stopped = true; graph.engine.pause() }
            let stopFrames = Int((rate * 0.024).rounded())
            try graph.render(stopFrames - 1)
            try await Task.sleep(for: .milliseconds(20))
            #expect(!stopped && graph.engine.isRunning)
            try graph.render(1)
            #expect(graph.lastSample == 0)
            try await Task.sleep(for: .milliseconds(40))
            #expect(stopped && !graph.engine.isRunning)
        }
    }

    @Test("Space OFF commits at rendered zero and retains audible tail after restoration")
    func protectedSpaceTail() async throws {
        let graph = try GainGraph(rate: 48000, withSpace: true)
        defer { graph.engine.stop() }
        try graph.render(7680)
        let space = try #require(graph.space)
        var commits = 0, commitAtZero = false
        let transition = EffectParameterTransition(isAudible: { true }, shouldDefer: { false },
            processingLatency: { space.transitionLatency },
            setEnvelope: { graph.effect.setImmediate($0) },
            audioRamp: { target, seconds, current, done in
                graph.effect.ramp(to: target, duration: seconds, isRunning: { graph.engine.isRunning },
                    isCurrent: current, stalled: { graph.engine.pause() }, completion: done)
            }, commit: { settings in
                commits += 1
                if commits > 1 {
                    commitAtZero = graph.lastSample == 0
                    graph.input.withLock { $0 = 0 } // Remaining output can only be retained wet history.
                }
                settings.forEach { space.apply(setting: $0) }
            })
        transition.apply([RealtimeAudioEffectSetting(kind: .space, isEnabled: true)], immediately: true)
        try graph.render(256)
        transition.apply([RealtimeAudioEffectSetting(kind: .space, isEnabled: false)])
        try graph.render(384)
        try await Task.sleep(for: .milliseconds(30))
        #expect(commits == 2 && commitAtZero)
        try graph.render(768 + 256)
        try await Task.sleep(for: .milliseconds(12))
        #expect(!transition.isProtectingOutput)
        #expect(graph.lastSample.isFinite && abs(graph.lastSample) > 0.000001)
        // Neither bypass nor the gain-node boundary resets Space's wet units.
        #expect(!space.isEnabled && graph.engine.isRunning)
    }

    @Test("Retargeting cancels obsolete completion without an output jump")
    func retarget() async throws {
        let graph = try GainGraph(rate: 48000)
        defer { graph.engine.stop() }
        var owner = 1, oldCompleted = false, cancelled = false, newCompleted = false
        graph.effect.ramp(to: 0, duration: 0.024, isRunning: { graph.engine.isRunning },
            isCurrent: { owner == 1 }, stalled: { graph.engine.pause() }, cancelled: { cancelled = true },
            completion: { oldCompleted = true })
        try graph.render(576)
        let before = graph.lastSample
        owner = 2
        graph.effect.ramp(to: 1, duration: 0.024, isRunning: { graph.engine.isRunning },
            isCurrent: { owner == 2 }, stalled: { graph.engine.pause() }, completion: { newCompleted = true })
        try graph.render(1)
        #expect(abs(graph.lastSample - before) < 0.00001)
        try graph.render(1151)
        try await Task.sleep(for: .milliseconds(20))
        #expect(cancelled && !oldCompleted && newCompleted)
        #expect(graph.lastSample == 0.05)
    }

    @Test("Missing render acknowledgement stops I/O before permitting a commit")
    func stalledRender() async throws {
        let graph = try GainGraph(rate: 48000)
        defer { graph.engine.stop() }
        var stopped = false, committed = false
        graph.effect.ramp(to: 0, duration: 0.008, isRunning: { graph.engine.isRunning },
            isCurrent: { true }, stalled: { stopped = true; graph.engine.pause() },
            completion: { committed = !graph.engine.isRunning })
        for _ in 0..<350 {
            if committed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(stopped && committed && !graph.engine.isRunning)
    }
}
