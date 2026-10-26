# Receipt snapshots, persistence and UI projection — 2026-10-25

## Decision and shared implementation

🟢 [Done] Change the shared Desktop / same-project iOS companion checkpoint's internal receipt storage from a Set to a value-type bitmap with a maintained unique-receipt count. A snapshot shares immutable bytes until modification; updating a receipt copies a compact bitmap rather than a growing Set. Duplicate receipts do not increment the count. Save that bitmap directly instead of rebuilding it from every received index after each payload. Compute admitted progress in constant time from count, chunk size and whether the short final chunk was received.

The old `receivedIndexes` Set API is retained as a conversion boundary for legacy JSON and non-hot callers. JSON metadata fields and version-1 binary-plist progress-file fields are unchanged. New custom Codable code continues reading/writing the old Set field and optional generation. No private receipt cache is encoded. Restore validates bitmap length and unused padding bits, normalizes Data slice indexing and counts bits once. Invalid legacy indexes are retained for validation, not silently dropped; admission rejects/reset them before computing file offsets. Empty files, duplicates, sparse/out-of-order receipts and truncated final chunks retain their semantics. Cold metadata decoding/conversion and first resumed-prefix traversal are still O(N).

The disk actor, lifecycle actor generations, staging/commit boundary and connection fencing are unchanged. Every accepted payload still writes a progress file atomically before in-memory success is published; no save batching, delayed acknowledgement or UI throttling is introduced. Final whole-file verification remains unchanged. File replacement is not a new fsync/power-loss guarantee.

Both controllers now call the same `DeviceTransferState.applyProjection(to:)` function for their existing upsert behavior. This is a shared behavior extraction, not a claim of a UI algorithm speedup. Paused/cancelled/interrupted/completed transitions remain immediate. The separate main iPhone application's legacy whole-resource runtime is unchanged.

## Measurement method and limits

Compile production before/after `DeviceChunkTransfer.swift` and `DeviceSyncModels.swift` with `swiftc -O -swift-version 6`; `-D RECEIPTS` selects the new hot receipt API/projection helper in the improved harness. Before state includes the earlier uncommitted compact checkpoint/request work. Archive original source snapshots and hashes. For **both** measurement variants, `saveProgress` is internal so the harness can time that actual stage; the baseline's only instrumentation change removes `private` from that method. This visibility change is not an alternative persistence implementation. Unused Track.ID and Playlist declarations use placeholder types solely for compilation.

arm64 macOS 27.0.1, Apple Swift 6.4 (swiftlang-6.4.0.34.1). Three alternating process pairs, three repetitions per size in each launch: nine samples per variant/size. All benchmark compilation and functional tests finished before final timed pairs; application builds started afterwards. Preliminary diagnostic samples are not mixed into the final table. Host load is not certified idle; raw samples are retained. No CPU, allocation or process-RSS profiler result is claimed.

Fixtures: 4,096 / 16,384 / 65,536 chunks at 64 KiB (256 MiB / 1 GiB / 4 GiB logical length), half-received synthetic checkpoints, sparse temporary files. These fabricate bookkeeping state and do not claim full-size verified audio transfer. Each receive stage actually writes 64 payloads (4 MiB); the joined stage writes the next 64. Setup and metadata creation are excluded.

Stages are timed separately:

- **Copy/update:** retain 64 checkpoint versions while recording the next receipt, forcing value-copy isolation rather than benchmarking a uniquely held container.
- **Progress:** four completed-byte reads for each of 64 snapshots. Optimized compiler reuse applies; tiny constant-time results approach the timer floor.
- **Persist:** call the production progress-save method for each snapshot: baseline bitmap regeneration plus plist encoding/atomic write; improved cached bitmap plus the same encoding/atomic write. There is no isolated syscall/encoder timer.
- **MainActor publication:** a detached producer awaits a MainActor ObservableObject with 101 transfer rows, updates the actual shared state projection (baseline's identical inline upsert) and a published checkpoint array. Observe objectWillChange. This is a headless controller-publication proxy, **not SwiftUI layout/rendering or an installed controller**.
- **Accept + progress:** actual per-payload SHA-256, partial-file open/seek/write/close, receipt update, progress persistence and four progress reads.
- **Joined path:** the next 64 actual accepts, progress/state/summary construction, compact next-request generation and JSON encoding, then awaited MainActor publication per receipt. This joins components, not the actual worker mailbox/AsyncStream, MCSession or SwiftUI renderer. Network send, final verification/import, controller orchestration and real disk durability are outside this timer.

Checksums, encoded next-request byte totals and publication counts agree across variants. Both standalone-publication and joined runs produce exactly 128 objectWillChange notifications per 64 receipts (state + checkpoints), so improved timings do not come from dropping updates. Stage medians must not be summed as an end-to-end estimate.

## Results

Median milliseconds, nine samples:

| Chunks | Stage | Baseline | Improved |
|---:|---|---:|---:|
| 4,096 | Copy/update ×64 | 0.113 | 0.010 |
| 4,096 | Progress ×256 | 0.524 | <0.010 |
| 4,096 | Progress persistence ×64 | 41.221 | 40.083 |
| 4,096 | MainActor publication ×64 | 0.662 | 0.568 |
| 4,096 | Accept + progress ×64 | 51.325 | 49.511 |
| 4,096 | Joined component path ×64 | 52.708 | 50.363 |
| 16,384 | Copy/update ×64 | 0.464 | 0.011 |
| 16,384 | Progress ×256 | 2.120 | <0.010 |
| 16,384 | Progress persistence ×64 | 45.639 | 40.100 |
| 16,384 | MainActor publication ×64 | 0.667 | 0.567 |
| 16,384 | Accept + progress ×64 | 56.976 | 48.578 |
| 16,384 | Joined component path ×64 | 58.603 | 50.632 |
| 65,536 | Copy/update ×64 | 1.541 | 0.025 |
| 65,536 | Progress ×256 | 8.305 | <0.010 |
| 65,536 | Progress persistence ×64 | 65.740 | 41.966 |
| 65,536 | MainActor publication ×64 | 0.654 | 0.568 |
| 65,536 | Accept + progress ×64 | 83.467 | 50.330 |
| 65,536 | Joined component path ×64 | 84.471 | 51.177 |

The joined component median is 4.4% / 13.6% / 39.4% shorter for these sizes. The largest scaling improvement is removing repeated received-index traversal from bitmap generation/progress and reducing snapshot copy size. An N-chunk bitmap carries ceil(N/8) bytes (8,192 bytes at 65,536), but no absolute retained-RSS saving is asserted. Remaining progress serialization/atomic replacement dominates; it still occurs 64 times. UI upsert logic/publication volume is unchanged and its sub-millisecond proxy differences are not established as a rendering improvement. No installed-app transfer-throughput or device-energy gain is claimed.

## Verification

- 🟢 [Done] Related suites pass 65 test entries (64 functional entries plus the prior opt-in measurement entry, which returns without measuring in an ordinary test run). The receipt reference-model test runs eight sizes: 0/1/7/8/9/4,096/16,385/65,537.
- 🟢 [Done] Compare bitmap contents/count/progress/completion with a Set model over unordered/duplicate updates; verify old snapshots stay independent. Verify old JSON reads and old-reader field compatibility, short final chunks, Data slice normalization, wrong length/padding rejection without mutating the original, invalid/overflow-sized legacy indexes, and projection order/terminal replacement.
- 🟢 [Done] Existing real-file tests cover atomic-save failure without new receipt publication, sparse resume, legacy migration/generations, corrupt sidecars, pause/resume/cancel/disconnect/stale packets/results, commit boundaries, failure retry and once-only callbacks. Encoded directory/mobile-library loopback and final SHA-256 tests still pass, including multi-chunk and non-advertising peers.
- 🟢 [Done] Signing-disabled Mac Debug and iOS Simulator companion Debug builds pass. Whitespace/project-format checks pass. No new App Store Release build, sanitizer run, installed-device or remote CI result is claimed.

[Raw final samples, harness, source snapshots and verification](../measurements/chunk-receipt-path-2026-10-25/).

## Follow-up

- 🟠 [Next] Split the remaining progress-save stage into encoding and filesystem costs before changing durability policy. Profile actual worker event delivery, resume metadata loading and larger UI histories separately. UI coalescing was not adopted on the strength of a headless proxy.
- ⭕️ [Pending] Installed Mac/physical iPhone MCSession throughput, SwiftUI rendering/frame cadence and MainActor contention, actual large Music files/permissions, old/new pairing, pause/resume/cancel/network loss under background/sleep or slow/external/network storage; CPU/RSS and sustained energy. Local fixtures and Simulator compilation do not qualify these.
