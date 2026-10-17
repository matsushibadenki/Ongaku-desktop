# Mac ON/OFF protection and iPhone parity — 2026-10-17

## Implemented behavior

🟢 [Done] Mac protects audible module enable/disable and global OFF/restore with the iPhone envelope policy: nominal 8 ms logarithmic descent, commit at zero gain, then nominal 16 ms recovery without a silent holding plateau. Both apps compile byte-identical policy source, including the step count, logarithmic floor and exact terminal gain. iPhone keeps its existing transition and transport architecture; its endpoint now lands exactly on the requested gain.

🟢 [Done] The Mac final stage multiplies the current user volume by a separate transition gain. Changing volume during protection cannot restore a stale user setting. In the true-peak candidate, both gains stay before the protector and the downstream mixer stays at unity. Ordinary builds still use the existing sample-based path; this change does not activate true-peak by default.

🟢 [Done] The coordinator keeps the latest complete effective rack, including OFF intent. Requests during descent coalesce into the protected commit. Requests during recovery are processed after recovery, using another protected commit if the enabled state changes. Continuous parameters retain eight-step interpolation and unchanged-module filtering; disabled-only edits do not initiate an audible fade.

🟢 [Done] Scheduled song overlaps reserve the nominal 24 ms protection window before their start. The shared rack remains unchanged during overlap. New crossfade preparation waits while a protection ramp is active and is retried by the regular playback tick. If a previously scheduled overlap becomes imminent during descent, the coordinator aborts the descent, restores gain and retries the latest settings after overlap. Recovery is never held at zero waiting for a song transition.

🟢 [Done] Stop/pause/seek and graph reconstruction invalidate previous callbacks, restore transition gain to one and apply the current effective settings while the player nodes are stopped. The existing stopped-engine lookahead reset remains in place for the true-peak candidate. Compatible song handoffs retain their shared DSP state.

## Verification

| Check | Result |
| --- | --- |
| Mac offline waveform matrix | 96/96 pass: 48 ordinary and 48 true-peak candidate |
| Negative controls | All 3 rejected: immediate continuous writes, forced continuous mute, unprotected bypass |
| Mac focused tests, ordinary / true-peak builds | 19/19 pass in each build, including 8 transition-state tests |
| iPhone effect and automatic-DSP regression | 48/48 pass, including OFF/restore, handoff and stop cancellation; negative controls pass |
| iPhone analysis/gain/loudness regression | 72/72 pass for both channels; all negative controls pass |
| Continuous-only minimum 10 ms RMS ratio | 0.941728, above the 0.1 acceptance threshold |
| Maximum reconstructed peak, protected quiet fixtures | 0.143036, below the −1 dB gate |
| Builds | iPhone Debug Simulator, Mac Debug and Mac App Store Debug succeed, signing disabled |

[Full waveform measurements](measurements/mac-effect-bypass-protection-2026-10-17.json) and [test/build summary](measurements/effect-bypass-protection-checks-2026-10-17.txt).

The transition-window RMS minimum reaches zero for stopped candidate playback, and drops below the continuous-control threshold during deliberate bypass attenuation. These are recorded as expected behavior, not presented as transparent switching. All tested paths recover to the latest settings and user volume.

The Mac waveform harness compiles the real effect registry/modules, final-output stage and coordinator. It extracts the production controller's transition adapter, commit implementation and `stopPlayerNodes` implementation. The scheduler and transport shell are virtualized; the preroll preparation guard and entry-point wiring are checked by extraction. This is not an end-to-end live file-preroll or physical-clock qualification.

The matrix uses Basic/Pro, 44.1/48/96 kHz outputs, ordinary/true-peak paths, and eight scenarios: continuous coalescing, repeated gestures, continuous updates during overlap, OFF/edit/restore, OFF during overlap, overlap beginning during descent, stop during descent and stop during recovery. Both player nodes render through the real common rack. Stop/resume cases execute the extracted stop method and reschedule PCM buffers after applying the latest stopped-state settings.

Assertions require audible bypass commits at zero control gain, latest-target settlement, no rack changes during overlap, no stale enabled writes while OFF, recovery to non-unity user volume 0.67, a unity post-protector mixer, finite PCM and the existing −1 dB reconstructed-peak gate on protected cases. Continuous-only cases retain the 10 ms RMS dropout threshold throughout the transition. Protected bypass intentionally attenuates the signal, and stopped playback can be silent: their transition-window RMS minima are measurements, not dropout failures. Their recovered audio must pass the RMS threshold after 360 ms. The quiet fixtures supplement the existing overload matrix; they do not establish new hot-signal headroom or inaudibility.

Intentional faults must be detected: immediate continuous writes, muting during continuous gestures, and audible bypass commits without zero-gain protection. State tests additionally cover latest requests during recovery, late-overlap abort/retry, both stop/rebuild phases, natural completion and preservation of user-volume changes.

## Reproduce

From `Ongaku` with adjacent `Ongaku-desktop` (or `ONGAKU_DESKTOP_ROOT`):

```sh
bash tests/run_desktop_effect_transition_regression.sh /private/tmp/mac-bypass.json
bash tests/run_dsp_transition_regression.sh
bash tests/run_dsp_transition_regression.sh --gain-path
```

From `Ongaku-desktop`:

```sh
swift test --filter 'EffectParameterTransitionTests|FinalOutputProtectionTests|M4AudioPathMilestoneTests|AudioFidelityPolicyTests'
swift test -Xswiftc -DONGAKU_ENABLE_TRUE_PEAK \
  --filter 'EffectParameterTransitionTests|FinalOutputProtectionTests|M4AudioPathMilestoneTests|AudioFidelityPolicyTests'
```

## Remaining work

🟠 [Next] Add latency-aligned reference/residual measurements around bypass, especially Space/Gloss/reverb tails, to define the acceptance criteria for sample-accurate protection. This envelope does not compensate algorithm latency or drain every effect tail.

🔴 [Later] Replace control-thread ramps with validated sample-accurate ramps on both platforms; evaluate residual/alias behavior before nonlinear oversampling.

⭕️ [Pending] Physical iPhone/Mac listening for OFF/restore clicks and short attenuation, rapid repeated toggles, real file crossfade timing, pause/resume/seek and effect tails. Also confirm behavior under main-queue/UI contention, device rate/route changes and sustained CPU/energy/thermal load. Nominal 8/16 ms callbacks and zero control gain are not a guarantee of sample-accurate silence or perceptual transparency under live load. Ordinary true-peak activation remains pending its existing device gates.
