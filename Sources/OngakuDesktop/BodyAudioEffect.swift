//
//  /Users/Shared/Program/Xcode/Ongaku/audio/effects/BodyAudioEffect.swift
//  BodyAudioEffect.swift
//
//  EN: Body (Low-mid) enhancer with dynamic acoustic gloss and liquid wetness.
//  JA: 低〜中低域の厚み（Body）を強調しつつ、アコースティックな艶とウェット感を付加するエフェクト。
//  2026/04/08.
//

import AVFoundation

final class BodyAudioEffect: AudioEffectNode {
    let kind: RealtimeAudioEffectKind = .body
    private(set) var isEnabled: Bool = false
    
    private let bodyEQ = AVAudioUnitEQ(numberOfBands: 4)
    
    // --- 追加: 艶出しと共鳴のための空間系ノード ---
    // EN: Nodes for adding acoustic resonance and glossy texture to the low-mids
    // JA: 中低域にアコースティックな共鳴と艶やかな質感を付加するためのノード
    private let glossDoubler = AVAudioUnitDelay()
    private let sheenReverb = AVAudioUnitReverb()
    private let inputSplitter = AVAudioMixerNode()
    private let dryMixer = AVAudioMixerNode()
    private let wetMixer = AVAudioMixerNode()
    private let outputMixer = AVAudioMixerNode()
    
    // Nodes配列に glossDoubler と sheenReverb を追加
    var nodes: [AVAudioNode] { [inputSplitter, dryMixer, wetMixer, outputMixer, bodyEQ, glossDoubler, sheenReverb] }
    var inputNode: AVAudioNode { inputSplitter }
    var outputNode: AVAudioNode { outputMixer }
    
    private(set) var estimatedGainBoostDB: Double = 0.0

    func attach(to engine: AVAudioEngine) {
        for node in nodes {
            engine.attach(node)
        }
        
        // --- Body EQ 4バンド 初期設定 ---
        bodyEQ.bands[0].filterType = .lowShelf;  bodyEQ.bands[0].frequency = 85;   bodyEQ.bands[0].bandwidth = 0.9; bodyEQ.bands[0].bypass = false
        bodyEQ.bands[1].filterType = .parametric; bodyEQ.bands[1].frequency = 130;  bodyEQ.bands[1].bandwidth = 1.0; bodyEQ.bands[1].bypass = false
        bodyEQ.bands[2].filterType = .parametric; bodyEQ.bands[2].frequency = 230;  bodyEQ.bands[2].bandwidth = 1.1; bodyEQ.bands[2].bypass = false
        bodyEQ.bands[3].filterType = .parametric; bodyEQ.bands[3].frequency = 520;  bodyEQ.bands[3].bandwidth = 0.95; bodyEQ.bands[3].bypass = false
        
        // --- 追加: ダブラーの初期設定（低域に最適化） ---
        // EN: 28ms delay avoids comb-filtering in the 100-200Hz range, keeping bass tight.
        // JA: 28msの遅延にすることで、100〜200Hz帯の位相干渉（音痩せ）を防ぎつつ厚みを出します。
        glossDoubler.delayTime = 0.028
        glossDoubler.feedback = 0.0
        glossDoubler.lowPassCutoff = 4_500 // 高域のチリチリしたノイズをカットし、滑らかな中低域のみを抽出
        glossDoubler.wetDryMix = 0
        
        // --- 追加: リバーブの初期設定（木や弦の艶やかな鳴り） ---
        // EN: Plate reverb adds metallic/wood gloss without muddying the sub-bass tail.
        // JA: サブベースを濁らせず、中低域の倍音にのみ金属的・アコースティックな艶を乗せるプレートを採用。
        sheenReverb.loadFactoryPreset(.plate)
        sheenReverb.wetDryMix = 0
        dryMixer.outputVolume = 1
        wetMixer.outputVolume = 0
        outputMixer.outputVolume = 1

        bodyEQ.bypass = true
        glossDoubler.bypass = true
        sheenReverb.bypass = true
    }
    
    func connectInternalNodes(engine: AVAudioEngine, format: AVAudioFormat?) {
        engine.connect(inputSplitter, to: bodyEQ, format: format)
        engine.connect(bodyEQ, to: [
            AVAudioConnectionPoint(node: dryMixer, bus: 0),
            AVAudioConnectionPoint(node: glossDoubler, bus: 0)
        ], fromBus: 0, format: format)
        engine.connect(dryMixer, to: outputMixer, fromBus: 0, toBus: 0, format: format)
        engine.connect(glossDoubler, to: sheenReverb, format: format)
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
        let weight = clamped(setting.parameters["weight"], defaultValue: 0.52)
        let punch = clamped(setting.parameters["punch"], defaultValue: 0.48)
        let intensityCurve = pow(intensity, 0.9)
        let weightCurve = pow(weight, 0.75)
        let punchCurve = pow(punch, 0.75)
        
        isEnabled = setting.isEnabled && intensity > 0.001
        
        guard isEnabled else {
            bodyEQ.bypass = true
            glossDoubler.bypass = true
            sheenReverb.bypass = true
            dryMixer.outputVolume = 1
            wetMixer.outputVolume = 0
            
            bodyEQ.globalGain = 0
            bodyEQ.bands[0].gain = 0
            bodyEQ.bands[1].gain = 0
            bodyEQ.bands[2].gain = 0
            bodyEQ.bands[3].gain = 0
            
            glossDoubler.wetDryMix = 100
            sheenReverb.wetDryMix = 100
            
            estimatedGainBoostDB = 0.0
            return
        }

        let sampleRate = bodyEQ.inputFormat(forBus: 0).sampleRate
        let isSampleRateSafe = sampleRate > 0 && sampleRate <= 96_000

        bodyEQ.bypass = false
        glossDoubler.bypass = !isSampleRateSafe
        sheenReverb.bypass = !isSampleRateSafe

        bodyEQ.bands[0].frequency = Float(72.0 + weight * 62.0)
        bodyEQ.bands[1].frequency = Float(112.0 + weight * 88.0)
        bodyEQ.bands[2].frequency = Float(190.0 + weight * 130.0 + punch * 50.0)
        bodyEQ.bands[3].frequency = Float(420.0 + punch * 260.0)

        bodyEQ.bands[0].gain = Float((5.8 + punchCurve * 2.2) * weightCurve * intensityCurve)
        bodyEQ.bands[1].gain = Float((4.4 + punchCurve * 2.6) * weightCurve * intensityCurve)
        bodyEQ.bands[2].gain = Float((1.2 + weightCurve * 4.2 + punchCurve * 4.2) * intensityCurve)
        bodyEQ.bands[3].gain = Float((1.0 + punchCurve * 6.6) * intensityCurve)
        bodyEQ.bands[2].bandwidth = Float(max(0.65, 1.15 - weight * 0.38))
        bodyEQ.bands[3].bandwidth = Float(max(0.52, 1.08 - punch * 0.45))

        // 低域の厚みは残しつつ、全体が痩せない程度にヘッドルーム確保。
        bodyEQ.globalGain = -Float((0.20 + weightCurve * 0.95 + punchCurve * 0.55) * intensityCurve)
        
        // --- 修正: 動的な艶出し処理 (Dynamic Acoustic Gloss) ---
        // EN: Add slight wetness proportional to the applied weight and punch, keeping the mix low to prevent mud.
        // JA: WeightとPunchの強調量に比例して、チェロやフレットレスベースのような「木鳴り・弦鳴りの艶」を付加します。
        // 低域の濁り（Mud）を防ぐため、Mix量は最大でも8%〜10%の「隠し味」に制限しています。
        if isSampleRateSafe {
            let glossIntensity = Float((weightCurve * 0.5 + punchCurve * 0.5) * intensityCurve)
            
            glossDoubler.wetDryMix = 100
            sheenReverb.wetDryMix = 100
            wetMixer.outputVolume = min(0.12, glossIntensity * 0.12)
        } else {
            glossDoubler.wetDryMix = 100
            sheenReverb.wetDryMix = 100
            wetMixer.outputVolume = 0
        }

        dryMixer.outputVolume = 1
        let hasWetSignal = isSampleRateSafe && wetMixer.outputVolume > 0.0001
        glossDoubler.bypass = !hasWetSignal
        sheenReverb.bypass = !hasWetSignal
        
        estimatedGainBoostDB = intensityCurve * (weightCurve * 2.9 + punchCurve * 2.3)
    }
    
    private func clamped(_ value: Double?, defaultValue: Double) -> Double {
        return min(max(value ?? defaultValue, 0.0), 1.0)
    }
}

