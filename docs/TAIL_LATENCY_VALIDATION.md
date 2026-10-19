# Effect tails and latency-change protection — 2026-10-19

## Implemented behavior

🟢 [Done] CPU upsampling remains the shipping policy. No Metal backend, processing-rate change or new full-track buffer is introduced.

Space, Gloss, Body and Warm now gate **new input to the wet path** instead of immediately muting/resetting its delay and reverb when switched OFF. A shared control-thread envelope closes wet input over 24 ms, retains the existing wet state for another 160 ms, and fades the wet output over 240 ms. At 424 ms it reaches zero, clears history and bypasses the idle wet units. This is a bounded tail release, not preservation of an arbitrarily long cathedral decay. New dry audio continues to flow. Repeated OFF requests do not extend the release; ON/rebuild/stop invalidates old callbacks. Pause and destructive stop clear tail history only after the final output reaches silence; enabled wet levels are retained for resume.

Both apps compare algorithmic latency before and after a protected effect commit. If it changes, the output stays at zero for `max(old, new) + 10 ms`, bounded to 60 ms, before the existing 16 ms restoration. Unchanged latency adds no hold. The existing descent is 8 ms. Intentional echo/reverb predelay is **not** treated as dry-path latency. Intensity reaching zero (or Space amount reaching zero) is also a protected bypass boundary, even if the UI switch remains ON. Requests arriving during protection retain latest-request ownership; cancelled drain/restore callbacks cannot re-enable an obsolete setting.

Mac Warm now shares iPhone's direct unity bypass path and latency reporting. Flutter changes pitch without also modulating output gain. The desktop-specific main-run-loop/Sendable declaration is retained. Space/Gloss/Body implementations, the tail-gate body, and `EffectTransitionPolicy` are identical between repositories; Warm's DSP body is identical apart from that concurrency declaration/comment.

Mac's final sample limiter and −1 dB safety trim now remain active during user-effect bypass, matching iPhone's fixed safety stage. OFF no longer removes that stage's latency or restores its 1 dB gain while an old tail is still present. This intentionally changes the old Mac fully-bypassed level by −1 dB below limiting. User volume still controls the same output gain. This does **not** enable the optional final true-peak Audio Unit in ordinary builds.

## High-quality replacement and alignment

The existing iPhone replacement strategy remains: old/new players converge before one shared 96 kHz rack and use the old render clock to schedule new PCM. Retiring the old player must not reconnect or reset the rack. Preserving this strategy is preferable to duplicating reverb instances or applying an arbitrary offset to intentional spatial predelay.

🟢 [Done] The new offline audit covers **144 shared-rack handoff cases**, both channels:

- 44.1/48 kHz source; 44.1/48/96 kHz output.
- Shipping linear/minimum-phase/apodizing Sinc, master quality.
- Space and Gloss; continuous multitone and a burst that ends before replacement starts.
- Variable 127/256/384-frame render blocks and 4/20 ms control updates.
- Shipping Sinc kernels, slice helper and timeline policy; actual AVAudioEngine player/mixer/effect nodes. The old player is stopped after its fade, as in production.

Measured multitone correlation lag was **0 output samples** throughout the ±8-sample search; minimum correlation **0.97424**. This is integer-output-sample resolution, not a proof of zero fractional delay. Worst completed-waveform residual was **−12.865 dB**, reflecting SRC/filter phase differences rather than bit identity. Completed-window level difference remained **−0.02368 to +0.03846 dB**. Gates are ≤3 equivalent 96 kHz frames, correlation >0.9, multitone residual <−6 dB and level change <0.5 dB.

For the burst/tail probe, a <−70 dB residual against the unbroken shared-rack reference is required. All cases passed. Deliberately resetting rack tail history at handoff fails the residual check. These are linear Space/Gloss reference comparisons; they do not claim identical phase through nonlinear saturation, moving Flutter, or a different HRTF preset.

Mac has no equivalent custom prepared-Sinc swap. Its compatible track crossfade already shares the rack. The Mac controller overlap/pause tests and transition PCM audit verify that path separately; this report does not mislabel the iPhone Sinc experiment as a Mac production SRC benchmark.

## OFF, restart and transport verification

🟢 [Done] Compile the actual effect files from **each** repository and render 4 effects × 3 output rates, both channels. The audit verifies natural tail history during the hold, exact dry settling, repeated OFF and rapid OFF→ON. The held-tail residual is at most **−138.12 dB** against the natural-history reference. After release, the continuing-input output matches the dry reference exactly in the measured window (maximum error **0**); a silent input also settles to silence. The abrupt-tail-reset mutation is rejected in both repositories.

Reported active/off algorithmic latency in this environment: Space/Gloss/Body **0/0 ms**; Warm **0.5/0 ms**. Warm therefore receives **10.5 ms** of drain before restoration. That measures Apple's reported latency and verifies its use; it is not a calibration of every Audio Unit/device latency. The handoff correlation test above supplies a separate waveform-based alignment check.

🟢 [Done] Extracted iPhone production transition methods verify zero-strength bypass commits at zero output, a synthetic 7 ms old-latency case holding for 17 ms, restoration and cancellation of stale restore callbacks. Mac state tests exercise the same drain and cancellation, explicit OFF/ON, and zero-intensity/zero-Space-amount boundaries. iPhone pause freezes transition callbacks, defers new requests through descent, and settles the latest request only after silence. Existing iPhone DSP/coalescing and gain-reference regressions remain covered.

🟢 [Done] Mac's transition PCM matrix covers **96 cases** across ordinary/true-peak candidate output, basic/pro racks, 44.1/48/96 kHz, continuous controls, active/late overlap, OFF/restore and stop in either fade phase. It also asserts the final sample limiter/trim stay fixed. Three mutations reject unprotected commits, muting ordinary parameter gestures, and unsafe bypass. Tail timers use the same virtual control clock as transition callbacks for reproducible offline rendering.

The ordinary Mac run passed 28 tests in 5 suites; the candidate run passed 22 tests in 4 suites. The final effect-state suite passed 10 tests, including zero-strength boundaries; these counts overlap and are not a sum of unique tests.

Mac transport tests include actual controller overlap schedules and pause/drain, normalization-reference preservation, and ordinary/candidate final output. Existing iPhone transport tests verify that source/rack resources remain until silence and tail reset happens afterward; all six output-rate/direction PCM fade cases and their negative controls pass. The Simulator app and both desktop product targets are built with signing disabled.

## Scope and remaining work

- 🟠 [Next] Move the qualified control-thread transition envelopes toward an audio-thread/sample-accurate implementation, retaining these reference/residual and fault-injection gates. The current DispatchQueue mixer writes are not sample accurate and can bunch under UI stalls.
- 🔴 [Later] Extend reference coverage to simultaneous nonlinear effect changes, moving Flutter and changes between different headphone spatial/HRTF preparations. Consider a configurable longer natural tail only with bounded resource ownership and measured need.
- ⭕️ [Pending] Physical iPhone speaker/headphone and Mac/DAC listening: start/stop/resume, fast OFF/ON and strength-zero gestures, high-quality replacement, track crossfade, sleep/recovery and live route changes. Offline/simulator success does not prove click-free device output.
- ⭕️ [Pending] Real main-thread/UI contention, sustained CPU/thermal/energy behavior and tail timers during background suspension. Measure device-specific AU latency and whether the 60 ms maximum drain remains sufficient before extending support to longer-latency modules/routes.
- ⭕️ [Pending] Ordinary true-peak activation still requires device qualification. Its candidate regression results do not remove that gate.

## Reproduction and evidence

From the iPhone repository:

```sh
bash tests/run_tail_latency_regression.sh
bash tests/run_tail_latency_regression.sh --desktop
bash tests/run_effect_handoff_residual_regression.sh
bash tests/run_effect_latency_state_regression.sh
bash tests/run_dsp_transition_regression.sh
bash tests/run_transport_continuity_regression.sh
bash tests/run_quality_gain_reference_regression.sh
bash tests/run_desktop_effect_transition_regression.sh
```

Mac-specific tests are in `Tests/OngakuDesktopTests/EffectParameterTransitionTests.swift`, with transport/final-protection/controller regression suites in the same test target. The standalone harness needs macOS Audio Unit host access; a sandbox Audio Unit initialization failure is not a DSP assertion failure. No production audio output is needed by offline waveform audits; controller integration uses zero user volume.

See [measurement/check index and final source hashes](measurements/tail-latency-checks-2026-10-19.txt), [handoff waveforms](measurements/tail-latency-handoff-2026-10-19.txt), [iPhone tail waveforms](measurements/tail-latency-iphone-2026-10-19.txt), [Mac tail waveforms](measurements/tail-latency-mac-2026-10-19.txt), and [Mac transition matrix](measurements/tail-latency-mac-transitions-2026-10-19.txt). Both repositories carry identical reports and result files.
