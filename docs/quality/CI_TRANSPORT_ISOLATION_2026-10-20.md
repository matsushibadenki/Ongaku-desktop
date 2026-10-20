# Real-engine CI isolation — 2026-10-20

Reported run: https://github.com/matsushibadenki/Ongaku-desktop/actions/runs/39384131607/job/118499810684

## Failure and evidence

The unit-test step ran 383 tests and failed only at `PlaybackTransportIntegrationTests.swift:68` (resume must be playing). This differs from the previously repaired teardown exclusivity trap and target-membership compile error. The arm64 capacity notice is not the test failure.

The 10-second fixture plays on AVAudioEngine's real audio clock while the test and transport callbacks resume on MainActor. The parallel run shows `frequencyAndLevelMatrix` and multiple unrelated MainActor tests completing together after roughly 140 seconds, with the failing resume assertion in the same burst. The transport test lasted 192.696 seconds. These observations are consistent with cross-suite MainActor starvation allowing the short fixture to reach EOF before the assertion; they do not prove every physical playback failure has the same cause.

A suite's `.serialized` only orders tests inside that suite; it does not exclude other suites. Track-end tests already extend the transport suite, but the heavy DSP/UI/library suites still ran alongside it.

## Repair

Run the unchanged tests in two sequential processes in the same quality job:

```sh
swift test --skip PlaybackTransportIntegrationTests
swift test --skip-build --filter PlaybackTransportIntegrationTests
```

The first command builds and runs every other suite. The second runs the complete serialized real-engine transport/track-end suite using the same build. No tests are removed, no retries hide failures, and no timing assertions or fixture lengths are relaxed. M3 performance and all compile/Sandbox gates remain mandatory. This change affects CI only; the published 0.1.11 (18) app binary and iPhone runtime are unchanged.

## Validation

- The previously failing transport test passes in isolation in 4.388 seconds using the unchanged production code and assertions.
- 🟢 [Done] Local real-engine partition: all 11 tests pass in 62.291 seconds. Other partition: all 372 tests pass in 133.019 seconds. Together these retain all 383 tests.
- 🟢 [Done] GitHub Xcode 26.6 [run 39385620014](https://github.com/matsushibadenki/Ongaku-desktop/actions/runs/39385620014) completes successfully: 372 tests in 261.464 seconds, all 11 real-engine tests in 120.273 seconds, M3 100,000-track budget, both Mac build variants, updater exclusion, minimum Sandbox permissions and iOS companion compilation all pass.
- ⭕️ [Pending] Physical output-device, interruption/EOF, listening and high-load app qualification remain in the existing audio roadmap. Isolating the test runner is not proof that production audio tolerates arbitrary MainActor stalls.
