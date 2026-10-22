# Shared audio-thread gain stage — 2026-10-22

## Scope

Follow-up: the candidate graphs are now connected and qualified in [the integration record](AUDIO_THREAD_GAIN_INTEGRATION_2026-10-22.md). The scope below records the preceding primitive milestone.

Both roadmaps prioritize moving protection envelopes off UI/control timers. This milestone implements the common **gain Audio Unit**, compiles it into both products and verifies it independently. It is **not yet connected to either shipping playback graph**. Existing effect, transport, tail and true-peak behavior is retained until controller integration is qualified.

`GainEnvelopeDSP.hpp`, `GainEnvelopeAudioUnit.mm` and the public header are byte-identical in mobile and Desktop. Desktop includes the source in both ordinary and App Store targets and its Swift Package. The public interface is visible through both apps' existing DSP bridge.

## Contract

- Mono/stereo, noninterleaved Float32, 8–384 kHz; gain is restricted to attenuation [0, 1]. Invalid gain requests target silence. Wider channel layouts are outside this first stage.
- One control writer publishes a bounded atomic command; one render reader snapshots it at the next successful render block. Ramps follow a cosine curve, one value per rendered frame shared by all channels. Retargeting starts at the last rendered gain. This uses the shared transport curve; it does not claim equivalence to the existing logarithmic effect-bypass curve.
- Commands do not require repeated UI writes or valid/rebased host/sample timestamps to continue. No heap allocation, Swift/Objective-C calls, locks or unbounded retry loop is added inside the render implementation. Audio buffers are allocated during resource setup.
- A token completes only when its endpoint has actually rendered. A superseding command invalidates previous completion ownership. Upstream render failure does not advance the envelope. Silent input still advances it.
- Initial allocation and reset are muted, invalidate stale tokens and require a new command to restore gain. Resource allocation/reset/deallocation must happen with rendering and command publication quiescent. An unavailable AU returns token 0. The AU adds no delay, latency or tail.

## Verification

- Both mobile and Desktop copies pass the same **72 real-AU cases**: 44.1/48/96/192 kHz × mono/stereo × 8/16/24 ms × 1/127/512-frame blocks. Each covers ramp up, partial ramp down, retargeting, silent input and resource reset/reallocation. Maximum sample residual against the independent cosine reference is **0 FS** at Float32 output precision. This is gain-stage PCM accuracy, not an end-to-end effect or audibility result.
- Tests verify exact silence, endpoint completion after the final frame rather than at a rounded block boundary, stale completion rejection, zero added phase delay for the input waveform, and missing-pull/oversized-block/wrong-bus/upstream-error paths.
- A 48-step substitute fails the waveform reference check as intended. This gate prevents a control-step implementation being mistaken for a per-frame ramp.
- Each copy passes 30,000 concurrently published control commands against at least 10,000 × 127-frame render blocks. AddressSanitizer/UndefinedBehaviorSanitizer report no findings in these runs. A separate ThreadSanitizer run of the shared core also passes with no reported races.
- Existing true-peak DSP/AU regressions pass, including their latency, resource lifecycle, PCM and zero-render-allocation checks. The new gain stage does not activate the true-peak candidate.
- Ordinary mobile Simulator Debug, Desktop Debug, Desktop App Store Release and Desktop `swift build` checks cover the final linked sources. Whitespace/project checks and source/test parity are also required before marking this milestone Done.
- Desktop's GitHub quality workflow now runs the standalone shared-gain waveform/safety gate. It has been executed locally; no remote CI result is claimed for unpushed changes.

Reproduce from mobile:

```sh
GAIN_SANITIZERS=1 bash tests/run_gain_envelope_regression.sh
GAIN_SANITIZERS=1 bash tests/run_gain_envelope_regression.sh --desktop
bash tests/run_true_peak_unit_regression.sh
xcrun clang++ -std=c++20 -O1 -g -fsanitize=thread -I audio tests/GainEnvelopeConcurrency.cpp -o /private/tmp/Ongaku-GainEnvelope-TSAN
/private/tmp/Ongaku-GainEnvelope-TSAN
```

Desktop has its own portable runner, `GAIN_SANITIZERS=1 bash tools/run_gain_envelope_regression.sh`, with identical tests in `Tests/AudioDSP/`. Temporary compiler outputs are removed by the runners. Measurement/build logs are `/private/tmp/ongaku-gain-envelope-*-2026-10-22.log`.

## Next stage and device limits

🟢 [Done] Connect the gain stage to each actual controller through an internal candidate path on 2026-10-22; see the integration record. The acceptance criteria for this completed milestone were: Keep user gain, transport protection and effect protection independently owned. Commit topology/latency changes only after rendered zero is acknowledged; preserve existing drain/tail holds, cancellation/seek/EOF and route-rebuild ownership. Run the full aligned handoff/effect residual, tail, transport and negative-control matrices on those connected graphs. A gain primitive's passing tests do not complete that integration.

⭕️ [Pending] After integration, qualify physical iPhone speaker/headphone and Mac/DAC listening, UI contention, interruptions/background/sleep/route changes and sustained CPU/thermal/energy behavior. The present tests use direct offline AU rendering on the development Mac and compilation for iPhone; they do not establish those device results or authorize ordinary activation.
