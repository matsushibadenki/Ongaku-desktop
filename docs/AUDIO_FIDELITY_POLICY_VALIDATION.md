# Output, processing-rate and loudness policy — 2026-10-17

## Implemented behavior

🟢 [Done] iPhone output classification no longer treats an unknown route as an
internal speaker or every Bluetooth transport as headphones. Automatic mode
recognizes built-in speaker/receiver and wired headphones; USB, Bluetooth,
AirPlay, HDMI, line out, mixed and absent routes are neutral. Settings offers
Automatic / Headphones / External output, saved by the sorted set of output
UIDs, and an independent low-volume compensation toggle. The same resolved
endpoint drives compensation and headphone spatial processing. An explicit
headphone selection enables those existing headphone features; their own OFF
settings still apply. External output disables the automatic loudness contour
and headphone virtualization, not the user's chosen effect rack. Mac currently
has neither this iOS automatic contour nor the iOS headphone virtualizer; no
unnecessary output EQ was introduced there.

🟢 [Done] Both effect racks use the shared 96 kHz processing policy. iPhone's
normal processing rate stays unchanged. Mac now converts from file rate at the
source mixer, processes all effects at 96 kHz and converts to the actual hardware
rate at the final mixer. Source frame clocks/seeks still use file rate. This
keeps Space and the rate-dependent reverb branches available for 192 kHz files.
The policy and meter sources are identical copies in both repositories, and
registered in the desktop Xcode project as well as SwiftPM. Existing optional
Mac hardware upsampling remains a separate preference. 96 kHz is a compatibility
choice for the current effects, not a claim that the highest rate always sounds
best. Hardware output is not guaranteed to equal the processing rate.

🟢 [Done] The shared worker-only integrated meter implements two-stage
K-weighting, per-channel energy summation, complete 400 ms blocks at 100 ms
intervals, a -70 LUFS absolute gate and a -10 LU relative gate. Filter/window
state survives arbitrary input chunk boundaries. It supports mono/stereo at
8–384 kHz; it never downmixes opposite-polarity stereo before measuring. Silence,
clips under 400 ms, nonfinite samples and unmapped multichannel layouts return
no integrated value and do not receive LUFS-based normalization.

🟢 [Done] iPhone uses the meter in its existing prepared-PCM analysis path,
invalidates old prepared-cache metadata (version 4), and shows an em dash for
unavailable LUFS. Native-first playback starts without waiting for analysis;
unmeasured and analysis-skipped paths no longer substitute RMS or a fabricated
LUFS value as a normalization measurement. Existing peak/headroom protection
still applies. This change does not add an independent full-track analysis job
to iPhone native-only/memory-safety playback or to protected system Music.

🟢 [Done] Mac streams the entire original-rate file into the stereo meter while
retaining the bounded first-60-second feature window for tempo/key/similarity.
Full-rate per-channel sample peaks replace the decimated mono peak for supported
layouts. Analysis runs on the utility worker with cancellation forwarded from
its owner and checked at each chunk. Incomplete file reads cannot supply LUFS.
Version 5 feature caches preserve legacy RMS as a separate similarity feature;
RMS-only/old records cannot normalize playback. The target is now labeled LUFS
in English/Japanese/Simplified Chinese, with a separate persisted LUFS key and
-16 LUFS default, rather than reinterpreting a saved RMS target.

Album mode gates the combined measured 400 ms energies on a utility worker and
caches the result by track membership and analysis revision. Stale completions
are rejected; playback updates do not reallocate or gate the block arrays.
Longer tracks receive the appropriate weight; it uses the loudest member's peak for a common safety
bound. Unmeasured queued album members defer normalization. Windows are measured
per file: this does not reconstruct the windows spanning track boundaries in a
single concatenated album render. The peak bound is sample-based and is not a
true-peak guarantee.

## Validation

- `bash tests/run_audio_fidelity_policy_regression.sh`: route classification,
  UID-key stability, common processing rate, opposite-polarity stereo, mono vs
  stereo +3.0103 LU, chunk invariance, incomplete windows, silence, invalid PCM
  and unsupported layout checks passed. 24 captured signals at 44.1/48/96/192 kHz
  (31.5/100/1000/10000 Hz, silence/absolute and relative gating probes) agree with
  independent FFmpeg `ebur128` within 0.12 LU; maximum observed difference
  **0.053101 LU**. This is engineering verification, not meter certification.
- Desktop `swift test --filter 'AudioFidelityPolicyTests|AudioFeatureAnalysisTests|M4AudioPathMilestoneTests'`:
  15 tests passed, including asynchronous album-cache/stale-revision rejection,
  inverse-polarity content only after 61 seconds,
  missing LUFS/cache handling, unchanged source bytes, the live controller's
  192 -> 96 kHz configuration and nine offline source-mixer/Space/output paths
  (44.1/48/192 kHz source × 44.1/48/96 kHz output). Tests do not change DAC rate.
- `bash tests/run_dsp_transition_regression.sh --gain-path`: all 72 cases and
  four negative controls passed. Shipping analysis,
  gain laws and control interpolation are checked with 72 stereo waveform cases
  and negative controls for unsmoothed writes, duplicate/inactive gain planning
  and output muting. The route-change case now ends on a neutral external route
  at volume 0.2, so bypass cannot pass merely because volume is high.
- iOS Debug Simulator build passed. Output settings rows were rendered in an
  isolated host using the production SwiftUI view on SE (3rd generation) and
  iPhone 16 Pro Max, in all three languages; content is contained within safe
  areas and the English SE label wraps between words. Both PreviewProvider
  devices are included. This host is a layout test, not an acoustic route test.

## Release/device work

⭕️ [Pending] Physical iPhone/Mac listening at matched loudness; USB DAC and
Bluetooth speaker/headphone classification and persisted UID behavior; reconnect,
route switching, lock screen, interruptions, and actual negotiated output rates.

⭕️ [Pending] CPU/energy/thermal behavior of the common 96 kHz Mac rack and
full-track analysis with long/high-rate files; iPhone slider/route transitions
under real UI load. Offline and simulator success do not establish audibility.

🟢 [Done] The final-rate protector now covers the complete Mac qualification
path; see [Mac true-peak validation](MAC_TRUE_PEAK_VALIDATION.md).

⭕️ [Pending] Physical-device qualification and ordinary-build activation on
iPhone and Mac. Keep the common -1 dBTP requirements after final SRC;
offline success alone does not enable distribution.

🔴 [Later] Explicit multichannel channel-layout weighting, an independent
streamed LUFS analysis for iPhone native-only playback, exact concatenated-album
boundary windows, calibrated acoustic loudness profiles, measured HRTFs,
residual/alias measurements and optional local oversampling of nonlinear stages.
Formal BS.1770 conformance vectors remain an additional qualification task.

References: [ITU-R BS.1770](https://www.itu.int/rec/R-REC-BS.1770/en),
[libebur128 rate-adapted filter coefficients](https://github.com/jiixyj/libebur128/blob/master/ebur128/ebur128.c),
[FFmpeg ebur128](https://ffmpeg.org/ffmpeg-filters.html#ebur128-1),
[Apple audio-session rate preferences](https://developer.apple.com/library/archive/qa/qa1631/_index.html).
