import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Audio effect presets")
struct AudioEffectPresetTests {
    @Test @MainActor
    func registryBuildsCompleteOrderedPipeline() {
        #expect(AudioEffectModuleRegistry.activeKinds == [
            .simulation,
            .equalizer,
            .body,
            .exciter,
            .optoFET,
            .warm,
            .gloss,
            .space,
            .bbe,
            .highQualityEnhancement
        ])
        #expect(AudioEffectModuleRegistry.makePipeline().count == 10)
        #expect(AudioEffectModuleRegistry.activeKinds(for: .off).isEmpty)
    }

    @Test @MainActor
    func defaultSettingsContainEveryDeclaredParameter() {
        for setting in AudioEffectModuleRegistry.makeDefaultSettings() {
            #expect(setting.parameters.count == setting.kind.parameterDefinitions.count)
            for definition in setting.kind.parameterDefinitions {
                #expect(setting.parameters[definition.key] == definition.defaultValue)
            }
        }
    }

    @Test @MainActor
    func settingsRoundTripForPersistentRestoration() throws {
        var settings = AudioEffectModuleRegistry.makeDefaultSettings()
        settings[0].isEnabled = true
        settings[0].parameters["intensity"] = 0.31

        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode([RealtimeAudioEffectSetting].self, from: data)

        #expect(restored == settings)
    }

    @Test("Enabled counts include only the selected effect mode")
    @MainActor
    func enabledCountIsScopedToSelectedMode() {
        var settings = AudioEffectModuleRegistry.makeDefaultSettings()
        for index in settings.indices {
            settings[index].isEnabled = [
                RealtimeAudioEffectKind.highQualityEnhancement,
                .simulation,
                .equalizer,
            ].contains(settings[index].kind)
        }

        #expect(
            AudioEffectModuleRegistry.countSummary(
                for: .basic,
                settings: settings,
                effectsBypassed: false
            ) == AudioEffectCountSummary(enabled: 1, total: 1)
        )
        #expect(
            AudioEffectModuleRegistry.countSummary(
                for: .pro,
                settings: settings,
                effectsBypassed: false
            ) == AudioEffectCountSummary(enabled: 2, total: 9)
        )
        #expect(
            AudioEffectModuleRegistry.countSummary(
                for: .off,
                settings: settings,
                effectsBypassed: true
            ) == AudioEffectCountSummary(enabled: 0, total: 0)
        )
    }
}
