//
//  ExciterAudioEffect.swift
//  audio
//
//  2026/04/08.
//

import AVFoundation

final class ExciterAudioEffect: AudioEffectNode {
    let kind: RealtimeAudioEffectKind = .exciter
    private(set) var isEnabled: Bool = false
    
    private let inputSplitter = AVAudioMixerNode()
    private let dryMixer = AVAudioMixerNode()
    private let harmonicMixer = AVAudioMixerNode()
    private let outputMixer = AVAudioMixerNode()
    private let harmonicBandEQ = AVAudioUnitEQ(numberOfBands: 2)
    private let exciterEQ = AVAudioUnitEQ(numberOfBands: 5)
    private let exciterDistortion = AVAudioUnitDistortion()
    private lazy var deEsserCompressor: AVAudioUnitEffect = Self.makeDynamicsProcessorUnit()
    private let deEsserEQ = AVAudioUnitEQ(numberOfBands: 2)
    private let airContourEQ = AVAudioUnitEQ(numberOfBands: 4)
    
    private var lastExciterDistPreset: Int = -1
    
    var nodes: [AVAudioNode] {
        [inputSplitter, dryMixer, harmonicMixer, outputMixer, harmonicBandEQ, exciterEQ, exciterDistortion, deEsserCompressor, deEsserEQ, airContourEQ]
    }
    var inputNode: AVAudioNode { inputSplitter }
    var outputNode: AVAudioNode { outputMixer }
    
    private(set) var estimatedGainBoostDB: Double = 0.0

    func attach(to engine: AVAudioEngine) {
        for node in nodes {
            engine.attach(node)
        }

        harmonicBandEQ.bands[0].filterType = .highPass
        harmonicBandEQ.bands[0].frequency = 2_800
        harmonicBandEQ.bands[0].bandwidth = 0.70
        harmonicBandEQ.bands[0].bypass = false
        harmonicBandEQ.bands[1].filterType = .lowPass
        harmonicBandEQ.bands[1].frequency = 18_000
        harmonicBandEQ.bands[1].bandwidth = 0.70
        harmonicBandEQ.bands[1].bypass = false
        dryMixer.outputVolume = 1.0
        harmonicMixer.outputVolume = 0.0
        outputMixer.outputVolume = 1.0
        
        // --- Exciter EQ ---
        exciterEQ.bands[0].filterType = .parametric; exciterEQ.bypass = false
        exciterEQ.bands[1].filterType = .parametric; exciterEQ.bypass = false
        exciterEQ.bands[2].filterType = .parametric; exciterEQ.bypass = false
        exciterEQ.bands[3].filterType = .parametric; exciterEQ.bypass = false
        exciterEQ.bands[4].filterType = .highShelf;  exciterEQ.bypass = false

        deEsserEQ.bands[0].filterType = .parametric
        deEsserEQ.bands[1].filterType = .highShelf
        for band in deEsserEQ.bands {
            band.bypass = false
        }

        airContourEQ.bands[0].filterType = .parametric
        airContourEQ.bands[1].filterType = .parametric
        airContourEQ.bands[2].filterType = .parametric
        airContourEQ.bands[3].filterType = .highShelf
        for band in airContourEQ.bands {
            band.bypass = false
        }
        
        lastExciterDistPreset = 11
        exciterDistortion.loadFactoryPreset(.multiDistortedSquared)
        
        exciterEQ.bypass = true
        exciterDistortion.bypass = true
        deEsserCompressor.bypass = true
        deEsserEQ.bypass = true
        airContourEQ.bypass = true
    }
    
    func connectInternalNodes(engine: AVAudioEngine, format: AVAudioFormat?) {
        let splitPoints = [
            AVAudioConnectionPoint(node: dryMixer, bus: 0),
            AVAudioConnectionPoint(node: harmonicBandEQ, bus: 0)
        ]
        engine.connect(inputSplitter, to: splitPoints, fromBus: 0, format: format)
        engine.connect(dryMixer, to: outputMixer, fromBus: 0, toBus: 0, format: format)
        engine.connect(harmonicBandEQ, to: exciterEQ, format: format)
        engine.connect(exciterEQ, to: exciterDistortion, format: format)
        engine.connect(exciterDistortion, to: deEsserCompressor, format: format)
        engine.connect(deEsserCompressor, to: deEsserEQ, format: format)
        engine.connect(deEsserEQ, to: airContourEQ, format: format)
        engine.connect(airContourEQ, to: harmonicMixer, format: format)
        engine.connect(harmonicMixer, to: outputMixer, fromBus: 0, toBus: 1, format: format)
    }
    
    func detach(from engine: AVAudioEngine) {
        for node in nodes {
            engine.detach(node)
        }
    }
    
    func apply(setting: RealtimeAudioEffectSetting) {
        let mode = ExciterMode.from(parameterValue: setting.parameters["mode"])
        let openTone = ExciterOpenTone.from(parameterValue: setting.parameters["openTone"])
        let intensity = clamped(setting.parameters["intensity"], defaultValue: 0.45)
        let frequency = clamped(setting.parameters["frequency"], defaultValue: 0.58)
        let effectiveIntensity = pow(intensity, mode == .smooth ? 1.08 : 0.92)
        
        isEnabled = setting.isEnabled && intensity > 0.001
        
        guard isEnabled else {
            dryMixer.outputVolume = 1.0
            outputMixer.outputVolume = 1.0
            harmonicMixer.outputVolume = 0.0
            exciterEQ.bypass = true
            exciterDistortion.bypass = true
            deEsserCompressor.bypass = true
            deEsserEQ.bypass = true
            airContourEQ.bypass = true
            exciterEQ.globalGain = 0
            exciterEQ.bands[0].gain = 0
            exciterEQ.bands[1].gain = 0
            exciterEQ.bands[2].gain = 0
            exciterEQ.bands[3].gain = 0
            exciterEQ.bands[4].gain = 0
            airContourEQ.globalGain = 0
            for band in airContourEQ.bands {
                band.gain = 0
            }
            deEsserEQ.globalGain = 0
            for band in deEsserEQ.bands {
                band.gain = 0
            }
            exciterDistortion.preGain = -6
            exciterDistortion.wetDryMix = 0
            estimatedGainBoostDB = 0.0
            return
        }

        let sampleRate = exciterEQ.inputFormat(forBus: 0).sampleRate
        let isExtendedAirSafe = sampleRate >= 88_200 && sampleRate <= 96_000
        let blendCurve = smoothstep((mode == .smooth ? 0.24 : 0.38) + frequency * (mode == .smooth ? 0.40 : 0.54))
        let contourCurve = smoothstep((mode == .smooth ? 0.18 : 0.28) + effectiveIntensity * (mode == .smooth ? 0.52 : 0.66))
        let openness = mode == .smooth ? 0.0 : 1.0
        let openBrightness = (mode == .open && openTone == .bright) ? 1.0 : 0.0

        exciterEQ.bypass = false
        exciterDistortion.bypass = false
        deEsserCompressor.bypass = mode != .open
        deEsserEQ.bypass = mode != .open
        airContourEQ.bypass = !isExtendedAirSafe
        exciterEQ.globalGain = -Float((0.82 + effectiveIntensity * (0.92 + openness * 0.20)) * max(0.40, frequency))

        let focusFrequency = 2200 + frequency * (1500 + openness * 260)
        harmonicBandEQ.bands[0].frequency = Float(max(1_800.0, focusFrequency * 0.82))
        harmonicBandEQ.bands[1].frequency = Float(min(20_000.0, max(12_000.0, 17_500.0 + openBrightness * 1_500.0)))
        harmonicBandEQ.bands[0].bypass = false
        harmonicBandEQ.bands[1].bypass = false
        dryMixer.outputVolume = 1.0
        // The wet branch contains only the generated high-frequency material.
        // Keep it conservative and let the output safety stage handle residual peaks.
        harmonicMixer.outputVolume = Float(min(0.42, 0.08 + effectiveIntensity * (0.20 + openness * 0.14)))
        exciterEQ.bands[0].frequency = Float(focusFrequency)
        exciterEQ.bands[0].gain = Float(effectiveIntensity * (2.9 + openness * 0.5))
        exciterEQ.bands[0].bandwidth = Float(1.32 - openness * 0.08)

        exciterEQ.bands[1].frequency = Float(3600 + frequency * (1300 + openness * 260))
        exciterEQ.bands[1].gain = Float(effectiveIntensity * (3.7 + openness * 0.8))
        exciterEQ.bands[1].bandwidth = Float(1.36 - openness * 0.10)

        exciterEQ.bands[2].frequency = Float(6600 + frequency * (1200 + openness * (620 + openBrightness * 110)))
        exciterEQ.bands[2].gain = Float(effectiveIntensity * (4.0 + openness * (1.35 + openBrightness * 0.20)))
        exciterEQ.bands[2].bandwidth = Float(1.24 - openness * (0.16 + openBrightness * 0.02))

        exciterEQ.bands[3].frequency = Float(11_800 + frequency * (1800 + openness * (1_050 + openBrightness * 190)))
        exciterEQ.bands[3].gain = Float(effectiveIntensity * (2.1 + frequency * (1.9 + openness * (1.45 + openBrightness * 0.30))))
        exciterEQ.bands[3].bandwidth = Float(1.62 - openness * (0.28 + openBrightness * 0.04))

        exciterEQ.bands[4].frequency = Float(14_400 + frequency * (1200 + openness * (1_020 + openBrightness * 240)))
        exciterEQ.bands[4].gain = Float(effectiveIntensity * (1.1 + frequency * (1.0 + openness * (1.75 + openBrightness * 0.34))))

        if lastExciterDistPreset != 11 {
            lastExciterDistPreset = 11
            exciterDistortion.loadFactoryPreset(.multiDistortedSquared)
        }
        exciterDistortion.preGain = Float(-15 + openness * (3.2 + openBrightness * 0.35))
        exciterDistortion.wetDryMix = 100.0

        if mode == .open {
            let deEssAmount = Float((0.55 + frequency * 0.35 + effectiveIntensity * 0.55) * (1.0 - openBrightness * 0.28) * openness)
            setDynamics(
                deEsserCompressor,
                thresholdDB: Float(-26.0 + frequency * 4.0),
                headroomDB: Float(5.0 + (1.0 - effectiveIntensity) * 3.0),
                attackMs: Float(0.35 + (1.0 - frequency) * 1.2),
                releaseMs: Float(70.0 + (1.0 - effectiveIntensity) * 90.0),
                masterGainDB: 0
            )
            deEsserEQ.globalGain = 0
            deEsserEQ.bands[0].frequency = Float(6_400 + frequency * 1_500)
            deEsserEQ.bands[0].gain = -deEssAmount * 0.32
            deEsserEQ.bands[0].bandwidth = Float(0.92 - openBrightness * 0.06)

            deEsserEQ.bands[1].frequency = Float(10_800 + frequency * 1_400)
            deEsserEQ.bands[1].gain = -Float((0.35 + effectiveIntensity * 0.9) * (1.0 - openBrightness * 0.32)) * 0.28
        } else {
            deEsserEQ.globalGain = 0
            for band in deEsserEQ.bands {
                band.gain = 0
            }
        }

        if isExtendedAirSafe {
            airContourEQ.globalGain = -Float(0.06 + effectiveIntensity * (0.22 + openness * 0.14))

            // 14-22kHz overlaps the original air band instead of jumping above 20kHz.
            airContourEQ.bands[0].frequency = Float(13_600 + openness * (650 + openBrightness * 100))
            airContourEQ.bands[0].gain = Float((blendCurve * (1.7 + openness * (1.35 + openBrightness * 0.24)) + contourCurve * 0.34) * effectiveIntensity)
            airContourEQ.bands[0].bandwidth = Float(1.80 - openness * (0.22 + openBrightness * 0.03))

            airContourEQ.bands[1].frequency = Float(16_800 + openness * (1_250 + openBrightness * 220))
            airContourEQ.bands[1].gain = Float((blendCurve * (1.0 + openness * (1.45 + openBrightness * 0.34)) + contourCurve * 0.36) * effectiveIntensity)
            airContourEQ.bands[1].bandwidth = Float(1.48 - openness * (0.24 + openBrightness * 0.04))

            airContourEQ.bands[2].frequency = Float(20_400 + openness * (1_500 + openBrightness * 260))
            airContourEQ.bands[2].gain = -Float((0.45 + contourCurve * (1.25 - openness * (0.36 + openBrightness * 0.08))) * effectiveIntensity)
            airContourEQ.bands[2].bandwidth = Float(1.14 - openness * (0.18 + openBrightness * 0.04))

            airContourEQ.bands[3].frequency = Float(24_000 + openness * (2_700 + openBrightness * 420))
            airContourEQ.bands[3].gain = -Float((0.9 + contourCurve * (2.6 - openness * (0.95 + openBrightness * 0.12))) * effectiveIntensity)
        } else {
            airContourEQ.globalGain = 0
            for band in airContourEQ.bands {
                band.gain = 0
            }
        }
        
        estimatedGainBoostDB = intensity * (frequency * (0.9 + openness * (0.28 + openBrightness * 0.04)) + effectiveIntensity * (1.35 + openness * (0.58 + openBrightness * 0.10)))
    }
    
    private func clamped(_ value: Double?, defaultValue: Double) -> Double {
        return min(max(value ?? defaultValue, 0.0), 1.0)
    }

    private static func makeDynamicsProcessorUnit() -> AVAudioUnitEffect {
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        return AVAudioUnitEffect(audioComponentDescription: description)
    }

    private func setDynamics(
        _ unit: AVAudioUnitEffect,
        thresholdDB: Float,
        headroomDB: Float,
        attackMs: Float,
        releaseMs: Float,
        masterGainDB: Float
    ) {
        guard let parameters = unit.auAudioUnit.parameterTree?.allParameters else { return }
        for parameter in parameters {
            let key = "\(parameter.identifier) \(parameter.displayName)".lowercased()
            if key.contains("threshold") {
                parameter.value = thresholdDB
            } else if key.contains("head") && key.contains("room") {
                parameter.value = headroomDB
            } else if key.contains("attack") {
                parameter.value = attackMs
            } else if key.contains("decay") || key.contains("release") {
                parameter.value = releaseMs
            } else if key.contains("master") && key.contains("gain") {
                parameter.value = masterGainDB
            } else if key.contains("expansion") && key.contains("ratio") {
                parameter.value = 1.0
            }
        }
    }

    private func smoothstep(_ value: Double) -> Double {
        let x = min(max(value, 0.0), 1.0)
        return x * x * (3.0 - 2.0 * x)
    }
}

