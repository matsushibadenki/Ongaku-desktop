//
//  EqualizerAudioEffect.swift
//  audio
//
//  2026/04/08.
//
//  EN: Equalizer simulating Solid State Logic Ultra Violet EQ, with dynamic glossy sheen.
//  JA: Solid State Logic Ultra Violet EQ をシミュレーションし、動的な艶とウェット感を付加したイコライザー。
//

import AVFoundation

final class EqualizerAudioEffect: AudioEffectNode {
    let kind: RealtimeAudioEffectKind = .equalizer
    private(set) var isEnabled: Bool = false

    private let mainEQ = AVAudioUnitEQ(numberOfBands: 5)
    
    // --- 追加: 艶出しのための空間系ノード ---
    // EN: Nodes for adding glossy/wet texture
    // JA: 艶とウェットな質感を付加するためのノード
    private let glossDoubler = AVAudioUnitDelay()
    private let sheenReverb = AVAudioUnitReverb()

    // Keep the original signal independent from the optional ambience path.
    private let inputSplitter = AVAudioMixerNode()
    private let dryMixer = AVAudioMixerNode()
    private let wetMixer = AVAudioMixerNode()
    private let outputMixer = AVAudioMixerNode()
    
    // Nodes配列に glossDoubler と sheenReverb を追加
    var nodes: [AVAudioNode] {
        [inputSplitter, dryMixer, wetMixer, outputMixer, mainEQ, glossDoubler, sheenReverb]
    }
    var inputNode: AVAudioNode { inputSplitter }
    var outputNode: AVAudioNode { outputMixer }

    private(set) var estimatedGainBoostDB: Double = 0.0

    func attach(to engine: AVAudioEngine) {
        for node in nodes {
            engine.attach(node)
        }
        
        configureBands()
        
        // --- 追加: ダブラーの初期設定（高域の拡散） ---
        // EN: Very short delay for thickening the high frequencies
        // JA: 高域に厚みを持たせるための極短ディレイ
        glossDoubler.delayTime = 0.022
        glossDoubler.feedback = 0.0
        glossDoubler.lowPassCutoff = 10_000 // デジタル臭さを消すため超高域はカット
        glossDoubler.wetDryMix = 0
        
        // --- 追加: リバーブの初期設定（滑らかな艶） ---
        // EN: Plate reverb for silky sheen
        // JA: シルクのような艶出しに最適なプレートリバーブ
        sheenReverb.loadFactoryPreset(.plate)
        sheenReverb.wetDryMix = 0

        dryMixer.outputVolume = 1
        wetMixer.outputVolume = 0
        outputMixer.outputVolume = 1

        mainEQ.bypass = true
        glossDoubler.bypass = true
        sheenReverb.bypass = true
    }

    func connectInternalNodes(engine: AVAudioEngine, format: AVAudioFormat?) {
        // EN: Preserve the EQ path and blend ambience in parallel.
        // JA: EQ後の原音を維持し、艶成分だけを並列でミックスする。
        engine.connect(inputSplitter, to: mainEQ, format: format)
        engine.connect(
            mainEQ,
            to: [
                AVAudioConnectionPoint(node: dryMixer, bus: 0),
                AVAudioConnectionPoint(node: glossDoubler, bus: 0)
            ],
            fromBus: 0,
            format: format
        )
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
        isEnabled = setting.isEnabled
        
        guard isEnabled else {
            mainEQ.bypass = true
            glossDoubler.bypass = true
            sheenReverb.bypass = true
            dryMixer.outputVolume = 1
            wetMixer.outputVolume = 0
            
            mainEQ.globalGain = 0
            glossDoubler.wetDryMix = 100
            sheenReverb.wetDryMix = 100
            estimatedGainBoostDB = 0.0
            return
        }

        let sampleRate = mainEQ.inputFormat(forBus: 0).sampleRate
        let isSampleRateSafe = sampleRate > 0 && sampleRate <= 96_000

        mainEQ.bypass = false
        glossDoubler.bypass = !isSampleRateSafe
        sheenReverb.bypass = !isSampleRateSafe
        
        // --- HPF (Band 0) ---
        let hpfVal = clamped(setting.parameters["hpf"], defaultValue: 0.0)
        let hpfFreqs: [Float] = [0, 30, 40, 50]
        let hpfCount = Double(hpfFreqs.count - 1)
        let hpfIdx = Int(round(hpfVal * hpfCount))
        let hpfFreq = hpfFreqs[hpfIdx]
        
        if hpfFreq > 0 {
            mainEQ.bands[0].bypass = false
            mainEQ.bands[0].frequency = hpfFreq
        } else {
            mainEQ.bands[0].bypass = true
        }

        // --- LF (Band 1: Low Shelf) ---
        let lfGain = musicalBipolarGain(setting.parameters["lfGain"], maxBoost: 10.0, maxCut: 12.0)
        let lfFreqVal = clamped(setting.parameters["lfFreq"], defaultValue: 0.0)
        let lfFreqs: [Float] = [55, 80, 120, 180]
        let lfCount = Double(lfFreqs.count - 1)
        let lfIdx = Int(round(lfFreqVal * lfCount))
        mainEQ.bands[1].frequency = lfFreqs[lfIdx]
        mainEQ.bands[1].gain = Float(lfGain)
        mainEQ.bands[1].bandwidth = 0.82

        // --- HF (Band 4: High Shelf) ---
        let hfGain = musicalBipolarGain(setting.parameters["hfGain"], maxBoost: 9.0, maxCut: 12.0)
        let hfFreqVal = clamped(setting.parameters["hfFreq"], defaultValue: 0.0)
        let hfFreqs: [Float] = [6_800, 9_500, 12_500, 16_000]
        let hfCount = Double(hfFreqs.count - 1)
        let hfIdx = Int(round(hfFreqVal * hfCount))
        mainEQ.bands[4].frequency = hfFreqs[hfIdx]
        mainEQ.bands[4].gain = Float(hfGain)
        mainEQ.bands[4].bandwidth = 0.72

        // --- LMF (Band 2: Parametric) ---
        let lmfGainRaw = clamped(setting.parameters["lmfGain"], defaultValue: 0.5)
        let lmfGain = musicalBipolarGain(lmfGainRaw, maxBoost: 8.0, maxCut: 10.0)
        
        let lmfFreqRaw = clamped(setting.parameters["lmfFreq"], defaultValue: 0.5)
        let lmfFreqLog = log(120.0) + lmfFreqRaw * (log(1_400.0) - log(120.0))
        let lmfFreq = exp(lmfFreqLog)
        
        let lmfQRaw = clamped(setting.parameters["lmfQ"], defaultValue: 0.5)
        let lmfFocus = clamped(setting.parameters["lmfFocus"], defaultValue: 0.0) > 0.5
        
        mainEQ.bands[2].frequency = Float(lmfFreq)
        mainEQ.bands[2].gain = Float(lmfGain)
        mainEQ.bands[2].bandwidth = musicalBellBandwidth(control: lmfQRaw, isFocused: lmfFocus, gainDB: lmfGain)

        // --- HMF (Band 3: Parametric) ---
        let hmfGainRaw = clamped(setting.parameters["hmfGain"], defaultValue: 0.5)
        let hmfGain = musicalBipolarGain(hmfGainRaw, maxBoost: 8.0, maxCut: 10.0)
        
        let hmfFreqRaw = clamped(setting.parameters["hmfFreq"], defaultValue: 0.5)
        let hmfFreqLog = log(700.0) + hmfFreqRaw * (log(8_200.0) - log(700.0))
        let hmfFreq = exp(hmfFreqLog)
        
        let hmfQRaw = clamped(setting.parameters["hmfQ"], defaultValue: 0.5)
        let hmfFocus = clamped(setting.parameters["hmfFocus"], defaultValue: 0.0) > 0.5

        mainEQ.bands[3].frequency = Float(hmfFreq)
        mainEQ.bands[3].gain = Float(hmfGain)
        mainEQ.bands[3].bandwidth = musicalBellBandwidth(control: hmfQRaw, isFocused: hmfFocus, gainDB: hmfGain)

        // --- Trim ---
        let userTrim = musicalBipolarGain(setting.parameters["trim"], maxBoost: 6.0, maxCut: 18.0)
        let totalBoost = max(0.0, lfGain) + max(0.0, lmfGain) + max(0.0, hmfGain) + max(0.0, hfGain)
        let autoMakeupTrim = -min(6.0, totalBoost * 0.28)
        let trim = userTrim + autoMakeupTrim
        mainEQ.globalGain = Float(trim)
        
        // --- 修正: 動的な艶出し処理 (Dynamic Gloss & Sheen) ---
        // EN: Calculate wetness based strictly on positive boosts in HMF and HF to prevent muddying the low end.
        // JA: 低域が濁るのを防ぐため、HMF(中高域)とHF(高域)がプラスにブーストされた時のみ、ウェット成分を加えます。
        if isSampleRateSafe {
            let hfBoostAmount = max(0.0, hfGain) / 9.0  // 0.0 to 1.0
            let hmfBoostAmount = max(0.0, hmfGain) / 8.0 // 0.0 to 1.0
            
            // HMFよりHF（Air帯域）のブーストを重み付けして艶を決定
            let glossIntensity = Float(hfBoostAmount * 0.7 + hmfBoostAmount * 0.3)
            
            // The ambience units run fully wet; the mixer controls the actual amount.
            glossDoubler.wetDryMix = 100
            sheenReverb.wetDryMix = 100
            wetMixer.outputVolume = min(0.16, glossIntensity * 0.16)
        } else {
            glossDoubler.wetDryMix = 100
            sheenReverb.wetDryMix = 100
            wetMixer.outputVolume = 0
        }

        dryMixer.outputVolume = 1
        let hasWetSignal = isSampleRateSafe && wetMixer.outputVolume > 0.0001
        glossDoubler.bypass = !hasWetSignal
        sheenReverb.bypass = !hasWetSignal
        
        estimatedGainBoostDB = max(0.0, trim + totalBoost)
    }

    private func configureBands() {
        // Band 0: HPF
        mainEQ.bands[0].filterType = .highPass
        mainEQ.bands[0].frequency = 30
        mainEQ.bands[0].bypass = true

        // Band 1: LF Shelf
        mainEQ.bands[1].filterType = .lowShelf
        mainEQ.bands[1].frequency = 80
        mainEQ.bands[1].bandwidth = 0.82
        mainEQ.bands[1].gain = 0
        mainEQ.bands[1].bypass = false

        // Band 2: LMF Parametric
        mainEQ.bands[2].filterType = .parametric
        mainEQ.bands[2].frequency = 420
        mainEQ.bands[2].bandwidth = 1.25
        mainEQ.bands[2].gain = 0
        mainEQ.bands[2].bypass = false

        // Band 3: HMF Parametric
        mainEQ.bands[3].filterType = .parametric
        mainEQ.bands[3].frequency = 2_700
        mainEQ.bands[3].bandwidth = 1.15
        mainEQ.bands[3].gain = 0
        mainEQ.bands[3].bypass = false

        // Band 4: HF Shelf
        mainEQ.bands[4].filterType = .highShelf
        mainEQ.bands[4].frequency = 9_500
        mainEQ.bands[4].bandwidth = 0.72
        mainEQ.bands[4].gain = 0
        mainEQ.bands[4].bypass = false
    }

    private func musicalBipolarGain(_ value: Double?, maxBoost: Double, maxCut: Double) -> Double {
        musicalBipolarGain(clamped(value, defaultValue: 0.5), maxBoost: maxBoost, maxCut: maxCut)
    }

    private func musicalBipolarGain(_ value: Double, maxBoost: Double, maxCut: Double) -> Double {
        let centered = value * 2.0 - 1.0
        guard abs(centered) > 0.002 else { return 0.0 }
        let shaped = pow(abs(centered), 1.45)
        return centered > 0 ? shaped * maxBoost : -shaped * maxCut
    }

    private func musicalBellBandwidth(control: Double, isFocused: Bool, gainDB: Double) -> Float {
        if isFocused {
            return Float(0.30 + control * 0.42)
        }

        let base = 1.65 - control * 0.72
        let boostWidening = max(0.0, gainDB) * 0.025
        let cutNarrowing = max(0.0, -gainDB) * 0.018
        return Float(min(1.85, max(0.72, base + boostWidening - cutNarrowing)))
    }

    private func clamped(_ value: Double?, defaultValue: Double) -> Double {
        return min(max(value ?? defaultValue, 0.0), 1.0)
    }
}

