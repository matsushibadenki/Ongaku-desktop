import AudioToolbox
import Testing
@testable import OngakuDesktop
import OngakuAudioDSP

@Suite("Custom audio unit sandbox registration")
struct AudioUnitSandboxRegistrationTests {
    @Test("All custom units are registered sandbox safe")
    func customUnitsAreSandboxSafe() throws {
        let transient = try #require(OngakuSpectralTransientAudioUnit.makeNode())
        let gain = OngakuGainEnvelopeAudioUnit.makeNode()
        let peak = OngakuTruePeakAudioUnit.makeNode()
        for node in [transient, gain, peak] {
            var query = node.audioComponentDescription
            query.componentFlags = 0
            query.componentFlagsMask = 0
            let component = try #require(AudioComponentFindNext(nil, &query))
            var actual = AudioComponentDescription()
            #expect(AudioComponentGetDescription(component, &actual) == noErr)
            #expect(actual.componentFlags & UInt32(2) != 0) // kAudioComponentFlag_SandboxSafe
        }
    }
}
