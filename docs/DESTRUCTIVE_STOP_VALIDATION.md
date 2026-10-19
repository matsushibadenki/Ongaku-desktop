# Destructive playback shutdown — 2026-10-18

Update 2026-10-19: Mac transport and late-analysis protection is now implemented; see [Mac parity verification](MAC_TRANSPORT_PARITY_VALIDATION.md). Earlier verification and implementation scope below remain historical; remaining shared Next work is latency-aligned handoff/bypass residual and tail qualification.

## Implemented scope

🟢 [Done] iPhone destructive stop, new track loading and quality/recovery reload now share the final-mixer transport envelope: nominal 24 ms / 48 cosine steps followed by a silent drain of at least 12 ms or two session I/O buffers. Stop reports stopped intent immediately, but retains the active file/PCM and both quality-handoff schedules until the graph is paused at zero output. Only then are schedules, DSP state and gain references reset.

🟢 [Done] Preparation/playback generations invalidate old work immediately. Repeated stops share one drain; the newest request owns session cleanup. New loads await that drain and reject stale generations. A task cancelled before entering load cannot stop the currently audible source; cancellation during the wait cannot strand the cleanup. Play/seek and quality replacements cannot interrupt destructive teardown.

🟢 [Done] Session deactivation, provisional Music-session cleanup and release to Music follow the local drain. Existing session queue and owner checks protect newer activation. A pause received during a quality/recovery reload prevents its automatic resume. Ordinary same-track seamless upgrade gain/EQ preservation remains in place.

Mac runtime transport is unchanged in this step. Both roadmaps record the same completed iPhone scope and outstanding Mac acceptance criteria. The shared `EffectTransitionPolicy.swift` remains byte-identical.

## Verification

| Check | Result |
| --- | --- |
| Shipping-method transport fixture | 11 state groups pass, including retained resources, coalesced stops, latest cleanup ownership and superseded load generations |
| Actual standard-mixer PCM | 6 stereo fade-in/out cases at 44.1/48/96 kHz pass; fade-out physically stops the source after the drain |
| PCM limits | Finite PCM, settled gain, silence after drain, maximum adjacent change × sample rate <25; observed maxima 0.0003630072 / 0.00033335388 / 0.00016669929 |
| Negative controls | Abrupt source start/stop and deliberately early resource teardown are both rejected |
| Final production-engine Simulator audit | 6 groups pass: retained file/session ordering, competing load/loadOpenedFile, pre-cancelled load, cancellation during drain, newer pause during reload, and both schedules during quality overlap |
| Existing native-first coverage | All 17 existing checks passed, including Precision Sinc, cache, gain/EQ and overlap pause/resume; that run also included 5 early shutdown checks before their extraction into the dedicated audit |
| Gain-reference regression | Measured/unmeasured quiet/hot upgrade references pass; intentional late-analysis gain replacement is rejected |
| Session queue regression | 7 checks pass, including ordered release, cancellation, failures and stale provisional ownership |
| Existing DSP/gain regression | 48 effect/DSP and 72 analysis/gain/loudness cases pass, including existing negative controls |
| Ordinary iPhone app | Final Debug iOS Simulator build succeeds with signing disabled |

The final dedicated audit uses the production engine on the iPhone 16 Pro Max Simulator. Its prepared handoff uses AVAudioConverter to exercise the same two-player handoff path quickly; actual Precision Sinc coverage comes from the broader native-first run on SE (3rd generation). The broad run preceded the final pre-cancelled-load guard and final cleanup refinements; the six-case dedicated audit and ordinary build were rerun against the final source.

The state fixture virtualizes scheduling/session state. PCM renders a real stock mixer with deterministic timer advancement and stereo DC input. Neither proves timing under main-queue congestion, Music daemon behavior, physical output-buffer latency or audible click removal. No new Mac runtime tests are claimed for this documentation-only coordination.

[Captured results and final source hashes](measurements/destructive-stop-checks-2026-10-18.txt).

## Reproduce

Run from the iPhone repository with host Audio Unit / Simulator access:

```sh
bash tests/run_transport_continuity_regression.sh
bash tests/run_quality_gain_reference_regression.sh
bash tests/run_audio_session_queue_regression.sh
bash tests/run_dsp_transition_regression.sh
bash tests/run_dsp_transition_regression.sh --gain-path
bash tests/run_native_first_simulator_audit.sh <simulator-UUID> --destructive-stop
bash tests/run_native_first_simulator_audit.sh <simulator-UUID>
xcodebuild -project Ongaku.xcodeproj -scheme audio -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

## Remaining work

🟠 [Next] Apply independent transport protection and stable late album-analysis gain behavior to Mac. Qualify signal alignment and handoff/tail behavior with latency-aligned reference/residual measurements, including Space/Gloss/reverb.

⭕️ [Pending] Confirm stop/start/track changes, quality replacement and memory recovery on the affected physical iPhone built-in speaker. Include rapid operations, several system volumes, effects, Music session transfers, route changes and UI load. Validate perceived loudness/clicks, render gaps and CPU/thermal/energy behavior; repeat applicable listening on Mac/external outputs. Do not interpret the nominal control-thread envelope as sample-accurate protection or guaranteed inaudibility.
