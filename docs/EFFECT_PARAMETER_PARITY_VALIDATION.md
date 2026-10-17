# Effect parameter continuity across iPhone and Mac — 2026-10-17

> Historical checkpoint before bypass protection. Current ON/OFF behavior and the expanded regression matrix are documented in [Mac bypass protection](EFFECT_BYPASS_PROTECTION_VALIDATION.md). The immediate-bypass statements and OFF/restore measurements below describe that earlier checkpoint.

## Priority and scope

Both roadmaps were reviewed after final-output true-peak integration. Physical output qualification remains pending. The next audio improvement selected was the desktop's immediate parameter writes: iPhone already interpolated continuous controls, while Mac applied each slider value directly to the Audio Units. Aligning this existing playback behavior takes priority over new acoustic profiles or nonlinear oversampling. Desktop A3/A4 library/search/transfer work remains on its existing roadmap; it is not marked complete by this change.

🟢 [Done] Both apps now compile byte-identical `EffectTransitionPolicy.swift`: eight updates, nominally 10 ms apart, and the same interpolation from the last applied parameter values toward the latest target. iPhone's interpolation math and timing are preserved. These are control-thread updates, not sample-accurate Audio Unit ramps.

🟢 [Done] Mac continuous controls now coalesce requests into one active sequence. A gesture passing through an intermediate applied value does not restart that sequence. Each commit writes only changed modules and updates the legacy output-protection enable state only when the rack's enabled state changes. Continuous controls do not alter source scheduling, source volume, the output-volume envelope, source files or true-peak activation.

🟢 [Done] Mac applies effective OFF intent before accepting a target. Disable/OFF, pause/stop/seek and graph rebuilds invalidate older callbacks. Stopped playback applies the latest settings immediately; rebuilding reapplies rate-dependent settings even when the requested values are unchanged. Continuous changes hold while the scheduled song crossfade is in progress, keeping both sources on the same shared rack settings. Future preroll alone does not block controls.

Existing enabled-state changes are still immediate on Mac. iPhone retains its existing short protected bypass commit. The new desktop coalescer does **not** establish inaudible ON/OFF switching, compensate effect latency changes or replace those bypass paths.

## Verification

| Check | Result |
| --- | --- |
| Mac full-rack PCM continuity | 48/48 cases pass: 24 ordinary, 24 true-peak qualification |
| Continuous controls / overlap, minimum 10 ms RMS ratio | 0.941728 of the lower reference/settled level; acceptance floor 0.1 |
| OFF/restore, minimum 10 ms RMS ratio | 0.275562; output envelope stays at 0.67, but this is not an inaudibility result for bypass |
| Maximum protected reconstructed peak | 0.143036 on these quiet continuity fixtures; below the −1 dB gate |
| Negative controls | Immediate parameter writes and forced muting are both rejected |
| Mac state-machine tests, ordinary build | 4/4 pass: coalescing, old-callback rejection, inactive-only edits, overlap/pause |
| Mac integrated tests, true-peak enabled | 14 tests in 4 suites pass, including final stage, rate policy and source-file preservation |
| iPhone effect/automatic-DSP continuity | 48/48 cases and immediate-write/mute controls pass |
| iPhone gain/loudness continuity | 72/72 cases; immediate-write, duplicate-gain, inactive-gain and mute controls pass |
| iPhone meter integration | Both store implementations pass freshness/reordering/convergence checks and reject the stale-meter fault; 3 quick continuous HRTF/nonlinear/latency cases pass with zero source/processed null error |
| Builds | iPhone Debug Simulator and both ordinary Mac Debug products (`OngakuDesktop`, `OngakuDesktopAppStore`) pass, signing disabled |

[Full Mac waveform measurements](measurements/mac-effect-parameter-continuity-2026-10-17.json) and [test/build summary](measurements/effect-parameter-parity-checks-2026-10-17.txt).

The state test initially caught a gesture crossing the currently applied intermediate value: it cancelled/restarted the active sequence. Coalescing now takes priority over equality with that intermediate value, matching iPhone's existing behavior; the latest-target/eight-tick test passes. The OFF/restore level variation remains evidence for the next bypass-protection task, not grounds for claiming all switching is transparent.

The Mac waveform runner compiles the real registry, effect modules, final-output stage and `EffectParameterTransition`. It extracts `PlaybackController`'s actual update/commit adapter and its crossfade deferral predicate. Only the control clock and transport shell are virtualized. Extraction also checks that parameter/reset/OFF entry points use this adapter, stop cancellation occurs after both players stop, and graph rebuilds force reapplication. Unit tests cover the live scheduler's state machine through an injected clock; the tests do not exercise physical main-queue load.

Waveform coverage uses a 96 kHz stereo four-tone input and 44.1/48/96 kHz final output, both Basic and Pro racks, and ordinary/true-peak qualification paths. Scenarios include superseded targets, 40 successive gesture updates, two-player complementary overlap, and OFF/edit/restore. Checks require latest-target settlement, exactly eight control ticks for coalesced changes, no writes during overlap, no enabled writes during OFF, unchanged non-unity output volume (0.67), finite output and every 10 ms RMS window above one tenth of the lower reference/settled level. The protected cases also check the same −1 dB reconstructed ceiling. These quiet-signal continuity probes supplement the existing adversarial peak matrices; they do not replace those overload tests.

Two intentional faults must fail: applying continuous parameters immediately, and muting the output during a parameter update. The Mac state tests also cover inactive-only edits, rapid OFF/restore, cancel/restart before an older timer fires, forced reapplication and pause during a deferred update.

## Reproduce

From `Ongaku`, with adjacent `Ongaku-desktop` (or set `ONGAKU_DESKTOP_ROOT`):

```sh
bash tests/run_desktop_effect_transition_regression.sh /private/tmp/mac-continuity.json
bash tests/run_dsp_transition_regression.sh
bash tests/run_dsp_transition_regression.sh --gain-path
bash tests/run_meter_delivery_regression.sh
```

The desktop runner first compares the shared transition policy and the existing true-peak sources byte-for-byte. Its adapter extractor fails if the production entry points no longer use the tested update path.

From `Ongaku-desktop`:

```sh
swift test --filter 'EffectParameterTransitionTests|FinalOutputProtectionTests|M4AudioPathMilestoneTests|AudioFidelityPolicyTests'
swift test -Xswiftc -DONGAKU_ENABLE_TRUE_PEAK \
  --filter 'EffectParameterTransitionTests|FinalOutputProtectionTests|M4AudioPathMilestoneTests|AudioFidelityPolicyTests'
```

## Next and pending

🟢 [Done] Superseded by [bypass protection](EFFECT_BYPASS_PROTECTION_VALIDATION.md): protect Mac enable/disable and OFF/restore commits with a validated short envelope or crossfade, including changes to latency/topology and interactions with song overlaps. Preserve saved settings, latest-target handling, cancellation and final-output protection. Match iPhone's documented behavior before pursuing more complex ramps.

🔴 [Later] Sample-accurate parameter/bypass ramps on both platforms, with latency-aware waveform comparisons and residual/alias analysis before introducing nonlinear oversampling.

⭕️ [Pending] Physical iPhone/Mac listening while rapidly dragging controls, switching OFF/restore, seeking and changing songs; main-queue contention, long-running CPU/energy behavior and actual device clock/tap timing. No claim is made that nominal 10 ms callbacks remain punctual under real UI/thermal load or that every parameter change is psychoacoustically transparent. Ordinary true-peak activation remains pending the separate device gates.
