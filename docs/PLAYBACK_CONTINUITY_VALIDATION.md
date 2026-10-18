# iPhone playback continuity — 2026-10-17

The user reports unexpected volume changes and plug-like clicks on the **iPhone built-in speaker**, especially start/stop and high-quality data replacement. The source review identifies abrupt player stop/rescheduling and late analysis changing shared gain/EQ as plausible contributors. These are code-path findings; the physical symptom has not yet been reproduced or confirmed resolved.

## Implemented

🟢 [Done] The current track keeps its gain reference across Precision Sinc and spatial PCM replacement, including the explicit absence of loudness measurement during native streaming. Prepared diagnostics remain available, but they no longer change normalization when an unrelated effect setting is later edited. A new load resets this reference.

🟢 [Done] A quality replacement keeps the currently applied automatic EQ. The new analysis is deferred until an explicit strength/voicing change, or a new fully prepared track load. This deliberately postpones automatic retuning during native-first playback; it does not discard the analysis or disable explicit tuning. Repeating an unchanged voicing selection does not activate deferred analysis.

🟢 [Done] Start/resume and seek use the final standard mixer for a nominal 24 ms, 48-step cosine envelope, independent of the effect bypass mixer/token. Startup waits for source frames to traverse the known pipeline latency. A pause immediately reports paused intent and freezes its reported position, while both handoff schedules continue through fade-out. Physical pause/seek rescheduling follows zero gain and a drain of at least 12 ms / two I/O buffers. Rapid resume cancels the pending physical pause and restores the existing schedule. If that schedule reached EOF during the fade, resume reschedules instead; EOF cannot override a pending pause/seek. Stop invalidates all old transport callbacks; seek-then-play keeps the pending seek destination.

The final transport gain only attenuates (0…1), including when the optional true-peak candidate is compiled. The existing standard source mixer and ordinary output protector remain in use; the previously unqualified custom handoff mixer/true-peak activation is not enabled by this change.

## Verification

| Check | Evidence |
| --- | --- |
| Production-method transport state fixture | 8 groups: render-gated startup, pause/drain/position, rapid resume, stop/new play, cancelled/paused seek, latest seek + immediate play, render timeout, EOF versus pause/seek |
| Actual standard mixer offline PCM | 6 cases, fade-in/out at 44.1/48/96 kHz, stereo DC +0.4/−0.2 to expose boundary discontinuities |
| PCM assertions | Finite output; silent startup before fade; zero after the pause drain; exact settled target; maximum adjacent change × rate <25 amplitude units/second |
| PCM observed maximum adjacent changes | 0.0003630072 at 44.1 kHz; 0.00033335388 at 48 kHz; 0.00016669929 at 96 kHz |
| Negative PCM control | Abrupt source start/stop rejected. Merely assigning mixer volume is not a valid hard-cut control: the standard mixer itself interpolates volume |
| Actual gain law | Measured and unmeasured references remain stable across quiet/hot replacement analysis; explicit DSP adjustment can adopt deferred analysis; new-track reference resets. Replacing the gain reference is rejected by a negative control |
| Existing iPhone regression | 48 effect/DSP and 72 analysis/gain/loudness cases, with existing negative controls |
| iPhone Simulator / build | 17 production-engine checks pass, including future-start and active quality-overlap pause/resume; ordinary Debug Simulator app build succeeds, signing disabled |
| Mac coordination | Byte-identical shared `EffectTransitionPolicy`; 19 focused transition/output/fidelity tests pass |

The transport state fixture extracts shipping play/pause/seek/ramp methods and virtualizes only transport/session state and timer deadlines. Its PCM companion extracts the same ramp method and renders a real `AVAudioEngine` standard mixer. Timers are advanced deterministically; this does not simulate main-thread congestion or a physical device clock.

The Simulator audit uses the production iPhone engine, local audio fixtures and standard audio units. It checks pause/resume/seek races and unchanged gain/EQ through actual quality replacement. Its local `AVAudioPlayer` stand-in cannot validate Music daemon ownership or a physical output route. Precision Sinc preparation may exceed the 20-second fixture: only a confirmed EOF deferral allows one cached retry after seeking back.

[Captured verification results and source hashes](measurements/playback-continuity-checks-2026-10-17.txt).

## Reproduce

From the iPhone repository (Audio Unit and Simulator access require the normal host environment):

```sh
bash tests/run_transport_continuity_regression.sh
bash tests/run_quality_gain_reference_regression.sh
bash tests/run_dsp_transition_regression.sh
bash tests/run_dsp_transition_regression.sh --gain-path
bash tests/run_native_first_simulator_audit.sh <installed-simulator-UUID>
```

From the Mac repository:

```sh
swift test --filter 'EffectParameterTransitionTests|FinalOutputProtectionTests|M4AudioPathMilestoneTests|AudioFidelityPolicyTests'
```

## Open work

🟢 [Done] Destructive stop/load/recovery now drains before releasing resources and sessions. See the superseding [2026-10-18 shutdown implementation and verification](DESTRUCTIVE_STOP_VALIDATION.md); the verification table above records the earlier pause/seek scope.

🟠 [Next] Qualify sample-accurate handoff, signal alignment and effect tails. Apply the same criteria to Mac transport and its late album-analysis gain updates; sharing the policy does not implement the iPhone transport path on Mac.

⭕️ [Pending] Listen on the affected physical iPhone built-in speaker at several system volumes, with effects ON/OFF and native/Precision Sinc sources. Exercise start/pause/resume/seek, early and active quality overlap, rapid gestures, UI contention, route changes and memory recovery. Verify clicks, perceived level, render gaps, thermal/CPU/energy behavior and effect tails. Repeat applicable tests on Mac and external outputs. Offline/Simulator success is not proof of inaudibility or resolution of every reported event.
