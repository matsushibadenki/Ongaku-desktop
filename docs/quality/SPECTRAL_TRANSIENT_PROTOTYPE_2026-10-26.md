# Gentle spectral transient prototype — 2026-10-26

## Availability and design

🟢 [Done] Add a default-OFF prototype to the **main iPhone app and Mac player** Pro rack. Effect names are English in all three display languages: Transient · Prototype. All 11 effect-name resource keys match English across both apps; descriptions and parameter labels remain localized. Intensity defaults to 0.20 on a normalized 0...1 control. Missing entries in old saved settings retain this OFF default; ordinary mode/persistence logic is unchanged. The iOS synchronization companion's transfer implementation is unrelated to this change.

DSP, AU header/implementation and Swift effect adapter are byte-identical between repositories. The module is placed after Exciter and before OptoFET in both racks. Register `spectralTransient` in both settings models, clipping reduction (`intensity`), persistence and generic UI; active module count becomes 11 (10 Pro + 1 Basic). Existing Basic/OFF behavior and other saved effect identities remain intact.

This is a **causal three-band transient prototype, not an FFT/STFT transient/tonal separator**. Complementary one-pole branches use 250 Hz and min(4,000 Hz, 0.35 × sample rate) crossovers. The original dry signal is retained; a small mid/high correction follows linked peak envelopes. Mid/high weights are at most 0.05/0.03 times intensity. A common detector across channels avoids independent left/right gain decisions. Compare an 8 ms peak hold/release with its 50 ms smoothed envelope; comparing peak against mean absolute level would unnecessarily brighten steady tones. Low-level activity is softly reduced below a 0.01 detector level. No dedicated harmonic exciter, lookahead or reverb generator is added. Time-varying gain can still produce modulation products; spectral transparency is not guaranteed. This does not reconstruct lost source information or reproduce a commercial spectral splitter.

The control thread writes lock-free atomic amount/reset requests. Render owns filters, envelope and ramp state. A changed amount starts a 20 ms **rendered-sample** linear ramp at the next successful render block. Rapid control writes coalesce to the latest target; this is not a wall-clock/UI-response guarantee. OFF continues updating detection history for warm re-entry and therefore has some processing cost even though settled output is dry. The C++ test observes no heap allocations in its DSP render call. CPU/energy and first-rack initialization costs are not certified here.

## Volume, delay and tail behavior

- The adapter reports a conservative reference headroom estimate of 1.5 × intensity dB while effectively enabled. The existing host gain staging and authoritative final limiter remain in charge, including an OFF transition whose rendered amount has not reached zero yet. The estimate is not a replacement for actual output protection.
- There is no FIFO/window/lookahead in this effect: AU latency, estimated frames and transition latency are all zero. Real-engine OFF impulse output equals the graph without this node at four rates; ON begins at the same sample. **No extra fixed-delay compensation is necessary.** Causal crossover filters still have frequency-dependent phase; zero fixed latency does not mean linear/zero phase. Existing final true-peak lookahead and source-handoff alignment are unchanged.
- Toggle changes only the rendered blend; it does not clear filter history, reconnect nodes or reset an upstream reverb. AU tailTime is a conservative 40 ms allowance for the small crossover residual on the bounded test signals. This is not an additional musical reverb. Transport reset requests are consumed on render, behind the host's existing muted/drained boundary; arbitrary unmuted live resets are not qualified as click-free.
- Existing application-wide protected fade-out/fade-in is retained for toggles; it can briefly attenuate the whole mix, including tails. We have not replaced that policy with an unprotected bypass. Direct-node tail preservation and host-transition guards are verified separately below.
- Maximum-strength steady-tone DSP RMS differs by less than 0.2% in six-rate fixtures. This is not an app-wide loudness-match guarantee: host headroom, limiter and other effects may alter level. Listening comparisons should match loudness.

Accepted AU format is equal input/output noninterleaved Float32, 1...8 channels, 8...384 kHz. AU tests exercise mono/stereo/6/8 channels with explicit surround layouts. They do **not** establish end-to-end multichannel Music-file or DAC support beyond the player's existing conversion/route policy. No new processing support is added to DRM/system-player paths.

## Local verification

| Gate | Result / scope |
|---|---|
| C++ DSP, optimized | PASS at 8/44.1/48/96/192/384 kHz: default OFF PCM, sample alignment, block partition invariance, actual enhancement, linked stereo ratio, no render `new`, steady-tone RMS, ON/OFF ramp reference, dry tail after OFF, reset/restart |
| ASan + UBSan | Same DSP gate passes without reported sanitizer issue |
| Negative control | Replacing the ramp with one sample is rejected by the nonzero-waveform switch test |
| Actual custom AU | PASS: 1/2/6/8 channels × 44.1/48/96/192 kHz, allocation, fixed-delay/tail metadata, OFF PCM, active finite PCM, block/bus guards, reset/silence and reallocation |
| Swift package related gates | 36 tests in five suites pass: prototype/settings, all-effect signal/peak matrix, transition unit tests and rack input regression |
| Final focused prototype gate | Three tests pass, including the additional OFF-vs-no-node real-engine identity check and ON impulse enhancement; this is an overlapping subset, not 39 unique tests |
| iPhone shipping-transition extraction | 24 focused scenarios pass, including continuous parameters, ON/OFF, auto-DSP interaction, handoff deferral and stop cancellation; interpolation/muting negative controls rejected |
| Mac shipping-transition extraction | 48 focused PCM scenarios pass, including control overlap, protected bypass and stop; unprotected/mute/unsafe-bypass negative controls rejected |
| iPhone-path protected handoff | Six source/output/level pairs pass; max difference 2.3841858e-7, max reconstructed peak 0.84438473 (criterion ≤ -1 dBTP) |
| Mac full-rack protected handoff | 24 pairs across 44.1/48/96/192 kHz source rates and 44.1/48/96 kHz output rates pass; max difference 8.940697e-8, max reconstructed peak 0.842271 |
| Builds | Main iPhone Simulator Debug, normal Mac Debug and Universal Mac App Store Release all succeed with signing disabled; release binary contains the new AU class in arm64 and x86_64 slices |

The true-peak graphs explicitly enable the existing true-peak path; these fixtures do not change its shipping activation policy. An independent 16-phase/96-tap reconstruction of hot, toggled prototype DSP through the limiter measures approximately -1.4074/-1.4095/-1.4194/-1.4257 dBTP at 44.1/48/96/192 kHz, below the -1 dBTP criterion. Real-engine Apple peak-limiter + post-margin tests also pass at those rates, with observed sample peaks ≤0.794042; this sample-peak result is not itself a true-peak measurement.

Upstream large-hall reverb remains audible after OFF/ON/OFF at 0.256/0.427/0.597 seconds in the offline fixture. Post-switch tail energies are approximately 0.0025824/0.0004622/0.0001618, and boundary jumps 0.0010697/0.0001444/0.0000252. These fixture bounds detect tail loss/discontinuity; they do not prove subjective inaudibility for all recordings.

Standalone audit scripts previously compiled only Swift effect sources. They now use a shared helper to link this native AU and import the complete bridge, with source-parity checks when the sibling desktop repo is available. Existing audit scopes are not silently skipped. The desktop extraction fixture now imports the shipping audio-ramp selector and inserts its virtual clock argument in the actual initializer order. The ordinary control-rate configuration is qualified; audio-thread-gain candidate activation is not newly qualified. Expected negative-control crashes/nonzero exits are accepted only after their intended failure messages are matched.

No real-time benchmark, physical listening, installed/signed-app run, deployment or remote CI result is claimed. Builds prove registration/compilation, not listening quality.

## Reproduction and evidence

From the main mobile repository, with the sibling desktop repository available:

```sh
bash tests/run_spectral_transient_regression.sh
bash tests/run_dsp_transition_regression.sh --spectral-transient-only
bash tests/run_protected_graph_regression.sh --spectral-transient-only
bash tests/run_desktop_effect_transition_regression.sh --spectral-transient-only
bash tests/run_desktop_true_peak_regression.sh --handoff --spectral-transient-only
```

The desktop package tests are `SpectralTransientPrototypeTests`, `AudioEffectPresetTests`, `AudioEffectSignalTests`, `EffectParameterTransitionTests` and `EffectRackInputTests`. The standalone native AU may need normal CoreAudio access; the restricted tool sandbox could not register it, and the successful run used the permitted elevated test context. There was no approval rejection or unresolved test blocker.

[Compact results and shared-source hashes](../measurements/spectral-transient-2026-10-26/).

## Next qualification

- 🟢 [Done] Isolated actual-AU OFF-inclusive startup/render cost and loudness-matched representative PCM are recorded in the [follow-up audit](TRANSIENT_COST_AND_PCM_COMPARISON_2026-10-26.md). Native/Simulator results are not physical-iPhone performance or listening certification.
- 🟠 [Next] Complete-rack matched comparisons alongside Exciter/BBE/space and final host protection. Keep this a voluntary default-OFF prototype.
- 🔴 [Later] Consider finer spectral/FFT separation only if comparative results justify added latency, phase/reconstruction complexity and device cost; that would require explicit delay compensation.
- ⭕️ [Pending] Physical iPhone speakers/headphones/Bluetooth/DAC and Mac outputs, real Music-managed files/routes/rates, brightness/harshness/noise emphasis, stereo image and listening fatigue, toggle/tail audibility, stop/resume and quality-data replacement under background/sleep/UI contention, thermal/energy/underruns, actual multichannel playback and Intel execution. No automatic activation before that evaluation.
