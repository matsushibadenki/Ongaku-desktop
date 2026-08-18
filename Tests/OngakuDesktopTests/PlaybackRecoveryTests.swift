import Testing
@testable import OngakuDesktop

@Suite("Playback recovery state")
struct PlaybackRecoveryTests {
    @Test("A playing track resumes from its saved position after wake")
    func resumesAfterWake() {
        var state = PlaybackRecoveryState()
        state.prepareForSleep(position: 42.5, isPlaying: true)

        #expect(state.isSleeping)
        #expect(
            state.requestAfterWake()
                == PlaybackRecoveryRequest(position: 42.5, shouldResume: true)
        )
        #expect(!state.isSleeping)
        #expect(state.requestAfterWake() == nil)
    }

    @Test("A paused track remains paused after wake")
    func remainsPausedAfterWake() {
        var state = PlaybackRecoveryState()
        state.prepareForSleep(position: -3, isPlaying: false)

        #expect(
            state.requestAfterWake()
                == PlaybackRecoveryRequest(position: 0, shouldResume: false)
        )
    }
}
