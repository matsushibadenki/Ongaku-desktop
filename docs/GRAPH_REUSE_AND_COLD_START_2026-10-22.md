# Initial graph setup and compatible reload reuse — 2026-10-22

## Outcome

Mac now retains a prepared graph across compatible explicit track reloads. The new file, schedule, normalization reference and EOF generation are always installed anew. iPhone retains the same policy at its processing boundary. Both hosts share the complete format/route identity and paused-state reset implementation verbatim. Constructor work was reduced, but full first-rack initialization remains a measured **Next** item; this change does not eliminate its substantial and variable cost.

## Implementation and safety boundary

- Mac removes premature effect-setting/protection writes from the constructor and applies them after the actual graph format is known. iPhone removes the constructor's nil-format connection pass, connecting once after the active session supplies the format.
- Mac reuse requires identical source processing format, 96 kHz rack format, complete device-output format and known default device identity. Comparison includes encoding, interleaving and channel layout. iPhone keys the actual processing/output formats and known route port identities, since its source mixer already accepts changing source formats. Unknown routes are not cached.
- Retire the old source only after the existing transport zero acknowledgement and downstream latency drain. Pause I/O, stop both source nodes, clear graph state, restore current settings and user gain, then schedule a fresh source behind the existing start gate. Compatible reload does not disconnect/reconnect or prepare the rack. Destructive clear, incompatible format, route change, system sleep and accepted engine recovery invalidate or bypass reuse. Recovery explicitly forces reconstruction.
- A stock reverb can retain late audio after `engine.reset()`, node reset and raw AU reset. While quiescent, capture its factory preset, wet mix and bypass; switch to another factory preset and back; restore mix/bypass. This erases history while preserving the selected voice. Unknown/custom presets fail closed to a full rebuild. This operation applies to retired tracks, not live effect OFF or seamless quality overlap, where tail continuity remains required.
- Device-side format now comes from `outputNode.outputFormat(forBus: 0)`. Its input scope can retain a previously negotiated engine format and can differ from the hardware side. The final SRC/true-peak connection and metadata must use the device side. A controller regression deliberately negotiates a different input rate to exercise this distinction.
- A real mobile topology/format miss unconditionally stops the paused engine before reconnecting; a paused engine still owns prepared resources. The matching fast path retains them. This closes the prepared-PCM reconnect exception exposed during this task's Simulator validation.

The 96 kHz processing policy, effect algorithms, live tail fades, source/seek clocks and next/repeat ownership are unchanged. Audio-thread gain and true-peak remain internal compile-time candidates; ordinary activation and releases are outside this change.

## Measurements

See [raw timings and correctness evidence](measurements/graph-reuse-2026-10-22/). Optimized Mac Release test hosts and optimized iPhone SE (3rd generation) Simulator hosts run on the same Apple M4 development Mac described in the previous [startup report](STARTUP_COST_COMPARISON_2026-10-22.md). CAF fixture generation occurs outside timestamps. Native file input, effects disabled but connected, automatic Sinc disabled, fixed 96 kHz stereo rack; Mac user output is muted. Ready includes the existing transport fade/fresh-render gate. This is not complete application launch-to-audible-sound or reboot-cold timing.

Three sequential process launches per variant rotate order. Initial matrix: exact pre-task baseline plus current ordinary and gain+true-peak; two source rates (44.1/96 kHz) per process. Baseline controller hashes are retained in the evidence manifest. Historical Mac baseline captures the old engine/input endpoint at 44.1 kHz; current code pins the actual device side at 88.2 kHz. Thus that before/after matrix includes an output-format correctness fix and is **not** a strictly internally rate-matched isolation of cache speedup. The headline reuse comparison below instead uses the current controller with identical source, device format, flags and rack: retained reload versus an explicit destructive clear forcing full reconstruction. Both include the protected retirement/start cycle. Three alternating ordinary/combined process launches per configuration; no concurrent build or audit during timing.

| Current configuration / source Hz | Forced full rebuild ready ms | Retained reload ready ms | Reduction |
| --- | ---: | ---: | ---: |
| ordinary / 44100 | 5393.96 | 110.26 | 98.0% |
| ordinary / 96000 | 5507.91 | 110.25 | 98.0% |
| combined / 44100 | 5117.43 | 130.77 | 97.4% |
| combined / 96000 | 6476.35 | 113.77 | 98.2% |

Constructor and first load medians from the rotated matrix (milliseconds):

| Host / configuration / source | Constructor | First load ready | Retained reload ready |
| --- | ---: | ---: | ---: |
| Mac ordinary / 44.1k | 25.18 | 2036.12 | 105.07 |
| Mac ordinary / 96k | 20.20 | 2205.38 | 99.80 |
| Mac gain+true-peak / 44.1k | 23.44 | 2457.74 | 114.74 |
| Mac gain+true-peak / 96k | 20.95 | 2450.01 | 114.07 |
| iPhone Simulator ordinary / 44.1k | 352.79 | 2239.99 | 144.99 |
| iPhone Simulator ordinary / 96k | 326.33 | 2142.46 | 137.86 |
| iPhone Simulator gain+true-peak / 44.1k | 358.82 | 2540.14 | 167.85 |
| iPhone Simulator gain+true-peak / 96k | 320.34 | 2543.06 | 164.98 |

Old mobile ordinary constructor medians were 390.44/331.08 ms and first-ready 2192.24/2185.21 ms. Current mobile connects once rather than twice per fresh instance, but overall first-ready ranges overlap: no material total first-play speedup is established. Mac baseline combined constructor was 73.41/22.87 ms; current 23.44/20.95 ms. The first constructor in a process includes framework/cache effects; three observations do not establish a general latency distribution. Mac combined initial-ready is about 2.45 s in the earlier rotated matrix, and mobile about 2.54 s. The later forced-rebuild control session has substantially slower fresh loads: Mac ordinary medians 4.92/4.96 s and combined 5.73/5.74 s, with individual fresh-load observations spanning 2.23–7.17 s. Both wall and process CPU time vary. Temperature/frequency and unrelated system scheduling were not controlled or measured, so the cause cannot be assigned; do not compare absolute times across these sessions or claim total cold-start improvement. The within-process retained-versus-rebuild comparison above uses the same current code and output format.

JSON/CSV retain wall time, process CPU and process peak RSS. CPU includes worker/audio threads; nested stages must not be added. Peak RSS is a process high-water mark including fixtures/test host, not incremental audio-unit allocation. Repeated full-rebuild controls occur later in the process and benefit from framework caches. These data are not physical-iPhone, p95, sustained-energy or memory-leak qualification.

## Correctness validation

- Shared format/route identity regression passes source/output rate, channel count, encoding, interleaving and channel-layout changes, and unknown-route rejection.
- Final ordinary and gain+true-peak Mac actual-controller suites each pass 14 tests, including compatible reuse identities/generation, changed gain reference, incompatible rebuild, pause/resume, crossfade, delayed analysis, CD formats/meter response, EOF fallback, next/repeat/wrap/final stop and a deliberately mismatched output input scope.
- Nine connected-gain/final-output tests pass in both ordinary and combined builds, including paused allocation/reset and final SRC/protection checks.
- Final optimized iPhone Simulator candidate aggregate completes all four phases with **35 PASS observations**: native/Precision Sinc handoff and gain, destructive stop/cancellation, render-loss/near-EOF recovery, actual ViewModel next/repeat/final stop with completion delivery removed. Simulator output is not physical-device qualification.

Strict retired-track waveform check: enabled full ten-effect rack, actual gain units, SRC and true-peak; 44.1/48/96 kHz outputs × four Space room sizes (12 cases per host source copy). Excite the graph, acknowledge actual rendered zero, drain downstream, pause/reset without deallocating resources, replace with zero PCM and reopen gain. Maximum residual is exactly 0.0 FS in all cases (limit 1e-7). Verify original factory preset/wet mix/bypass and allocated render resources survive. Removing reset is a required failing negative control. Both source copies pass; Desktop also has the portable CI script, run locally. Remote CI is not claimed.

Live OFF/tail regression separately passes 12 effect/output-rate cases per host, both channels, including repeated OFF, rapid ON, exact settled dry output and latency policy; abrupt-tail negative controls are rejected. This distinguishes retired-source history removal from live-effect tail preservation.

## Investigation and remaining work

A diagnostic offline rack prefix probe grows from about 1 ms for a few modules to 853 ms for all ten (90 nodes); repeated full-rack prepares are about 822–872 ms in this smaller diagnostic fixture. A sampled stack is dominated by recursive Core Audio graph traversal (`AUGraphParser::TraverseGraphNodes` / `InitializeActiveNodesInOutputChain`). These values are not directly comparable to the complete host's multi-second setup. A private experiment removing eleven unity serial/dry mixers still measured about 838 ms and was not adopted. No effect-node implementation was changed based on that experiment.

Intermediate observations are excluded from final pass counts: a stale output-input key caused unnecessary mobile rebuilds; paused prepared-PCM reconnection raised an AVAudioEngine exception until actual misses stopped I/O; a manual-offline controller test used an invalid host playback clock and was replaced by the real-time device/input-scope test. Final results use corrected production code and rerun relevant gates. Diagnostic reset experiments revealed residuals up to roughly 1.4e-4 FS before the factory-preset reset; the acceptance limit was not relaxed.

- 🟢 [Done] Remove redundant constructor setup; implement compatible Mac reload reuse and shared strict route/format identity; verify retired-state reset, live tails, output protection and transport/EOF behavior.
- 🟠 [Next] Reduce the remaining *first full-rack* traversal/initialization cost with an evidence-backed graph design, retaining complete waveform, gain, tail, source-switch and EOF gates. Do not claim caching solves cold initialization.
- ⭕️ [Pending] Physical iPhone and installed Mac/DAC launch/listening, actual Music-managed CD files, real route/rate/session changes, sleep/background/UI contention, sustained thermal/energy and audible transition qualification. Simulator/offline tests cannot establish resolution of the user's intermittent physical-device symptoms.
