//
//  AudioEffectPreset.swift
//  audio
//
//  エフェクトの種別定義・パラメータ定義・設定モデル
//  2026/04/02.
//

import Foundation

enum ExciterMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case smooth
    case open

    var id: String { rawValue }

    var parameterValue: Double {
        switch self {
        case .smooth: return 0.0
        case .open: return 1.0
        }
    }

    static func from(parameterValue: Double?) -> ExciterMode {
        (parameterValue ?? 0.0) >= 0.5 ? .open : .smooth
    }

    var title: String {
        switch self {
        case .smooth:
            return L10n.text("effect.exciter.mode.smooth")
        case .open:
            return L10n.text("effect.exciter.mode.open")
        }
    }
}

enum ExciterOpenTone: String, CaseIterable, Identifiable, Codable, Sendable {
    case soft
    case bright

    var id: String { rawValue }

    var parameterValue: Double {
        switch self {
        case .soft: return 0.0
        case .bright: return 1.0
        }
    }

    static func from(parameterValue: Double?) -> ExciterOpenTone {
        (parameterValue ?? 0.0) >= 0.5 ? .bright : .soft
    }

    var title: String {
        switch self {
        case .soft:
            return L10n.text("effect.exciter.open_tone.soft")
        case .bright:
            return L10n.text("effect.exciter.open_tone.bright")
        }
    }
}

enum MaximizerMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case tight
    case rich

    var id: String { rawValue }

    var parameterValue: Double {
        switch self {
        case .tight: return 0.0
        case .rich: return 1.0
        }
    }

    static func from(parameterValue: Double?) -> MaximizerMode {
        (parameterValue ?? 0.0) >= 0.5 ? .rich : .tight
    }

    var title: String {
        switch self {
        case .tight:
            return L10n.text("effect.maximizer.mode.tight")
        case .rich:
            return L10n.text("effect.maximizer.mode.rich")
        }
    }
}

enum RealtimeAudioEffectKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case simulation
    case bbe
    case body
    case exciter
    case gloss
    case optoFET
    case warm
    case space
    case equalizer
    case highQualityEnhancement

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .simulation: return L10n.text("effect.simulation.name")
        case .bbe: return L10n.text("effect.bbe.name")
        case .body: return L10n.text("effect.body.name")
        case .exciter: return L10n.text("effect.exciter.name")
        case .gloss: return L10n.text("effect.gloss.name")
        case .optoFET: return L10n.text("effect.opto_fet.name")
        case .warm: return L10n.text("effect.warm.name")
        case .space: return L10n.text("effect.space.name")
        case .equalizer: return L10n.text("effect.equalizer.name")
        case .highQualityEnhancement: return L10n.text("effect.high_quality_enhancement.name")
        }
    }

    var description: String {
        switch self {
        case .simulation: return L10n.text("effect.simulation.description")
        case .bbe: return L10n.text("effect.bbe.description")
        case .body: return L10n.text("effect.body.description")
        case .exciter: return L10n.text("effect.exciter.description")
        case .gloss: return L10n.text("effect.gloss.description")
        case .optoFET: return L10n.text("effect.opto_fet.description")
        case .warm: return L10n.text("effect.warm.description")
        case .space: return L10n.text("effect.space.description")
        case .equalizer: return L10n.text("effect.equalizer.description")
        case .highQualityEnhancement: return L10n.text("effect.high_quality_enhancement.description")
        }
    }
    
    var parameterDefinitions: [EffectParameterDefinition] {
        switch self {
        case .simulation:
            return [
                EffectParameterDefinition(key: "intensity", name: L10n.text("effect.parameter.intensity"), defaultValue: 0.75),
                EffectParameterDefinition(key: "bass", name: L10n.text("effect.parameter.bass_boost"), defaultValue: 0.75),
                EffectParameterDefinition(key: "spatial", name: L10n.text("effect.parameter.spatial"), defaultValue: 0.50),
                EffectParameterDefinition(key: "loudness", name: L10n.text("effect.parameter.loudness"), defaultValue: 0.60),
                EffectParameterDefinition(key: "cabinetResonance", name: L10n.text("effect.parameter.cabinet_resonance"), defaultValue: 0.42),
                EffectParameterDefinition(key: "materialHardness", name: L10n.text("effect.parameter.material_hardness"), defaultValue: 0.50),
                EffectParameterDefinition(key: "materialMetallic", name: L10n.text("effect.parameter.material_metallic"), defaultValue: 0.50)
            ]
        case .bbe:
            return [
                EffectParameterDefinition(key: "mode", name: L10n.text("effect.parameter.mode"), defaultValue: 0.0),
                EffectParameterDefinition(key: "intensity", name: L10n.text("effect.parameter.intensity"), defaultValue: 0.80),
                EffectParameterDefinition(key: "loContour", name: L10n.text("effect.parameter.lo_contour"), defaultValue: 0.58),
                EffectParameterDefinition(key: "process", name: L10n.text("effect.parameter.process"), defaultValue: 0.62)
            ]
        case .body:
            return [
                EffectParameterDefinition(key: "intensity", name: L10n.text("effect.parameter.intensity"), defaultValue: 0.80),
                EffectParameterDefinition(key: "weight", name: L10n.text("effect.parameter.weight"), defaultValue: 0.52),
                EffectParameterDefinition(key: "punch", name: L10n.text("effect.parameter.punch"), defaultValue: 0.48)
            ]
        case .exciter:
            return [
                EffectParameterDefinition(key: "mode", name: L10n.text("effect.parameter.mode"), defaultValue: 0.0),
                EffectParameterDefinition(key: "openTone", name: L10n.text("effect.parameter.open_tone"), defaultValue: 0.0),
                EffectParameterDefinition(key: "intensity", name: L10n.text("effect.parameter.intensity"), defaultValue: 0.45),
                EffectParameterDefinition(key: "frequency", name: L10n.text("effect.parameter.frequency"), defaultValue: 0.58)
            ]
        case .gloss:
            return [
                EffectParameterDefinition(key: "intensity", name: L10n.text("effect.parameter.intensity"), defaultValue: 0.80),
                EffectParameterDefinition(key: "clarity", name: L10n.text("effect.parameter.clarity"), defaultValue: 0.48),
                EffectParameterDefinition(key: "air", name: L10n.text("effect.parameter.air"), defaultValue: 0.52)
            ]
        case .optoFET:
            return [
                EffectParameterDefinition(key: "intensity", name: L10n.text("effect.parameter.intensity"), defaultValue: 0.70),
                EffectParameterDefinition(key: "peak", name: L10n.text("effect.parameter.peak"), defaultValue: 0.52),
                EffectParameterDefinition(key: "level", name: L10n.text("effect.parameter.level"), defaultValue: 0.50, isBiPolar: true)
            ]
        case .warm:
            return [
                EffectParameterDefinition(key: "intensity", name: L10n.text("effect.parameter.intensity"), defaultValue: 0.78),
                EffectParameterDefinition(key: "drive", name: L10n.text("effect.parameter.drive"), defaultValue: 0.44),
                EffectParameterDefinition(key: "tone", name: L10n.text("effect.parameter.tone"), defaultValue: 0.50),
                EffectParameterDefinition(key: "flutter", name: L10n.text("effect.parameter.flutter"), defaultValue: 0.24),
                EffectParameterDefinition(key: "mc901", name: L10n.text("effect.parameter.mc901"), defaultValue: 0.0)
            ]
        case .space:
            return [
                EffectParameterDefinition(key: "intensity", name: L10n.text("effect.parameter.intensity"), defaultValue: 0.80),
                EffectParameterDefinition(key: "amount", name: L10n.text("effect.parameter.amount"), defaultValue: 0.22),
                EffectParameterDefinition(key: "size", name: L10n.text("effect.parameter.size"), defaultValue: 0.45),
                EffectParameterDefinition(key: "preDelay", name: L10n.text("effect.parameter.pre_delay"), defaultValue: 0.24),
                EffectParameterDefinition(key: "damping", name: L10n.text("effect.parameter.damping"), defaultValue: 0.46)
            ]
        case .equalizer:
            return [
                EffectParameterDefinition(key: "hpf", name: L10n.text("effect.parameter.hpf"), defaultValue: 0.0, group: "FILTER"),
                EffectParameterDefinition(key: "lfGain", name: L10n.text("effect.parameter.lf_gain"), defaultValue: 0.5, group: "LOW BAND", isBiPolar: true),
                EffectParameterDefinition(key: "lfFreq", name: L10n.text("effect.parameter.lf_freq"), defaultValue: 0.0, group: "LOW BAND"),
                EffectParameterDefinition(key: "lmfGain", name: L10n.text("effect.parameter.lmf_gain"), defaultValue: 0.5, group: "LMF", isBiPolar: true),
                EffectParameterDefinition(key: "lmfFreq", name: L10n.text("effect.parameter.lmf_freq"), defaultValue: 0.5, group: "LMF"),
                EffectParameterDefinition(key: "lmfQ", name: L10n.text("effect.parameter.lmf_q"), defaultValue: 0.5, group: "LMF"),
                EffectParameterDefinition(key: "lmfFocus", name: L10n.text("effect.parameter.lmf_focus"), defaultValue: 0.0, group: "LMF"),
                EffectParameterDefinition(key: "hmfGain", name: L10n.text("effect.parameter.hmf_gain"), defaultValue: 0.5, group: "HMF", isBiPolar: true),
                EffectParameterDefinition(key: "hmfFreq", name: L10n.text("effect.parameter.hmf_freq"), defaultValue: 0.5, group: "HMF"),
                EffectParameterDefinition(key: "hmfQ", name: L10n.text("effect.parameter.hmf_q"), defaultValue: 0.5, group: "HMF"),
                EffectParameterDefinition(key: "hmfFocus", name: L10n.text("effect.parameter.hmf_focus"), defaultValue: 0.0, group: "HMF"),
                EffectParameterDefinition(key: "hfGain", name: L10n.text("effect.parameter.hf_gain"), defaultValue: 0.5, group: "HIGH BAND", isBiPolar: true),
                EffectParameterDefinition(key: "hfFreq", name: L10n.text("effect.parameter.hf_freq"), defaultValue: 0.0, group: "HIGH BAND"),
                EffectParameterDefinition(key: "trim", name: L10n.text("effect.parameter.trim"), defaultValue: 0.5, group: "OUTPUT", isBiPolar: true)
            ]
        case .highQualityEnhancement:
            return [
                EffectParameterDefinition(key: "intensity", name: L10n.text("effect.parameter.intensity"), defaultValue: 0.68),
                EffectParameterDefinition(key: "air", name: L10n.text("effect.parameter.air"), defaultValue: 0.58),
                EffectParameterDefinition(key: "harmonic", name: L10n.text("effect.parameter.harmonic"), defaultValue: 0.42),
                EffectParameterDefinition(key: "warmth", name: L10n.text("effect.parameter.warmth"), defaultValue: 0.46),
                EffectParameterDefinition(key: "bass", name: L10n.text("effect.parameter.bass_boost"), defaultValue: 0.75),
                EffectParameterDefinition(key: "spatial", name: L10n.text("effect.parameter.spatial"), defaultValue: 0.50),
                EffectParameterDefinition(key: "loudness", name: L10n.text("effect.parameter.loudness"), defaultValue: 0.60),
                EffectParameterDefinition(key: "cabinetResonance", name: L10n.text("effect.parameter.cabinet_resonance"), defaultValue: 0.42),
                EffectParameterDefinition(key: "materialHardness", name: L10n.text("effect.parameter.material_hardness"), defaultValue: 0.50),
                EffectParameterDefinition(key: "materialMetallic", name: L10n.text("effect.parameter.material_metallic"), defaultValue: 0.50)
            ]
        }
    }
}

struct EffectParameterDefinition: Hashable {
    let key: String
    let name: String
    let defaultValue: Double
    let range: ClosedRange<Double>
    let group: String?
    let isBiPolar: Bool
    
    init(key: String, name: String, defaultValue: Double, range: ClosedRange<Double> = 0...1, group: String? = nil, isBiPolar: Bool = false) {
        self.key = key
        self.name = name
        self.defaultValue = defaultValue
        self.range = range
        self.group = group
        self.isBiPolar = isBiPolar
    }
}

struct RealtimeAudioEffectSetting: Identifiable, Hashable, Codable, Sendable {
    let id: RealtimeAudioEffectKind
    let kind: RealtimeAudioEffectKind
    var isEnabled: Bool
    var parameters: [String: Double] // 複数パラメータ対応

    init(kind: RealtimeAudioEffectKind, isEnabled: Bool = false) {
        self.id = kind
        self.kind = kind
        self.isEnabled = isEnabled
        
        // デフォルト値で初期化
        var initialParams: [String: Double] = [:]
        for def in kind.parameterDefinitions {
            initialParams[def.key] = def.defaultValue
        }
        self.parameters = initialParams
    }
}
