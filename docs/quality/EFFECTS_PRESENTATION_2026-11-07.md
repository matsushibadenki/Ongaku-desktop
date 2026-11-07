# Effects-page presentation noise mitigation — 2026-11-07

## Evidence and scope

The user reports a noise exactly when pressing the iPhone Effects navigation button. Their latest log shows Precision Sinc work in flight at navigation, but no render-gap event. The monitor's threshold is max(350 ms, four expected callback intervals), so absence of that event does not exclude a short dropout or a waveform click. No source waveform/physical-device trace has established a single root cause. The page-active path only schedules meter auditing; no effect-setting write was found in that presentation path.

The navigation binding now calls prepareForEffectsPresentation BEFORE changing the selected tab. It requests cancellation of only the current quality-upgrade task and the following-track cache task, clears their handles and reserves at least two seconds of quiet time for presentation. Cancellation is cooperative; this does not prove that a worker stops before the first frame. It deliberately does not call the broad optional-work cleanup, cancel system-asset recovery, flush prepared caches, stop/rebuild the audio graph or change effect mode/settings. The preflight itself publishes no view state. A diagnostic event `audio.optional_work.deferred reason=effects_presentation minimumDelayMs=2000` is emitted before the navigation log when local playback has initialized the engine.

Presentation is idempotent: the button preflight and subsequent onChange do not repeatedly cancel work or reset the audit timer. Programmatic navigation/foreground presentation has the same fallback through setEffectScreenActive. Leaving resets the one-presentation guard. The deadline uses max(existing, now+2), so the prior 30-second render-gap backoff cannot be shortened. The existing watchdog now resumes deferred work only after deadline expiry with both VM and engine playing; expired deadlines remain pending while paused. It restores a missing following-track preload after starting current-track quality work. The existing preload waits for the current upgrade before conversion; an already present preload is preserved.

## Verification

- The shipping preflight, page-active method and deferred-resume method are extracted verbatim into a small MainActor fixture. Real Swift Task handles, controlled source/engine state and timer/scheduling stubs verify four groups: cancellation before activation/idempotence; re-entry and longer cooldown preservation; native-Music/cold-engine exclusions; paused/stopped-engine gating plus one-shot retry and existing-preload preservation. A source-boundary check verifies that the real tab binding invokes the preflight before assigning selection and that the tab bar uses that binding.
- `bash tests/run_effect_presentation_regression.sh`: all four groups PASS.
- iPhone `audio` scheme Debug Simulator signing-disabled Xcode build: PASS on the final code. The earlier build before the retry helper is retained as intermediate evidence, not a separate final qualification.
- These fixtures isolate state/order and do not render the actual SwiftUI screen, emulate worker cancellation latency, or prove unchanged audible PCM during a real tap. No Mac build or DSP regression was rerun because this change is iPhone presentation/task scheduling only. Both ROADMAPs record the same scope; common audio algorithms and formats are unchanged.

⭕️ [Pending] Repeat the exact Effects-button operation on the physical iPhone speaker, including first/second page entry, current/next conversion running, cancelled-worker latency, mode controls, pause/resume and foreground return. Confirm the deferred-work log precedes navigation, playback stays continuous and quality/preloading later recover. The user's reported noise is NOT marked resolved by fixture/build success. A noise persisting with optional work already absent requires further device tracing of UI/render scheduling or waveform discontinuity. Actual 88.2 kHz Mac issues remain separate Pending items.

[Logs and source hashes](../measurements/effects-presentation-2026-11-07/).

## Follow-up: remaining UI invalidation load

[Telemetry isolation](EFFECTS_TELEMETRY_ISOLATION_2026-11-07.md) removes broad model observation from the Effects page. The earlier preflight remains active. This addresses a separate remaining load contributor; physical waveform/click and first-mount qualification remain Pending.
