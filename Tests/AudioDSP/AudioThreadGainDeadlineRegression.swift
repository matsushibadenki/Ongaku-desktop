import AVFoundation
import Foundation
import Darwin

private struct AuditFailure: Error { let message: String }
@MainActor private final class ControlQueue {
    var time: TimeInterval = 0
    var actions: [@MainActor () -> Void] = []
    func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        actions.append(action)
    }
    func deliver(after delay: TimeInterval) throws {
        time += delay
        guard !actions.isEmpty else { throw AuditFailure(message: "missing scheduled poll") }
        actions.removeFirst()()
    }
}

@MainActor private final class Graph {
    let clock = ControlQueue()
    let engine = AVAudioEngine()
    let gain: AudioThreadGainStage
    let source: AVAudioSourceNode
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    init() throws {
        let clock = clock
        gain = AudioThreadGainStage(gain: 1, now: { clock.time }, schedule: clock.schedule)
        source = AVAudioSourceNode { _, _, frames, list in
            for buffer in UnsafeMutableAudioBufferListPointer(list) {
                buffer.mData!.assumingMemoryBound(to: Float.self).initialize(repeating: 0.05, count: Int(frames))
            }
            return noErr
        }
        engine.attach(source); engine.attach(gain.node)
        engine.connect(source, to: gain.node, format: format)
        engine.connect(gain.node, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        try engine.start(); gain.synchronizeAfterStart()
    }
    func render(_ frames: Int) throws -> Float {
        var left = frames, last: Float = 0
        while left > 0 {
            let count = AVAudioFrameCount(min(512, left))
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
            guard try engine.renderOffline(count, to: pcm) == .success else { throw AuditFailure(message: "render failed") }
            last = pcm.floatChannelData![0][Int(count)-1]
            left -= Int(count)
        }
        return last
    }
}

@main private struct DeadlineAudit {
    @MainActor static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw AuditFailure(message: message) }
    }
    @MainActor static func run() throws {
        // One callback delayed beyond the budget must stop I/O before commit.
        do {
            let graph = try Graph(); defer { graph.engine.stop() }
            var stopped = false, complete = false
            graph.gain.ramp(to: 0, duration: 0.008, isRunning: { graph.engine.isRunning }, isCurrent: { true },
                stalled: { stopped = true; graph.engine.pause() }, completion: { complete = !graph.engine.isRunning })
            try graph.clock.deliver(after: 3)
            try require(stopped && complete, "elapsed deadline did not stop I/O before commit")
            print("PASS: one poll delayed 3 s stops I/O before committing")
        }
        // Before the deadline, time alone never acknowledges unrendered audio.
        do {
            let graph = try Graph(); defer { graph.engine.stop() }
            var stopped = false, complete = false
            graph.gain.ramp(to: 0, duration: 0.008, isRunning: { graph.engine.isRunning }, isCurrent: { true },
                stalled: { stopped = true; graph.engine.pause() }, completion: { complete = true })
            try graph.clock.deliver(after: 1.999)
            try require(!stopped && !complete, "unrendered ramp completed before deadline")
            try graph.clock.deliver(after: 0.001)
            try require(stopped && complete && !graph.engine.isRunning, "deadline boundary did not stop I/O")
            print("PASS: no early commit and exact monotonic deadline is enforced")
        }
        // A valid zero rendered before a late callback is stronger evidence than timeout.
        do {
            let graph = try Graph(); defer { graph.engine.stop() }
            var stopped = false, complete = false
            graph.gain.ramp(to: 0, duration: 0.008, isRunning: { graph.engine.isRunning }, isCurrent: { true },
                stalled: { stopped = true; graph.engine.pause() }, completion: { complete = true })
            let last = try graph.render(384)
            try require(last == 0, "ramp did not render actual zero")
            try graph.clock.deliver(after: 3)
            try require(complete && !stopped && graph.engine.isRunning, "late valid acknowledgement incorrectly stopped I/O")
            print("PASS: actual rendered zero wins over a delayed callback deadline")
        }
        // Old timeout work must not pause a superseding audible request.
        do {
            let graph = try Graph(); defer { graph.engine.stop() }
            var stopped = false, oldComplete = false, cancelled = false, newComplete = false
            graph.gain.ramp(to: 0, duration: 0.008, isRunning: { graph.engine.isRunning }, isCurrent: { true },
                stalled: { stopped = true; graph.engine.pause() }, cancelled: { cancelled = true }, completion: { oldComplete = true })
            graph.gain.ramp(to: 1, duration: 0.008, isRunning: { graph.engine.isRunning }, isCurrent: { true },
                stalled: { stopped = true; graph.engine.pause() }, completion: { newComplete = true })
            try graph.clock.deliver(after: 3)
            try require(cancelled && !stopped && !oldComplete && graph.engine.isRunning, "stale timeout affected new request")
            _ = try graph.render(384)
            try graph.clock.deliver(after: 0)
            try require(newComplete && !stopped, "current rendered endpoint was lost")
            print("PASS: superseded callback cancels without stopping the current request")
        }
        do {
            let graph = try Graph(); defer { graph.engine.stop() }
            var stopped = false, complete = false
            graph.gain.ramp(to: 0, duration: 0.008, isRunning: { graph.engine.isRunning }, isCurrent: { true },
                stalled: { stopped = true }, completion: { complete = true })
            graph.engine.pause()
            try graph.clock.deliver(after: 0.1)
            try require(complete && !stopped, "physically paused graph did not finish safely")
            print("PASS: physically paused I/O completes without false stall")
        }
    }
    @MainActor static func main() {
        do { try run() } catch {
            let message = (error as? AuditFailure)?.message ?? String(describing: error)
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1)
        }
    }
}
