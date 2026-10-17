# Mac final-output true-peak qualification — 2026-10-17

## Implementation and activation

🟢 [Done] The desktop local-file playback graph now has a qualification-only final-rate protector, using the same `TruePeakDSP.hpp`, `TruePeakAudioUnit.mm` and public header as iPhone. The cross-repository runner checks all three files byte-for-byte before testing. Both repositories remain independently buildable.

```text
file-rate players (normalization / crossfade gains)
  → source mixer → 96 kHz complete effect rack
  → existing effect-dependent sample limiter / trim
  → final conversion mixer (actual output rate / channels, user volume)
  → linked true-peak protector
  → unity main mixer (post-protection meter tap)
  → output at that same rate / channel count
```

The final protector is independent of effect bypass and loudness-normalization settings. Existing sample protection remains available before final conversion when effects are enabled. User volume is clamped to 0…1 (nonfinite values mute) and applied before the final protector. Stereo-to-mono mapping also occurs before protection; Apple’s equal-power summation can add about 3 dB for identical channels.

`PlaybackController.configureEngine` rebuilds the final stage from the actual output format on initial load and route recovery. Unsupported protected formats fail instead of silently falling back to unprotected output. Abrupt stop/pause/seek stops the engine before resetting queued lookahead audio; compatible continuous handoffs retain the shared downstream state. Source clocks and normalization remain upstream. Diagnostics expose qualification activation and the additional latency. Protected Apple Music system playback is outside this local graph.

The main mixer is explicitly pinned to the final format. Apple documents that clients setting this connection format must also update it after configuration changes: [mainMixerNode](https://developer.apple.com/documentation/avfaudio/avaudioengine/mainmixernode). Tests validate the offline graph formats; physical route negotiation remains pending.

⭕️ [Pending] Ordinary builds retain the stock output graph. Enable qualification with `ONGAKU_ENABLE_TRUE_PEAK`, matching iPhone. This is not yet a distribution default: live audio, final tail delivery, route changes and resource use must pass on physical devices first. There is no new user-facing switch.

## Common acceptance criteria

- Same −1 dBTP engineering ceiling and 84 adversarial input signals as iPhone: 44.1/48/96 kHz output, near-Nyquist tones/phases, impulse, alternating signal, step, multitone and sweep; quiet/overloaded inputs; irregular 127/512/61/256-frame render blocks.
- Independent 8x/16x reconstruction with adaptive 32x phase refinement (97-tap meter, separate from the 129-tap limiter detector), convergence check (unchanged 0.08 dB tolerance), and a deliberately bypassed overload that must exceed full scale.
- Captured final PCM checked separately by FFmpeg `ebur128=peak=true`, calibrated against the known +0.984 dB intersample sine. This is an engineering cross-check, not certified meter conformance.
- Same linked-channel gain, quiet-PCM transparency after declared delay, block-size invariance, reset, invalid/nonfinite input, zero counted processing allocations, ASan/UBSan and real AU resource-lifecycle checks.
- Four milliseconds of lookahead plus 64 detector frames: 241/256/448 frames at 44.1/48/96 kHz, approximately 5.465/5.333/4.667 ms. The detector target is −1.5 dBFS with reconstruction margin for the −1 dBTP acceptance gate.

## Automated results

| Check | Result |
| --- | --- |
| Mac full rack + sample protection + final protection | 84/84 pass; maximum reconstructed peak 0.848809 (−1.424 dB) |
| Mac OFF: sample protection bypassed, final protection active | 84/84 pass; maximum reconstructed peak 0.854534 (−1.365 dB) |
| Independent FFmpeg meter, both Mac matrices | 168/168 pass; maximum −1.5 dBFS / −1.2 dBFS respectively; calibration +1.0 dBFS |
| iPhone protected matrix, same updated runner | 84/84 pass; maximum 0.847640 (−1.436 dB) |
| Mac full-rack controlled overlaps | 72/72 pairs pass; maximum sample difference 5.9604645e−7; reconstructed peak 0.8444463 |
| iPhone protected overlaps | 18/18 pairs pass; maximum sample difference 2.3841858e−7; reconstructed peak 0.844502 |
| Shared DSP / real AU ASan + UBSan | Pass: quiet PCM, latency, stereo linking, chunk invariance, reset, buffer/resource lifecycle and zero counted render allocations |
| Desktop stage/controller/audio-policy tests | 10 tests in 3 suites pass in each of ordinary and qualification SwiftPM builds |
| Xcode Debug qualification builds | Both `OngakuDesktop` and `OngakuDesktopAppStore` pass, code signing disabled |

Evidence: [Mac protected matrix](measurements/mac-final-output-protected-2026-10-17.json), [OFF matrix](measurements/mac-final-output-off-protected-2026-10-17.json), [independent protected](measurements/mac-final-output-independent-2026-10-17.json), [independent OFF](measurements/mac-final-output-off-independent-2026-10-17.json), [iPhone comparison](measurements/iphone-final-output-protected-2026-10-17.json), [72 overlap measurements](measurements/mac-true-peak-handoffs-2026-10-17.txt).

Two untrimmed OFF-mode sweeps at 48/96 kHz initially exceeded the 8x→16x convergence tolerance (0.084120/0.085632 dB). Refining to 32 phases gave zero additional peak difference in both; the 0.08 dB tolerance and −1 dBTP ceiling were not relaxed. Both platforms use this same adaptive meter. The FFmpeg meter uses its own reconstruction and reports a different worst-case value; both independent estimates satisfy the gate for these fixtures.

The Mac matrix compiles the actual desktop registry, every effect module, sample-protection stage and final-output connector. The legacy-comparison matrix bypasses the rack modules but enables the upstream sample limiter; the additional OFF matrix bypasses both the rack modules and that sample limiter. Both exercise the new final protector. Neither matrix alone represents all possible effect parameters.

The transition matrix covers 44.1/48/96/192 kHz source files through the fixed 96 kHz rack to 44.1/48/96 kHz final output, with OFF/Exciter/Warm, quiet/hot input and complementary two-player overlaps. It compares against a matched single-player render, checks audible energy, finite samples and the same reconstructed ceiling. This validates controlled offline overlaps, not asynchronous live host-clock scheduling or every effect topology.

The final-stage lifecycle test reuses one engine/AU across 44.1→48→96→192→384→48 kHz and stereo/mono changes, checks reported latency and unity post-protection gain, confirms volume precedes limiting, and resets queued hot PCM before silence. The 192/384 kHz checks are format/audio/reset smoke tests, not the full 84-case peak matrix.

## Reproduce

From the iPhone repository (`Ongaku`, with adjacent `Ongaku-desktop`; override `ONGAKU_DESKTOP_ROOT` if needed):

```sh
TRUE_PEAK_SANITIZERS=1 bash tests/run_true_peak_unit_regression.sh
ONGAKU_PEAK_PCM_DIRECTORY=/private/tmp/OngakuMacProtectedPCM \
  bash tests/run_desktop_true_peak_regression.sh --protected --require-ceiling /private/tmp/mac-peaks.json
python3 tests/verify_true_peak_meter.py /private/tmp/OngakuMacProtectedPCM /private/tmp/mac-independent.json
ONGAKU_PEAK_PCM_DIRECTORY=/private/tmp/OngakuMacOffProtectedPCM \
  bash tests/run_desktop_true_peak_regression.sh --protected --effects-off --require-ceiling /private/tmp/mac-off-peaks.json
python3 tests/verify_true_peak_meter.py /private/tmp/OngakuMacOffProtectedPCM /private/tmp/mac-off-independent.json
bash tests/run_desktop_true_peak_regression.sh --handoff
bash tests/run_final_output_peak_regression.sh --protected --require-ceiling /private/tmp/iphone-peaks.json
bash tests/run_protected_graph_regression.sh
```

From `Ongaku-desktop`:

```sh
swift test --filter 'FinalOutputProtectionTests|M4AudioPathMilestoneTests|AudioFidelityPolicyTests'
swift test -Xswiftc -DONGAKU_ENABLE_TRUE_PEAK \
  --filter 'FinalOutputProtectionTests|M4AudioPathMilestoneTests|AudioFidelityPolicyTests'
xcodebuild -project OngakuDesktop.xcodeproj -scheme OngakuDesktop \
  -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG ONGAKU_ENABLE_TRUE_PEAK' build
```

For the App Store qualification scheme, use `OngakuDesktopAppStore` and retain `APP_STORE` in the compilation conditions. Omit the true-peak condition for an ordinary build. The standalone stage-level `run_final_output_peak_regression.sh --desktop` remains a historical sample-protection baseline; it does not exercise the full new graph.

## Remaining gates

⭕️ [Pending] Physical Mac/iPhone sound, pause/seek/stop/repeat and final tail delivery; gapless/crossfade timing against the device clock; post-protection visualization timing; output switching and sleep/wake; built-in/wired/Bluetooth/USB DAC routes and negotiated sample rates/channel layouts.

⭕️ [Pending] Sustained CPU, thermal/energy use and subjective transparency of active limiting under real UI/background load; downstream codec/DAC reconstruction. No universal −1 dBTP, analog-output or bit-perfect claim is made.

🔴 [Later] Extend the full adversarial matrix to additional output rates/multichannel layouts and qualify against formal BS.1770 meter vectors. Keep ordinary-build activation pending the physical-device gates above.
