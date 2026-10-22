# Matched playback startup cost — 2026-10-22

> Follow-up: [compatible reload reuse and first-setup investigation](GRAPH_REUSE_AND_COLD_START_2026-10-22.md) implements the reuse item below. Historical Mac `output_rate` here was read from the output node’s engine/input scope (44.1 kHz), not its authoritative device/output scope; it must not be interpreted as proof of the physical hardware rate. The follow-up pins/reports the device side and uses a same-format forced-rebuild control for cache attribution. Historical raw results remain unchanged.

## Method and scope

Compare ordinary, `ONGAKU_ENABLE_AUDIO_THREAD_GAIN`, and gain + `ONGAKU_ENABLE_TRUE_PEAK`. All use `ONGAKU_STARTUP_AUDIT`, the same production controllers/rack, optimized code (`-O`), native file playback, 10-second stereo 440 Hz CAF fixtures at 44.1/96 kHz, effect-module settings disabled, crossfade off and automatic output-rate switching off on Mac. Mac track normalization/clipping compensation is disabled; mobile uses its neutral-analysis native-file path and fixed default route/gain compensation. Existing safety limiting is retained in every variant. This isolates protection/topology overhead; it is not a Precision Sinc preparation benchmark or an all-effects-enabled throughput test.

Build all variants before measurement; run one test process/app at a time, with no concurrent build. Three rounds rotate ordinary → gain → combined, gain → combined → ordinary, combined → ordinary → gain. Each new process creates one fresh controller per source rate; each controller performs initial load, pause/resume, same-instance reload and pause/resume. Fixture generation and process installation/launch are outside the measured spans. Framework/disk caches are not flushed, and the second source rate follows the first within a process. These are fresh-graph initial-load costs, not reboot-cold or full app-launch-to-sound benchmarks.

Mac: Mac16,13 / Apple M4, 10 physical cores, macOS 27.0.1 (26A434), Xcode 27.1 (27A9275), Release Swift Package test host with testable imports. iPhone: iPhone SE (3rd generation), iOS 26.2 (23C54) Simulator on the same development Mac, optimized internal Debug host. All samples use a 96 kHz stereo effect rack. The captured Mac engine/input endpoint remains 44.1 kHz stereo; Simulator output remains 88.2 kHz stereo. The Mac capture does not establish the device/output-scope rate (see the follow-up note). The outputs are observed, not forced during the measurements. Mac is muted at user volume; Simulator uses a very quiet source. Compare variants within each platform; these are not absolute Mac-versus-iPhone hardware rankings.

`controller.init` is separate from load. Ready includes the existing fresh-render gate and completed transport fade; the iPhone audit additionally confirms 20 ms of fresh source progression through its existing recovery API. Resume includes protected rescheduling and completed fade, not just the button call. CPU milliseconds are process user+system CPU (including audio/worker threads); nested stages overlap and must not be summed. `process_peak_rss_bytes` is the process high-water RSS including the test host/fixtures, not incremental AU allocation or device energy. Tables show medians of three observations; min/max and CPU/RSS are retained in JSON/CSV. Three runs are not a statistical latency distribution or p95 claim.

## Before the correction

### Mac

| Configuration / source | Init ms | Initial load ready ms | Reload ready ms | Resume ms |
| --- | ---: | ---: | ---: | ---: |
| ordinary / 44100 | 73.2 | 1982.8 | 2126.2 | 54.3 |
| ordinary / 96000 | 26.0 | 2041.4 | 2371.3 | 52.1 |
| gain / 44100 | 69.5 | 2187.6 | 2347.0 | 56.7 |
| gain / 96000 | 24.6 | 2375.6 | 2852.5 | 57.6 |
| gain-truepeak / 44100 | 69.7 | 5064.1 | 5863.6 | 2933.6 |
| gain-truepeak / 96000 | 23.1 | 5588.9 | 6352.2 | 2703.4 |

### iPhone Simulator

| Configuration / source | Init ms | Initial load ready ms | Reload ready ms | Resume ms |
| --- | ---: | ---: | ---: | ---: |
| ordinary / 44100 | 391.0 | 2282.2 | 143.5 | 92.4 |
| ordinary / 96000 | 326.3 | 2206.6 | 136.4 | 91.1 |
| gain / 44100 | 381.4 | 2345.2 | 155.8 | 93.3 |
| gain / 96000 | 327.2 | 2451.0 | 150.4 | 101.0 |
| gain-truepeak / 44100 | 402.4 | 2718.5 | 153.6 | 96.6 |
| gain-truepeak / 96000 | 334.8 | 2474.7 | 150.9 | 93.0 |

## Correction

Mac `configureEngine` prepares the complete rack, then `schedule` calls `stopPlayerNodes`. With true-peak enabled that helper previously called `engine.stop()`, invalidating preparation; the following `engine.start()` initializes the rack again. The same helper runs during protected pause/resume/seek. Measured combined-path start spans alone took seconds, while ordinary/gain-only starts took milliseconds.

Use `engine.pause()` in this true-peak reset helper, keeping render resources while I/O is quiescent. Keep `resetWhileStopped` to clear lookahead, the rendered-zero acknowledgement, downstream drain, readiness gate, independent gains, tail-reset policy and schedule/EOF generations. Destructive cleanup still calls `engine.stop()` and graph-format changes still rebuild. This matches the iPhone host's existing pause/resource-retention policy; no iPhone runtime behavior change is needed. The correction does not cache a stale hardware format or skip required topology changes.

## After the correction

| Configuration / source | Init ms | Initial load ready ms | Reload ready ms | Resume ms |
| --- | ---: | ---: | ---: | ---: |
| ordinary / 44100 | 67.5 | 2005.1 | 2060.5 | 54.6 |
| ordinary / 96000 | 23.9 | 2010.6 | 2079.6 | 53.9 |
| gain / 44100 | 69.1 | 2206.8 | 2265.9 | 56.4 |
| gain / 96000 | 24.4 | 2174.5 | 2252.1 | 57.0 |
| gain-truepeak / 44100 | 70.1 | 2468.0 | 2504.0 | 64.2 |
| gain-truepeak / 96000 | 26.9 | 2419.3 | 2529.5 | 65.5 |

For 44.1 kHz, combined initial-ready median falls from 5064.1 to 2468.0 ms (51.3% reduction), and protected resume from 2933.6 to 64.2 ms (97.8%). At 96 kHz, initial-ready falls from 5588.9 to 2419.3 ms, and resume from 2703.4 to 65.5 ms. Combined first `engine.start` is now 3.48/2.73 ms, compared with 2626.56/2697.81 ms before correction. Ordinary/gain-only executables are unchanged in the second rotated matrix; only the combined product was rebuilt for the lifecycle correction.

The new full-rack initial load still costs about 2.0 s ordinary, 2.2 s gain and 2.4–2.5 s combined on this Mac. Gain/combined protection has measurable startup cost; this is not a zero-overhead claim. The very large repeated initialization is removed without changing the fade duration. The Simulator already retains paused resources: its ready/resume figures above are unchanged by the Mac-only fix. Small timing differences and all first-rate initialization effects require larger/device samples before broader conclusions.

At 44.1 kHz, initial-ready process CPU and process peak RSS (medians):

| Host / build | CPU ms | Process peak RSS MiB |
| --- | ---: | ---: |
| Mac / ordinary | 1977.3 | 166.8 |
| Mac / gain | 2172.4 | 166.9 |
| Mac / gain-truepeak | 2425.7 | 167.1 |
| Simulator / ordinary | 2350.3 | 368.1 |
| Simulator / gain | 2422.1 | 367.9 |
| Simulator / gain-truepeak | 2841.4 | 367.5 |

Validation after correction: 9 connected-gain/final-output tests pass, including a new paused-resource test at 44.1/96 kHz: queue hot PCM, pause I/O, assert resources remain allocated, reset lookahead, restart with silence and require exactly zero output in both channels. All 12 serialized real-controller/CD/EOF tests pass in 98.615 s, including an added assertion that the true-peak AU remains allocated after protected pause/seek. This total is a correctness result, not a matched comparison with earlier integration-suite durations. The rotated startup matrices contain 18 Mac processes (before/after) and 9 Simulator processes, two fresh-controller rates each, with successful load/reload/pause/resume checks. Shared Swift adapter parity, shell/Python syntax and whitespace checks pass.

Raw reports, summaries and regression results are retained in [measurements/startup-cost-2026-10-22](measurements/startup-cost-2026-10-22). Earlier 144-case handoff/12-case tail matrices remain historical evidence; they were not rerun for this pause-lifecycle-only change. The current connected Space-tail test and all actual-controller crossfade/EOF tests pass. No remote CI, release upload or physical qualification is claimed.

## Reproduction and limitations

- Desktop: `bash tools/run_startup_cost_audit.sh /private/tmp/OngakuStartup-reproduce`.
- Mobile: `bash tests/run_startup_cost_simulator_audit.sh <Simulator-UUID> /private/tmp/OngakuStartup-iOS-reproduce`.
- Summaries: `python3 tests/summarize_startup_cost.py <report-directory> mac` (or `ios`) from mobile.
- Internal timing hooks compile out without `ONGAKU_STARTUP_AUDIT`; no per-frame instrumentation, production diagnostics or product UI was added.

The default Swift Build backend produced incompatible/mixed module references while preparing Release test variants; those attempts and concurrent-build smoke measurements were discarded. The reproducible Mac runner pins the native backend and explicit testable imports in separate scratch paths. This backend is deprecated by the installed toolchain; it is used here as a local audit workaround, not a product build-system migration. Test-host Release optimization is not a signed App Store performance qualification.

🟠 [Next] Initial full-rack initialization remains material even in the ordinary path. Investigate retaining compatible graphs across complete track reloads and reducing rack traversal/allocation cost, using the same waveform/tail/route/EOF gates. Do not infer significance from small median differences where ranges overlap, or shorten protection waits merely to lower the numbers. Ordinary gain/true-peak activation remains gated.

⭕️ [Pending] Physical iPhone speaker/headphones and Mac/DAC cold launch, real Music-managed tracks, sample-rate/route changes, background/OS audio arbitration, UI contention, sustained thermal/energy load and listening. Simulator/fixture timing cannot qualify these. Confirm silence and tails as well as elapsed time before normal activation.
