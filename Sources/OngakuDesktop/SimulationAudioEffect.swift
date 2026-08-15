//
//  SimulationAudioEffect.swift
//  audio
//
//  2026/04/08.
//
//  EN: Cabinet and waveguide simulation with added wet/glossy texture.
//  JA: キャビネットおよびウェーブガイドのシミュレーション（ウェットで艶のある質感を追加）。
//

import AVFoundation

final class SimulationAudioEffect: AudioEffectNode {
    let kind: RealtimeAudioEffectKind = .simulation
    private(set) var isEnabled: Bool = false

    private let contourEQ = AVAudioUnitEQ(numberOfBands: 8)
    private let waveguideDelay = AVAudioUnitDelay()
    private let cabinetEQ = AVAudioUnitEQ(numberOfBands: 7)
    
    // --- 追加: 艶出しのためのダブリングノード ---
    // EN: Doubling delay for glossy texture
    // JA: 艶の質感を出すためのダブリング用ディレイ
    private let glossDoubler = AVAudioUnitDelay()
    private let roomReverb = AVAudioUnitReverb()
    private let dryMixer = AVAudioMixerNode()
    private let wetMixer = AVAudioMixerNode()
    private let outputMixer = AVAudioMixerNode()

    // Nodes配列に glossDoubler を追加
    var nodes: [AVAudioNode] { [dryMixer, wetMixer, outputMixer, contourEQ, waveguideDelay, cabinetEQ, glossDoubler, roomReverb] }
    var inputNode: AVAudioNode { contourEQ }
    var outputNode: AVAudioNode { outputMixer }

    private(set) var estimatedGainBoostDB: Double = 0.0

    func attach(to engine: AVAudioEngine) {
        for node in nodes {
            engine.attach(node)
        }

        configureContourEQ()
        configureCabinetEQ()

        waveguideDelay.delayTime = 0.009
        waveguideDelay.feedback = 0
        waveguideDelay.lowPassCutoff = 1_050
        waveguideDelay.wetDryMix = 0
        
        // --- 追加: ダブラーの初期設定（滑らかな厚みの付加） ---
        // EN: Haas effect doubling. 24ms delay adds thickness without audible echo.
        // JA: ハース効果によるダブリング。24msの遅延でエコーを感じさせずに厚みを追加。
        glossDoubler.delayTime = 0.024
        glossDoubler.feedback = 0.0
        glossDoubler.lowPassCutoff = 8_500 // Sizzlyな高域をカットし、滑らかさを保つ
        glossDoubler.wetDryMix = 0

        // --- 修正: 艶（Sheen）に特化するため、初期プリセットを Plate に変更 ---
        roomReverb.loadFactoryPreset(.plate)
        dryMixer.outputVolume = 1
        wetMixer.outputVolume = 0
        outputMixer.outputVolume = 1

        contourEQ.bypass = true
        waveguideDelay.bypass = true
        cabinetEQ.bypass = true
        glossDoubler.bypass = true
        roomReverb.bypass = true
    }

    func connectInternalNodes(engine: AVAudioEngine, format: AVAudioFormat?) {
        engine.connect(contourEQ, to: waveguideDelay, format: format)
        engine.connect(waveguideDelay, to: cabinetEQ, format: format)
        // --- 修正: Cabinet出力の直後にDoublerを挟む ---
        engine.connect(cabinetEQ, to: [
            AVAudioConnectionPoint(node: dryMixer, bus: 0),
            AVAudioConnectionPoint(node: glossDoubler, bus: 0)
        ], fromBus: 0, format: format)
        engine.connect(dryMixer, to: outputMixer, fromBus: 0, toBus: 0, format: format)
        engine.connect(glossDoubler, to: roomReverb, format: format)
        engine.connect(roomReverb, to: wetMixer, format: format)
        engine.connect(wetMixer, to: outputMixer, fromBus: 0, toBus: 1, format: format)
    }

    func detach(from engine: AVAudioEngine) {
        for node in nodes {
            engine.detach(node)
        }
    }

    func apply(setting: RealtimeAudioEffectSetting) {
        let intensity = clamped(setting.parameters["intensity"], defaultValue: 0.75)
        let bass = clamped(setting.parameters["bass"], defaultValue: 0.75)
        let spatial = clamped(setting.parameters["spatial"], defaultValue: 0.50)
        let loudness = clamped(setting.parameters["loudness"], defaultValue: 0.60)
        let cabinetResonance = clamped(setting.parameters["cabinetResonance"], defaultValue: 0.42)
        let hardness = clamped(setting.parameters["materialHardness"], defaultValue: 0.50)
        let metallic = clamped(setting.parameters["materialMetallic"], defaultValue: 0.50)

        let intensityCurve = pow(intensity, 0.90)
        let bassCurve = pow(bass, 0.78)
        let spatialCurve = pow(spatial, 0.82)
        let loudnessCurve = pow(loudness, 0.84)
        let cabinetResonanceCurve = pow(cabinetResonance, 0.62)
        let hardnessCurve = pow(hardness, 0.85) // 0.5 center, higher = hard attack
        let metallicCurve = pow(metallic, 0.90) // 0.5 center, higher = metallic resonance

        isEnabled = setting.isEnabled && intensity > 0.001

        guard isEnabled else {
            contourEQ.bypass = true
            waveguideDelay.bypass = true
            cabinetEQ.bypass = true
            glossDoubler.bypass = true
            roomReverb.bypass = true
            dryMixer.outputVolume = 1
            wetMixer.outputVolume = 0

            contourEQ.globalGain = 0
            cabinetEQ.globalGain = 0
            waveguideDelay.wetDryMix = 0
            waveguideDelay.feedback = 0
            glossDoubler.wetDryMix = 100
            roomReverb.wetDryMix = 100
            estimatedGainBoostDB = 0.0
            return
        }

        let sampleRate = contourEQ.inputFormat(forBus: 0).sampleRate
        let isSampleRateSafe = sampleRate > 0 && sampleRate <= 96_000

        contourEQ.bypass = false
        waveguideDelay.bypass = !isSampleRateSafe
        cabinetEQ.bypass = false
        glossDoubler.bypass = !isSampleRateSafe
        roomReverb.bypass = !isSampleRateSafe

        // Stage 1: broad waveguide contour.
        contourEQ.globalGain = -Float((0.85 + bassCurve * 2.3 + loudnessCurve * 1.8 + hardnessCurve * 0.45) * intensityCurve)

        contourEQ.bands[0].gain = Float((1.2 + bassCurve * 11.6) * intensityCurve)
        contourEQ.bands[1].gain = Float((0.8 + bassCurve * 8.4) * intensityCurve)
        contourEQ.bands[2].gain = Float((0.5 + bassCurve * 5.4 + loudnessCurve * 1.0) * intensityCurve)
        
        let presenceOffset = (hardness - 0.5) * 13.0
        // --- 修正: 耳障りにならないよう、Brillianceの上がり幅を少し抑える ---
        let brillianceOffset = (hardness - 0.4) * 7.5 
        
        contourEQ.bands[3].gain = -Float((0.45 + loudnessCurve * 2.1) * intensityCurve)
        contourEQ.bands[4].gain = -Float((0.35 + loudnessCurve * 1.8) * intensityCurve)
        contourEQ.bands[5].gain = Float((0.9 + loudnessCurve * 3.6 + presenceOffset) * intensityCurve)
        contourEQ.bands[6].gain = Float((0.4 + loudnessCurve * 2.0 + brillianceOffset) * intensityCurve)
        contourEQ.bands[7].gain = Float((-0.3 - loudnessCurve * 1.4 + (hardness - 0.5) * 7.0) * intensityCurve)

        // Stage 2: very short low-passed delay (Waveguide Simulation).
        if isSampleRateSafe {
            let metallicDelayBase = 0.0015 + (1.0 - metallicCurve) * 0.0085
            waveguideDelay.delayTime = TimeInterval(metallicDelayBase + spatialCurve * 0.011 + bassCurve * 0.03)
            waveguideDelay.lowPassCutoff = Float(650 + bassCurve * 1300 + loudnessCurve * 300 + metallicCurve * 4_500)
            
            let feedbackBase = (1.5 + spatialCurve * 10.0 + bassCurve * 5.0)
            waveguideDelay.feedback = Float((feedbackBase + metallicCurve * 70.0) * intensityCurve)
            
            let wetBase = (4.0 + bassCurve * 20.0 + spatialCurve * 16.0)
            waveguideDelay.wetDryMix = Float((wetBase + metallicCurve * 30.0) * intensityCurve)
        } else {
            waveguideDelay.wetDryMix = 0
            waveguideDelay.feedback = 0
        }

        // Stage 3: cabinet mouth / enclosure resonances.
        let mouthShift = Float(bass * 42.0)
        cabinetEQ.globalGain = -Float((0.16 + bassCurve * 0.90 + spatialCurve * 0.44 + cabinetResonanceCurve * 0.68 + metallicCurve * 0.25) * intensityCurve)
        
        let resonanceQ = Float(0.85 + metallicCurve * 2.8)
        for i in 0...5 { cabinetEQ.bands[i].bandwidth = 1.0 / resonanceQ }

        cabinetEQ.bands[0].frequency = 118.0 + mouthShift
        cabinetEQ.bands[1].frequency = 215.0 + mouthShift * 1.1
        cabinetEQ.bands[2].frequency = 285.0 + Float(cabinetResonance * 150.0)
        cabinetEQ.bands[3].frequency = 420.0 + Float(spatial * 100.0 + cabinetResonance * 110.0)
        cabinetEQ.bands[4].frequency = 1_700.0 + Float(loudness * 1000.0 + hardness * 300.0)
        cabinetEQ.bands[5].frequency = 2_350.0 + Float(cabinetResonance * 520.0 + metallicCurve * 800.0)
        cabinetEQ.bands[6].frequency = 5_400.0 + Float(loudness * 2200.0 + hardness * 1_200.0)

        cabinetEQ.bands[0].gain = Float((0.7 + bassCurve * 5.2) * intensityCurve)
        cabinetEQ.bands[1].gain = Float((0.5 + bassCurve * 3.6) * intensityCurve)
        cabinetEQ.bands[2].gain = Float((0.35 + cabinetResonanceCurve * 7.2 + bassCurve * 0.9) * intensityCurve)
        cabinetEQ.bands[3].gain = Float((0.08 + cabinetResonanceCurve * 3.6) * intensityCurve)
        
        let hardnessBoost = (hardness - 0.5) * 10.4
        cabinetEQ.bands[4].gain = Float((0.8 + loudnessCurve * 2.9 + hardnessBoost) * intensityCurve)
        cabinetEQ.bands[5].gain = Float((0.18 + cabinetResonanceCurve * 3.1 + metallicCurve * 8.4) * intensityCurve)
        // --- 修正: 金属的なピークを和らげ、艶を際立たせるために高域のカット量を微増 ---
        cabinetEQ.bands[6].gain = -Float((0.30 + loudnessCurve * 1.4 + cabinetResonanceCurve * 0.24 - hardnessBoost * 0.4) * intensityCurve)

        // Stage 4: Add Gloss and Spatial Sheen.
        if isSampleRateSafe {
            // EN: Apply doubling mix based on spatial width parameter.
            // JA: 空間の広がり（Spatial）に比例して、ダブリングのウェット感を付加
            glossDoubler.wetDryMix = 100
            
            // EN: Plate reverb mix. Fixed to Plate preset for constant sheen.
            // JA: 原本の動的プリセット切り替えを廃止し、艶出し特化のPlateに固定。ミックス量を増強。
            roomReverb.wetDryMix = 100
            wetMixer.outputVolume = min(0.18, Float((spatialCurve * 0.12 + metallicCurve * 0.04 + 0.04) * intensityCurve))
        } else {
            glossDoubler.wetDryMix = 100
            roomReverb.wetDryMix = 100
            wetMixer.outputVolume = 0
        }

        dryMixer.outputVolume = 1
        let hasWetSignal = isSampleRateSafe && wetMixer.outputVolume > 0.0001
        glossDoubler.bypass = !hasWetSignal
        roomReverb.bypass = !hasWetSignal

        estimatedGainBoostDB = intensityCurve * (bassCurve * 2.4 + spatialCurve * 1.1 + loudnessCurve * 1.0 + cabinetResonanceCurve * 1.45 + hardnessCurve * 0.8 + metallicCurve * 1.2)
    }

    private func configureContourEQ() {
        let subBass = contourEQ.bands[0]
        subBass.filterType = .lowShelf
        subBass.frequency = 42
        subBass.bandwidth = 0.62
        subBass.bypass = false

        let bass = contourEQ.bands[1]
        bass.filterType = .parametric
        bass.frequency = 96
        bass.bandwidth = 0.95
        bass.bypass = false

        let upperBass = contourEQ.bands[2]
        upperBass.filterType = .parametric
        upperBass.frequency = 185
        upperBass.bandwidth = 1.15
        upperBass.bypass = false

        let lowMid = contourEQ.bands[3]
        lowMid.filterType = .parametric
        lowMid.frequency = 430
        lowMid.bandwidth = 1.35
        lowMid.bypass = false

        let mid = contourEQ.bands[4]
        mid.filterType = .parametric
        mid.frequency = 1_350
        mid.bandwidth = 1.8
        mid.bypass = false

        let presence = contourEQ.bands[5]
        presence.filterType = .parametric
        presence.frequency = 3_200
        presence.bandwidth = 1.15
        presence.bypass = false

        let brilliance = contourEQ.bands[6]
        brilliance.filterType = .parametric
        brilliance.frequency = 7_200
        brilliance.bandwidth = 1.0
        brilliance.bypass = false

        let air = contourEQ.bands[7]
        air.filterType = .highShelf
        air.frequency = 11_500
        air.bandwidth = 0.85
        air.bypass = false
    }

    private func configureCabinetEQ() {
        let mouthResonance = cabinetEQ.bands[0]
        mouthResonance.filterType = .parametric
        mouthResonance.frequency = 132
        mouthResonance.bandwidth = 0.85
        mouthResonance.bypass = false

        let tubeResonance = cabinetEQ.bands[1]
        tubeResonance.filterType = .parametric
        tubeResonance.frequency = 232
        tubeResonance.bandwidth = 0.92
        tubeResonance.bypass = false

        let cabinetBloom = cabinetEQ.bands[2]
        cabinetBloom.filterType = .parametric
        cabinetBloom.frequency = 320
        cabinetBloom.bandwidth = 0.78
        cabinetBloom.bypass = false

        let boxDip = cabinetEQ.bands[3]
        boxDip.filterType = .parametric
        boxDip.frequency = 445
        boxDip.bandwidth = 1.05
        boxDip.bypass = false

        let articulation = cabinetEQ.bands[4]
        articulation.filterType = .parametric
        articulation.frequency = 1_950
        articulation.bandwidth = 1.1
        articulation.bypass = false

        let cabinetKnock = cabinetEQ.bands[5]
        cabinetKnock.filterType = .parametric
        cabinetKnock.frequency = 2_450
        cabinetKnock.bandwidth = 1.2
        cabinetKnock.bypass = false

        let edgeSoftener = cabinetEQ.bands[6]
        edgeSoftener.filterType = .highShelf
        edgeSoftener.frequency = 5_900
        edgeSoftener.bandwidth = 0.9
        edgeSoftener.bypass = false
    }

    private func clamped(_ value: Double?, defaultValue: Double) -> Double {
        min(max(value ?? defaultValue, 0.0), 1.0)
    }
}

