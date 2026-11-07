# Effects page telemetry isolation — 2026-11-07

## Remaining cause and limits of the previous mitigation

The iPhone Effects page still used `@ObservedObject AudioPlayerViewModel`. Every VU/RMS/peak, spectrum and transport-time publication therefore invalidated its full rack, even though the controls do not read those values. Retaining the hosting controller keeps page identity; it does not remove that model subscription. The previous pre-navigation cancellation of optional conversion work and two-second quiet deadline did not change this UI invalidation path. First mounting the controls also remains a cost.

This is a confirmed unnecessary notification path in source and the production publisher-selection fixture. It is a remaining scheduling-load contributor, **not an established waveform-level root cause of the user's audible noise**. No new physical iPhone trace has been collected, and lack of a render-gap event cannot rule out a short click.

## Change

EffectsTabContent now owns a CoalescedViewUpdates observer for 21 explicitly selected effect/settings/readiness/diagnostic publications. The player is a plain reference for bindings/actions; the page no longer subscribes to all its objectWillChange events. VU, spectrum, RMS/peak and elapsed-time/progress updates do not invalidate controls. Synchronous relevant writes are coalesced after the model commits; repeated identical scalar values are ignored. Actual controls, selected OFF/BASIC/Pro mode, availability/retry, preparation indicators, format, effect audit and render-health diagnostics retain update signals. Existing theme/environment delivery and tab identity remain unchanged.

The presentation preflight, asset recovery and optional-work resumption remain in place. No audio graph, gain, limiter, DSP parameter, render/tap scheduling or device sample-rate policy is changed by navigation. No new localized UI text or geometry change is introduced. This is iPhone presentation-only; Desktop code is unchanged, both ROADMAPs carry the same scope, and the Mac build was not repeated for documentation-only changes.

## Verification

- `bash tests/run_effect_events_regression.sh`: **4 groups PASS**. The 21-event method is extracted from shipping source at test time and compiled with the actual CoalescedViewUpdates. A controlled model emits 1,800 telemetry publications: broad objectWillChange receives **1,800**, the narrow Effects observer receives **0**. Mode/parameter/spatial/A/B writes arrive as one batch after commit; all 15 other readiness/recovery/format/diagnostic/memory inputs still invalidate the observer; duplicate scalar values do not. The logged elapsed time includes a 25ms run-loop drain and is not an app-render benchmark or an audio deadline measurement.
- `bash tests/run_effect_presentation_regression.sh`: **4 groups PASS**, including cancellation ordering, repeat entry, paused resumption and recovery exclusions. The source-boundary check additionally rejects reintroduction of broad @ObservedObject player monitoring in the shipping page and verifies its narrow observer wiring.
- `bash tests/run_navigation_presentation_regression.sh`: **6 groups PASS** for existing Library/Search telemetry isolation, batch delivery and route identity.
- `bash tests/run_dsp_transition_regression.sh`: **48 cases PASS** (full log retained), including shipping effect-mode transitions and negative mutation guard. The old extractor lacked the recently added AudioMixerCapacity dependency; the fixture now compiles the actual AudioProcessingPolicy and obtains the real attached engine from its player node rather than stubbing out capacity reservation. The restricted trial could not create the system Player AU; final verification uses normal CoreAudio service access. These offline DSP regressions are not a live UI tap or output-device test.
- iPhone `audio` scheme Debug generic Simulator, signing-disabled Xcode build: **PASS** on final code. An initial restricted-sandbox attempt could not run Observation macro/CoreSimulator services; the final build ran with access to required Xcode services. No code workaround was added for that environment failure.

## Pending

⭕️ [Pending] Actual iPhone speaker, first/repeated Effects entry under OFF/BASIC/Pro, current/next Precision Sinc conversion and cancellation latency, scroll/parameter controls, pause/resume, foreground return and full Music library. Capture output and correlate UI frame/render deadlines to distinguish scheduling dropout from waveform discontinuity. Confirm actual rendering reduction, parameter responsiveness, diagnostics freshness and no audible noise. The fixtures do not render SwiftUI controls or simulate real worker contention; first-mount CPU/GPU cost is not measured. Installed signed app and hardware listen tests remain unqualified.

[Regression/build logs and source hashes](../measurements/effects-telemetry-isolation-2026-11-07/).

## Follow-up: first mount and cancellation

[Actual Simulator mount and Sinc cancellation measurements](EFFECTS_MOUNT_CANCELLATION_2026-11-07.md) now cover the local first-mount contributor and cold kernel cancellation gap. Physical waveform/GPU/whole-pipeline and audible-noise qualification remain Pending.
