# Strong-input protected product path — 2026-11-07

Debug qualification flags: BOTH ONGAKU_ENABLE_TRUE_PEAK and ONGAKU_ENABLE_AUDIO_THREAD_GAIN. Only ProductFrameCapacityTests.strongInputTransitions was selected. One declaration contains 32 pairs (64 renders). The preliminary 32-render trial is retained separately; it preceded the explicit clipping ON/OFF control and is not counted as another final test.

The shipping graph builder and all effect settings at normalized 0.5 are driven through the existing Debug audit path. Input is stereo Float32 CAF at 44.1/48 kHz, with either amplitude-4.0 12 kHz sinusoids (right channel phase +0.7 radians), or isolated +4/-3 channel pulses every 1024 samples. A floating-point value 4.0 intentionally exceeds nominal 0 dBFS to stress the graph. User volume is 1. Output rates are 88.2/48 kHz and block limits 512/2048. Each case first rebuilds with the two-player shipping crossfade gains, then loads a same-format separate file into the retained graph without overlap. Generation must match after reuse. The audit rejects unsuccessful frame delivery and nonfinite PCM; every reported peak must be nonzero and <=0.9.

The clipping-prevention preference is explicitly false and true in isolated rounds; its original stored value (including an absent key) is restored on normal test completion. That preference controls normalization/crossfade protection and does NOT disable the compile-time final true-peak stage in this qualification configuration. The audit requires final true-peak instantiation and restores gain intent after allocation. The frame matrix holds native gain stages at unity; it is not a ramp waveform measurement.

**PASS: all 64 renders; 1 declaration; 0 recorded issues.** Observed per-render sample peak range 0.40723085 to 0.84139514. The maximum is approximately -1.500 dBFS SAMPLE peak. No -10874 or nonfinite sample was encountered in this matrix. This is not an independently reconstructed true-peak/ISP measurement and must not be labelled -1.5 dBTP qualification.

Only tests were added in this step. No DSP coefficients, protection defaults, controller implementation or deployment configuration changed. The native true-peak/gain sources and common capacity policy remain byte-identical across mobile and Mac. No new independent iPhone/Xcode app build was run: the modified test target compiled successfully with the qualification flags; the preceding app build remains a historical result.

🟠 [Next] Independently reconstruct output intersample peaks, including phase/amplitude differences and longer release/tail behavior. The present peak-only return value does not retain PCM for that analysis. No perceptual sound-quality, normalization loudness or click/reverb guarantee follows from these sample maxima.

⭕️ [Pending] Physical 88.2 kHz negotiation and original -10874 reproduction, actual device switch/unplug/reconnect, real Music assets and queue/repeat, signed builds, speaker/headphone listening and thermal/power conditions. Offline success does not close those physical issues.

[Raw logs and final source hash](../measurements/product-strong-input-2026-11-07/).

Follow-up: [Independent reconstructed peaks and long tails](INDEPENDENT_INTERSAMPLE_2026-11-07.md) completes the scoped local Next above with calibrated independent interpolation, 18 product captures, eight-second tails and isolated limiter release. Physical verification remains Pending.
