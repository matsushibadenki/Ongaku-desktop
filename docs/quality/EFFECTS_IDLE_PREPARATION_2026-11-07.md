# Effects idle preparation — 2026-11-07

## Diagnosis and limits

The supplied physical-iPhone log records a 400.8 ms render-observer gap and a 434.8 ms meter-delivery gap after Effects navigation, with Speaker output and effects=none. The quality worker had already ended before the gap. Its elapsed=2.06 is total lifetime, not cancellation latency. Consequently, cancellation alone did not resolve this case, and later user effect-mode changes cannot explain the initial gap.

Code inspection found that the retained tab container still creates the real Effects UIHostingController, SwiftUI tree and native controls on its first visit. Retaining a page only helps subsequent visits. Hidden Effects also continued publishing presentation invalidations. Two diagnostic getters accessed the lazy playback engine when the page read them. These are concrete avoidable initialization/update paths, but **no captured physical-device stack proves which caused the 401 ms interruption**. Framework/allocator contention and first-layout work remain hypotheses, not measured root causes.

## Changes

- Prepare the actual Effects hosting controller after 750 ms on the active Now Playing page, only while local playback is idle and loading, recovery, scanning, authorization and effect preparation are absent. Recheck current readiness immediately before mounting. Cancel a queued warm-up on navigation, backgrounding/readiness changes or teardown. Keep the visible host, selection and navigation state; temporarily mount the candidate behind it, without interaction/accessibility, then retain it for a normal visit.
- If playback is already running before the first eligible idle interval, skip warming. This deliberately leaves that cold first-visit case unmitigated by prewarming; existing presentation preflight still applies. Synchronous UIKit layout cannot be preempted by a new tap that arrives after the final guard. This is not a hard real-time UI guarantee.
- Stop Effects presentation notifications while hidden and deliver one deferred catch-up on reactivation. Coalesce rapid reactivation, preserving existing default behavior for other consumers. Guard diagnostic getters so idle UI reads do not initialize the lazy engine.
- No DSP, gain, sample-rate, protection, tail, transport or sync protocol changes. Mac runtime code is unchanged; both ROADMAPs share the same evidence and limits.

## Successful verification

- Shipping idle predicate extracted into a controllable fixture plus actual CoalescedViewUpdates: 2 groups PASS. Covers playing/loading/recovery/background/system states, cold engine access, hidden publications, visible batching and reactivation.
- Existing effect observation 4 groups, presentation/preflight 4 groups and navigation observation 6 groups PASS: **16 groups total**, not 16 full-app audio tests.
- Actual UIKit retained-container Simulator audit PASS: retained state and paths, appearance lifecycle, no native tab bar, idle warm-up, late-playing rejection, preservation of current host, warmed-state reuse, navigation and explicit teardown cancellation. This generic host audit does not reproduce the whole Effects UI or output waveform.
- Ordinary mobile Debug Simulator Xcode build PASS, signing disabled. No new product change was made after that final build. Mac runtime/build and the broad DSP matrix were not rerun for this mobile UI-only patch.

## Unqualified full-app audio experiment

An opt-in generated-CAF/full-ContentView audit was added in tests/run_effects_switch_playback_audit.sh and EffectsSwitchPlaybackAuditApp.swift. It uses an isolated bundle, actual local playback engine and render callback counter. The test copy excludes Music authorization/library/remote-command/Now Playing metadata backends and supplies the active SwiftUI scene environment; it is not a production-account or signed-device test. A foreground assertion is required for valid samples.

Early attempts displayed a Music permission dialog; their apparent first-visit timings are rejected as foreground comparison evidence. Foreground-checked attempts did not complete a valid pair, including after restarting the dedicated Simulator (cold/warm timeout). This environment could not control that Simulator permission UI through the available computer-use surfaces. No cold/warm performance improvement or absence of output gaps is claimed from these attempts. One screenshot and final failure logs are retained for this limitation. The harness remains opt-in and is not a passing CI gate.

## Pending

⭕️ [Pending] On a physical iPhone speaker, capture first/repeated Effects transitions with playback started both before and after idle preparation, OFF/BASIC/Pro, interruption/resume and short rapid taps. Collect System Trace/Time Profiler stacks for render, UI initialization/layout, allocator and workers, cancellation latency and actual output waveform. Confirm idle preparation never changes settings, starts playback or steals focus. The original 400.8 ms root cause and audible resolution remain unconfirmed.

⭕️ [Pending] Complete a foreground-qualified full-app comparison without permission overlays; measure first layout, peak memory and retained-page cost on narrow/large iPhones. Verify signed-device accessibility, lifecycle, thermal/load behavior and layout. The generic UIKit test and successful build do not establish these results.

[Evidence](../measurements/effects-idle-preparation-2026-11-07/).
