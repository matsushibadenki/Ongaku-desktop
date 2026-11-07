# Remaining first-layout work and full preparation cancellation — 2026-11-07

## Findings and fixes

The lazy card list still constructs several native sliders when visible cards mount. HardwareSlider generated an identical thumb bitmap for each native view, again on remount. In the fixed light-theme audit this was 24 raster generations per mount, despite only two card bodies being evaluated. Production now shares the immutable UIImage in a bounded NSCache (24 entries), keyed by appearance and actual slider display scale. A scale change refreshes the native image even if appearance is unchanged. Geometry, gradients, normal/highlighted images, native tracking, tint and bindings are unchanged. This does not remove the remaining SwiftUI layout, text, mask, shadow or GPU work.

The complete preparation path revealed a separate correctness gap: analyzeSignalLevels/analyzeAutomaticDSP return empty/neutral values when cancelled. preparePlaybackData could continue to cache or return those values without another cancellation check. The final code checks entry/migration, cached return, spatial/validation boundaries, between analyses, before analysis publication and before returning prepared data. A cancelled finite-buffer scan is now recognized as cancellation before being reported as a conversion failure. Cached PCM read/allocation boundaries have checks; sample cloning checks every 16,384 frames rather than copying a complete channel without a check. The minimum-phase routine checks between its FFT/array phases. Framework allocation, file read and DFT calls remain non-preemptible while inside the call.

Observed cancellation while throttling was the largest component in the earlier free-running trial (33.492ms). The synchronous worker still waits for workDuration×3, preserving its nominal 25% work-duty policy, but each sleep quantum is reduced from 20ms to 5ms. Later 5ms-quantum trials observed caller-return delays ranging from about 10ms to 98ms. The final worker-end versus caller-return values are recorded separately below; shorter sleep quanta do not bound OS scheduling. These are observations, not a 5ms/10ms deadline guarantee. More wakeups and physical energy behavior need device testing.

Cancelled shared-preload waiters now resume independently of the shared producer, which remains available to other consumers. A small locked continuation latch resolves installation/completion/cancellation exactly once; an observer only awaits shared completion and does not perform another conversion. All three consumers check cancellation before starting replacement work. Pre-cancelled consumers leave the prepared cache untouched. The effects preflight also cancels the independently owned optional disk-cache writer without clearing completed caches or stopping audio.

All runtime changes are iPhone presentation/preparation code. Desktop does not use this custom polyphase generator/slider host, and shared DSP/AU algorithms, effect defaults, output gain and rate policies are unchanged. Both ROADMAPs share the evidence; no Mac build was repeated for its documentation-only update.

## Actual module / complete preparation test

The isolated Scene audit compiles the actual iPhone module. A generated copy inserts spans around the shipping functions and wrappers that call the real AVAudioFile, AVAudioPCMBuffer and vDSP APIs. Same-file adapters expose the private preparation entry point without replacing its logic. The dedicated bundle ID has media permission denied and unique input roots for each run; no user library/preferences are accessed. The 3-second input is local 44.1kHz stereo Float32 CAF, target 96kHz. Tests use background tasks, subject to Swift priority escalation on await; no actual hardware audio render runs.

**32 records PASS:** one full uncancelled preparation with synchronous persistence; 10 main-path entry cancellations; one optional copy/spatial successful call plus two entry cancellations; five externally cancelled free-running calls; 11 full-mode preparations (all 10 current UpsamplingMode cases plus the legacy precisionSinc value). Two additional records exercise the actual independently scheduled disk writer: normal completion publishes audio and metadata, and cancellation at entry removes partial artifacts. Each mode produced 288,000 frames; finite-buffer validation is the shipping check. The optional route branch uses the real clone and spatial functions with explicit route support, verifies clone samples equal the source, then verifies finite spatial output and frame length; it is not a physical headphone-route test.

The deterministic entry tests use withUnsafeCurrentTask.cancel on the executing worker at the selected boundary, then run the real operation/checkpoint. This avoids blocking a cooperative executor. External requests use normal Task.cancel and report the active span sampled at request time; a very fast target can have completed before the parent observes it. Worker-end stamps are recorded by the worker defer, separately from await task.value returning to the caller. Unit-only rows without worker stamps retain their caller metric in both columns. Earlier trials measured only caller return and cannot be retroactively split. Timing includes instrumentation, cleanup and scheduling. Neither establishes that a framework call can be interrupted internally.

| Case | Cancellation method | Active stage sampled | Request → worker end ms | Request → caller return ms |
|---|---|---|---:|---:|
| prepare | self_cancel_at_entry | prepare | 0.025 | 0.221 |
| allocation | self_cancel_at_entry | allocation | 0.229 | 0.254 |
| read | self_cancel_at_entry | read | 0.291 | 0.322 |
| fft_execute | self_cancel_at_entry | fft_execute | 0.054 | 0.077 |
| wait | self_cancel_at_entry | wait | 5.366 | 5.392 |
| validation | self_cancel_at_entry | validation | 0.206 | 0.252 |
| analysis | self_cancel_at_entry | analysis | 0.098 | 0.124 |
| auto_analysis | self_cancel_at_entry | auto_analysis | 0.133 | 0.174 |
| persist | self_cancel_at_entry | persist | 0.401 | 0.441 |
| cache_read | self_cancel_at_entry | cache_read | 0.013 | 0.032 |
| copy_unit | self_cancel_at_entry | copy_unit | 0.040 | 0.040 |
| spatial_unit | self_cancel_at_entry | spatial_unit | 0.030 | 0.030 |
| racing-allocation | free_running | allocation | 0.103 | 0.121 |
| racing-read | free_running | read | 0.549 | 0.777 |
| racing-fft_execute | free_running | fft | 1.676 | 1.729 |
| racing-wait | free_running | wait | 97.466 | 97.526 |
| racing-analysis | free_running | analysis | 1.218 | 1.260 |

Every cancelled entry before analysis publication left zero analysis entries. The persistence-entry case retains one **already completed valid** analysis entry and still exits with CancellationError; that is distinct from publishing cancellation fallback values. Cache-read cancellation preserves the completed cache entry. The test does not claim that every possible cancellation race can atomically erase valid work completed before a request.

The uncancelled reference's maximum observed duration per operation (nested spans overlap; these are not additive):

| Stage | Max operation ms |
|---|---:|
| allocation | 0.281 |
| analysis | 141.891 |
| auto_analysis | 88.153 |
| conversion | 531.787 |
| fft | 2.712 |
| fft_execute | 0.015 |
| kernel | 141.442 |
| normalize | 0.001 |
| persist | 12.156 |
| prepare | 830.331 |
| read | 0.189 |
| validation | 47.672 |
| wait | 6.268 |

These Debug Simulator samples include instrumentation and scheduling. Read/allocation fixtures are small; long compressed tracks, slow/remote storage, lock contention and large allocations can behave differently. The primary preparation adapter uses synchronous persistence to observe it, followed by actual asynchronous-writer tests. The shared waiter is tested from extracted shipping source in four separate control-flow groups, not by a live Music session. External asset snapshot/export and every other file/route combination are outside this fixture. Those exclusions are not implied by “full preparation” to be universally qualified.

## Actual effects UI comparison

The same audit executable runs the shipping light-theme Pro page with the same lazy container in both variants. Only its test copy can bypass the new thumb cache via --uncached. Model/engine setup is outside timing, no playback is active, controls are unavailable, and one 402×874pt iPhone 18 Pro / iOS 27.2 Simulator is used. Earlier alternating pairs and a final-source pair are retained. The final pair is below; the earlier first-pair results are stored as intermediate evidence so OS cache warm-up is visible. The same first-frame improvement cannot be concluded from these small, varying samples.

| Variant | Remount round | Thumb raster generations | Host layout ms | Layout + forced CPU snapshot ms |
|---|---:|---:|---:|---:|
| Uncached | 0 | 24 | 360.25 | 894.35 |
| Uncached | 1 | 24 | 47.47 | 580.61 |
| Uncached | 2 | 24 | 70.37 | 855.46 |
| Cached | 0 | 1 | 446.43 | 1278.43 |
| Cached | 1 | 0 | 63.66 | 862.80 |
| Cached | 2 | 0 | 65.41 | 870.71 |

The structural reduction is 24 raster generations → 1 on the first cached mount and 0 on later mounts. All 14 appearance×scale image checks pass (7 themes, scales 2 and 3): dimensions/scale, identical PNG data on repeated calls, and object reuse in the cached variant. Scroll-to-bottom / top return / Pro preservation pass, and the saved light-theme screenshot was inspected. The old original-theme audit did not use HardwareSlider, so its timings are not compared against these light-theme numbers. GPU completion, display-link deadlines and active-control interactions are not measured by layer.render screenshot readback. In the final pair, the first cached host layout was slower than the uncached one; the raw table is retained rather than selecting the favorable earlier sample. The small samples are not a fixed first-frame target or evidence of audible-noise resolution.

## Regression and build

- Existing effects notification, preflight/resume/source boundary and navigation regressions: **4 + 4 + 6 groups PASS**. Shared-wait cancellation / producer survival / pre-cancel cache preservation / 200 resolution races: **4 additional groups PASS**; presentation regression also verifies writer cancellation is requested only once.
- Optimized extracted Sinc cancellation regression: **PASS**; three eco phase coefficient SHA-256 values still match the original implementation exactly after FFT checkpoints. No new GPU backend.
- Final ordinary iPhone Debug generic Simulator signing-disabled build: **PASS**, without instrumentation.
- Isolated instrumented full-module build and the 32 pipeline records / light UI comparisons / 14 image checks: **PASS**.
- During trial development, the semaphore-based boundary test at background QoS starved its own cooperative continuation. A sample shows the worker inside the test semaphore while the main loop was idle. The final tests self-cancel at entry without blocking. Trial roots were also made unique and errors observable. Failed/intermediate harness runs are not used as qualification or attributed to the product.

⭕️ [Pending] Physical iPhone speaker noise/output waveform, actual first-frame and GPU timing while audio renders, signed app/full Music library, all screen sizes, active tracking/VoiceOver, routes and simultaneous optional workers, long/compressed/remote inputs and I/O stalls, large allocation/FFT/lock waits, whole-song cancellation and resource-release/scheduler delays under memory/thermal contention, stop/resume/foreground/handoffs, and wakeup/energy impact. Framework-call completion may exceed the cooperative quantum. Do not mark the user's noise fixed.

[Raw measurements, snapshots, source hashes and precise product diff](../measurements/full-preparation-cancellation-2026-11-07/).
