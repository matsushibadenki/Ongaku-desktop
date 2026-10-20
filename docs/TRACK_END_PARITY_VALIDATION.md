# Track-end ownership parity — 2026-10-20

The iPhone report was silence at a track boundary with the old song and Pause button still shown. This follow-up audited the Mac local-file controller for corresponding EOF, preroll and recovery ownership failures. No claim is made that the same reported device incident occurred on Mac.

## Confirmed Mac defects

Four control-flow regressions were reproduced before the fix using the shipping controller and generated CAF fixtures:

1. An incoming segment's EOF delivered before the outgoing segment's EOF was discarded because it was not yet the current track. Promotion then left the incoming track shown as playing despite having already ended.
2. Gapless repeat-one shares the transport generation, track ID and player node. A duplicate outgoing callback therefore matched another repeat and advanced its sample offset again. A distinct segment identity is required even within one transport generation.
3. Configuration recovery captured the old song's position, waited 300 ms, then could rebuild a newly promoted gapless song at that old position. The pre-fix test moved the new song to approximately 8 seconds rather than its start.
4. If Pause won the race against a queued EOF, its drained schedule could have zero remaining frames. That synchronous empty-schedule callback selected the next song despite the newer pause intent.

The fixed controller assigns each scheduled segment a UUID in addition to the existing transport generation and immutable node identity. Incoming EOF is retained in its preroll until promotion; the active schedule is completed only once. Obsolete callbacks cannot match another repeat. Recovery is scoped to both identities and cancelled when the active segment completes or is promoted. A paused empty schedule reports no autoplay completion. The existing MainActor hop captures only Sendable identities, preserving the earlier CI concurrency repair.

## Shared acceptance criteria

| Requirement | iPhone | Mac |
| --- | --- | --- |
| Rejected preparation keeps audible EOF valid | Per-node prepared-buffer callback token | Existing next-file preroll rejection retains the current schedule; verified with an injected open failure |
| EOF survives temporary ownership | Accepted EOF is retained until recovery releases ownership | Incoming EOF is retained until that segment becomes current |
| Exactly one completion per schedule | Engine generation and ViewModel schedule identity | Transport generation plus segment UUID, node and track identity |
| No old recovery operates on a new song | Pause/preparation tokens gate recovery | Transport and segment identity gate delayed recovery; promotion cancels the old task |
| New pause/stop/selection wins | Transport intent invalidates/suppresses EOF | Drain generation rejects callbacks; paused empty schedules cannot auto-advance |
| Very short remaining tail | 10 ms tail qualified in the prior iPhone Simulator run | Real local-file 10 ms tails exercised for next, repeat-one, repeat-all, repeat-album and final stop |

Mac's ordinary local playback uses AVAudioEngine sample-rate conversion and next-track file preroll. It does not use iPhone's Precision Sinc same-track prepared-buffer replacement, global handoff token or interruption progress-confirmation loop. No such path was added to Mac. The separate MusicKit `ApplicationMusicPlayer` owns its queue and was inspected without changing that ownership. CPU conversion, effects, normalization and output protection policies remain unchanged.

## Verification

- Before fixing: the four cases above fail with explicit expectation failures. Baseline tests changed only the EOF callback's access from private to internal so delivery order could be injected; its behavior was unchanged.
- New Mac tests live in `Tests/OngakuDesktopTests/TrackEndContinuityTests.swift`, extending the existing serialized `PlaybackTransportIntegrationTests` suite. They exercise the real controller with muted AVAudioEngine output. Reordered/duplicated EOF is delivered directly to the same internal callback entry used by the audio nodes, not by claiming the OS produced that ordering.
- Coverage includes gapless and crossfade callback reversal, repeat-one duplicate rejection, a queued real EOF followed by Pause, a synthetic configuration notification followed by promotion, retained EOF versus newer pause/resume/selection/stop, rejected preroll followed by a fresh load, and actual 10 ms tail playback in five queue/repeat configurations. Existing natural crossfade, outgoing-repeat rejection and gain-reference tests remain in the same suite.
- `swift test`: all **370 tests in 40 suites pass**, including 11 real-controller integration tests (the incoming-EOF test runs both gapless and crossfade cases). `swift test -Xswiftc -DONGAKU_ENABLE_TRUE_PEAK --filter PlaybackTransportIntegrationTests`: all **11 integration tests pass** in the existing candidate configuration. Both ordinary Debug `build-for-testing` and Mac App Store Release builds succeed on Xcode 27.1. Only the existing skipped App Intents metadata warning appears in the Xcode builds. The shared iPhone/Mac `EffectTransitionPolicy.swift` files remain byte-identical.
- iPhone shipping-method regressions were rerun: 3 prepared-EOF groups and the global-token negative control, 10 queue/intent cases and the stranded-seek negative control, 13 recovery groups and both negative controls pass. No iPhone production code changed in this follow-up; its previous normal build and 9 Simulator groups are historical results, not newly rerun here.

An initial expanded test run exposed harness assumptions: crossfade preparation needed to await asynchronous silence analysis, and album-repeat fixtures needed a shared album UUID. The real-controller tests now share one serialized suite, so one test's synchronous engine setup does not consume another test's short playback window. The final evidence below corresponds to that corrected harness. This is not a qualification of audio timing under arbitrary compiler/UI/CPU load.

[Recorded verification output](measurements/track-end-parity-2026-10-20.txt)

## Reproduction commands

```sh
# In Ongaku-desktop
swift test
swift test -Xswiftc -DONGAKU_ENABLE_TRUE_PEAK --filter PlaybackTransportIntegrationTests
xcodebuild build-for-testing -project OngakuDesktop.xcodeproj -scheme OngakuDesktop \
  -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project OngakuDesktop.xcodeproj -scheme OngakuDesktopAppStore \
  -configuration Release -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO

# In Ongaku
bash tests/run_prepared_eof_regression.sh
bash tests/run_recovered_track_end_regression.sh
bash tests/run_foreground_recovery_regression.sh
```

## Pending qualification

⭕️ [Pending] Physical iPhone reproduction with the user's Music-managed non-DRM tracks and built-in speaker, including other-app takeover, explicit Play, background/lock screen, quality replacement and all repeat modes.

⭕️ [Pending] Mac listening on speakers/headphones/external DACs, real device/rate switches, sleep/wake at EOF, competing audio applications, MusicKit/account playback, long playback and callback delays under heavy UI/CPU load. Automated tests ran on the development Mac but were muted and used generated local files; synthetic notifications do not establish recovery from real hardware events. Ordinary true-peak activation remains subject to the existing separate device gate.
