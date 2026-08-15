import Foundation

enum AudioEffectPageTab: String, CaseIterable, Hashable, Identifiable, Sendable {
    case basic
    case pro
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .basic: return L10n.text("effects.tab.basic")
        case .pro: return L10n.text("effects.tab.pro")
        case .off: return L10n.text("effects.tab.off")
        }
    }
}

/// Describes everything the host needs to attach or detach an effect module.
///
/// Effect implementations remain in their own files. To temporarily remove an
/// effect from the app without deleting its implementation, change only that
/// module's `isIncluded` value below. The engine pipeline, settings UI, saved
/// state restoration, and clipping protection all derive from this registry.
struct AudioEffectModuleDescriptor {
    let kind: RealtimeAudioEffectKind
    let pageTab: AudioEffectPageTab
    let isIncluded: Bool
    let clippingReductionParameterKeys: [String]
    let makeNode: () -> AudioEffectNode

    init(
        kind: RealtimeAudioEffectKind,
        pageTab: AudioEffectPageTab = .pro,
        isIncluded: Bool = true,
        clippingReductionParameterKeys: [String],
        makeNode: @escaping () -> AudioEffectNode
    ) {
        self.kind = kind
        self.pageTab = pageTab
        self.isIncluded = isIncluded
        self.clippingReductionParameterKeys = clippingReductionParameterKeys
        self.makeNode = makeNode
    }
}

@MainActor
enum AudioEffectModuleRegistry {
    /// The order here is the signal-flow order.
    /// Set `isIncluded: false` on one entry to detach that module everywhere.
    private static let catalog: [AudioEffectModuleDescriptor] = [
        .init(kind: .simulation, isIncluded: true, clippingReductionParameterKeys: ["intensity", "bass"]) {
            SimulationAudioEffect()
        },
        .init(kind: .equalizer, isIncluded: true, clippingReductionParameterKeys: ["trim"]) {
            EqualizerAudioEffect()
        },
        .init(kind: .body, isIncluded: true, clippingReductionParameterKeys: ["intensity", "punch"]) {
            BodyAudioEffect()
        },
        .init(kind: .exciter, isIncluded: true, clippingReductionParameterKeys: ["intensity", "frequency"]) {
            ExciterAudioEffect()
        },
        .init(kind: .optoFET, isIncluded: true, clippingReductionParameterKeys: ["intensity", "peak"]) {
            OptoFETAudioEffect()
        },
        .init(kind: .warm, isIncluded: true, clippingReductionParameterKeys: ["intensity", "drive"]) {
            WarmAudioEffect()
        },
        .init(kind: .gloss, isIncluded: true, clippingReductionParameterKeys: ["intensity", "air"]) {
            GlossAudioEffect()
        },
        .init(kind: .space, isIncluded: true, clippingReductionParameterKeys: ["intensity", "amount"]) {
            SpaceAudioEffect()
        },
        .init(kind: .bbe, isIncluded: true, clippingReductionParameterKeys: ["intensity", "process"]) {
            BBEAudioEffect()
        },
        .init(
            kind: .highQualityEnhancement,
            pageTab: .basic,
            isIncluded: true,
            clippingReductionParameterKeys: ["intensity", "harmonic"]
        ) {
            HighQualityEnhancementAudioEffect()
        }
    ]

    static var activeModules: [AudioEffectModuleDescriptor] {
        let modules = catalog.filter(\.isIncluded)
        precondition(
            Set(modules.map(\.kind)).count == modules.count,
            "Each active audio effect kind must be registered exactly once."
        )
        precondition(
            modules.filter { $0.pageTab == .basic }.map(\.kind) == [.highQualityEnhancement],
            "The Basic tab must contain only High Quality Enhancement."
        )
        return modules
    }

    static var activeKinds: [RealtimeAudioEffectKind] {
        activeModules.map(\.kind)
    }

    static func activeKinds(for pageTab: AudioEffectPageTab) -> Set<RealtimeAudioEffectKind> {
        guard pageTab != .off else { return [] }
        return Set(activeModules.lazy.filter { $0.pageTab == pageTab }.map(\.kind))
    }

    static func makePipeline() -> [AudioEffectNode] {
        activeModules.map { $0.makeNode() }
    }

    static func makeDefaultSettings() -> [RealtimeAudioEffectSetting] {
        activeKinds.map { RealtimeAudioEffectSetting(kind: $0) }
    }

    static func clippingReductionParameterKeys(
        for kind: RealtimeAudioEffectKind
    ) -> [String] {
        activeModules.first(where: { $0.kind == kind })?.clippingReductionParameterKeys ?? []
    }
}
