# Gain acknowledgement deadline and startup qualification — 2026-10-22

## Implemented

Both hosts now use the same monotonic uptime deadline for the candidate audio-thread gain acknowledgement: **two seconds of uptime**, checked on the next available control callback, instead of 500 successive callbacks at nominal 4 ms intervals. A slow queue can stretch 500 callbacks far beyond two seconds. This does not make MainActor execution real-time: if it is blocked, I/O fallback cannot execute until control resumes. It avoids waiting another hundreds of callbacks after that point.

The existing safety order is preserved: reject stale ownership first; accept an actual rendered endpoint; accept physically stopped I/O; otherwise, after expiry or unavailable resources, invoke the host's I/O stop/pause fallback before completing a commit. An endpoint actually rendered before a late callback remains valid and does not trigger an unnecessary stop. DSP ramp frames, gain targets, zero acknowledgement, tail/drain policy and EOF generations are unchanged.

Clock and control scheduling can be injected for deterministic tests. Production uses `ProcessInfo.systemUptime` and the existing main-queue 4 ms scheduling. Clock reads remain on the control thread; no render-thread algorithm or allocation changes. The Swift source is byte-identical in both repositories. `ONGAKU_ENABLE_AUDIO_THREAD_GAIN` remains an internal qualification flag; this change does not activate the candidate in ordinary builds.

## Verification

- Both host source copies pass five real-Audio-Unit / manual-render cases on the development Mac: a first callback delayed three seconds; no early commit and exact deadline boundary; actual rendered zero taking priority over callback expiry; stale callback cancellation without pausing its successor; already paused I/O completing safely. A required negative control removing the deadline fails. No three-second sleep or scheduling guess is used for these cases.
- Run the new portable Desktop CI script locally and add it to the workflow. Remote CI is not claimed for unpublished changes.
- Ordinary-build direct connected-gain / final-output suites pass **nine tests**. These instantiate the actual candidate units even when ordinary controllers do not connect them.
- iPhone SE (3rd generation) optimized Simulator candidate gain+true-peak aggregate completes **35 PASS observations across four phases**: native/Precision Sinc handoff/gain, destructive stop/cancellation, render-loss/near-EOF recovery, actual ViewModel next/repeat/final stop. This is not physical-iPhone qualification.
- Mac gain+true-peak Release candidate: four connected-gain tests (2.672 s), five final-output tests (0.514 s) and all fourteen actual playback/controller/CD/EOF tests (170.704 s) pass in separate processes. The controller suite covers compatible reload, changed formats, pause/resume, late analysis, crossfade and next/repeat/wrap/final-stop ownership. Suite wall times are correctness results, not a matched performance comparison.

Raw logs and source hashes are retained in [measurements](measurements/gain-deadline-and-startup-2026-10-22/).

## First full-rack startup: investigated, not accelerated

Preparation-only measurements are insufficient. Extend `tests/GraphInitializationAudit.swift` to measure prepare, actual engine/player start, first PCM render and complete setup-to-PCM time. Verify both output channels. The optional `--equalizer-check` enables the real serial EQ at -18 dB trim and requires the corresponding output, so an inactive/unconnected effect path cannot be mistaken for a fast startup. Both host copies pass all ten rack prefixes. These are functional developer probes, run alongside other compilation; their absolute times are not a matched cross-platform speed ranking or an application-launch benchmark.

Exploratory offline trials used the unchanged full rack:

| Approach | Observation | Decision |
| --- | --- | --- |
| Incremental prefix prepare | One exploratory preparation fixture: 4.303 s versus baseline 2.219 s; final prepare alone was almost free because it repeated an already prepared graph | Reject; total setup matters |
| Direct AU preallocation | Preparation fixture total 2.542 s in that run, no reduction | Reject |
| Independently prepared effect islands, then serial reconnection | Preparation-only results appeared to be 0.085–0.123 s, but later engine/player start failed with a disconnected-player error | Reject; no valid PCM startup result |
| Isolated preparation with live or reset-based reconnection | Core Audio connection assertion / disconnected-player errors | Reject |

The exploratory logs contain intentional candidate failures, excluded from pass counts. The incremental/preallocation trial measured preparation only and is not counted as a completed PCM startup qualification. The archived prototype is only the last experimental snapshot, not production code or a complete reproducibility package for all earlier variants. The reset variant aborted before a later stop variant in that process; the latter is **not** counted as tested. Preparation-only timings are explicitly rejected as performance evidence. The accepted baseline rendered 0.006294627 FS from a 0.05 FS source with the -18 dB EQ trim; the strengthened committed audit checks that result. No experimental routing or AU preallocation was introduced into either host.

- 🟢 [Done] Bound candidate gain acknowledgement by monotonic time and qualify delayed control/ownership behavior in both sources. Strengthen initial graph measurement through actual PCM output and reject invalid apparent speedups.
- 🟠 [Next] Reduce remaining full-rack initialization with a graph design that preserves valid source connections, exact signal path, final protection, live wet tails and EOF ownership. The existing multi-second cold setup remains unresolved. Also retain ordinary-activation and other recovery-loop qualification gates.
- ⭕️ [Pending] Physical iPhone/Mac/DAC listening, live route/rate/session changes, sleep/background/thermal/UI contention and installed-user-library qualification. A control-thread deadline is not a hard real-time stop guarantee or proof that the earlier physical-device symptoms are resolved.
