# Independent intersample peaks, phase/level and long tail — 2026-11-07

## Method and independence

The test-only meter shares no detector code, coefficients or state with TruePeakDSP.hpp. It reconstructs each channel in Float64 using Kaiser-windowed sinc (beta 9), radius 96, 32 phases, evaluated with Accelerate vDSP correlation. Phase zero is measured directly. Each kernel is DC-normalized; samples before/after the captured region are zero-extended, and full captured edges are included in product measurements. The production detector instead uses radius 64, 8 phases and a Blackman window. This is an engineering reconstruction estimate, not a certified BS.1770 instrument or a characterization of a physical DAC.

Analytic calibration: a quarter-sample-rate sine with phase pi/4 has sample peak 0.70710677 and reconstructed peak 0.9999988414 (expected 1). The sample-only value would pass a -1 dB threshold; the reconstructed value correctly fails it. This negative control demonstrates detection of a known +3.01 dB intersample excess. Interior DC, silence and edge impulses also pass. The known sine is rechecked with radius 192/64 phases. Calibration trims the analytic sine/DC edges to compare the infinite steady signal; product measurements do not trim them.

## Product matrix

Both ONGAKU_ENABLE_TRUE_PEAK and ONGAKU_ENABLE_AUDIO_THREAD_GAIN are compiled ON. The shipping graph builder and all effects are used; normalized parameters are 0.5. A Debug-only output callback copies PCM after renderOffline returns, not inside the real-time render observer. A second actual file is scheduled for incoming playback, with amplitude 1.4 versus outgoing 4, phase +1.3 radians, right-channel gain 0.65 and phase +0.9 radians. The 12 kHz tones and early impulse components are specified in the fixture code; input becomes zero after 0.4 seconds. Tone amplitudes are Float32 and intentionally exceed nominal full scale. Source files contain nine seconds including silence, so the player remains scheduled during the tail observation.

Sixteen short captures (>=0.8 s) cross source 44.1/48 kHz × output 88.2/48 kHz × phase pi/4 or 3pi/4 × user volume 1 or 0.3. Block size is 512 for volume 1 and 2048 for volume 0.3: those two factors are paired, not independently crossed. The shipping crossfade gain policy drives overlap over 0.25 s. Normalization/crossfade clipping prevention is explicitly OFF, with its original stored value restored at normal test completion; final native true-peak remains ON by the qualification flag. Native gain stages are held at unity in the frame driver; this matrix does not measure their transport-ramp waveforms.

Two more full-product captures run for >=8 s, with Space size 0.9 selecting the cathedral factory preset: 44.1→88.2 kHz and 48→48 kHz, volume 1, no overlap. Other parameters remain at 0.5. Early tail RMS (0.8–1.3 s) is approximately 1.65e-4 / 1.75e-4; late RMS (7.5–8 s) is approximately 3.57e-12 / 3.26e-12. Both have nonzero early tails and decreasing late energy. These observations are not RT60, every-preset or perceptual tail qualification.

All 18 reconstructed product peaks pass the -1 dBTP engineering gate (linear 0.89125094). The largest 32-phase estimate is 0.84328400. The PCM selected by that maximum is remeasured at radius 192, 64 phases: **0.84335676, approximately -1.47977 dBTP**, delta **0.00074942 dB** (required <0.05 dB). Dense reconstruction is a convergence check of this one worst-primary PCM, not an error bound for every waveform. Do not infer that the largest independent product peak must equal a largest sample peak.

## Isolated release and regression

A separate test uses the actual FinalOutputProtection stage, 96→88.2 kHz conversion, amplitude-4 997 Hz for 0.1 s followed by amplitude-0.04 quiet tone. It captures >1.3 s. Early quiet RMS (0.12–0.14 s) is 0.01348114; late quiet RMS (0.8–1 s) is 0.02828124, compared with expected 0.02828427 (within 2%, actually about 0.011% low). Late RMS must exceed early RMS by 10%. Independent peak is 0.84179349 and passes -1 dBTP. This verifies final-limiter recovery independently of the other compressors/reverbs; it does not prescribe their combined envelope.

The extended driver also reruns the preceding 16 rebuilt +16 retained-graph frame matrix. Final command:

`swift test --jobs 2 -Xswiftc -DONGAKU_ENABLE_TRUE_PEAK -Xswiftc -DONGAKU_ENABLE_AUDIO_THREAD_GAIN --filter 'IndependentIntersampleMeterTests|ProductIntersampleTests|IndependentLimiterReleaseTests|ProductFrameCapacityTests.routeAndTrackTransitions'`

**4 declarations / 4 suites PASS** (calibration; 18-capture product ISP/tail matrix; isolated limiter release; 32-render prior frame regression). Intermediate 8-case phase/level and isolated-release logs are retained separately, not added as extra final declarations. No assertion was relaxed and no production detector coefficient changed.

Mac qualification Debug and App Store Release signing-disabled Xcode builds PASS. The capture/long-render driver is excluded from Release. The identical independent-meter source is placed in iPhone tests and compiles as an arm64 iOS Simulator module. This is not an independent iPhone app build or device measurement. Gain/true-peak DSP headers and AU wrappers, as well as AudioProcessingPolicy, match between repositories; native hashes are retained. Production defaults and rollout flags remain unchanged. Existing integration transport passes from the preceding step are historical; this step reruns the listed frame regression, not every transport test.

⭕️ [Pending] Physical Mac/iPhone 88.2 kHz outputs and DAC reconstruction; real route events/unplug/reconnect; original -10874 and render-gap reproduction; real Music assets, queue/repeat, background interruption and signed Sandbox; actual click, reverb and loudness-matched listening; power/thermal behavior. The ordinary default build without final true-peak is not qualified by these ON/ON results. Other parameters, presets, mono/multichannel and longer-than-observed tails remain outside this matrix.

[Logs, commands and final-source hashes](../measurements/independent-intersample-2026-11-07/).
