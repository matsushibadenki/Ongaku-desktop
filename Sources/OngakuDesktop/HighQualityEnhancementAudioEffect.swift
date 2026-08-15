import AVFoundation

/// Compressed-source enhancement effect.
///
/// The harmonic branch extracts upper-band material and passes it through a
/// deliberately restrained non-linear stage. This cannot recover the original
/// lost samples above Nyquist, but it synthesizes musically related upper
/// harmonics and mixes them back at a controlled level.
final class HighQualityEnhancementAudioEffect: AudioEffectNode {
    let kind: RealtimeAudioEffectKind = .highQualityEnhancement
    private(set) var isEnabled = false

    private let inputSplitter = AVAudioMixerNode()
    private let dryMixer = AVAudioMixerNode()
    private let harmonicHighPass = AVAudioUnitEQ(numberOfBands: 1)
    private let harmonicExciter = AVAudioUnitDistortion()
    private let harmonicAirEQ = AVAudioUnitEQ(numberOfBands: 2)
    private let harmonicMixer = AVAudioMixerNode()
    private let outputMixer = AVAudioMixerNode()
    private let contourEQ = AVAudioUnitEQ(numberOfBands: 8)
    private let cabinetEQ = AVAudioUnitEQ(numberOfBands: 7)
    private let masterEQ = AVAudioUnitEQ(numberOfBands: 4)

    var nodes: [AVAudioNode] {
        [
            inputSplitter,
            dryMixer,
            harmonicHighPass,
            harmonicExciter,
            harmonicAirEQ,
            harmonicMixer,
            outputMixer,
            contourEQ,
            cabinetEQ,
            masterEQ
        ]
    }

    var inputNode: AVAudioNode { inputSplitter }
    var outputNode: AVAudioNode { masterEQ }

    private(set) var estimatedGainBoostDB: Double = 0

    func attach(to engine: AVAudioEngine) {
        for node in nodes { engine.attach(node) }

        configureContourEQ()
        configureCabinetEQ()

        harmonicHighPass.bands[0].filterType = .highPass
        harmonicHighPass.bands[0].bypass = false
        harmonicExciter.loadFactoryPreset(.multiDistortedSquared)
        harmonicAirEQ.bands[0].filterType = .highShelf
        harmonicAirEQ.bands[0].bypass = false
        harmonicAirEQ.bands[1].filterType = .parametric
        harmonicAirEQ.bands[1].bypass = false

        for band in masterEQ.bands {
            band.filterType = .parametric
            band.bypass = true
        }
        harmonicHighPass.bypass = true
        harmonicExciter.bypass = true
        harmonicAirEQ.bypass = true
        contourEQ.bypass = true
        cabinetEQ.bypass = true
        harmonicMixer.outputVolume = 0
        dryMixer.outputVolume = 1
        outputMixer.outputVolume = 1
    }

    func connectInternalNodes(engine: AVAudioEngine, format: AVAudioFormat?) {
        engine.connect(inputSplitter, to: [
            AVAudioConnectionPoint(node: dryMixer, bus: 0),
            AVAudioConnectionPoint(node: harmonicHighPass, bus: 0)
        ], fromBus: 0, format: format)
        engine.connect(harmonicHighPass, to: harmonicExciter, format: format)
        engine.connect(harmonicExciter, to: harmonicAirEQ, format: format)
        engine.connect(harmonicAirEQ, to: harmonicMixer, format: format)
        engine.connect(dryMixer, to: outputMixer, format: format)
        engine.connect(harmonicMixer, to: [
            AVAudioConnectionPoint(node: outputMixer, bus: 1)
        ], fromBus: 0, format: format)
        engine.connect(outputMixer, to: contourEQ, format: format)
        engine.connect(contourEQ, to: cabinetEQ, format: format)
        engine.connect(cabinetEQ, to: masterEQ, format: format)
    }

    func detach(from engine: AVAudioEngine) {
        for node in nodes { engine.detach(node) }
    }

    func apply(setting: RealtimeAudioEffectSetting) {
        let intensity = clamped(setting.parameters["intensity"], defaultValue: 0.68)
        let air = clamped(setting.parameters["air"], defaultValue: 0.58)
        let harmonic = clamped(setting.parameters["harmonic"], defaultValue: 0.42)
        let warmth = clamped(setting.parameters["warmth"], defaultValue: 0.46)
        
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
        let hardnessCurve = pow(hardness, 0.85)
        let metallicCurve = pow(metallic, 0.90)

        isEnabled = setting.isEnabled && intensity > 0.001
        guard isEnabled else {
            harmonicHighPass.bypass = true
            harmonicExciter.bypass = true
            harmonicAirEQ.bypass = true
            contourEQ.bypass = true
            cabinetEQ.bypass = true
            harmonicMixer.outputVolume = 0
            for band in masterEQ.bands { band.bypass = true }
            estimatedGainBoostDB = 0
            return
        }

        // 12-16 kHz content remains available in common lossy sources. The
        // non-linear stage creates related harmonics above 20 kHz at 96 kHz.
        harmonicHighPass.bands[0].frequency = Float(11_500 + air * 3_500)
        harmonicHighPass.bands[0].bandwidth = 0.75
        harmonicHighPass.bypass = false

        harmonicExciter.preGain = Float(-10 + harmonic * 6)
        harmonicExciter.wetDryMix = 100
        harmonicExciter.bypass = false

        harmonicAirEQ.bands[0].frequency = 13_500
        harmonicAirEQ.bands[0].gain = Float(air * 1.8)
        harmonicAirEQ.bands[1].frequency = 4_200
        harmonicAirEQ.bands[1].gain = -Float((1 - warmth) * 0.8)
        harmonicAirEQ.bypass = false

        // Keep the synthesized branch subtle to avoid harshness and clipping.
        harmonicMixer.outputVolume = Float(min(0.24, 0.045 + intensity * (0.12 + harmonic * 0.10)))
        dryMixer.outputVolume = 1
        outputMixer.outputVolume = 1

        contourEQ.bypass = false
        cabinetEQ.bypass = false

        contourEQ.globalGain = -Float((0.85 + bassCurve * 2.3 + loudnessCurve * 1.8 + hardnessCurve * 0.45) * intensityCurve)
        contourEQ.bands[0].gain = Float((1.2 + bassCurve * 11.6) * intensityCurve)
        contourEQ.bands[1].gain = Float((0.8 + bassCurve * 8.4) * intensityCurve)
        contourEQ.bands[2].gain = Float((0.5 + bassCurve * 5.4 + loudnessCurve * 1.0) * intensityCurve)
        
        let presenceOffset = (hardness - 0.5) * 13.0
        let brillianceOffset = (hardness - 0.4) * 7.5 
        
        contourEQ.bands[3].gain = -Float((0.45 + loudnessCurve * 2.1) * intensityCurve)
        contourEQ.bands[4].gain = -Float((0.35 + loudnessCurve * 1.8) * intensityCurve)
        contourEQ.bands[5].gain = Float((0.9 + loudnessCurve * 3.6 + presenceOffset) * intensityCurve)
        contourEQ.bands[6].gain = Float((0.4 + loudnessCurve * 2.0 + brillianceOffset) * intensityCurve)
        contourEQ.bands[7].gain = Float((-0.3 - loudnessCurve * 1.4 + (hardness - 0.5) * 7.0) * intensityCurve)

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
        cabinetEQ.bands[6].gain = -Float((0.30 + loudnessCurve * 1.4 + cabinetResonanceCurve * 0.24 - hardnessBoost * 0.4) * intensityCurve)

        masterEQ.bands[0].frequency = 85
        masterEQ.bands[0].gain = -Float((1 - warmth) * 0.8)
        masterEQ.bands[0].filterType = .lowShelf
        masterEQ.bands[0].bypass = abs(masterEQ.bands[0].gain) < 0.01
        masterEQ.bands[1].frequency = 2_000
        masterEQ.bands[1].gain = Float((warmth - 0.5) * 0.8)
        masterEQ.bands[1].filterType = .parametric
        masterEQ.bands[1].bypass = abs(masterEQ.bands[1].gain) < 0.01
        masterEQ.bands[2].frequency = 9_000
        masterEQ.bands[2].gain = Float((air - 0.5) * 2.0)
        masterEQ.bands[2].filterType = .parametric
        masterEQ.bands[2].bypass = abs(masterEQ.bands[2].gain) < 0.01
        masterEQ.bands[3].frequency = 16_000
        masterEQ.bands[3].gain = Float(air * 1.8)
        masterEQ.bands[3].filterType = .highShelf
        masterEQ.bands[3].bypass = air < 0.01

        estimatedGainBoostDB = Double(intensityCurve * (bassCurve * 2.4 + spatialCurve * 1.1 + loudnessCurve * 1.0 + cabinetResonanceCurve * 1.45 + hardnessCurve * 0.8 + metallicCurve * 1.2))
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
        min(max(value ?? defaultValue, 0), 1)
    }
}
