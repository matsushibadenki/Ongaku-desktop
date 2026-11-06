# Shared custom Audio Unit alignment — 2026-11-06

## Findings and implementation

The iPhone Transient factory/header/Swift adapter still predated the Mac launch-crash hardening: nonnull factory, uncaught Objective-C registration/construction exceptions, and a forced AU subclass cast. Its MM source/header/adapter differed from Mac, so the shared audit's intentional source-parity gate stopped before rendering. This was a real code/infrastructure gap; it does not establish the cause of the user's spontaneous High Quality OFF report.

Copied the existing Mac implementation to iPhone: nullable factory, registration/construction exception handling and a mixer bypass for nil or wrong-type results. An unavailable Transient remains inactive with zero estimated boost even when the saved setting requests ON; the saved setting is retained. Audio still traverses the rest of the rack and output protection. The valid-unit DSP, coefficients, 20 ms amount ramp, defaults (OFF), filter/tail reset and latency are unchanged. Common gain and true-peak now also use Mac's SandboxSafe component flag. All 11 native implementation/header/DSP and shared gain/Transient adapter pairs match their Mac counterparts; no Mac audio runtime source changed in this stage.

Removed the duplicate logger shim from the extracted mode fixture (EffectAuditSupport already supplies it). Fixed the DSP runner's no-argument set-u failure in its final optional Vocal test branch. The parity gate remains strict and negative controls remain enabled; they were not removed to get a pass.

## Final verification

- `bash tests/run_spectral_transient_fallback_regression.sh`: six offline graph renders (nil/wrong-type × 44.1/48/96 kHz), each with 16 ON/OFF and reset calls. Actual output matches the unity reference exactly (max absolute difference 0), is finite/non-silent, and the effect never claims active boost. Uses shipping Swift adapter with an injected failing factory, not a mock adapter.
- `bash tests/run_spectral_transient_regression.sh`: six-rate DSP checks, ASan/UBSan, real AU mono/stereo/6/8-channel × four rates, allocation/reset/null-buffer/oversized-block/bus guards and abrupt-ramp negative control PASS. The native harness now checks actual component registration flags.
- `env GAIN_SANITIZERS=1 bash tests/run_gain_envelope_regression.sh --desktop`: exact mute/completion, rendered ramps, retargeting and lifecycle tests PASS; 30,000 concurrent commands / 10,000 render blocks PASS; coarse 48-step negative control rejected. The runner compares current Mac/mobile source and header parity before executing; actual SandboxSafe registration is now asserted.
- `env TRUE_PEAK_SANITIZERS=1 bash tests/run_true_peak_unit_regression.sh`: DSP and real AU protection/resource/reset/invalid-input/block/bus tests PASS; actual SandboxSafe registration is now asserted.
- `bash tests/run_dsp_transition_regression.sh`: saved OFF/BASIC/Pro selection, 48 shipping effect/automatic-DSP transitions, latest-request coalescing, handoff deferral and stop cancellation PASS; non-interpolated update and output-mute negative controls rejected. This uses extracted shipping control methods and actual effects/stock limiter, not an actual Music library/network/physical playback session.
- iPhone Debug generic Simulator build, arm64/x86_64, signing disabled: final BUILD SUCCEEDED. This compiles the actual application; no production app was launched or reconfigured.
- Diff and shell syntax checks PASS.

Initial fallback test fixture used a nonexistent settings initializer argument; corrected to set the production parameter dictionary. Its restricted execution then failed at system AVAudioPlayerNode construction; the unrestricted Core Audio run passed. The first full transition attempt found the duplicated logger; after that fix its matrix/negative controls passed but its trailing no-argument shell expression failed. Fixed the wrapper and reran to a successful overall exit. These initial failures and final logs are retained; no failure is counted as a passing run.

[Logs and final-source SHA-256](../measurements/audio-unit-alignment-2026-11-06/).

## Remaining qualification

⭕️ [Pending] Signed physical iPhone/Mac launch, actual AU availability, speakers/headphones/Bluetooth/DAC, clicks/tails/stop-resume listening, real Music assets, interruptions and background/thermal/energy behavior. A native host test and Simulator compilation do not certify device audio. The user's unexpected effect OFF report remains separately Pending until reproduced with the existing intent/application diagnostics.

🟠 [Next] First full-rack startup cost and the existing product-path/gain/tail/EOF/performance qualification gates remain. This work restores reliable shared regression execution and iPhone factory-failure behavior; it does not complete all audio or ROADMAP work or demonstrate a startup speedup.
