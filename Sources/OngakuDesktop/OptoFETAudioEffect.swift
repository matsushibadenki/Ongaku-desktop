//
//  OptoFETAudioEffect.swift
//  audio
//
//  Vocals-focused serial compression: fast FET-like peak control + smooth opto leveling.
//

import AVFoundation

final class OptoFETAudioEffect: AudioEffectNode {
    let kind: RealtimeAudioEffectKind = .optoFET
    private(set) var isEnabled: Bool = false

    private let inputToneEQ = AVAudioUnitEQ(numberOfBands: 2)
    private let fetCompressor: AVAudioUnitEffect
    private let optoCompressor: AVAudioUnitEffect
    private let outputToneEQ = AVAudioUnitEQ(numberOfBands: 2)

    var nodes: [AVAudioNode] { [inputToneEQ, fetCompressor, optoCompressor, outputToneEQ] }
    var inputNode: AVAudioNode { inputToneEQ }
    var outputNode: AVAudioNode { outputToneEQ }

    private(set) var estimatedGainBoostDB: Double = 0.0

    init() {
        self.fetCompressor = Self.makeDynamicsProcessorUnit()
        self.optoCompressor = Self.makeDynamicsProcessorUnit()
    }

    func attach(to engine: AVAudioEngine) {
        for node in nodes {
            engine.attach(node)
        }

        inputToneEQ.bands[0].filterType = .highPass
        inputToneEQ.bands[0].frequency = 90
        inputToneEQ.bands[0].bandwidth = 0.75
        inputToneEQ.bands[0].gain = 0
        inputToneEQ.bands[0].bypass = false

        inputToneEQ.bands[1].filterType = .parametric
        inputToneEQ.bands[1].frequency = 3800
        inputToneEQ.bands[1].bandwidth = 1.0
        inputToneEQ.bands[1].gain = 0
        inputToneEQ.bands[1].bypass = false

        outputToneEQ.bands[0].filterType = .lowShelf
        outputToneEQ.bands[0].frequency = 220
        outputToneEQ.bands[0].bandwidth = 0.9
        outputToneEQ.bands[0].gain = 0
        outputToneEQ.bands[0].bypass = false

        outputToneEQ.bands[1].filterType = .highShelf
        outputToneEQ.bands[1].frequency = 8200
        outputToneEQ.bands[1].bandwidth = 0.75
        outputToneEQ.bands[1].gain = 0
        outputToneEQ.bands[1].bypass = false

        inputToneEQ.bypass = true
        fetCompressor.bypass = true
        optoCompressor.bypass = true
        outputToneEQ.bypass = true

        resetDynamicsUnit(fetCompressor)
        resetDynamicsUnit(optoCompressor)
    }

    func connectInternalNodes(engine: AVAudioEngine, format: AVAudioFormat?) {
        engine.connect(inputToneEQ, to: fetCompressor, format: format)
        engine.connect(fetCompressor, to: optoCompressor, format: format)
        engine.connect(optoCompressor, to: outputToneEQ, format: format)
    }

    func detach(from engine: AVAudioEngine) {
        for node in nodes {
            engine.detach(node)
        }
    }

    func apply(setting: RealtimeAudioEffectSetting) {
        let intensity = clamped(setting.parameters["intensity"], defaultValue: 0.70)
        let peak = clamped(setting.parameters["peak"], defaultValue: 0.52)
        let level = clamped(setting.parameters["level"], defaultValue: 0.50)

        let intensityCurve = pow(intensity, 0.90)
        let peakCurve = pow(peak, 0.78)
        let signedLevel = (level - 0.5) * 2.0

        isEnabled = setting.isEnabled && intensity > 0.001

        guard isEnabled else {
            inputToneEQ.bypass = true
            fetCompressor.bypass = true
            optoCompressor.bypass = true
            outputToneEQ.bypass = true

            inputToneEQ.globalGain = 0
            inputToneEQ.bands[1].gain = 0
            outputToneEQ.globalGain = 0
            outputToneEQ.bands[0].gain = 0
            outputToneEQ.bands[1].gain = 0
            resetDynamicsUnit(fetCompressor)
            resetDynamicsUnit(optoCompressor)
            estimatedGainBoostDB = 0
            return
        }

        inputToneEQ.bypass = false
        fetCompressor.bypass = false
        optoCompressor.bypass = false
        outputToneEQ.bypass = false

        let fetThreshold = -19.5 + (1.0 - intensityCurve) * 10.0 - peakCurve * 2.2
        let fetHeadroom = 3.8 + (1.0 - peakCurve) * 4.2
        let fetAttackMs = 2.4 + (1.0 - peakCurve) * 5.6
        let fetReleaseMs = 55.0 + (1.0 - intensityCurve) * 110.0

        let optoThreshold = -21.5 + (1.0 - intensityCurve) * 8.8
        let optoHeadroom = 8.5 + (1.0 - intensityCurve) * 5.2
        let optoAttackMs = 32.0 + (1.0 - peakCurve) * 28.0
        let optoReleaseMs = 240.0 + (1.0 - peakCurve) * 320.0

        let density = intensityCurve * 0.68 + peakCurve * 0.24
        let makeUp = density * 1.15
        let fetGain = makeUp * 0.35
        let optoGain = makeUp * 0.45

        setDynamics(
            fetCompressor,
            thresholdDB: Float(fetThreshold),
            headroomDB: Float(fetHeadroom),
            attackMs: Float(fetAttackMs),
            releaseMs: Float(fetReleaseMs),
            masterGainDB: Float(fetGain)
        )

        setDynamics(
            optoCompressor,
            thresholdDB: Float(optoThreshold),
            headroomDB: Float(optoHeadroom),
            attackMs: Float(optoAttackMs),
            releaseMs: Float(optoReleaseMs),
            masterGainDB: Float(optoGain)
        )

        inputToneEQ.bands[1].gain = Float((0.8 + peakCurve * 1.6) * intensityCurve)
        inputToneEQ.globalGain = -Float(0.18 + intensityCurve * 0.48)

        outputToneEQ.bands[0].gain = Float(-0.6 * intensityCurve)
        outputToneEQ.bands[1].gain = Float((0.6 + peakCurve * 1.2) * intensityCurve)
        outputToneEQ.globalGain = Float(signedLevel * 4.0)

        estimatedGainBoostDB = makeUp * 0.8 + signedLevel * 2.2
    }

    private static func makeDynamicsProcessorUnit() -> AVAudioUnitEffect {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard AudioComponentFindNext(nil, &desc) != nil else {
            let limiterDesc = AudioComponentDescription(
                componentType: kAudioUnitType_Effect,
                componentSubType: kAudioUnitSubType_PeakLimiter,
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0,
                componentFlagsMask: 0
            )
            return AVAudioUnitEffect(audioComponentDescription: limiterDesc)
        }
        return AVAudioUnitEffect(audioComponentDescription: desc)
    }

    private func resetDynamicsUnit(_ unit: AVAudioUnitEffect) {
        setDynamics(
            unit,
            thresholdDB: -20,
            headroomDB: 8,
            attackMs: 20,
            releaseMs: 200,
            masterGainDB: 0
        )
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

    private func clamped(_ value: Double?, defaultValue: Double) -> Double {
        min(max(value ?? defaultValue, 0.0), 1.0)
    }
}

