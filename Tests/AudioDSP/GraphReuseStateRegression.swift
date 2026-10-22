import AVFoundation
import Foundation

@main @MainActor struct GraphReuseStateRegression {
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: message, code: 1) }
    }
    static func main() throws {
        let cases: [(Double, Double)] = [44_100.0, 48_000.0, 96_000.0].flatMap { rate in
            [0.1, 0.4, 0.6, 0.9].map { (rate, $0) }
        }
        for (rate, size) in cases {
            let engine = AVAudioEngine(), player = AVAudioPlayerNode()
            let rack = AudioEffectModuleRegistry.makePipeline()
            let effectGain = AudioThreadGainStage(gain: 1), transportGain = AudioThreadGainStage(gain: 1)
            let final = OngakuTruePeakAudioUnit.makeNode()
            let format = AVAudioFormat(standardFormatWithSampleRate: 96_000, channels: 2)!
            let output = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            engine.attach(player); engine.attach(effectGain.node); engine.attach(transportGain.node); engine.attach(final)
            var node: AVAudioNode = player
            for effect in rack {
                effect.attach(to: engine); effect.connectInternalNodes(engine: engine, format: format)
                engine.connect(node, to: effect.inputNode, format: format); node = effect.outputNode
                var setting = RealtimeAudioEffectSetting(kind: effect.kind, isEnabled: true)
                if effect.kind == .warm { setting.parameters["flutter"] = 0 }
                if effect.kind == .space { setting.parameters["size"] = size }
                effect.apply(setting: setting)
            }
            engine.connect(node, to: effectGain.node, format: format)
            engine.connect(effectGain.node, to: transportGain.node, format: format)
            let conversion = AVAudioMixerNode(); engine.attach(conversion)
            engine.connect(transportGain.node, to: conversion, format: format)
            engine.connect(conversion, to: final, format: output)
            engine.connect(final, to: engine.mainMixerNode, format: output)
            try engine.enableManualRenderingMode(.offline, format: output, maximumFrameCount: 512)
            let hot = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
            hot.frameLength = hot.frameCapacity
            for ch in 0..<2 { for i in 0..<Int(hot.frameLength) {
                hot.floatChannelData![ch][i] = Float(0.015 * sin(2 * .pi * 997 * Double(i) / 96_000))
            } }
            let rendered = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 512)!
            player.scheduleBuffer(hot); try engine.start()
            effectGain.synchronizeAfterStart(); transportGain.synchronizeAfterStart(); player.play()
            var hotPeak: Float = 0
            for _ in 0..<Int(rate * 0.25 / 512) {
                try require(try engine.renderOffline(512, to: rendered) == .success, "hot render failed")
                for ch in 0..<2 { for i in 0..<Int(rendered.frameLength) { hotPeak = max(hotPeak, abs(rendered.floatChannelData![ch][i])) } }
            }
            try require(hotPeak > 0.0001, "fixture never excited the rack")
            // Match the hosts: rendered zero and downstream drain precede reuse.
            let gainUnit = transportGain.node.auAudioUnit as! OngakuGainEnvelopeAudioUnit
            let token = gainUnit.ramp(toGain: 0, durationFrames: 2304)
            for _ in 0..<Int(ceil(rate * 0.024 / 512)) + 1 {
                try require(try engine.renderOffline(512, to: rendered) == .success, "fade render failed")
            }
            try require(gainUnit.isRampComplete(token), "transport never acknowledged rendered zero")
            for _ in 0..<Int(ceil(rate * 0.024 / 512)) + 1 {
                try require(try engine.renderOffline(512, to: rendered) == .success, "drain render failed")
            }
            engine.pause(); player.stop()
            let reverbState = engine.attachedNodes.compactMap { node -> (AVAudioUnitReverb, Int?, Float, Bool)? in
                guard let reverb = node as? AVAudioUnitReverb else { return nil }
                return (reverb, reverb.auAudioUnit.currentPreset?.number, reverb.wetDryMix, reverb.bypass)
            }
            if !CommandLine.arguments.contains("--skip-reset") {
                try require(AudioGraphLifecycle.resetWhilePaused(engine), "unknown preset rejected reuse")
                rack.forEach { $0.resetTailState() }
                for (unit, preset, mix, bypass) in reverbState {
                    try require(unit.auAudioUnit.currentPreset?.number == preset && unit.wetDryMix == mix
                        && unit.bypass == bypass, "reset changed reverb voice or gain")
                    try require(unit.auAudioUnit.renderResourcesAllocated, "reset freed reverb resources")
                }
            }
            try require(final.auAudioUnit.renderResourcesAllocated && effectGain.node.auAudioUnit.renderResourcesAllocated
                && transportGain.node.auAudioUnit.renderResourcesAllocated, "reset freed render resources")
            let silent = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
            silent.frameLength = silent.frameCapacity
            for ch in 0..<2 { silent.floatChannelData![ch].initialize(repeating: 0, count: 48_000) }
            transportGain.setImmediate(0)
            player.scheduleBuffer(silent); try engine.start()
            effectGain.synchronizeAfterStart(); transportGain.synchronizeAfterStart(); player.play()
            // The hosts hold transport at zero until fresh source frames have
            // traversed the rack, then restore with the existing 24 ms fade.
            var residual: Float = 0
            var renderedFrames = 0, lastNonzeroFrame = -1
            for _ in 0..<Int(ceil(rate * 0.008 / 512)) {
                try require(try engine.renderOffline(512, to: rendered) == .success, "fresh render failed")
                for ch in 0..<2 { for i in 0..<Int(rendered.frameLength) { residual = max(residual, abs(rendered.floatChannelData![ch][i])); if abs(rendered.floatChannelData![ch][i]) > 1e-7 { lastNonzeroFrame = renderedFrames + i } } }
                renderedFrames += Int(rendered.frameLength)
            }
            _ = gainUnit.ramp(toGain: 1, durationFrames: 2304)
            for _ in 0..<Int(rate * 0.20 / 512) {
                try require(try engine.renderOffline(512, to: rendered) == .success, "reuse render failed")
                for ch in 0..<2 { for i in 0..<Int(rendered.frameLength) { residual = max(residual, abs(rendered.floatChannelData![ch][i])); if abs(rendered.floatChannelData![ch][i]) > 1e-7 { lastNonzeroFrame = renderedFrames + i } } }
                renderedFrames += Int(rendered.frameLength)
            }
            FileHandle.standardOutput.write(Data("REUSE_STATE rate=\(Int(rate)) spaceSize=\(size) residual=\(residual) FS lastNonzeroFrame=\(lastNonzeroFrame)\n".utf8))
            try require(residual < 1e-7, "retired track history survived graph reuse: \(residual)")
            engine.stop(); player.stop()
            print("PASS: retained full rack + SRC + gain + true-peak reuse at \(Int(rate)) Hz, spaceSize=\(size), residual=\(residual) FS")
        }
    }
}
