# Transient · Prototype: cost and matched PCM — 2026-10-26

## Decision and scope

🟢 [Done] Keep CPU processing, default OFF, intensity 0.20 and the warm OFF detector. The measured component cost does not justify a new cold bypass or DSP rewrite. This audit changes measurement tools and documentation only; production DSP, headroom, final true-peak protection, delay and transport behavior remain unchanged. This is an objective characterization of a small prototype, not evidence that all music sounds better.

Mac and main-iPhone production DSP, AU header/implementation, Swift adapter and BS.1770 meter are byte-identical. The synchronization companion is outside this audio task. Both SDKs render the actual AU; the iOS measurement runs in a dedicated Simulator, **not on a physical iPhone**.

## Method

Apple M4 arm64; macOS 27.0.1 / 26A434, Apple clang 21, Swift 6.4; native AU compiled `-Os`, comparison `-O`. iOS 27.0 Simulator with iPhone SE (3rd generation) profile, arm64 iOS 17 deployment target. See [metadata and source hashes](../measurements/transient-cost-pcm-2026-10-26/metadata.json).

Four configurations: `bare` (no node), `off` (settled amount 0, detector active), `default` (0.20) and `max` (1.0). Three fresh process launches per configuration/platform; launch order rotates by round. Each process constructs graphs at 44.1/48/96/192 kHz in that order. Wall-clock and process CPU are measured independently. Compilation, file export and quality analysis run outside timed sections. No concurrent audit compilation is performed during sampling.

The timed graph is player → optional actual transient AU → main mixer, stereo Float32, AVAudioEngine manual offline rendering. It excludes the production effect rack, decoder, SwiftUI, audio route, device driver and final limiter. Startup begins immediately before engine/player construction and ends after ready/start or the first successful nonzero 512-frame PCM block. It excludes executable/UIKit launch. The first 44.1 kHz graph includes per-process lazy CoreAudio initialization; later graphs share warmed framework state. None is an OS-cold boot. Do not subtract first-graph startup medians to infer AU savings.

After 64 warm-up blocks, each graph renders 2,000 × 512 frames from the same looping nonzero input. CPU percentages divide process CPU by virtual audio duration and express a fraction of one host core; offline timing does not establish real-time deadlines, power or battery use. Checksums and first-PCM checks require actual rendering. The short runs and three samples characterize scale; they are not a statistical performance guarantee.

## Measured component cost

Medians of three launches; CPU is µs per 512 stereo frames, including engine/mixer. The four CPU columns are no node / OFF / 0.20 / 1.0.

| Platform | Rate kHz | bare | OFF | default | max |
|---|---:|---:|---:|---:|---:|
| Mac native | 44.1 | 0.469 | 4.858 | 5.527 | 6.070 |
| Mac native | 48 | 0.445 | 5.148 | 5.398 | 5.551 |
| Mac native | 96 | 0.455 | 4.659 | 6.225 | 5.693 |
| Mac native | 192 | 0.444 | 4.793 | 7.551 | 5.545 |
| iOS Simulator | 44.1 | 0.388 | 4.813 | 5.387 | 6.232 |
| iOS Simulator | 48 | 0.452 | 4.707 | 5.993 | 5.803 |
| iOS Simulator | 96 | 0.394 | 4.701 | 5.459 | 5.615 |
| iOS Simulator | 192 | 0.392 | 4.626 | 5.314 | 5.929 |

At 48 kHz, OFF minus bare is about 4.70 µs/block on Mac and 4.25 µs/block in Simulator. OFF's total measured CPU is 0.048% / 0.044% of one host core respectively. At 192 kHz, OFF totals 0.180% / 0.173%; active configurations are at most 0.283% among these medians. OFF is not free, but the retained history supports the existing smooth re-entry policy. No cold bypass is introduced on this evidence. These figures are not iPhone CPU estimates.

Startup and memory (medians):

| Platform / configuration | First 44.1 kHz PCM ms | Later 48 kHz PCM ms | Process RSS after rendering MiB (48 kHz) |
|---|---:|---:|---:|
| Mac / bare | 76.397 | 3.070 | 16.20 |
| Mac / off | 66.377 | 3.383 | 16.33 |
| Mac / default | 72.648 | 3.139 | 16.22 |
| Mac / max | 64.053 | 3.287 | 16.33 |
| Simulator / bare | 74.914 | 4.207 | 156.02 |
| Simulator / off | 76.402 | 2.964 | 156.14 |
| Simulator / default | 73.486 | 3.508 | 156.11 |
| Simulator / max | 77.610 | 2.746 | 156.16 |

Per-process first graph dominates the several-millisecond warmed graphs; no stable startup improvement/regression is established by the small series. RSS is a point sample **after timed rendering** (raw field `rssReady`), not peak RSS, allocation count or DSP-only memory. UIKit explains much of the Simulator baseline, so cross-platform RSS is not comparable as effect memory. Raw startup CPU, AU factory time, before/after RSS, render wall/CPU and min/median/max are preserved in [summary](../measurements/transient-cost-pcm-2026-10-26/summary.json) and the platform raw JSON files.

## Loudness-matched representative PCM

Eight deterministic **original synthetic** stereo families, four seconds each at 48 and 96 kHz: steady harmonics, percussion-like attacks, plucked harmonics, decaying tail, stereo mixture, anti-phase, low-level noise and silence. These are repeatable stress/characterization signals, not released songs or a substitute for real-music listening. Inputs have a final 50 ms fade and hashes in the fixture manifest. Actual native and iOS AU direct render follows 50+ ms of silent warm-up; the adapter's host headroom and final limiter are deliberately excluded to isolate the algorithm. Existing full-chain protection/toggle/tail qualification remains in the [prototype report](SPECTRAL_TRANSIENT_PROTOTYPE_2026-10-26.md).

Use the production stereo BS.1770 integrated loudness meter (sum channel energy, not mono downmix). Per fixture, all eight variants use a common target at or below −23 LUFS and no amplification. A common extra attenuation would cap sample peak at 0.8 if required; that is not a true-peak guarantee. Low-level gated noise uses matched RMS instead; silence is left untouched. Normalization is applied only to offline comparison copies, never during playback. PCM24 exports are remeasured after quantization.

All 128 records pass: OFF and bare equal source exactly, native/Simulator raw PCM maximum absolute difference **0**, unchanged first nonzero sample, finite output, loudness error <0.01 LU (RMS fallback <0.01 dB), silence preserved. The anti-phase fixture is analyzed in stereo and does not collapse into a false silence reading.

48 kHz objective changes below: raw LUFS increase is before matching; attack/body contrast compares first 10 ms against 40–100 ms after known onsets, after matching. A larger ratio is not an independent quality score.

| Family | Raw LU increase default / max | Matched attack/body change dB default / max |
|---|---:|---:|
| steady | 0.0030 / 0.0148 | — |
| percussion | 0.0344 / 0.1716 | 0.0393 / 0.1956 |
| pluck | 0.0218 / 0.1094 | 0.0371 / 0.1847 |
| tail | 0.0071 / 0.0357 | 0.0375 / 0.1856 |
| stereo_mix | 0.0049 / 0.0245 | 0.0217 / 0.1086 |
| antiphase | 0.0040 / 0.0200 | 0.0093 / 0.0467 |

The 96 kHz results show the same small-scale behavior (percussion contrast +0.0364 / +0.1811 dB). The default setting produces a measurable but gentle change after level matching. Steady/tail/noise responses, crest factor, stereo correlation and matched residuals are retained in [comparison JSON](../measurements/transient-cost-pcm-2026-10-26/comparison.json); the quiet-noise residual is extremely small, not mathematically zero. No perceptual superiority or noise transparency is inferred from these metrics.

Optional four-second, 48 kHz stereo PCM24 comparisons, all measured approximately −23.000 LUFS: [dry](../measurements/transient-cost-pcm-2026-10-26/mac-bare-matched.wav), [default](../measurements/transient-cost-pcm-2026-10-26/mac-default-matched.wav), [maximum](../measurements/transient-cost-pcm-2026-10-26/mac-max-matched.wav). They use the synthetic stereo mixture and do not contain the final application protection chain. No automatic playback/listening result is claimed.

## Reproduction and remaining qualification

Measurement sources live in mobile `tests/TransientCostAudit.mm`, `TransientCostAudit-Info.plist`, `generate_transient_cost_pcm.py`, `TransientLoudnessComparison.swift` and `run_transient_cost_samples.py`. Both repositories contain this identical report/evidence; the mobile test tools are the canonical runner. Build commands and isolated Simulator setup are in [REPRODUCTION.md](../measurements/transient-cost-pcm-2026-10-26/REPRODUCTION.md). A dedicated audit bundle/device was used and removed after export. No production app preferences were changed; temporary full PCM was removed after saving compact results and the three WAV files.

- 🟢 [Done] OFF-inclusive startup/render samples, matched representative PCM, source parity, gated/silent/anti-phase handling and PCM24 level verification. All 96 timed graph records and 128 PCM records pass their validity checks.
- 🟠 [Next] Measure the same signals in the complete production rack with Exciter/BBE/space and final headroom/limiter. Isolated AU costs and matched comparisons do not close that separate combination task.
- ⭕️ [Pending] Physical iPhone/Mac listening with real music: speakers, headphones, Bluetooth/DAC, harshness/noise, stereo image and fatigue; actual route-rate/thermal/energy/underrun behavior, background UI load and ON/OFF/tail/stop-resume audibility. A Simulator profile cannot certify these. Keep default OFF until listening evidence supports any change.
