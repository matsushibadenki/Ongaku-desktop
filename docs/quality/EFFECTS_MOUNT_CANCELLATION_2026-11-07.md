# Effects first mount and Sinc cancellation — 2026-11-07

## Remaining work after telemetry isolation

The prior preflight requests cancellation of optional work and the prior narrow observer removes meter-driven rack invalidations. Neither prevents an eager first mount of every EffectCard. The card ForEach was still inside ordinary stacks, including controls well below the viewport.

The output renderer checks cancellation every 1,024 output frames and the throttle checks between sleeps of at most 20ms. However cachedPolyphaseSincKernels had no cancellation checks: a cold build completed and published a cache entry despite a cancelled worker. Existing `quality_worker.ended elapsed` reports total worker lifetime, not request-to-exit latency; it must not be interpreted as cancellation latency.

## Implementation

The card list alone now uses LazyVStack. The outer header, actual top anchor, mode selection and spatial card remain eager. Re-entry still scrolls to the actual top anchor without restoring a saved absolute offset based on estimated lower-card heights. Card identities, bindings and presets remain unchanged. No spinner, fade, silence insertion, graph rebuild or gain change is added to navigation.

Kernel preparation now throws on cancellation before cache lookup/allocation, at each phase, every 16 prototype taps during generation and before publishing a completed cache entry. Callers propagate CancellationError. Checks around source-chunk reads and normalization stop subsequent optional work after those non-preemptible operations finish. No coefficient, phase profile, chunk size, render arithmetic or throttle duty policy changes. The standalone CPU/Metal measurement adapters were updated for the throwing signature; this does not introduce GPU conversion.

These are iPhone UI/custom-Sinc preparation changes. Desktop does not contain this custom polyphase-kernel generator; its conversion path and all shared DSP/AU algorithms remain unchanged. Both ROADMAPs record the same qualification boundaries. No Mac runtime build was required for its documentation-only update.

## Render measurement

The isolated audit compiles actual EffectsTabContent, EffectCard and the rest of the iPhone module. It changes page visibility only for test access, inserts an EffectCard body-evaluation counter and supplies a UIKit Scene audit entry point. It does not replace the controls or renderer with a mock. Both eager and deferred card containers are compiled into **one executable**, selected by a launch argument. A dedicated bundle ID uses an empty Simulator library with media access denied; model/engine setup and permission handling finish before timing. No user library or installed app preferences are used.

Device: iPhone 18 Pro Simulator, iOS 27.2, 402×874 points, Pro mode, no playback, controls unavailable. A first deferred launch warms the audit, then eager and deferred launches alternate without recompilation. Each launch creates three hosts; round 0 is first view mount in that process, rounds 1/2 are warm remounts. This is a small local sample, not a percentile budget or randomized benchmark.

`mountMs` measures synchronous host assignment and layoutIfNeeded. `mountAndSnapshotMs` additionally forces a CPU layer.render screenshot readback; it is **not** GPU frame time or audible-render deadline latency. Startup/font caches and Simulator scheduling remain confounders. Structural body counts are the stronger evidence.

| Container | Round | Initial card body evaluations | Mount ms | Mount + CPU snapshot ms |
|---|---:|---:|---:|---:|
| Eager | 0 | 11 | 403.17 | 1997.07 |
| Eager | 1 | 11 | 160.35 | 3110.10 |
| Eager | 2 | 11 | 188.13 | 2906.46 |
| Deferred | 0 | 2 | 463.30 | 1181.04 |
| Deferred | 1 | 2 | 71.74 | 813.22 |
| Deferred | 2 | 2 | 133.47 | 1081.40 |

The matched first-mount sample is 403.17ms eager versus 463.30ms deferred, so this small sample does **not** establish a reduction of first host-layout time. Warm remount samples and the forced-snapshot work differ as shown; none is a GPU deadline guarantee. The earlier separate-build exploratory 1896→623ms observation is not used as proof of first-mount speedup after the stricter comparison. All final eager mounts evaluate 11 cards; deferred mounts evaluate 2. After deferred scrolling to the bottom, more cards are evaluated (2→4 in the final audit); scrolling returns to the top and the Pro selection remains intact. The initial visible layout was also inspected in the saved screenshot. This establishes local mounting/scroll access, not hardware sound continuity or gesture latency during real playback. Original separate-build exploratory measurements are retained as intermediate evidence and are not the matched comparison above.

## Cancellation measurement

The shipping Sinc methods are extracted verbatim and optimized on the development Mac. A background task signals entry into cold minimum-phase/master kernel generation; the test requests cancellation after a 5ms delay, then measures request-to-task-exit. This is a worst-profile cold-kernel probe, not a full-song/iPhone timing model.

- Before: three tasks ignore cancellation, finish successfully and publish one cache entry; request-to-exit **45.59 / 48.26 / 54.67 ms**.
- After: all three throw CancellationError and publish no entry; request-to-exit **4.91 / 1.16 / 2.08 ms**.
- A pre-cancelled warm-cache request also throws for linear, apodizing and minimum-phase modes. Retrying after cold cancellation generates the same eco coefficients: all three SHA-256 digests match the original implementation exactly.

Timing is observed data, not a hard iPhone bound. File decoding, buffer allocation and Accelerate FFT calls cannot be preempted inside a framework call; the checks stop work at the next boundary. The unchanged 20ms throttle sleep can remain another latency component. Full preparation stages under physical-device contention remain Pending.

## Regression and build

- Sinc cold cancellation 3 runs, cancelled-cache exclusion, warm cancellation 3 modes and unchanged kernel hashes: PASS. The baseline is a positive sensitivity control (it intentionally fails to honor cancellation).
- Existing narrowed-event fixture: 4 groups PASS; preflight/resume/source-wiring fixture: 4 groups PASS; Library/Search navigation fixture: 6 groups PASS.
- Existing CPU/Metal benchmark consumer typecheck with the new throwing adapter: PASS. The 58-case GPU benchmark was not repeated because the conversion math/GPU policy did not change.
- Actual Simulator mounting, lazy lower-card access, top return and Pro state preservation: PASS in the isolated final audit. Only one device/size and unavailable-controls state are qualified here.
- Final ordinary iPhone Debug generic Simulator signing-disabled Xcode build: PASS. The audit itself also builds the full module with instrumentation. No signing/distribution qualification is implied.

The initial audit harness used a legacy app lifecycle and was rejected by iOS 27 before mounting any page; it was replaced with a Scene delegate. A first media permission dialog was then excluded by denying access only for the dedicated audit bundle. These were harness corrections; the production SwiftUI App lifecycle is unchanged. Successful Scene-based measurements are the evidence used above.

⭕️ [Pending] Physical iPhone speaker noise and output waveform during first/repeated Effects entry, active controls under OFF/BASIC/Pro, full Music library, cold/warm high-quality conversion, I/O/FFT/allocation/throttle cancellation latency, source handoff, scrolling and rapid mode changes, foreground/pause/resume, narrow and largest iPhone screens and signed-app/thermal/power conditions. Do not mark the user's noise resolved from these measurements. Hardware frame/GPU counters, concurrent workers and actual audio deadlines are not measured here.

[Raw logs, before/after measurements, screenshots and source hashes](../measurements/effects-mount-cancellation-2026-11-07/).

## Follow-up: preparation boundaries and remaining UI work

[Full-module preparation and light-theme raster reuse](FULL_PREPARATION_CANCELLATION_2026-11-07.md) adds measured read/allocation/FFT/wait/analysis/persistence boundaries, all modes, and native-thumb sharing. Physical noise, true GPU/first-frame deadlines and the explicitly excluded async/remote paths remain unqualified.
