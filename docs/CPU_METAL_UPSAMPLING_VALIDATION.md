# CPU / Metal upsampling comparison — 2026-10-19

**Update 2026-10-19:** The first shared-rack residual, latency-change and bounded-tail stage is complete; see [tail/latency verification](TAIL_LATENCY_VALIDATION.md). Sample-accurate envelopes remain Next and physical-device qualification remains Pending.

## Decision

🟢 [Done] **Keep CPU processing as the shipping default in both apps.** The M4
prototype demonstrates useful GPU acceleration for some large offline Sinc jobs,
but does not justify making GPU processing mandatory or changing either playback
path. Short jobs are slower, some longer cases also regress, memory is higher,
and no numerical-accuracy improvement was found.

The iPhone app uses the shipping Accelerate/vDSP Precision Sinc implementation
with deliberate offline-worker throttling. The Mac app currently uses Apple's
AVAudioEngine conversion into its shared 96 kHz rack; it does not have the custom
Precision Sinc path. The same CPU extraction, Metal prototype, thresholds and
results are shared by both repositories. These measurements compare equivalent
Sinc implementations on the development Mac, **not the complete Mac production
converter against a GPU replacement, and not iPhone performance**. No production
DSP, processing-rate policy, sound level or playback code changed in this task.
192 kHz is a benchmark stress case, not a new app processing-rate policy.

🔴 [Later] Consider an optional GPU backend for large, repeated offline jobs only
if target-device measurements show a meaningful end-to-end benefit. A production
backend would also need bounded reusable buffers, CPU fallback, allocation/error
handling, cancellation/stale-result ownership and playback-priority integration.
Do not remove the iPhone CPU thermal-duty policy based on these Mac measurements.

🟠 [Next] Continue the shared playback-quality priority: latency-aligned
handoff/bypass residuals and Space/Gloss/reverb tails. GPU integration is not the
next production priority.

## Measured environment and method

- Real development hardware: MacBook Air Mac16,13, Apple M4, 10 CPU / 10 GPU cores,
  32 GB unified memory; macOS 27.0.1 (26A434), Apple Swift 6.4, optimized `-O` arm64.
- Two independent complete runs, 29 settings × CPU/GPU = 58 result rows per run.
  Each process measures one first transform and seven warm transforms; backends
  alternate order. 116 result rows total. These short runs are not a controlled
  sustained-load, energy or thermal experiment.
- Stereo 44.1→96, 48→96 and 44.1→192 kHz; all linear/minimum-phase/apodizing ×
  eco/standard/master settings on 3-second sources. Also 256-source-frame and
  10-second linear/master cases at 44.1→96 kHz. Larger cases cross the shipping
  262,144-output-frame chunk boundary.
- CPU kernel generation and `renderSincChunk` are extracted from the current
  iPhone source without rewriting their arithmetic. Both backends use identical
  Float32 coefficients and zero extension. GPU sample/phase positions are planned
  with the same host Double arithmetic to avoid Float timeline drift; its cost is
  included. Metal fast math is off, with explicit FMA accumulation.
- Warm wall time includes output allocation, GPU source/position buffer copies,
  dispatch/wait and output copy-back. Kernel construction and backend setup are
  separate fields. Apple unified memory does not eliminate these prototype copies.
  No CPU thermal sleeps are included in this like-for-like comparison.
- Each CPU/GPU process is isolated for peak RSS. RSS is sampled before correctness
  reference allocations. Post-run physical footprint and live Metal allocation
  counters are also recorded; these are different, overlapping accounting views,
  **not additive memory totals**. The footprint sample is not a measured peak.
- Whole generated sources are retained in this harness. Production iPhone decoding
  reads source windows while retaining a contiguous output. This experiment does
  not establish full-song application memory use or memory savings from GPU use.

## Speed and memory

The table reports the range of the **two run medians**, not min/max individual
iterations or a confidence interval. Raw JSON includes all eight timings,
first-transform time, device-only time and warm nearest-rank p95 (the maximum of
seven observations, too few for a reliable tail estimate). GPU speedup is CPU/GPU
wall time for the same run; values below 1 mean GPU was slower.

Across the 28 non-tiny cases, GPU won 25 cases in run 1 and 26 in run 2, with
speedups ranging from **0.765× to 2.948×**. A 3-second 44.1→96 kHz linear/master
case varied from 6.418 to 3.389 ms on GPU while CPU stayed near 5.1 ms: this is a
real variation to retain in the decision, not a reason to select only the best run.
The 256-frame case took CPU 0.026–0.028 ms versus GPU 0.234–0.314 ms (about 9–11×
slower). The 10-second case took CPU 17.125–17.233 ms versus GPU 8.176–8.379 ms.

GPU backend setup (device/queue, runtime library/pipeline and coefficient buffer)
added **22.58–53.47 ms** before the first transform. Driver shader caches were not
purged, so this is process-first setup, not guaranteed uncached compilation.
Common kernel generation took about 0.99–16.18 ms. A first-use decision must include
kernel generation + backend setup + first transform, not warm time alone.

Peak RSS across the matrix was CPU **7.67–18.41 MiB**, GPU **16.41–41.89 MiB**.
Post-measurement physical footprint was CPU **2.63–13.38 MiB**, GPU
**48.36–68.49 MiB**; Metal's sampled allocations were **1.09–8.47 MiB**.
For 3-second 44.1→96 kHz linear/master, peak RSS was 10.91 MiB CPU versus
27.05–27.08 MiB GPU. The prototype offers no memory advantage. RSS alone would
understate the GPU/driver charge visible in physical footprint.

| Input→output kHz / source length | Phase / quality | CPU warm ms | GPU warm ms | CPU peak RSS MiB | GPU peak RSS MiB |
|---|---|---:|---:|---:|---:|
| 44.1→96 / 3 s | linear / eco | 2.983–4.538 | 2.442–3.797 | 10.34–10.36 | 25.92 |
| 44.1→96 / 3 s | linear / standard | 3.588–3.591 | 2.728–4.690 | 10.47 | 26.17 |
| 44.1→96 / 3 s | linear / master | 5.129–5.165 | 3.389–6.418 | 10.91 | 27.05–27.08 |
| 44.1→96 / 3 s | minimumPhase / eco | 4.151–4.350 | 2.452–3.018 | 10.88 | 26.55–26.58 |
| 44.1→96 / 3 s | minimumPhase / standard | 5.995–6.110 | 3.005–3.723 | 11.12 | 27.02–27.08 |
| 44.1→96 / 3 s | minimumPhase / master | 10.509–10.597 | 3.749–3.909 | 12.52 | 28.41–28.42 |
| 44.1→96 / 3 s | apodizing / eco | 3.014–3.046 | 2.755–2.797 | 10.34 | 25.95–25.98 |
| 44.1→96 / 3 s | apodizing / standard | 3.612–3.658 | 2.977–3.580 | 10.47 | 26.20 |
| 44.1→96 / 3 s | apodizing / master | 5.166–5.281 | 2.978–5.667 | 10.91 | 27.05–27.30 |
| 48→96 / 3 s | linear / eco | 2.972–2.975 | 2.571–2.591 | 10.44 | 26.11–26.19 |
| 48→96 / 3 s | linear / standard | 3.611–3.621 | 2.022–2.130 | 10.56 | 26.33–27.64 |
| 48→96 / 3 s | linear / master | 5.142–5.162 | 2.366–2.672 | 11.00 | 27.27–27.80 |
| 48→96 / 3 s | minimumPhase / eco | 4.097–4.390 | 3.078–3.392 | 10.97–11.02 | 26.70–27.03 |
| 48→96 / 3 s | minimumPhase / standard | 5.893–5.960 | 3.209–4.078 | 11.22 | 27.22–27.23 |
| 48→96 / 3 s | minimumPhase / master | 7.770–7.785 | 2.641–3.427 | 12.61 | 28.53 |
| 48→96 / 3 s | apodizing / eco | 2.934–2.956 | 2.570–2.682 | 10.44 | 26.11–26.17 |
| 48→96 / 3 s | apodizing / standard | 3.553–3.665 | 2.793–3.409 | 10.56 | 26.36–26.42 |
| 48→96 / 3 s | apodizing / master | 5.151–5.199 | 3.727–4.070 | 11.00 | 27.23–27.30 |
| 44.1→192 / 3 s | linear / eco | 5.916–6.002 | 3.841–4.615 | 12.55 | 30.16–30.19 |
| 44.1→192 / 3 s | linear / standard | 7.640–7.664 | 4.294–4.934 | 12.67 | 30.38–30.45 |
| 44.1→192 / 3 s | linear / master | 10.996–11.223 | 5.276–6.342 | 13.11 | 31.25–35.12 |
| 44.1→192 / 3 s | minimumPhase / eco | 8.510–8.672 | 4.722–5.189 | 13.08 | 30.72–30.77 |
| 44.1→192 / 3 s | minimumPhase / standard | 12.792–12.967 | 5.350–5.433 | 13.33 | 31.25–31.27 |
| 44.1→192 / 3 s | minimumPhase / master | 19.612–20.782 | 7.225–7.629 | 14.72 | 32.52–32.61 |
| 44.1→192 / 3 s | apodizing / eco | 5.901–6.035 | 3.825–3.974 | 12.55 | 30.12 |
| 44.1→192 / 3 s | apodizing / standard | 7.636–7.669 | 4.145–8.773 | 12.67 | 30.41 |
| 44.1→192 / 3 s | apodizing / master | 10.835–11.013 | 4.994–6.466 | 13.11 | 31.25 |
| 44.1→96 / 256 frames | linear / master | 0.026–0.028 | 0.234–0.314 | 7.67 | 16.41–16.48 |
| 44.1→96 / 10 s | linear / master | 17.125–17.233 | 8.176–8.379 | 18.41 | 41.89 |

## Numerical checks and shipping policy probe

🟢 [Done] All 58 CPU/GPU pairs across the two runs passed full-output finite and
maximum-difference checks. Maximum CPU/GPU difference was **2.98023224e-7 FS**
(about −130.5 dBFS). This is excellent agreement, not bit identity.

An independent Double-precision dot product of the same quantized coefficients
checked roughly 4,096 positions/channel plus start/end, signal transitions and
chunk-boundary regions (all positions for the tiny case). CPU maximum error was
**1.0192e-7 FS**, GPU **2.2720e-7 FS**. Worst sampled reference SNR was **139.74 dB
CPU** and **133.44 dB GPU**. Gates were max error < 2e-6 FS and SNR > 110 dB.
Thus this GPU accumulation was slightly less accurate numerically; it does not
improve filtering precision simply by using Metal. These tests measure arithmetic
agreement, not an ideal infinite-sinc filter or new audible detail.

Fixtures cover silence/impulses, DC, 997 Hz, a near-Nyquist tone, a chirp and seeded
noise with distinct channels. The corrupted-shader negative control (×1.001 gain)
failed the Float64 tolerance gate as expected in both runs; each runner then
reported success. The intentional Swift error termination in the log is not an
unexplained playback crash.

🟢 [Done] The shipping file-to-buffer path, including its deliberate roughly 25%
CPU duty policy, was separately exercised on 3-second 44.1→96 kHz master fixtures,
five iterations per mode per run. Linear median: **26.63–35.16 ms**;
minimum-phase median: **60.51–66.37 ms**. All samples matched the unthrottled
shipping reference exactly. This adds decoding/file access and sleeps, so it must
not be used to inflate the equivalent-work GPU speedup. These are still M4 results,
not measurements of iPhone preparation time or battery impact.

## Remaining qualification

- ⭕️ [Pending] Physical iPhones across supported generations: preparation latency,
  peak process memory/headroom, energy, thermal throttling, foreground/background
  restrictions and uninterrupted playback while conversion runs.
- ⭕️ [Pending] Sustained Mac playback plus GPU rendering/UI load, other Mac GPU
  families, power modes, long songs and concurrent preparations. The real M4
  compute benchmark above is Done; application-level/device-matrix qualification
  remains Pending.
- ⭕️ [Pending] Any future GPU production candidate: cancellation during in-flight
  work, rapid track changes, stale completions, memory pressure/fallback, output
  handoff and listening for clicks/level changes. Prototype cancellation checks
  only bracket submissions; largest observed device dispatch was 8.48 ms, not an
  upper bound or an application cancellation guarantee.
- 🔴 [Later] If preparation time becomes a measured bottleneck, evaluate reusable
  chunk buffers and reduced copy/position-planning overhead before deciding on a
  device/size/quality-specific GPU threshold. No universal GPU crossover threshold
  is justified by these short runs.

## Reproduction and evidence

The iPhone harness is `tests/sinc-benchmark`; the byte-identical Mac copy is
`tools/sinc-benchmark`. Both require the explicit current iPhone source root when
run from Mac. See the harness README for commands and accounting details.
No app build was necessary for this step: only isolated optimized benchmark
executables were compiled; production files were not edited.

- [Run 1 raw timing/precision/memory](measurements/cpu-metal-2026-10-19-run1.jsonl),
  [run 2](measurements/cpu-metal-2026-10-19-run2.jsonl).
- [Run 1 shipping-policy probe](measurements/cpu-metal-2026-10-19-run1-policy.jsonl),
  [run 2](measurements/cpu-metal-2026-10-19-run2-policy.jsonl).
- [Run 1 runner log](measurements/cpu-metal-2026-10-19-run1.log),
  [run 2](measurements/cpu-metal-2026-10-19-run2.log).
- [Environment and exact source SHA-256 manifest](measurements/cpu-metal-2026-10-19-manifest.json).
