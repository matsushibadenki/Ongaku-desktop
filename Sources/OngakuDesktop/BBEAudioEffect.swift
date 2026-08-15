//
//  /Users/Shared/Program/Xcode/Ongaku/audio/effects/BBEAudioEffect.swift
//  BBEAudioEffect.swift
//
//  EN: BBE Sonic Maximizer simulation with dynamic glossy sheen and wet texture.
//  JA: BBEソニックマキシマイザーのシミュレーション（動的な艶とウェット感を付加）。
//  2026/04/08.
//

import AVFoundation

final class BBEAudioEffect: AudioEffectNode {
    let kind: RealtimeAudioEffectKind = .bbe
    private(set) var isEnabled: Bool = false

    // Maximizer is implemented as a restoration-style multi-band contour:
    // bass outline, low-mid cleanup, presence recovery, transient definition and air.
    private let eq = AVAudioUnitEQ(numberOfBands: 7)
    private let airContourEQ = AVAudioUnitEQ(numberOfBands: 4)
    private let focusTamerEQ = AVAudioUnitEQ(numberOfBands: 3)
    
    // --- 追加: 艶出しのための空間系ノード ---
    // EN: Nodes for adding glossy/wet texture (Radio-ready sheen)
    // JA: 艶とウェットな質感（ラジオ・レディな光沢）を付加するためのノード
    private let sheenDoubler = AVAudioUnitDelay()
    private let sheenReverb = AVAudioUnitReverb()

    private let inputSplitter = AVAudioMixerNode()
    private let dryMixer = AVAudioMixerNode()
    private let wetMixer = AVAudioMixerNode()
    private let outputMixer = AVAudioMixerNode()

    // Nodes配列に sheenDoubler と sheenReverb を追加
    var nodes: [AVAudioNode] {
        [inputSplitter, dryMixer, wetMixer, outputMixer, eq, airContourEQ, focusTamerEQ, sheenDoubler, sheenReverb]
    }
    var inputNode: AVAudioNode { inputSplitter }
    var outputNode: AVAudioNode { outputMixer }

    private(set) var estimatedGainBoostDB: Double = 0.0

    func attach(to engine: AVAudioEngine) {
        for node in nodes {
            engine.attach(node)
        }

        // --- EQ Bands Setup ---
        eq.bands[0].filterType = .lowShelf
        eq.bands[0].frequency = 82
        eq.bands[0].bandwidth = 0.82

        eq.bands[1].filterType = .parametric
        eq.bands[1].frequency = 180
        eq.bands[1].bandwidth = 0.92

        eq.bands[2].filterType = .parametric
        eq.bands[2].frequency = 430
        eq.bands[2].bandwidth = 1.05

        eq.bands[3].filterType = .parametric
        eq.bands[3].frequency = 1_650
        eq.bands[3].bandwidth = 0.95

        eq.bands[4].filterType = .parametric
        eq.bands[4].frequency = 3_400
        eq.bands[4].bandwidth = 0.80

        eq.bands[5].filterType = .parametric
        eq.bands[5].frequency = 6_000
        eq.bands[5].bandwidth = 0.78

        eq.bands[6].filterType = .highShelf
        eq.bands[6].frequency = 9_400
        eq.bands[6].bandwidth = 0.90

        airContourEQ.bands[0].filterType = .parametric
        airContourEQ.bands[1].filterType = .parametric
        airContourEQ.bands[2].filterType = .parametric
        airContourEQ.bands[3].filterType = .highShelf
        for band in airContourEQ.bands {
            band.bypass = false
        }

        focusTamerEQ.bands[0].filterType = .parametric
        focusTamerEQ.bands[1].filterType = .parametric
        focusTamerEQ.bands[2].filterType = .highShelf
        for band in focusTamerEQ.bands {
            band.bypass = false
        }
        
        // --- 追加: ダブラーの初期設定（高域の拡散） ---
        // EN: Very short delay for thickening the high frequencies
        // JA: 高域成分に厚みを持たせるための極短ディレイ（ハース効果）
        sheenDoubler.delayTime = 0.020 // 20ms
        sheenDoubler.feedback = 0.0
        sheenDoubler.lowPassCutoff = 14_000
        sheenDoubler.wetDryMix = 0
        
        // --- 追加: リバーブの初期設定（最終的な艶） ---
        // EN: Plate reverb for final gloss
        // JA: 全体の空間を保ちつつ最終的な光沢を乗せるプレートリバーブ
        sheenReverb.loadFactoryPreset(.plate)
        sheenReverb.wetDryMix = 0

        dryMixer.outputVolume = 1
        wetMixer.outputVolume = 0
        outputMixer.outputVolume = 1

        for band in eq.bands {
            band.bypass = true
        }
        eq.bypass = true
        airContourEQ.bypass = true
        focusTamerEQ.bypass = true
        sheenDoubler.bypass = true
        sheenReverb.bypass = true
    }

    func connectInternalNodes(engine: AVAudioEngine, format: AVAudioFormat?) {
        // Keep the contour path dry and blend the optional sheen path separately.
        engine.connect(inputSplitter, to: eq, format: format)
        engine.connect(
            eq,
            to: [
                AVAudioConnectionPoint(node: dryMixer, bus: 0),
                AVAudioConnectionPoint(node: airContourEQ, bus: 0)
            ],
            fromBus: 0,
            format: format
        )
        engine.connect(dryMixer, to: outputMixer, fromBus: 0, toBus: 0, format: format)
        engine.connect(airContourEQ, to: focusTamerEQ, format: format)
        engine.connect(focusTamerEQ, to: sheenDoubler, format: format)
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
        let mode = MaximizerMode.from(parameterValue: setting.parameters["mode"])
        let intensity = clamped(setting.parameters["intensity"], defaultValue: 0.80)
        let loContour = clamped(setting.parameters["loContour"], defaultValue: 0.58)
        let process = clamped(setting.parameters["process"], defaultValue: 0.62)

        let intensityCurve = pow(intensity, 0.90)
        let contourCurve = pow(loContour, 0.78)
        let processCurve = pow(process, 0.76)
        let richness = mode == .rich ? 1.0 : 0.0

        isEnabled = setting.isEnabled && intensity > 0.001

        guard isEnabled else {
            eq.bypass = true
            airContourEQ.bypass = true
            focusTamerEQ.bypass = true
            sheenDoubler.bypass = true
            sheenReverb.bypass = true
            dryMixer.outputVolume = 1
            wetMixer.outputVolume = 0
            
            eq.globalGain = 0
            for band in eq.bands {
                band.gain = 0
                band.bypass = true
            }
            airContourEQ.globalGain = 0
            for band in airContourEQ.bands {
                band.gain = 0
            }
            focusTamerEQ.globalGain = 0
            for band in focusTamerEQ.bands {
                band.gain = 0
            }
            sheenDoubler.wetDryMix = 100
            sheenReverb.wetDryMix = 100
            
            estimatedGainBoostDB = 0.0
            return
        }

        let sampleRate = eq.inputFormat(forBus: 0).sampleRate
        let isSampleRateSafe = sampleRate > 0 && sampleRate <= 96_000
        let isExtendedAirSafe = sampleRate >= 88_200 && sampleRate <= 96_000

        eq.bypass = false
        airContourEQ.bypass = !isExtendedAirSafe
        focusTamerEQ.bypass = !isSampleRateSafe
        sheenDoubler.bypass = !isSampleRateSafe
        sheenReverb.bypass = !isSampleRateSafe
        
        for band in eq.bands {
            band.bypass = false
        }

        // Shift the contour slightly with the controls so compressed masters can be
        // restored differently from already-open material.
        eq.bands[0].frequency = Float(68.0 + loContour * 72.0)
        eq.bands[1].frequency = Float(145.0 + loContour * 95.0)
        eq.bands[2].frequency = Float(320.0 + loContour * 180.0)
        eq.bands[3].frequency = Float(1_350.0 + process * 950.0)
        eq.bands[4].frequency = Float(2_900.0 + process * 2_000.0)
        eq.bands[5].frequency = Float(5_000.0 + process * 1_600.0)
        eq.bands[6].frequency = Float(8_000.0 + process * 1_800.0)

        // Low-end outline: restore punch without bloating the sub-bass.
        eq.bands[0].gain = Float((3.4 + processCurve * (1.9 + richness * 0.7)) * contourCurve * (1.9 + richness * 0.12) * intensityCurve)
        eq.bands[1].gain = Float((0.9 + contourCurve * (3.0 + richness * 0.6)) * intensityCurve)

        // Low-mid cleanup: make room between vocal fundamentals and backing instruments.
        eq.bands[2].gain = -Float((1.4 + contourCurve * (2.7 - richness * 0.35) + processCurve * (2.5 - richness * 0.25)) * intensityCurve)

        // Presence recovery: push vocals, snare edge and guitar/piano articulation forward.
        eq.bands[3].gain = Float((1.8 + contourCurve * (1.7 + richness * 0.35) + processCurve * (3.0 + richness * 0.55)) * intensityCurve)
        eq.bands[4].gain = Float((2.6 + contourCurve * (1.4 + richness * 0.45) + processCurve * (4.1 + richness * 0.85)) * intensityCurve)

        // Definition + air: separate cymbals, consonants and upper harmonics without adding harshness.
        eq.bands[5].gain = Float((1.4 + processCurve * (2.6 + richness * 0.45)) * intensityCurve)
        eq.bands[6].gain = Float((1.0 + processCurve * (2.0 + richness * 0.35)) * processCurve * intensityCurve)

        // Keep headroom while letting the tonal restoration be clearly audible.
        eq.globalGain = -Float((0.18 + contourCurve * (0.34 + richness * 0.04) + processCurve * (0.40 + richness * 0.05)) * intensityCurve)

        if isExtendedAirSafe {
            let blendCurve = smoothstep(0.26 + process * 0.56)
            let taperCurve = smoothstep(0.18 + processCurve * 0.64)

            airContourEQ.globalGain = -Float(0.08 + processCurve * (0.24 + richness * 0.04))

            airContourEQ.bands[0].frequency = 14_200
            airContourEQ.bands[0].gain = Float((1.8 + blendCurve * (1.4 + richness * 0.35)) * processCurve * intensityCurve)
            airContourEQ.bands[0].bandwidth = 1.45

            airContourEQ.bands[1].frequency = 17_600
            airContourEQ.bands[1].gain = Float((0.9 + blendCurve * (1.1 + richness * 0.24)) * processCurve * intensityCurve)
            airContourEQ.bands[1].bandwidth = 1.10

            airContourEQ.bands[2].frequency = 21_000
            airContourEQ.bands[2].gain = -Float((0.7 + taperCurve * (1.8 - richness * 0.25)) * processCurve * intensityCurve)
            airContourEQ.bands[2].bandwidth = 0.86

            airContourEQ.bands[3].frequency = 25_000
            airContourEQ.bands[3].gain = -Float((1.2 + taperCurve * (3.6 - richness * 0.55)) * processCurve * intensityCurve)
        } else {
            airContourEQ.globalGain = 0
            for band in airContourEQ.bands {
                band.gain = 0
            }
        }

        if isSampleRateSafe {
            let presenceTame = Float((0.25 + processCurve * (1.1 - richness * 0.18) + max(0.0, process - 0.55) * (1.6 - richness * 0.22)) * intensityCurve)
            let glossTame = Float((0.15 + processCurve * (0.65 - richness * 0.14)) * intensityCurve)

            focusTamerEQ.globalGain = 0
            focusTamerEQ.bands[0].frequency = Float(2_600 + process * 1_000)
            focusTamerEQ.bands[0].gain = -Float((0.18 + contourCurve * 0.55) * intensityCurve)
            focusTamerEQ.bands[0].bandwidth = 1.18

            focusTamerEQ.bands[1].frequency = Float(4_800 + process * 1_500)
            focusTamerEQ.bands[1].gain = -presenceTame
            focusTamerEQ.bands[1].bandwidth = 0.96

            focusTamerEQ.bands[2].frequency = Float(10_800 + process * 1_400)
            focusTamerEQ.bands[2].gain = -glossTame
        } else {
            focusTamerEQ.globalGain = 0
            for band in focusTamerEQ.bands {
                band.gain = 0
            }
        }
        
        // --- 修正: 動的な艶出し処理 (Dynamic Gloss & Sheen) ---
        // EN: Dynamically add plate reverb based on the 'Process' (HF Exciter) parameter.
        // JA: BBEのキモである「Process（高域エキサイター）」に連動して艶を付加。
        // 低域（Lo-Contour）のパンチ力はタイトなまま維持されます。
        if isSampleRateSafe {
            let glossIntensity = Float(processCurve * intensityCurve)
            let contourMix = Float(0.82 + contourCurve * 0.18)

            sheenDoubler.delayTime = 0.011 + process * (0.005 + richness * 0.0015)
            sheenDoubler.lowPassCutoff = Float(11_200 + process * (3_000 + richness * 1_200))
            sheenDoubler.wetDryMix = 100
            sheenReverb.wetDryMix = 100
            let doublerAmount = glossIntensity * contourMix * Float(0.11 + richness * 0.025)
            let reverbAmount = glossIntensity * max(0.0, Float(process - 0.22)) * Float(0.06 + richness * 0.025)
            wetMixer.outputVolume = min(0.16, doublerAmount + reverbAmount)
        } else {
            sheenDoubler.wetDryMix = 100
            sheenReverb.wetDryMix = 100
            wetMixer.outputVolume = 0
        }

        dryMixer.outputVolume = 1
        let hasWetSignal = isSampleRateSafe && wetMixer.outputVolume > 0.0001
        sheenDoubler.bypass = !hasWetSignal
        sheenReverb.bypass = !hasWetSignal

        estimatedGainBoostDB = intensityCurve * (contourCurve * (2.0 + richness * 0.2) + processCurve * (2.3 + richness * 0.35))
    }

    private func clamped(_ value: Double?, defaultValue: Double) -> Double {
        min(max(value ?? defaultValue, 0.0), 1.0)
    }

    private func smoothstep(_ value: Double) -> Double {
        let x = min(max(value, 0.0), 1.0)
        return x * x * (3.0 - 2.0 * x)
    }
}

