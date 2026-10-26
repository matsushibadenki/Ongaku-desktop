# Large chunk checkpoint load — 2026-10-25

## Scope and decision

🟢 [Done] Improve the shared Desktop / same-project iOS companion checkpoint store. The separate main iPhone application's legacy whole-resource path is unchanged. No wire DTO or chunk size policy changes were made. Prior validated descriptors and actor generation/commit ownership remain in place.

Each received chunk previously re-encoded and atomically replaced a JSON checkpoint containing every SHA-256 string and all received indexes. Keep immutable descriptor metadata in JSON once; persist received positions in a compact binary-plist bitmap after every verified payload write. There is no batching or delayed acknowledgement. A UUID generation binds progress to its metadata. A valid sidecar from a different generation is ignored; a corrupt current sidecar is rejected. Legacy JSON loads without a generation and migrates once on its next accepted chunk. New in-memory progress is published only after the atomic progress save succeeds. Removal, cancellation cleanup, summaries and expiry include/read the new progress file. Final whole-file integrity verification is unchanged.

An older application can read the JSON metadata but does not read the sidecar and may re-download chunks. Filesystem atomic replacement is retained; this is not a new guarantee of power-loss durability or fsync ordering. Synchronous filesystem calls retain the cancellation limits described in the actor report.

## Matched component measurement

Production `DeviceChunkTransfer.swift` and `DeviceSyncModels.swift` are compiled directly with `swiftc -O` before/after. The harness supplies unrelated Track.ID and Playlist placeholder types solely to compile unused playlist declarations; measured store/descriptor/checkpoint code is unmodified. The ordinary package's full Release build was interrupted during initial compilation and provides **no Release application test result**. Local functional tests and actual application builds are recorded separately below.

Host: arm64 macOS 27.0.1; Apple Swift 6.4 (swiftlang-6.4.0.34.1). Three alternating process pairs (before/after, after/before, before/after), each containing three repetitions per size: nine samples per variant/size. Timed runs follow completion of our benchmark compilation and functional-test build; application builds start after all pairs finish. This is a warm local component comparison, not an idle-machine certification or installed-device result.

Fixtures: 4,096 / 16,384 descriptors at 64 KiB per chunk (256 MiB / 1 GiB logical length), synthetic half-received checkpoint sets, 64 new payloads (4 MiB actually written per repetition) in sparse temporary files. Synthetic checkpoint metadata is for load isolation, not a claim of a verified full-size audio transfer. Timings exclude setup, network, JSON wire messages, UI and final whole-file verification. The accept timing includes SHA-256, file open/seek/write/close and checkpoint persistence; it is **not an isolated syscall/encoding timer**. Missing-index and progress timings each call the existing computation 64 times on the half-received checkpoint. Checksums agree before/after.

Median milliseconds for 64 operations:

| Chunks | Operation | Before | After |
|---:|---|---:|---:|
| 4,096 | Missing-index scan | 5.936 | 7.074 |
| 4,096 | Progress aggregation | 0.403 | 0.461 |
| 4,096 | Receive, verify, write and persist | 479.472 | 239.106 |
| 16,384 | Missing-index scan | 41.819 | 40.919 |
| 16,384 | Progress aggregation | 2.260 | 2.427 |
| 16,384 | Receive, verify, write and persist | 1178.991 | 197.361 |

The receive/persistence pipeline is 50.1% / 83.3% shorter in these samples. The source change and relative costs identify repeated full-checkpoint serialization/replacement as the highest-value first target; hashing/data I/O remain in the measured pipeline. Missing-index/progress implementations are unchanged: their small timing variations are **not improvements or regressions established by this experiment**. Raw samples show host scheduling variation; no end-to-end speed, CPU, RSS, energy or physical-storage throughput claim is made.

At 16,384 chunks, each new save carries a 2,048-byte bitmap plus plist headers, instead of rewriting the full hash list. Retained metadata is still approximately 1.10 MB including the immutable JSON (before approximately 1.14 MB); this is primarily a reduction in repeated encoding/writes, not a large retained-disk-space reduction. Bitmap creation still walks received indexes. No write batching is used.

## Verification

- 🟢 [Done] Related protocol/resilience/actor/load suites: 56 test entries passed, including 55 functional cases and the opt-in measurement entry (its ordinary-test body returns without measuring; the standalone harness actually runs the measurement).
- 🟢 [Done] Existing actor tests continue covering pause/resume/cancel/disconnect, stale-result fencing, commit boundaries, durable directory/library loopback and failure retry. New tests cover unchanged immutable metadata across accepts, unordered/duplicate indexes across bitmap bytes, old JSON migration, replacement generations, corrupt/truncated sidecars, failed atomic writes without publishing new state, summary/deletion handling, and a 16,385-chunk sparse checkpoint resumed under a new transfer ID with a seven-byte final chunk. Sparse fixtures do not claim full-file verification; existing loopback/final corruption tests cover that separately.
- 🟢 [Done] Signing-disabled normal Mac Debug and iOS Simulator companion Debug application builds pass. No new App Store Release build, physical iPhone run, sanitizer run or remote CI result is claimed for this change. Whitespace checks pass.

See [raw samples, harness and evidence](../measurements/chunk-checkpoint-load-2026-10-25/).

## Follow-up

- 🟢 [Done] The [request-cost follow-up](CHUNK_REQUEST_LOAD_2026-10-25.md) measures selection/serialization/local IPC and introduces capability-gated compact requests. Actual MCSession performance remains Pending. Bitmap rebuilding, received-Set copies and progress/UI pipeline profiling remain Next.
- ⭕️ [Pending] Installed Mac/physical iPhone large-file transfer, old/new peer pairing, background/suspension, pause/cancel/network recovery, actual permissions and slow/external/network volumes; end-to-end throughput, memory/CPU and sustained energy. Development fixtures and Simulator compilation do not qualify these.
