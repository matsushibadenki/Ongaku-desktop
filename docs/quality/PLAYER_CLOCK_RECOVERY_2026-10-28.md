# Player clock recovery crash — 2026-10-28

## Evidence

The supplied desktop stack terminates through an Objective-C `NSException` raised inside `AVAudioPlayerNode.playerTime(forNodeTime:)`, called from `PlaybackController.currentElapsed()` during `AVAudioEngineConfigurationChange` recovery. The supplied trace does not contain the exception reason, route-change details or OS diagnostic log. It establishes the failing call, but not the precise device-state transition or original exception reason.

## Fix

- 🟢 [Done] Mac `currentElapsed()` now uses the last published position if the engine is not running, the player node is not playing, its render clock is absent, or converted time is invalid. This fallback can be slightly older than the actual playback position; it intentionally avoids inventing a timestamp while the device graph is changing. Existing generation/schedule cancellation and protected recovery remain in place.
- 🟢 [Done] A small shared Objective-C boundary rejects node timestamps that have neither host nor sample time, catches `NSException` **only** around `playerTimeForNodeTime:`, and returns nil. AVAudioEngine can invalidate a clock between state checks and conversion; a Swift optional alone cannot catch an Objective-C exception. The first caught exception's name/reason is logged once per process for diagnosis without flooding. Normal valid-clock results still pass through unchanged.
- 🟢 [Done] Mac startup's render-progress check and all five mobile production `playerTime(forNodeTime:)` conversions use the same boundary. On iPhone, existing nil-clock paths keep their previous behavior (last known position, retry, or cancel/defer handoff). Native header/implementation are byte-identical across apps. DSP math, output protection, effect defaults and audio routing were not changed.

## Validation

- Native `tests/run_safe_player_time_regression.sh`: PASS. A player subclass intentionally raises an Objective-C exception; the direct call confirms the fixture really raises and the wrapper returns nil. An empty timestamp is rejected before conversion; a real offline AVAudioEngine advances its clock, and a stopped engine's stale time does not crash. This tests the containment and fallback mechanics, not the unavailable original system exception reason.
- Mac real-controller test simulates an engine stop before a configuration notification, verifies recovery near the last saved position and current track, then verifies user pause cancels a pending recovery. Alongside recovery policy tests, 4 tests pass. Full Mac playback transport suite: 15 tests pass, including pause/resume, track replacement, crossfade, next/repeat and EOF behavior. These use generated local PCM and muted output on the development Mac.
- Mobile transport regression: 6 stock-mixer PCM fade cases at 44.1/48/96 kHz and abrupt-boundary/early-teardown negative controls pass. The extracted fake clock delegates to the fixture's clock; this does not reproduce an iPhone OS interruption.
- iPhone Simulator arm64 Debug and Mac App Store Release (arm64 + x86_64) builds succeed with signing disabled. [Compact test results and hashes](../measurements/player-clock-recovery-2026-10-28/).

## Pending

⭕️ [Pending] Reproduce the original configuration-change sequence on the physical Mac and observe sleep/wake, audio device removal/reconnection and sample-rate switching during playback/crossfade. Verify stable resume position, no crash or stale autoplay after pause/selection; collect the first `Ongaku: player clock unavailable` log if the guarded exception recurs. On physical iPhone, validate interruption/foreground recovery and quality-data handoff with actual output routes. An injected exception and an engine stop do not prove the reported device failure is fully reproduced.
