# Foreground playback recovery — 2026-10-19

Update 2026-10-19: Mac transport and late-analysis protection is now implemented; see [Mac parity verification](MAC_TRANSPORT_PARITY_VALIDATION.md). Earlier verification and implementation scope below remain historical; remaining shared Next work is latency-aligned handoff/bypass residual and tail qualification.

## Report and scope

The user reports that playback sometimes remains silent after another app takes audio and Ongaku returns to the foreground, while the button still indicates playing. The user confirmed **non-DRM songs managed by Music**, and that **the other app had already stopped audio before returning**. These songs can use Ongaku's local AVAudioEngine with a retained Music asset identity. The physical incident is not yet reproduced; the paths below were identified in code and tested with controlled fixtures.

## Implemented

- 🟢 [Done] Reconcile local playback before foreground state refresh can overwrite pre-suspension playing intent. A stopped engine or stalled render with stale running flags becomes a guarded recovery request, retaining the track and current position.
- 🟢 [Done] If an interruption-end notification is missing, allow a foreground activation attempt only for the original playing request, with unchanged pause/selection tokens and no other audio reported. The OS still arbitrates activation. Foregrounding never overrides an explicit pause, track change, or another app's continuing audio.
- 🟢 [Done] Rebuild the retained schedule through protected seek/start, and confirm at least 20 ms of fresh source-position progress after seek/fade completion within a bounded 1.5-second check. An old render timestamp or playing flag alone no longer confirms local recovery. Pause, stop, cancellation and superseding transport invalidate the check.
- 🟢 [Done] Keep app/Now Playing observations paused while local interruption recovery is unconfirmed or render is stalled. Exhausted recovery pauses the engine and preserves intent for a later foreground/route retry. Unexpected render-stop recovery also observes other audio ownership and fresh progress. Explicit play can retry a stalled graph instead of accepting its stale playing flag.

The system Music player still owns DRM/system playback. This update does not take over that session or modify the Mac audio runtime. There are no new UI strings or layout changes.

## Verification

| Check | Result |
| --- | --- |
| Extracted production foreground/state/recovery methods | 10 groups pass: intent before refresh, stale running flags, missing end, other audio, pause/selection fencing, healthy/system ownership, confirmed recovery, exhausted recovery with retry, fresh versus frozen position, cancellation/superseded transport |
| Negative control | Deliberately refreshing UI state before capturing intent fails the original-intent assertion |
| Production engine on iPhone 16 Pro Max Simulator | 5 groups pass: native startup; paused render I/O rejection; reactivation/rescheduling with position and Music ID retained; newer pause cancels confirmation; explicit resume and destructive stop after recovery |
| Existing transport policy | 14 groups pass |
| Session queue | 7 groups pass |
| Render monitoring | 6 groups pass, including actual observer installation/removal and observer-on/off PCM equivalence |
| Existing fade/drain continuity | 11 state groups and 6 stock-mixer PCM cases at 44.1/48/96 kHz pass; hard start/stop and premature teardown negative controls are rejected |
| Ordinary iPhone app | Final Debug iOS Simulator build passes, signing disabled |

The method fixture extracts shipping foreground reconciliation, playback-state observation, interruption recovery and progress-wait logic. OS/session/player collaborators are mocked; recovery exhaustion uses the real bounded retry delays. The Simulator audit uses the production engine and local CAF PCM with an `ipod-library` logical identity, then pauses render I/O. It does not read a real Music library or reproduce another app's session ownership. The final ordinary build additionally includes the terminal cancellation guard for unexpected recovery.

[Captured results and source hashes](measurements/foreground-recovery-checks-2026-10-19.txt).

## Reproduce

From the iPhone repository, with host Audio Unit / Simulator access:

```sh
bash tests/run_foreground_recovery_regression.sh
bash tests/run_native_first_simulator_audit.sh <simulator-UUID> --foreground-recovery
bash tests/run_playback_transport_regression.sh
bash tests/run_audio_session_queue_regression.sh
bash tests/run_render_health_regression.sh
bash tests/run_transport_continuity_regression.sh
xcodebuild -project Ongaku.xcodeproj -scheme audio -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

## Device acceptance

⭕️ [Pending] On the affected iPhone, play the same Music-managed non-DRM song, let another app take audio, stop that app's audio, and foreground Ongaku. Verify retained track/position, resumed sound and matching button/Now Playing state. Repeat with long background suspension, calls, route changes and UI load. Pause or select another song during recovery and confirm that the old request never resumes. Also verify that continuing audio in another app is not taken over.

Use `audio.foreground.reconcile missing_end=true` / `stale_playing=true`, `audio.interruption.resume ready=true/false`, and `audio.local.recovered/recovery_failed` to distinguish captured intent, actual progress confirmation and failed attempts. Do not label the physical symptom resolved solely from the Simulator or mocked ownership checks.

🟠 [Next] The existing Mac transport/late-analysis parity and latency-aligned handoff/tail measurement work remains next. Hardware-dependent iPhone confirmation stays Pending.
