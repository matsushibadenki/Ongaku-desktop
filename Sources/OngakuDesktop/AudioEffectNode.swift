//
//  AudioEffectNode.swift
//  audio
//
//  2026/04/08.
//

import AVFoundation

/// 全てのオーディオエフェクトクラスが準拠する基礎プロトコル。
/// パイプライン・アーキテクチャによる安全な動的ルーティングとゲイン管理を提供します。
protocol AudioEffectNode: AnyObject {
    /// エフェクトの種別
    var kind: RealtimeAudioEffectKind { get }
    
    /// このエフェクトが有効化されているかどうか
    var isEnabled: Bool { get }
    
    /// このエフェクトを構成する全ての AVAudioNode の配列 (エンジンへのアタッチ用)
    var nodes: [AVAudioNode] { get }
    
    /// 前段のエフェクトやソースから信号を受け取るノード
    var inputNode: AVAudioNode { get }
    
    /// 次段のエフェクトやミキサーへ信号を送るノード
    var outputNode: AVAudioNode { get }
    
    /// エフェクトがシステムに適用された時点での予測音量ブースト（dB）
    /// - 0未満: 音量が減衰する
    /// - 0を超える: 音量が増幅する
    var estimatedGainBoostDB: Double { get }

    /// Known algorithmic latency. Parallel dry/wet effects report zero here;
    /// callers can still aggregate explicit look-ahead stages consistently.
    var estimatedLatencyFrames: AVAudioFramePosition { get }
    var transitionLatency: TimeInterval { get }
    
    /// エンジンにノードをアタッチし、内部の初期接続を行います。
    /// - Parameter engine: 接続対象の AVAudioEngine
    func attach(to engine: AVAudioEngine)
    
    /// エフェクト内部のノード同士の結線を行います（該当エフェクトが2つ以上のノードで構成されている場合）。
    /// - Parameters:
    ///   - engine: 対象の AVAudioEngine
    ///   - format: 結線に使用するオーディオフォーマット
    func connectInternalNodes(engine: AVAudioEngine, format: AVAudioFormat?)
    
    /// エンジンから自身のノード群を取り除きます。
    /// - Parameter engine: 対象の AVAudioEngine
    func detach(from engine: AVAudioEngine)
    
    /// エフェクトパラメータを適用し、内部状態を更新します。
    /// - Parameter setting: UIから渡されたエフェクト設定
    func apply(setting: RealtimeAudioEffectSetting)
    func resetTailState()
}

extension AudioEffectNode {
    func resetTailState() {}
    var estimatedLatencyFrames: AVAudioFramePosition { 0 }
    var transitionLatency: TimeInterval {
        guard isEnabled else { return 0 }
        return nodes.compactMap { $0 as? AVAudioUnit }.reduce(0) { sum, unit in
            let latency = unit.auAudioUnit.latency
            return sum + (latency.isFinite && latency > 0 ? latency : 0)
        }
    }
}

/// Use stable parameter IDs, not localized display names. Apple dynamics times
/// are seconds; UI and effect formulas express milliseconds.
enum EffectDynamicsParameters {
    static func apply(to unit: AVAudioUnitEffect, thresholdDB: Float,
                      headroomDB: Float, attackMs: Float, releaseMs: Float,
                      masterGainDB: Float) {
        guard unit.audioComponentDescription.componentSubType == kAudioUnitSubType_DynamicsProcessor,
              let tree = unit.auAudioUnit.parameterTree else { return }
        let values: [(AudioUnitParameterID, Float)] = [
            (kDynamicsProcessorParam_Threshold, thresholdDB),
            (kDynamicsProcessorParam_HeadRoom, headroomDB),
            (kDynamicsProcessorParam_AttackTime, attackMs / 1000),
            (kDynamicsProcessorParam_ReleaseTime, releaseMs / 1000),
            (kDynamicsProcessorParam_OverallGain, masterGainDB),
            (kDynamicsProcessorParam_ExpansionRatio, 1)
        ]
        for (id, value) in values {
            if let parameter = tree.parameter(withAddress: AUParameterAddress(id)) {
                parameter.value = min(parameter.maxValue, max(parameter.minValue, value))
            }
        }
    }
}

/// Final sample-peak protection after the complete floating-point effect rack.
/// The post-limiter margin is 1 dB; this is not an oversampled true-peak limiter.
final class EffectOutputProtection {
    let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    let trim = AVAudioUnitEQ(numberOfBands: 0)
    var nodes: [AVAudioNode] { [limiter, trim] }

    func attach(to engine: AVAudioEngine) {
        nodes.forEach { engine.attach($0) }
        let tree = limiter.auAudioUnit.parameterTree
        tree?.parameter(withAddress: AUParameterAddress(kLimiterParam_AttackTime))?.value = 0.001
        tree?.parameter(withAddress: AUParameterAddress(kLimiterParam_DecayTime))?.value = 0.06
        tree?.parameter(withAddress: AUParameterAddress(kLimiterParam_PreGain))?.value = 0
        setEnabled(true)
    }

    func connect(from upstream: AVAudioNode, engine: AVAudioEngine, format: AVAudioFormat,
                 destination: AVAudioNode? = nil) {
        engine.connect(upstream, to: limiter, format: format)
        engine.connect(limiter, to: trim, format: format)
        engine.connect(trim, to: destination ?? engine.mainMixerNode, format: format)
    }

    func setEnabled(_ enabled: Bool) {
        limiter.bypass = !enabled
        trim.globalGain = enabled ? -1 : 0
    }
}

/// Control-thread wet-path gate. OFF stops new excitation, retains the delay/reverb
/// state, then releases the tail. Callbacks are generation-checked across ON/rebuild.
/// AVAudioEngine control writes and the injected scheduler must use one thread.
final class EffectTailGate: @unchecked Sendable {
    typealias Schedule = (TimeInterval, @escaping @Sendable () -> Void) -> Void
    static func scheduleOnMain(_ delay: TimeInterval, _ action: @escaping @Sendable () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
    }
    static let inputFade = 0.024
    static let tailHold = 0.160 // Covers Space's longest intentional predelay.
    static let tailRelease = 0.240
    private let input: AVAudioMixerNode
    private let outputs: [AVAudioMixerNode]
    private let wetUnits: [AVAudioNode]
    private let schedule: Schedule
    private var generation: UInt64 = 0
    private var enabled = false
    private(set) var isDraining = false

    init(input: AVAudioMixerNode, outputs: [AVAudioMixerNode], wetUnits: [AVAudioNode],
         schedule: @escaping Schedule = EffectTailGate.scheduleOnMain) {
        self.input = input; self.outputs = outputs; self.wetUnits = wetUnits; self.schedule = schedule
    }

    func activate() {
        generation &+= 1
        enabled = true; isDraining = false
        wetUnits.compactMap { $0 as? AVAudioUnitEffect }.forEach { $0.bypass = false }
        input.outputVolume = 1
    }

    func reset() {
        generation &+= 1
        enabled = false; isDraining = false
        input.outputVolume = 0
        outputs.forEach { $0.outputVolume = 0 }
        wetUnits.forEach { $0.reset() }
        wetUnits.compactMap { $0 as? AVAudioUnitEffect }.forEach { $0.bypass = true }
    }

    func resetPreservingEnabledState() {
        let wasEnabled = enabled, levels = outputs.map(\.outputVolume)
        reset()
        if wasEnabled {
            for (node, level) in zip(outputs, levels) { node.outputVolume = level }
            activate()
        }
    }

    func stop(rendering: Bool) {
        guard rendering else { reset(); return }
        guard enabled else { return } // Repeated OFF must not extend the tail.
        enabled = false; isDraining = true; generation &+= 1
        let token = generation, inputStart = input.outputVolume
        let levels = outputs.map(\.outputVolume)
        for step in 1...48 {
            let factor = Float((1 + cos(Double.pi * Double(step) / 48)) * 0.5)
            schedule(Self.inputFade * Double(step) / 48) { [weak self] in
                guard let self, self.generation == token else { return }
                self.input.outputVolume = step == 48 ? 0 : inputStart * factor
            }
            schedule(Self.inputFade + Self.tailHold + Self.tailRelease * Double(step) / 48) { [weak self] in
                guard let self, self.generation == token else { return }
                for (node, level) in zip(self.outputs, levels) { node.outputVolume = step == 48 ? 0 : level * factor }
                if step == 48 { self.reset() }
            }
        }
    }
}
