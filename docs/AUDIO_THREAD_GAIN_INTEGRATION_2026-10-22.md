# Connected audio-thread protection — 2026-10-22

## Implemented scope and activation

Both playback controllers now have an actual connected path using the shared gain Audio Unit. **The path is enabled by the internal build condition `ONGAKU_ENABLE_AUDIO_THREAD_GAIN`; ordinary builds retain the qualified existing path.** Physical qualification and startup-cost investigation remain before ordinary activation. This is no longer an unconnected primitive, and it is not a claim that the device qualification is complete.

The byte-identical `AudioThreadGainStage.swift` owns commands and polls rendered completion. Two separate stages own effect protection and transport protection. User volume, normalization/automatic-EQ references, source handoff gains, wet-tail history and final peak protection retain their existing owners.

- iPhone: output ceiling → effect gain → transport gain → existing mixer/SRC → optional final true-peak → unity main mixer. Transport writes no longer also attenuate the main mixer in the candidate build.
- Mac: effect rack → existing sample limiter/−1 dB trim → effect gain → transport gain → existing user-volume/conversion path → optional true-peak → output. The old final-stage transition/transport factors remain unity in this build, avoiding duplicate attenuation.
- Gain AUs retain the rack's mono/stereo processing format. SRC/channel conversion stays in the stock mixers, rather than requesting unsupported rate conversion inside the custom gain AUs. Each ramp calculates its duration in the connected AU's frames.

## Completion and lifecycle

A rendered endpoint, not a control-thread deadline, releases the effect topology commit or transport drain. The existing algorithmic-latency hold and wet-tail release follow that acknowledgement. Main-thread polling only observes completion; it does not write per-step gains.

Both adapter and controller generations reject superseded completion. Effect awaiters are released on cancellation without applying stale settings; superseded transport commits are discarded. Engine allocation/reconnection starts the AUs muted. After engine start, retained effect intent is restored and transport is explicitly held at zero until the existing fresh-render gate arms its ramp. A running AU is not reset to obtain a fade.

An already stopped engine is physically silent and can finish a pending transport operation. If an active graph never acknowledges the ramp (500 bounded polls, nominally 4 ms apart), the host pauses I/O **before** allowing a commit. This fallback is tested; it is not reported as a rendered-zero acknowledgement. These control callbacks and wet-tail timers still depend on MainActor scheduling. Moving the ramp itself off that thread does not remove every possible silent hold during a blocked topology commit.

## Verification

| Check | Result |
| --- | --- |
| Real connected stages + effect/transport owners | 4 tests pass, both with gain alone and gain + true-peak. Includes 44.1/48/96 kHz endpoints, no commit before PCM rendering, physical pause after zero/drain, retarget continuity/cancellation, and stopped-I/O fallback. |
| Real Space bypass | Included above: OFF commits at rendered zero; source input is then stopped so restored output can only be retained wet history. |
| Connected high-quality handoff reference/residual | Both repositories pass the same 144 cases, both channels, Space/Gloss, multitone/tail, three Sinc phases, variable blocks and 4/20 ms control intervals. Maximum completed-window level difference is 0.0384513 dB; measured correlation lag is 0 output samples at the gate's resolution. The intentional shared-rack reset fails as expected. |
| Connected wet-tail matrix | Both repositories pass 12 effect/output-rate cases, both channels, including repeated OFF, exact dry settling and rapid ON. Abrupt tail reset is rejected. |
| Actual Mac controller, gain candidate | All 12 serialized transport/CD/EOF tests pass in 153.391 s. Includes retained overlap, newest pause/seek/load, early incoming EOF, duplicate schedule callbacks, recovery, next/repeat/wrap/final stop and real 10 ms tails. Output is muted by the fixture. |
| Actual Mac controller, gain + true-peak candidates | The same 12 tests pass in 734.646 s. This long run is a correctness result, not a startup/performance acceptance result; see Next below. |
| Actual iPhone engine and ViewModel | Optimized SE Simulator host completes all four phases and 36 PASS observations: native/Precision Sinc quality handoff, normalization/EQ reference preservation, pause/resume during overlap, deferred destructive teardown, cancellation, I/O recovery, prepared/file-backed 10 ms EOF and actual next/repeat/final stop with UI completion delivery removed. |
| Ordinary-path regressions | Existing 48 effect/DSP transitions, transport/PCM and negative controls, 10 recovered queue/intent cases, 3 prepared-EOF groups and 14 recovery groups with their negative controls pass. |
| Builds | Gain-enabled mobile Debug and optimized Simulator host, gain-enabled Desktop SPM tests and App Store Release, and ordinary mobile/Desktop Debug succeed. Signing is disabled for compilation. |

The iPhone aggregate originally inherited a 180 s limit intended for one audit. Its unoptimized attempt timed out while computing Sinc coefficients; the optimized attempt also exceeded that wrapper budget. The **same optimized process** subsequently completed all four original audits; a separate collector verified the exact final `COMPLETE` line and retained the report. Launch was 14:12:01 JST and final report 14:18:17 JST (about 376 s). The runner now budgets 900 s for the four phases, retains build diagnostics and reports partial progress on timeout. Assertions and Sinc mode/algorithms are unchanged. The existing fixture's near-EOF preparation deferral/cache retry was exercised. Neither this run nor its 6266 ms native-ready observation is a product startup or energy benchmark.

The connected-acknowledgement tests use actual AUs and offline graphs with real MainActor polling. CI runs these in their own process, like the existing real-controller suite, to prevent long synchronous DSP audits from expiring real-time tail windows. Workflow syntax and project membership pass validation. These are local results; no remote CI or release upload is claimed.

### Final downstream-drain follow-up

The final gain stages precede stock SRC and optional true-peak processing. After rendered zero, mobile now adds the downstream SRC/true-peak AU latencies to its existing I/O drain; Mac includes conversion/true-peak latency and candidate main-mixer latency. Resources remain retained throughout this drain. Ordinary mobile drain behavior is unchanged.

The full 12-controller and 36-observation Simulator runs above preceded this conservative drain extension. After the extension, the combined gain/true-peak build passes 8 final-output/connected-stage tests and 2 actual-controller pause/seek/load/crossfade tests (27.234 s). The final mobile candidate passes all 9 actual foreground-recovery observations, including prepared/file-backed 10 ms EOF and destructive stop, and the legacy transport suite passes its 12 state groups, 6 PCM cases and negative controls. These targeted follow-up results are retained separately; the complete matrix was not rerun after the extension.

## Reproduction

From mobile:

```sh
GAIN_GRAPH=1 bash tests/run_tail_latency_regression.sh
GAIN_GRAPH=1 bash tests/run_tail_latency_regression.sh --desktop
GAIN_GRAPH=1 bash tests/run_effect_handoff_residual_regression.sh
GAIN_GRAPH=1 bash tests/run_effect_handoff_residual_regression.sh --desktop
bash tests/run_native_first_simulator_audit.sh <simulator-UUID> --gain-integration
```

The Simulator integration mode enables the gain condition and `-O` in an isolated application bundle; it does not replace the installed app. Both ordinary and candidate full builds are checked separately.

From Desktop, use a task-specific scratch path:

```sh
swift test --scratch-path /private/tmp/Ongaku-Gain-Check -Xswiftc -DONGAKU_ENABLE_AUDIO_THREAD_GAIN --filter AudioThreadGainIntegrationTests
swift test --scratch-path /private/tmp/Ongaku-Gain-Check -Xswiftc -DONGAKU_ENABLE_AUDIO_THREAD_GAIN --skip-build --filter PlaybackTransportIntegrationTests
```

For the combined path, use another scratch directory and add `-Xswiftc -DONGAKU_ENABLE_TRUE_PEAK` to both commands. Keep both the connected-acknowledgement suite and the wall-clock real-controller suite separate from heavy synchronous waveform suites.

Raw waveform/result summaries are in [measurements/audio-gain-integration-2026-10-22](measurements/audio-gain-integration-2026-10-22). Full build and diagnostic logs remain `/private/tmp/ongaku-gain-integration-*.log`.

## Remaining work

🟢 [Done] Complete matched startup profiling and the repeated-initialization correction; see [follow-up results](STARTUP_COST_COMPARISON_2026-10-22.md). The following unmatched observations are historical: The combined integration run took substantially longer, and a captured stack was in `AVAudioEngineGraph::Initialize` traversal. Simultaneous builds and Simulator activity prevent attributing that difference solely to the new nodes. This is development-environment work, not a physical-device Pending item.

⭕️ [Pending] Physical iPhone speaker/headphone and Mac/DAC listening, UI contention, repeated background/interruption/sleep and route changes, real Music-managed CD assets, and sustained CPU/thermal/energy measurement. Confirm actual rate/drain behavior and silence/tail audibility before activating the gain candidate in ordinary distribution. True-peak ordinary activation retains its independent qualification gate. Generated PCM, muted development-Mac playback and Simulator I/O injection do not establish OS audio arbitration or resolve the user's previously reported intermittent physical-iPhone issue.
