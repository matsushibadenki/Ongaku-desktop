//
//  WarmAudioEffect.swift
//  audio
//
//  2026/04/08.
//
//  McIntosh MC901 Hybrid Drive などのシミュレーションを含む
//  温かみのあるサチュレーション・エフェクト。
//

import AVFoundation
import Foundation

// The rack owns and mutates this effect exclusively from PlaybackController's
// main-actor audio graph. Timer callbacks are also installed on the main run loop.
final class WarmAudioEffect: AudioEffectNode, @unchecked Sendable {
    let kind: RealtimeAudioEffectKind = .warm
    private(set) var isEnabled: Bool = false

    // 基本構成: PreEQ -> Varispeed -> (Parallel Branches) -> Mixer
    private let preEQ = AVAudioUnitEQ(numberOfBands: 3)
    private let varispeed = AVAudioUnitVarispeed()
    
    // Low Path (Solid State Simulation)
    private let lowLPF = AVAudioUnitEQ(numberOfBands: 1)
    private let lowSat = AVAudioUnitDistortion()
    private let lowDownsampleMixer = AVAudioMixerNode()
    
    // High Path (Tube Simulation)
    private let highHPF = AVAudioUnitEQ(numberOfBands: 1)
    private let highSat = AVAudioUnitDistortion()
    private let highDownsampleMixer = AVAudioMixerNode()
    
    // --- 修正: コーラスの代わりにDelayを使用したダブリングとReverb ---
    private let highDoubler = AVAudioUnitDelay()
    private let highReverb = AVAudioUnitReverb()
    private let highWetMixer = AVAudioMixerNode()
    
    private let mainMixer = AVAudioMixerNode()

    private var modulationTimer: Timer?
    private var modulationPhase: Double = 0
    private var flutterDepth: Double = 0

    var nodes: [AVAudioNode] { 
        [
            preEQ,
            varispeed,
            lowLPF,
            lowSat,
            lowDownsampleMixer,
            highHPF,
            highSat,
            highDownsampleMixer,
            highDoubler,
            highReverb,
            highWetMixer,
            mainMixer
        ]
    }
    var inputNode: AVAudioNode { preEQ }
    var outputNode: AVAudioNode { mainMixer }

    private(set) var estimatedGainBoostDB: Double = 0.0

    func attach(to engine: AVAudioEngine) {
        for node in nodes {
            engine.attach(node)
        }

        // Default PreEQ settings
        preEQ.bands[0].filterType = .parametric
        preEQ.bands[0].frequency = 180
        preEQ.bands[1].filterType = .parametric
        preEQ.bands[1].frequency = 980
        preEQ.bands[2].filterType = .highShelf
        preEQ.bands[2].frequency = 4600
        
        // Low Path: LPF for Solid State
        lowLPF.bands[0].filterType = .lowPass
        lowLPF.bands[0].frequency = 250
        lowSat.loadFactoryPreset(.multiDistortedFunk)
        lowSat.preGain = -10
        lowSat.wetDryMix = 0
        
        // High Path: HPF for Tube
        highHPF.bands[0].filterType = .highPass
        highHPF.bands[0].frequency = 250
        highSat.loadFactoryPreset(.multiDistortedSquared)
        highSat.preGain = -10
        highSat.wetDryMix = 0

        // --- 修正: コーラスの代替としてのショートディレイ（ダブリング）設定 ---
        highDoubler.delayTime = 0.025 // 25msの極短ディレイで厚みを出す
        highDoubler.feedback = 0.0    // 反復させない
        highDoubler.lowPassCutoff = 8000.0 // デジタル特有の高域のチリチリ感を抑える
        highDoubler.wetDryMix = 0
        
        // リバーブの初期設定（高密度の滑らかさ）
        highReverb.loadFactoryPreset(.plate)
        highReverb.wetDryMix = 0
        highWetMixer.outputVolume = 0

        lowDownsampleMixer.outputVolume = 1.0
        highDownsampleMixer.outputVolume = 1.0
        varispeed.rate = 1.0
        
        // Bypass all effect units by default
        for node in nodes {
            if let effect = node as? AVAudioUnitEffect {
                effect.bypass = true
            }
        }
    }

    func connectInternalNodes(engine: AVAudioEngine, format: AVAudioFormat?) {
        // Linear part
        engine.connect(preEQ, to: varispeed, format: format)
        
        // --- 修正ポイント: AVAudioConnectionPoint によるマルチ・ルーティング (Fan-out) ---
        // EN: Use ConnectionPoints to fan out from varispeed to both Low and High paths.
        // JA: varispeedから低域パス(Low)と高域パス(High)の両方に分岐させるため、ConnectionPointを使用します。
        let connectionPoints = [
            AVAudioConnectionPoint(node: lowLPF, bus: 0),
            AVAudioConnectionPoint(node: highHPF, bus: 0)
        ]
        engine.connect(varispeed, to: connectionPoints, fromBus: 0, format: format)
        
        // Low Path
        // Keep the realtime graph on one processing format. AVAudioEngine can reject
        // an internal sample-rate island here with kAudioUnitErr_FormatNotSupported.
        engine.connect(lowLPF, to: lowSat, format: format)
        engine.connect(lowSat, to: lowDownsampleMixer, format: format)
        engine.connect(lowDownsampleMixer, to: mainMixer, format: format)
        
        // High Path (サチュレーション -> ダブリング -> リバーブ)
        engine.connect(highHPF, to: highSat, format: format)
        engine.connect(highSat, to: highDownsampleMixer, format: format)
        engine.connect(highDownsampleMixer, to: [
            AVAudioConnectionPoint(node: mainMixer, bus: 0),
            AVAudioConnectionPoint(node: highDoubler, bus: 0)
        ], fromBus: 0, format: format)
        engine.connect(highDoubler, to: highReverb, format: format)
        engine.connect(highReverb, to: highWetMixer, format: format)
        engine.connect(highWetMixer, to: mainMixer, format: format)
    }

    func detach(from engine: AVAudioEngine) {
        stopModulation()
        for node in nodes {
            engine.detach(node)
        }
    }

    func apply(setting: RealtimeAudioEffectSetting) {
        let intensity = clamped(setting.parameters["intensity"], defaultValue: 0.78)
        let drive = clamped(setting.parameters["drive"], defaultValue: 0.44)
        let tone = clamped(setting.parameters["tone"], defaultValue: 0.50)
        let flutter = clamped(setting.parameters["flutter"], defaultValue: 0.24)
        let hybrid = clamped(setting.parameters["mc901"], defaultValue: 0.0)

        let intensityCurve = pow(intensity, 0.90)
        let driveCurve = pow(drive, 0.72)
        let toneCurve = pow(tone, 0.84)
        let flutterCurve = pow(flutter, 0.86)
        let hybridCurve = pow(hybrid, 0.75)

        isEnabled = setting.isEnabled && intensity > 0.001

        guard isEnabled else {
            stopModulation()
            for node in nodes {
                if let effect = node as? AVAudioUnitEffect { effect.bypass = true }
            }
            varispeed.rate = 1.0
            highWetMixer.outputVolume = 0
            estimatedGainBoostDB = 0.0
            return
        }

        // Enable necessary units
        preEQ.bypass = false
        lowLPF.bypass = false
        lowSat.bypass = false
        highHPF.bypass = false
        highSat.bypass = false
        highDoubler.bypass = false
        highReverb.bypass = false

        // --- Pre-EQ logic (Tone shaping) ---
        preEQ.bands[0].frequency = Float(150.0 + tone * 150.0)
        preEQ.bands[0].gain = Float((1.5 + driveCurve * 0.05) * intensityCurve) 
        
        preEQ.bands[1].frequency = Float(800.0 + tone * 400.0)
        preEQ.bands[1].gain = Float((1.0 + driveCurve * 0.02) * intensityCurve) 
        
        preEQ.bands[2].frequency = Float(4000.0 + tone * 2000.0)
        preEQ.bands[2].gain = -Float((1.0 + (1.0 - toneCurve) * 0.05) * intensityCurve) 

        // --- Hybrid Drive (MC901 Simulation) Original Logic ---
        let xOverFreq = Float(250.0 + hybridCurve * 550.0)
        lowLPF.bands[0].frequency = xOverFreq
        highHPF.bands[0].frequency = xOverFreq

        // Low Path (Solid State)
        lowSat.preGain = Float(-10.0 + (driveCurve * 5.0 + hybridCurve * 2.0) * 0.01)
        lowSat.wetDryMix = Float((driveCurve * 10.0) * intensityCurve)
        
        // High Path (Tube)
        highSat.preGain = Float(-8.0 + (driveCurve * 6.0 + hybridCurve * 4.0) * 0.01)
        highSat.wetDryMix = Float((driveCurve * 15.0 + hybridCurve * 5.0) * intensityCurve)

        // --- 修正: 艶と濡れ感の付加 ---
        // コーラスの代わりにショートディレイで厚みを出し、Varispeedの揺れと混ぜてウェット感を演出
        highDoubler.wetDryMix = 100
        highReverb.wetDryMix = 100
        highWetMixer.outputVolume = min(0.14, Float((toneCurve * 0.14) * intensityCurve))
        let hasWetSignal = highWetMixer.outputVolume > 0.0001
        highDoubler.bypass = !hasWetSignal
        highReverb.bypass = !hasWetSignal

        mainMixer.outputVolume = 1.0
        lowDownsampleMixer.outputVolume = 1.0
        highDownsampleMixer.outputVolume = 1.0

        // --- Wow / Flutter ---
        flutterDepth = (0.003 + flutterCurve * 0.013) * intensityCurve
        updateVarispeedRate()
        if flutterDepth > 0.00015 {
            startModulation()
        } else {
            stopModulation()
        }

        estimatedGainBoostDB = intensityCurve * (driveCurve * 1.5 + hybridCurve * 1.0)
    }

    private func startModulation() {
        guard modulationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            self?.updateVarispeedRate()
        }
        RunLoop.main.add(timer, forMode: .common)
        modulationTimer = timer
    }

    private func stopModulation() {
        modulationTimer?.invalidate()
        modulationTimer = nil
        modulationPhase = 0
        varispeed.rate = 1.0
    }

    private func updateVarispeedRate() {
        modulationPhase += 1.0 / 24.0
        
        let f1 = sin(modulationPhase * 2.0 * .pi * 0.42)   
        let f2 = sin(modulationPhase * 2.0 * .pi * 1.15)   
        let f3 = sin(modulationPhase * 2.0 * .pi * 4.70)   
        let f4 = sin(modulationPhase * 2.0 * .pi * 0.05)   
        
        let yuragi = (f1 * 0.5 + f2 * 0.25 + f3 * 0.1 + f4 * 0.15)
        
        guard flutterDepth > 0 else {
            varispeed.rate = 1.0
            mainMixer.outputVolume = 1.0
            return
        }
        
        let rateOffset = yuragi * flutterDepth
        varispeed.rate = Float(1.0 + rateOffset)
        
        let volumeOffset = yuragi * (flutterDepth * 0.3)
        mainMixer.outputVolume = Float(1.0 + volumeOffset)
    }

    private func clamped(_ value: Double?, defaultValue: Double) -> Double {
        min(max(value ?? defaultValue, 0.0), 1.0)
    }
}
