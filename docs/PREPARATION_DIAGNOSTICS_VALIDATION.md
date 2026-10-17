# Audio preparation diagnostics — 2026-10-17

## Scope and behavior

🟢 [Done] iPhone preparation diagnostics distinguish actual streaming work from the requested future Precision Sinc mode. `audio.prepare.failed` records `path=streaming` and `requestedMode` separately. A request for Precision Sinc no longer makes an initial AVAudioFile failure appear to be a Sinc conversion failure.

🟢 [Done] Replace the Boolean offline preflight with a throwing validation API. Current-track upgrades, next-track cache preparation and memory-recovery checks preserve the original failure instead of replacing every failed check with `offlineBufferTooLarge`. Missing/corrupt files remain opening failures. Explicit buffer, frame-count, live-memory-budget, snapshot and remote-cache size limits report `capacity_exceeded`. Invalid metadata, decoder errors, timeouts and copy failures report `preparation_failed`; a non-Precision preflight request reports `unsupported_mode`.

🟢 [Done] Retain the innermost failure stage, original NSError domain/code and underlying localized description. CancellationError remains unwrapped so existing cancellation handling still works. Logs use single-line quoted domains without dumping arbitrary userInfo, source paths or asset URLs. Existing English/Japanese/Simplified Chinese UI messages are retained; the new fields are developer diagnostics.

🟢 [Done] `audio.quality_worker.ended` now distinguishes `outcome=prepared`, `failed` and `cancelled`. `prepared` means PCM preparation completed, not that audio ownership transferred. Continue to use `audio.handoff.scheduled`, `completed` and `deferred` to determine handoff outcome. Optional preparation failure continues native playback.

These production changes apply to iPhone's native-first/Music/Precision Sinc pipeline. Mac has no equivalent Precision Sinc preparation pipeline in the current codebase. Its roadmap links this evidence for cross-app tracking; no new Mac audio path or DSP policy is implied.

## Log fields

`stage`, `reason`, `errorDomain` and `errorCode` describe the actual failure. The surrounding event distinguishes initial preparation, optional upgrade, next-track cache and memory-recovery contexts. Upgrade/cache events also retain the requested mode and song ID where available.

| Stage | Meaning |
| --- | --- |
| `asset_snapshot` | Prepare a readable Music asset snapshot |
| `streaming_open` | Validate source readiness and open the streaming file |
| `streaming_session` | Activate/configure the audio session |
| `streaming_graph` | Install the streaming source and audio graph |
| `streaming_start` | Start/seek or wait for the replacement's render readiness |
| `offline_preflight` | Validate whether the requested offline mode is supported |
| `offline_open` | Open offline source metadata, in preflight or preparation |
| `offline_budget` | Check frame count, buffer size and available allocation budget |
| `offline_conversion` | Decode/convert the playback PCM |
| `offline_spatial` | Clone/process spatial PCM |
| `offline_validation` | Validate resulting PCM |
| `quality_handoff` | Install/schedule prepared playback |
| `cache_preparation` | Cache materialization failure without a more specific inner stage |

Example from the missing-file Simulator fixture (not a diagnosis of the user's original Music file):

```text
stage=streaming_open reason=preparation_failed errorDomain="NSCocoaErrorDomain" errorCode=260
```

An allocation guard instead records `stage=offline_budget reason=capacity_exceeded`. Capacity here includes the configured PCM budget and currently available process allocation budget; it does not assert that the device's storage is full. Unknown system failures are not guessed to be capacity errors.

The user's supplied `code 9: killed` was confirmed to be a manual debugger stop. It is not evidence of a crash or memory termination. The old Music preparation log lacks the original domain/code, so this change cannot retrospectively determine that failure's exact cause.

## Verification

- 🟢 [Done] Eight diagnostic groups pass using extracted shipping preflight/allocation checks, actual missing/corrupt/readable files, the streaming worker and the real error classifier. Checks cover missing/corrupt source errors, live-memory/buffer/frame-count limits versus invalid metadata, snapshot/cache size versus other failures, unsupported mode, cancellation, inner-stage preservation and safe single-line formatting. The live-memory allowance is injected in this host test; no large PCM allocation is required.
- 🟢 [Done] The negative control that restores capacity-for-all classification fails with the expected diagnostic assertion.
- 🟢 [Done] Existing streaming-file regression passes all six checks, including exact stereo samples, incomplete-file rejection, UI responsiveness and cancellation.
- 🟢 [Done] Music-asset preparation passes six checks for passthrough/PCM fidelity, cleanup, cancellation, size limits, timeout and unreadable exported containers. Remote resilience passes its four groups, including limits, cancellation, revisions and active cache leases.
- 🟢 [Done] The isolated production-engine audit completes on the existing iOS 26.2 SE Simulator with twelve checks: actual streaming/open errors despite a Precision Sinc preference; cache failures retain their true cause; failed quality preparation leaves native playback running; subsequent handoff, cached reuse, pause and stop remain correct.
- 🟢 [Done] Debug iPhone Simulator build succeeds with signing disabled. Final frame-limit/error-formatting changes additionally pass the focused diagnostic suite and app build.

The initial simulator audit reached fixture EOF because conversion took about 23 seconds for a 20-second test source. The production `invalid_timeline_or_tail` guard correctly cancelled the unsafe handoff. The harness now accepts only verified EOF deferral, checks that preparation produced a cache, restarts the test source and retries once. It does not suppress unrelated cancellation failures or change production scheduling. The final audit verifies this branch and subsequent successful handoff.

The asset-export regression initially hit an AVFoundation service error inside the sandbox and passed with the required service access. A temporary extraction-script newline error was corrected before the final diagnostic run. [Recorded test/build summary](measurements/preparation-diagnostics-checks-2026-10-17.txt).

## Reproduce

From the iPhone repository:

```sh
bash tests/run_preparation_diagnostics_regression.sh
bash tests/run_streaming_file_preparation_regression.sh
bash tests/run_music_asset_preparation_regression.sh
bash tests/run_remote_resilience_regression.sh
bash tests/run_native_first_simulator_audit.sh <simulator-uuid>
```

The extractor also checks production caller wiring and stage annotations. Unit checks exercise stage preservation with injected errors; they do not reproduce every hardware/session/converter failure. The Simulator audit uses the actual engine, while Music ownership is represented by a local test source.

⭕️ [Pending] Capture new diagnostics for the affected Music tracks on a physical iPhone, including account/download timing, session or decoder failures, real process memory pressure and long-track preparation. Confirm audible continuity and timing under actual UI/thermal/device load. Do not infer successful Mac ON/OFF acoustic qualification from these iPhone diagnostics.
