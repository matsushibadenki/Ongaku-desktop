# Vocal Presence prototype — 2026-10-28

## Design

🟢 [Done] Add `Vocal Presence · Prototype` to the iPhone and Mac Pro racks, after Transient and before OptoFET. Its only parameter, Intensity, defaults to 0.35; the switch defaults OFF, including when a previous saved configuration has no entry. Both apps use the same byte-identical Swift effect implementation and matching parameter definitions and English effect name. Descriptions remain localized in English, Japanese and Simplified Chinese.

This is one stock `AVAudioUnitEQ` parametric band centered at 2,800 Hz, bandwidth 1.2 octaves, gain 0…1.2 dB proportional to intensity (0.42 dB at the default). It operates on the complete mix: guitars, percussion and other content in the band can also change. There is no vocal isolation, automatic instrument suppression, AI recognition, M/S processing, dynamic de-esser, harmonic synthesis or reverb. The small high-frequency response is measured below. A dynamic de-esser is deferred until real listening or an objective comparison establishes the need; it could also affect cymbals and instruments.

The band remains attached and flat when OFF; no abrupt graph insertion/removal is needed. The hosts apply their existing protected ON/OFF commit and interpolate continuous controls, including deferring rack writes during a track handoff. `estimatedGainBoostDB` reports the selected center-frequency boost as a gain-planning reference, not a transient peak guarantee. Mac retains its final true-peak stage; the default iPhone build retains Apple peak limiting with a post-limiter sample margin. Reverb paths, routing and upsampling are unchanged. Native EQ is causal and may introduce frequency-dependent phase; measured unit metadata and absence of audible latency are not inferred from the center-frequency response.

## Measured results

All results are from deterministic synthetic PCM and native Apple audio components on the development Mac; the iPhone Simulator build and these tests are not physical-iPhone performance or hearing results.


### Response and defaults

`tests/run_vocal_presence_regression.sh` measures the actual Apple EQ in a stereo AVAudioEngine at 44.1 / 48 / 96 / 192 kHz. For 250 Hz, 2,800 Hz and 8,000 Hz sines, OFF differs from the no-node graph by less than 1e−5 full scale; in these runs the largest observed difference was approximately 2.51e−15. At 2,800 Hz, default/maximum gains measure +0.420/+1.200 dB. At 8,000 Hz maximum is +0.105…+0.124 dB; the implementation does not dynamically control sibilance. All measured PCM is finite and the gain reference matches the configured contour. These are steady sines, not a proof of perceptual improvement or silence-free transients for every recording.

### Transitions and peak protection

- iPhone extracted production transition policy and actual effect graph: 24 cases across 44.1/48/96 kHz; ON/OFF and parameter gestures, automatic DSP, stop cancellation and handoff deferral. In the tested ON/OFF waveforms the maximum adjacent sample step was 0.025351 full scale, below the fixture's 0.08 threshold. Muting and un-interpolated update negative controls, and an injected +0.25 click, are rejected. These are checks against finite test signals, not a universal click-free guarantee.
- Mac extracted production transition policy: 48 cases, three output rates, stock protection and final true-peak variants; gestures, ON/OFF, handoff overlap and stop/restart. Usual mute, unprotected update and unsafe-bypass negative controls are rejected. An additional 18 focused ON/OFF/overlap cases check adjacent PCM steps, with a maximum of 0.0150592 full scale against the same 0.08 fixture threshold. An injected +0.25 click is rejected.
- iPhone **normal-build stock** protection: six reference/handoff pairs at 44.1/48/96 kHz output, 96 kHz input, signal levels 0.1 and 4.0, maximum effect strength. With the Apple peak limiter and its −1 dB post-limiter margin before rate conversion, the largest output sample peak was 0.850596 and 16-phase reconstructed peak 0.852529 for these signals. The test does not include source-specific gain planning and is not a general true-peak ceiling guarantee. The default mobile app does not enable its optional custom true-peak AU unless `ONGAKU_ENABLE_TRUE_PEAK` is specified.
- Optional mobile custom true-peak qualification: six equivalent pairs, maximum reconstructed peak 0.844233 (−1.471 dBTP) and reference/handoff maximum sample difference 2.39e−7. This is a qualification graph, not evidence that the optional AU is enabled in the default app.
- Mac full protected output path with final true-peak stage: 24 reference/handoff pairs, input 44.1/48/96/192 kHz and output 44.1/48/96 kHz, both levels and maximum effect strength. Maximum 16-phase reconstructed peak 0.842814 (−1.485 dBTP); maximum reference/handoff difference 1.79e−7. Both custom true-peak test sets meet their −1 dBTP threshold for these fixtures. Tests run offline on the development Mac and do not certify physical iPhone/DAC output or all source material.

### Build and UI

- Main iPhone Debug build for iOS Simulator arm64: PASS, signing disabled. Mac App Store Release build: PASS, signing disabled; binary contains arm64 and x86_64. Mac preset and existing transient suites: 7 tests pass, including the updated 12-module registry and 11 Pro entries.
- Mac `EffectRackInputTests.productionRackClicks`: PASS across English/Japanese/Simplified Chinese, 420/900 pt, Basic/Pro, multiple scroll positions, repeated controls and switches. A Japanese 900-pt green-theme capture was visually inspected for new-card wrapping and alignment. The mobile generic card has not been visually inspected on a physical device.
- Initially running several AVAudioEngine audits simultaneously caused CoreAudio component initialization failures before measurement. The affected tests were rerun individually; final results above are the successful runs.

[Measurement logs and source hashes](../measurements/vocal-presence-2026-10-28/).

## Remaining work

- 🟠 [Next] Compare level-matched music-like PCM and full-rack combinations with OptoFET/Exciter/space to decide whether the chosen amount provides useful vocal clarity and whether a dynamic de-esser is warranted. Measure effect cost and any phase/headroom impact in that context.
- ⭕️ [Pending] Physical iPhone built-in speakers, headphones, Bluetooth/DAC and Mac outputs with real music, quiet/loud and different vocal styles: intelligibility, harshness/sibilance, instrument balance, stereo image, level-matched preference, fatigue, and ON/OFF or residual click audibility. Validate route changes, actual latency/CPU/energy, rapid toggles, track handoffs and stop/resume on devices. Keep default OFF while listening evaluation is pending.
