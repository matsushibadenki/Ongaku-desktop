# Mac transport and late-analysis gain protection — 2026-10-19

**Update 2026-10-19:** The first shared-rack residual, latency-change and bounded-tail stage is complete; see [tail/latency verification](TAIL_LATENCY_VALIDATION.md). Sample-accurate envelopes remain Next and physical-device qualification remains Pending.

## Implemented

- 🟢 [Done] Give Mac transport an independent final-output envelope using the byte-identical iPhone `EffectTransitionPolicy`: nominal 24 ms / 48 cosine steps. User volume × effect-transition gain × transport gain precedes the optional true-peak candidate; its downstream mixer remains at unity. Volume or bypass changes cannot cancel transport attenuation.
- 🟢 [Done] Pause, external-player takeover, seek, destructive stop/load and recovery pass through zero output and a drain before graph/schedule/resource changes. Drain is at least 12 ms or two maximum render blocks at the output rate, plus candidate lookahead latency. Both crossfade schedules and their last gains survive descent. Repeated requests share a drain and only the newest action commits; EOF cannot override pending transport.
- 🟢 [Done] Start/resume remains silent until fresh player frames traverse the known rack/final processing latency, then fades in. A bounded render-start timeout leaves the graph paused and transport silent. Pause and seek intent update immediately. A pause during a pending new-track load changes that requested track's autoplay intent.
- 🟢 [Done] Retain the current playback's track/album normalization reference, including absent measurements. Asynchronous feature/album results populate caches without changing current gain. A new load or newly scheduled incoming track captures the then-available reference. Explicit changes to normalization mode/target/clipping policy may adopt new analysis; repeated unchanged settings do not.
- 🟢 [Done] Store incoming crossfade/gapless references independently, including repeat-one where both schedules have the same track ID. Keep that reference when advancing. Reject an outgoing node's completion after a crossfade has already advanced, including repeated songs.

Compatible song handoffs retain their existing graph and crossfade behavior. Destructive operations fade and reschedule after the barrier; a rapid pause/resume may rebuild a schedule on Mac, whereas iPhone can retain its schedule during a pending pause. Both follow the same resource-retention, stale-request and waveform acceptance criteria. No iPhone runtime changes were needed for this Mac step.

## Validation

| Check | Result |
| --- | --- |
| Ordinary Mac regressions | 43 tests across transport envelope, effect transition, final output, fidelity, recovery, gapless and M1/M4 suites pass |
| Ordinary Mac controller integration | 4 tests pass: newest pause/seek/load; late track analysis across pause/resume/new load; incoming references with repeat-one; crossfade pause/drain and resume |
| True-peak candidate regressions/integration | The same 43 regressions and 4 controller integration tests pass with `ONGAKU_ENABLE_TRUE_PEAK` |
| PCM across both output paths | 6 stereo cases: ordinary/candidate × 44.1/48/96 kHz, each containing fade-in and fade-out with real source stop after drain |
| PCM criteria | Finite output, exact silent tail, maximum adjacent change × rate <25 amplitude units/second, matching iPhone's criterion |
| Observed maximum adjacent change | 44.1 kHz: 0.0003629923; 48 kHz: 0.00033335388; 96 kHz: 0.00016669929; final tail peak 0 in both paths |
| Fault injection | Generated copies with premature resource release or stale completion ownership are rejected; the unmodified shipping envelope passes |
| iPhone parity | Shared policy byte-identical; 11 transport state groups, 6 real stock-mixer PCM cases, abrupt start/stop and early-teardown negative controls, measured/unmeasured gain-reference regressions pass |
| App builds | Ordinary iPhone Simulator, Mac Developer ID target and Mac App Store target all pass with signing disabled |

The state scheduler is virtualized. PCM uses actual AVAudioEngine mixers and the optional protector in offline rendering, with deterministic timer advancement. Controller integration uses actual local CAF playback at user volume zero; it checks graph/schedule state, not audibility. The controller cases were first run separately, then combined with all regression suites for final 47-test runs in both configurations. Repeat-one includes a check after the outgoing EOF window. Sustained UI/load and device-clock qualification remains Pending. No claim of sample-accurate callbacks or physical inaudibility follows from these results.

[Captured results and source hashes](measurements/mac-transport-parity-checks-2026-10-19.txt).

## Reproduce

From `Ongaku-desktop`, with normal host Audio Unit access:

```sh
swift test --filter 'TransportOutputEnvelopeTests|EffectParameterTransitionTests|FinalOutputProtectionTests|AudioFidelityPolicyTests|PlaybackRecoveryTests|GaplessPlaybackTests|M1PlaybackMilestoneTests|M4AudioPathMilestoneTests'
swift test --filter PlaybackTransportIntegrationTests
swift test -Xswiftc -DONGAKU_ENABLE_TRUE_PEAK --filter 'TransportOutputEnvelopeTests|EffectParameterTransitionTests|FinalOutputProtectionTests|AudioFidelityPolicyTests|PlaybackRecoveryTests|GaplessPlaybackTests|M1PlaybackMilestoneTests|M4AudioPathMilestoneTests'
swift test -Xswiftc -DONGAKU_ENABLE_TRUE_PEAK --filter PlaybackTransportIntegrationTests
bash tools/run_transport_negative_controls.sh
```

From `Ongaku`, run `tests/run_transport_continuity_regression.sh` and `tests/run_quality_gain_reference_regression.sh`. Build both desktop schemes (`OngakuDesktop`, `OngakuDesktopAppStore`) and the iPhone `audio` Simulator scheme with signing disabled for this development check.

## Remaining work

🟠 [Next] Add latency-aligned reference/residual measurements for handoffs and effect bypass, especially Space/Gloss/reverb tails. Define measured acceptance bounds before replacing control-thread fades with sample-accurate ramps. This drain does not preserve the full decay of every effect tail.

⭕️ [Pending] Matched-level listening on physical Mac/iPhone speakers and external outputs: start/pause/resume/seek, rapid commands, file changes, active crossfades, repeat-one, late analysis, sleep/wake, output-rate/route changes and main-queue/UI load. Measure sustained CPU/energy/thermal use and verify that sleep permits the drain to finish. Ordinary true-peak activation remains gated by its existing hardware qualification.

## CPU / GPU upsampling

**Update 2026-10-19:** The CPU/Metal comparison is now measured on the M4 development Mac. See [results, retained CPU default and remaining Pending qualification](CPU_METAL_UPSAMPLING_VALIDATION.md). The following rationale records the pre-benchmark state.

The iPhone custom Precision Sinc implementation uses CPU polyphase convolution with Accelerate/vDSP; its offline worker deliberately throttles work to reduce sustained CPU pressure. Normal iPhone conversion and Mac's source-to-rack conversion use Apple's audio conversion path. There is no application-owned Metal/GPU sample-rate converter. GPU execution is not a prerequisite for numerical precision, and these tests do not establish conversion-speed sufficiency or a GPU speedup.

🔴 [Later] Measure current conversion time, peak working memory and numerical error for representative source/target rates, lengths and Sinc quality modes. Compare a Metal prototype only against the same kernels and output criteria, including transfer/setup costs and cancellation; decide adoption from measurements rather than GPU availability.

⭕️ [Pending] Physical iPhone/Mac energy, thermal throttling and playback contention comparisons for any GPU prototype. No GPU performance or accuracy advantage has been measured here.
