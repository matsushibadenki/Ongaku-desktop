//
//  /Users/Shared/Program/Xcode/Ongaku/audio/effects/GlossAudioEffect.swift
//  GlossAudioEffect.swift
//
//  EN: Gloss and Air enhancer with dynamic silky sheen and wet texture.
//  JA: 高域の明瞭さと空気感（Gloss/Air）を強調し、シルキーでウェットな艶を付加するエフェクト。
//  2026/04/08.
//

import AVFoundation

final class GlossAudioEffect: AudioEffectNode {
    let kind: RealtimeAudioEffectKind = .gloss
    private(set) var isEnabled: Bool = false
    
    private let glossEQ = AVAudioUnitEQ(numberOfBands: 3)
    
    // --- 追加: シルキーな艶出しのための空間系ノード ---
    // EN: Nodes for adding a silky wet sheen to the high frequencies
    // JA: 高音域にシルクのようなウェットな艶を付加するためのノード
    private let sheenDoubler = AVAudioUnitDelay()
    private let sheenReverb = AVAudioUnitReverb()
    private let inputSplitter = AVAudioMixerNode()
    private let dryMixer = AVAudioMixerNode()
    private let wetMixer = AVAudioMixerNode()
    private let outputMixer = AVAudioMixerNode()
    
    // Nodes配列に sheenDoubler と sheenReverb を追加
    var nodes: [AVAudioNode] { [inputSplitter, dryMixer, wetMixer, outputMixer, glossEQ, sheenDoubler, sheenReverb] }
    var inputNode: AVAudioNode { inputSplitter }
    var outputNode: AVAudioNode { outputMixer }
    
    private(set) var estimatedGainBoostDB: Double = 0.0

    func attach(to engine: AVAudioEngine) {
        for node in nodes {
            engine.attach(node)
        }
        
        // --- Gloss EQ 3バンド ---
        glossEQ.bands[0].filterType = .parametric; glossEQ.bands[0].frequency = 3200;  glossEQ.bands[0].bandwidth = 1.0; glossEQ.bands[0].bypass = false
        glossEQ.bands[1].filterType = .parametric; glossEQ.bands[1].frequency = 6400;  glossEQ.bands[1].bandwidth = 0.85; glossEQ.bands[1].bypass = false
        glossEQ.bands[2].filterType = .highShelf;  glossEQ.bands[2].frequency = 9800; glossEQ.bands[2].bandwidth = 0.75; glossEQ.bands[2].bypass = false
        
        // --- 追加: ダブラーの初期設定（高域の拡散と厚み） ---
        // EN: 22ms Haas delay for high-frequency widening. LPF applied to avoid harsh sibilance.
        // JA: 22msのハース・ディレイで高域を広げます。サ行の刺さりを防ぐためLPFを適用。
        sheenDoubler.delayTime = 0.022
        sheenDoubler.feedback = 0.0
        sheenDoubler.lowPassCutoff = 12_000 // 耳障りな超高域のチリチリ感を防ぐ
        sheenDoubler.wetDryMix = 0
        
        // --- 追加: リバーブの初期設定（シルキーな余韻） ---
        // EN: Plate reverb adds a smooth, metallic sheen ideal for vocals and cymbals.
        // JA: ボーカルやシンバルに最適な、滑らかで金属的な艶を乗せるプレートリバーブ。
        sheenReverb.loadFactoryPreset(.plate)
        sheenReverb.wetDryMix = 0
        dryMixer.outputVolume = 1
        wetMixer.outputVolume = 0
        outputMixer.outputVolume = 1

        glossEQ.bypass = true
        sheenDoubler.bypass = true
        sheenReverb.bypass = true
    }
    
    func connectInternalNodes(engine: AVAudioEngine, format: AVAudioFormat?) {
        engine.connect(inputSplitter, to: glossEQ, format: format)
        engine.connect(glossEQ, to: [
            AVAudioConnectionPoint(node: dryMixer, bus: 0),
            AVAudioConnectionPoint(node: sheenDoubler, bus: 0)
        ], fromBus: 0, format: format)
        engine.connect(dryMixer, to: outputMixer, fromBus: 0, toBus: 0, format: format)
        engine.connect(sheenDoubler, to: sheenReverb, format: format)
        engine.connect(sheenReverb, to: wetMixer, format: format)
        engine.connect(wetMixer, to: outputMixer, fromBus: 0, toBus: 1, format: format)
    }
    
    func detach(from engine: AVAudioEngine) {
        for node in nodes {
            engine.detach(node)
        }
    }
    
    func apply(setting: RealtimeAudioEffectSetting) {
        let intensity = clamped(setting.parameters["intensity"], defaultValue: 0.8)
        let clarity = clamped(setting.parameters["clarity"], defaultValue: 0.48)
        let air = clamped(setting.parameters["air"], defaultValue: 0.52)
        let intensityCurve = pow(intensity, 0.9)
        let clarityCurve = pow(clarity, 0.75)
        let airCurve = pow(air, 0.75)
        
        isEnabled = setting.isEnabled && intensity > 0.001
        
        guard isEnabled else {
            glossEQ.bypass = true
            sheenDoubler.bypass = true
            sheenReverb.bypass = true
            dryMixer.outputVolume = 1
            wetMixer.outputVolume = 0
            
            glossEQ.globalGain = 0
            glossEQ.bands[0].gain = 0
            glossEQ.bands[1].gain = 0
            glossEQ.bands[2].gain = 0
            
            sheenDoubler.wetDryMix = 100
            sheenReverb.wetDryMix = 100
            
            estimatedGainBoostDB = 0.0
            return
        }

        let sampleRate = glossEQ.inputFormat(forBus: 0).sampleRate
        let isSampleRateSafe = sampleRate > 0 && sampleRate <= 96_000

        glossEQ.bypass = false
        sheenDoubler.bypass = !isSampleRateSafe
        sheenReverb.bypass = !isSampleRateSafe

        glossEQ.bands[0].frequency = Float(2900.0 + clarity * 1800.0)
        glossEQ.bands[1].frequency = Float(5700.0 + clarity * 1700.0 + air * 800.0)
        glossEQ.bands[2].frequency = Float(9000.0 + air * 4200.0)

        glossEQ.bands[0].gain = Float((2.8 + airCurve * 2.6) * clarityCurve * intensityCurve)
        glossEQ.bands[0].bandwidth = Float(max(0.78, 1.15 - clarity * 0.32))
        glossEQ.bands[1].gain = Float((1.6 + clarityCurve * 2.8 + airCurve * 4.0) * intensityCurve)
        glossEQ.bands[1].bandwidth = Float(max(0.62, 0.98 - air * 0.24))
        glossEQ.bands[2].gain = Float((3.6 + clarityCurve * 1.8) * airCurve * intensityCurve)

        // 明瞭感を維持しつつ、刺さりと過大出力を抑える最小限のトリム。
        glossEQ.globalGain = -Float((0.12 + clarityCurve * 0.45 + airCurve * 0.58) * intensityCurve)
        
        // --- 修正: 動的なシルキー艶出し処理 (Dynamic Silky Sheen) ---
        // EN: Add wet sheen proportional to the 'Air' and 'Clarity' parameters.
        // JA: Clarity（明瞭さ）とAir（空気感）の強調量に比例して、高域の先端にウェットな艶を乗せます。
        if isSampleRateSafe {
            // Air（超高域）の要素を少し強めに重み付けして艶の量を決定します。
            let glossIntensity = Float((clarityCurve * 0.4 + airCurve * 0.6) * intensityCurve)
            
            // 高域専用のため、Mix量は控えめ（最大12〜16%）にし、原音の輪郭をぼやけさせないようにします。
            sheenDoubler.wetDryMix = 100
            sheenReverb.wetDryMix = 100
            wetMixer.outputVolume = min(0.16, glossIntensity * 0.16)
        } else {
            sheenDoubler.wetDryMix = 100
            sheenReverb.wetDryMix = 100
            wetMixer.outputVolume = 0
        }

        dryMixer.outputVolume = 1
        let hasWetSignal = isSampleRateSafe && wetMixer.outputVolume > 0.0001
        sheenDoubler.bypass = !hasWetSignal
        sheenReverb.bypass = !hasWetSignal
        
        estimatedGainBoostDB = intensityCurve * (clarityCurve * 1.7 + airCurve * 2.2)
    }
    
    private func clamped(_ value: Double?, defaultValue: Double) -> Double {
        return min(max(value ?? defaultValue, 0.0), 1.0)
    }
}

