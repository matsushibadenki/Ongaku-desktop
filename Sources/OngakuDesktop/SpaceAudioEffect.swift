//
//  /Users/Shared/Program/Xcode/Ongaku/audio/effects/SpaceAudioEffect.swift
//  SpaceAudioEffect.swift
//
//  EN: Fixed 3D Spatial Audio Reverb using explicit mixer buses for dry/wet summing.
//  JA: 各パスを個別のミキサーバスに接続し、原音とエフェクト音のミックスを修正した3D立体音響リバーブ。
//  Created by Codex on 2026/04/08.
//

import AVFoundation

final class SpaceAudioEffect: AudioEffectNode {
    let kind: RealtimeAudioEffectKind = .space
    private(set) var isEnabled: Bool = false
    
    // --- 3Dルーティング用ミキサーノード ---
    private let inputSplitter = AVAudioMixerNode()
    
    // --- Path 1: Width (Early Reflections) ---
    private let earlyDelay = AVAudioUnitDelay()
    private let earlyReverb = AVAudioUnitReverb()
    private let earlyMixer = AVAudioMixerNode()
    
    // --- Path 2: Depth (Late Reverberation) ---
    private let lateDelay = AVAudioUnitDelay()
    private let lateEQ = AVAudioUnitEQ(numberOfBands: 2)
    private let lateReverb = AVAudioUnitReverb()
    private let lateMixer = AVAudioMixerNode()
    
    private let outputMixer = AVAudioMixerNode()
    
    private var lastSpaceReverbPreset: Int = -1
    
    var nodes: [AVAudioNode] {
        [inputSplitter,
         earlyDelay, earlyReverb, earlyMixer,
         lateDelay, lateEQ, lateReverb, lateMixer,
         outputMixer]
    }
    
    var inputNode: AVAudioNode { inputSplitter }
    var outputNode: AVAudioNode { outputMixer }
    
    private(set) var estimatedGainBoostDB: Double = 0.0

    func attach(to engine: AVAudioEngine) {
        for node in nodes {
            engine.attach(node)
        }

        // --- Early Path Setup (Width) ---
        earlyDelay.delayTime = 0.018
        earlyDelay.feedback = 0
        earlyDelay.lowPassCutoff = 12_000
        earlyDelay.wetDryMix = 100.0 // 100% Wet
        
        earlyReverb.loadFactoryPreset(.smallRoom)
        earlyReverb.wetDryMix = 100.0

        // --- Late Path Setup (Depth) ---
        lateDelay.delayTime = 0.040
        lateDelay.feedback = 0
        lateDelay.lowPassCutoff = 8_000
        lateDelay.wetDryMix = 100.0 // 100% Wet
        
        lateEQ.bands[0].filterType = .highShelf
        lateEQ.bands[0].frequency = 4_200
        lateEQ.bands[0].bandwidth = 0.9
        lateEQ.bands[0].bypass = false

        lateEQ.bands[1].filterType = .lowShelf
        lateEQ.bands[1].frequency = 250
        lateEQ.bands[1].gain = -6.0
        lateEQ.bands[1].bandwidth = 1.0
        lateEQ.bands[1].bypass = false
        
        lateReverb.loadFactoryPreset(.mediumRoom)
        lateReverb.wetDryMix = 100.0
        
        earlyMixer.outputVolume = 0
        lateMixer.outputVolume = 0
    }
    
    func connectInternalNodes(engine: AVAudioEngine, format: AVAudioFormat?) {
        // --- 修正ポイント: AVAudioConnectionPoint によるマルチ・ルーティング (Fan-out) ---
        // EN: In AVAudioEngine, calling connect() multiple times from the same source bus
        //     replaces the previous connection. We must use AVAudioConnectionPoint for fan-out.
        // JA: 同じ出力バスから複数回 connect() を呼ぶと、前の接続が解除されてしまいます。
        //     原音(Dry)、初期反射(Early)、後期残響(Late)の3つのパスを同時に生かすため、ConnectionPointを使用します。
        
        let connectionPoints = [
            AVAudioConnectionPoint(node: outputMixer, bus: 0),
            AVAudioConnectionPoint(node: earlyDelay, bus: 0),
            AVAudioConnectionPoint(node: lateDelay, bus: 0)
        ]
        engine.connect(inputSplitter, to: connectionPoints, fromBus: 0, format: format)
        
        // --- Path 2 (Early Reflections) ---
        engine.connect(earlyDelay, to: earlyReverb, format: format)
        engine.connect(earlyReverb, to: earlyMixer, format: format)
        engine.connect(earlyMixer, to: outputMixer, fromBus: 0, toBus: 1, format: format)
        
        // --- Path 3 (Late Reverberation) ---
        engine.connect(lateDelay, to: lateEQ, format: format)
        engine.connect(lateEQ, to: lateReverb, format: format)
        engine.connect(lateReverb, to: lateMixer, format: format)
        engine.connect(lateMixer, to: outputMixer, fromBus: 0, toBus: 2, format: format)
    }
    
    func detach(from engine: AVAudioEngine) {
        for node in nodes {
            engine.detach(node)
        }
    }
    
    func apply(setting: RealtimeAudioEffectSetting) {
        let intensity = clamped(setting.parameters["intensity"], defaultValue: 0.8)
        let amount = clamped(setting.parameters["amount"], defaultValue: 0.22)
        let size = clamped(setting.parameters["size"], defaultValue: 0.45)
        let preDelay = clamped(setting.parameters["preDelay"], defaultValue: 0.24)
        let damping = clamped(setting.parameters["damping"], defaultValue: 0.46)
        
        let intensityCurve = pow(intensity, 0.88)
        let amountCurve = pow(amount, 0.82)
        let sizeCurve = pow(size, 0.84)
        let preDelayCurve = pow(preDelay, 0.90)
        let dampingCurve = pow(damping, 0.80)

        isEnabled = setting.isEnabled && intensity > 0.001 && amount > 0.001
        
        guard isEnabled else {
            earlyMixer.outputVolume = 0
            lateMixer.outputVolume = 0
            estimatedGainBoostDB = 0.0
            return
        }

        let sampleRate = lateReverb.inputFormat(forBus: 0).sampleRate
        let isSampleRateSafe = sampleRate > 0 && sampleRate <= 96000

        guard isSampleRateSafe else {
            earlyMixer.outputVolume = 0
            lateMixer.outputVolume = 0
            return
        }
        
        let spacePresetIndex: Int
        if size > 0.75 { spacePresetIndex = 3 }
        else if size > 0.50 { spacePresetIndex = 2 }
        else if size > 0.25 { spacePresetIndex = 1 }
        else { spacePresetIndex = 0 }

        if spacePresetIndex != lastSpaceReverbPreset {
            lastSpaceReverbPreset = spacePresetIndex
            switch spacePresetIndex {
            case 3: lateReverb.loadFactoryPreset(.cathedral)
            case 2: lateReverb.loadFactoryPreset(.largeChamber)
            case 1: lateReverb.loadFactoryPreset(.mediumHall)
            default: lateReverb.loadFactoryPreset(.mediumRoom)
            }
        }

        // Width (Early Reflections) のバランス
        let earlyRatio = 1.0 - (sizeCurve * 0.3)
        let earlyVolume = Float(amountCurve * earlyRatio * intensityCurve * 0.425)
        earlyMixer.outputVolume = earlyVolume

        // Depth (Late Reverberation) のバランス
        lateDelay.delayTime = TimeInterval(0.020 + preDelayCurve * 0.120)
        lateEQ.bands[0].gain = -Float((6.0 + dampingCurve * 18.0) * intensityCurve)
        
        let lateRatio = 0.4 + (sizeCurve * 0.6)
        let lateVolume = Float(amountCurve * lateRatio * intensityCurve * 0.6)
        lateMixer.outputVolume = lateVolume
        
        estimatedGainBoostDB = intensityCurve * (amountCurve * 1.2 + sizeCurve * 0.4)
    }
    
    private func clamped(_ value: Double?, defaultValue: Double) -> Double {
        return min(max(value ?? defaultValue, 0.0), 1.0)
    }
}

