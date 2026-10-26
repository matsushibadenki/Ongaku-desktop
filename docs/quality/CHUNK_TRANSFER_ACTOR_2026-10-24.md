# Chunk transfer actor ownership — 2026-10-24

🟢 [Done] Desktop and its iOS companion now share `DeviceChunkTransferWorker`. The separate Ongaku iPhone app's legacy whole-resource controller is unchanged. This validates shared transfer behavior and companion compilation, not physical-device pairing.

## Ownership and ordering

| Owner | Responsibility |
|---|---|
| MainActor controllers | Published UI projections, pairing, legacy MCSession resources and bulk orchestration |
| Connection mailbox | Thread-safe physical connection UUID, synchronous FIFO command admission |
| Transfer actor | Session dictionaries, generation tickets, pause/resume/cancel/disconnect state and once-only completion callbacks |
| Private serial disk actor | Validated source descriptors, reads, checkpoint creation/persistence/removal, verification, staging and durable commit |

Both controllers no longer own chunk I/O queues, checkpoint stores or active chunk dictionaries. The lifecycle actor can accept controls while disk work runs; disk jobs execute serially without suspension inside checkpoint mutations. Generation tickets and physical connection checks reject delayed results. A single requested incoming index is accepted at a time. Paused sender data is read and verified again on resume. Cancel cleanup precedes reopening the same file; active duplicate hashes are rejected. Disconnect retains recoverable checkpoints; a new session requests only missing chunks. Wire DTOs and per-chunk/final SHA-256 checks remain compatible with the earlier validated-snapshot implementation.

Source descriptor and whole-file hashing check cancellation between bounded reads. FileManager copies and individual filesystem calls are synchronous and cannot be forcibly interrupted; there is no hard cancellation-latency guarantee. The lifecycle actor establishes a commit boundary before durable publication. Cancellation/pause arriving after that boundary does not undo a committed file. Disconnect permits local commit to finish but suppresses acknowledgement on the old connection. Checkpoints/staging are removed only after successful verified publication. Companion chunk commits share the existing library repository instance with legacy imports; legacy repository locking is retained.

## Local verification

- 🟢 [Done] `swift test --filter 'ChunkTransferWorkerTests|M8TransferResilienceMilestoneTests|DeviceSyncTests'`: 52 tests, three suites passed. The actor suite contributes 20 tests.
- 🟢 [Done] Thread Sanitizer: all 20 actor tests passed with no reported sanitizer race. Real temporary-file I/O is exercised; transport uses spies and JSON-encoded loopback, not physical MCSession peers.
- 🟢 [Done] Tests hold I/O/result delivery at deterministic gates: pause/resume during descriptor/read/checkpoint/staging; cancel before publication; commit winning late cancellation; exactly-once callbacks; shutdown draining; disconnect/new generation; persisted restart with missing chunks only; old-session packets/results; duplicate SHA ownership; capacity/send/commit failures and retry; cancellable whole-file verification. Encoded loopback covers empty and 150,123-byte files for Mac-directory and mobile-library destinations with hash and durable manifest checks.
- 🟢 [Done] Signing-disabled builds pass: normal Mac Debug, Mac App Store Release, iOS Simulator companion Debug. Xcode project registers the shared worker in all three targets. `git diff --check` passes. AppIntents metadata and Simulator architecture notices are not test failures.

Evidence is in [the measurement directory](../measurements/chunk-transfer-actor-2026-10-24/). This task establishes correctness/ownership; no new transfer-speed or memory improvement is claimed. Changes have not been pushed or deployed by this task.

## Remaining qualification

- ⭕️ [Pending] Installed Mac/physical iPhone pairing, pause/resume/cancel, real network loss/reconnect and background/suspension; actual Music files and permissions; slow external/network volumes, sustained energy and end-to-end throughput.
- 🟢 [Done] Initial large-transfer scan/progress/persistence comparison and compact checkpoint improvement are recorded in the [2026-10-25 follow-up](CHUNK_CHECKPOINT_LOAD_2026-10-25.md). Request/scan profiling and legacy resource-path / broader A4 ownership remain unfinished.
