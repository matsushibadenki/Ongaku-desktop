# Mobile session recovery — 2026-10-27

## Evidence and scope

The supplied screenshot shows `error.playback_session_failed` with the literal fallback `Session activation failed`. The explicit-play retry path used that fallback when no exception was captured, including an expired background lease or activation followed by an unconfirmed start. Therefore the screenshot alone does **not** establish an AVAudioSession setActive exception or implicate Transient DSP. No OS error domain/code or device logs were supplied; the actual device trigger remains unconfirmed.

## Changes

- 🟢 [Done] The explicit-play retry's local-file path now reschedules at the retained position using the existing protected seek, starts playback and awaits actual transport progress instead of sleeping 160 ms and trusting playing/engine flags. Accepted short-tail EOF goes through the existing track-end handler; successful local recovery restores automatic quality-upgrade and next-track preload scheduling.
- 🟢 [Done] Distinguish activation exceptions from unconfirmed playback. Only an activation exception uses the session-failure message. An unconfirmed start uses the localized start-failure message with a specific explanation (English/Japanese/Simplified Chinese). Clear stale attempt errors after a successful activation, and record attempt, session_activation/playback_progress stage, NSError domain/code and foreground status in logs. Exhausted confirmed failures leave the UI paused and stop its timer; a native stale playing flag with stalled render health cannot suppress the failure result.
- 🟢 [Done] Background lease expiry defers the still-current request rather than reporting a fabricated activation error. Foreground is allowed to continue after an expired background lease. A deferred request is considered on the next active notification only if pause/preparation tokens still match, no interruption is active, no activation task is running and other audio is not playing. Do not restart an obsolete song or reverse a user's pause. The first activation request also preserves this deferred intent when its lease expires before playback handoff.

This modifies the main iPhone application's recovery control path. Mac uses a different audio-session lifecycle and has no corresponding AVAudioSession activation branch to copy; shared DSP, limiter, effect defaults and ramp algorithms remain unchanged.

## Validation

- `tests/run_playback_transport_regression.sh`: PASS. New exhaustive Boolean cases distinguish activation/start failure, defer expired-background requests, suppress obsolete/confirmed requests and permit foreground recovery despite lease expiry. Existing pause/selection/interruption/cancellation and other-audio ownership policy checks remain passing. This is policy testing, not a live OS-session reproduction.
- `tests/run_transport_continuity_regression.sh`: PASS. Existing extracted shipping transport state checks, six stock-mixer PCM fade cases at 44.1/48/96 kHz and negative controls for abrupt start/stop and early teardown. This preserves evidence for the protected seek/start primitives, not end-to-end proof of the new asynchronous VM path under a real interruption.
- Main app iOS Simulator arm64 Debug build succeeds with signing disabled; diff whitespace checks pass. [Compact logs and source hashes](../measurements/session-recovery-2026-10-27/).
- ⭕️ [Pending] Physical iPhone reproduction: background/suspension and another app acquiring/releasing audio; foreground auto/explicit resume; lock-screen play; pause/new selection during pending activation; short tail/next/repeat, route changes and calls. Confirm audio progress, no false alert and no stale restart with the new stage/domain/code logs. The screenshot's original failure is not claimed reproduced in Simulator.
