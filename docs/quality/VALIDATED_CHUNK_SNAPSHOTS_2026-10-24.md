# Validated chunk snapshots — 2026-10-24

## Change and scope

ROADMAP A4 calls for clearer transfer ownership and test boundaries. This bounded step removes repeated descriptor-wide validation from each admitted session's payload reads and checkpoint writes. Previously every chunk checked the entire hash list again; for N chunks, that shape/hash-string work grows with N for every request. Keep one immutable `ValidatedDeviceChunkTransferDescriptor` snapshot per outgoing/incoming session in both Desktop `PhoneSyncController` and its same-project iOS companion `MobileSyncController`.

Only successful local validation can construct that type. It is Sendable, holds a value-semantic immutable DTO, is not Codable and cannot import a trusted status from the network. The outgoing factory validates once after building the chunk list; incoming offers validate once before checkpoint admission. The original DTO APIs remain validated compatibility entry points, and old receive-API invalid-descriptor errors keep their checkpoint-mismatch classification. Wire Codable models and all message fields are unchanged.

Every payload read still checks index bounds and hashes the bytes read from the current file. Every accept still checks session UUID, checkpoint file size/chunk size/hash identity, index, exact byte count and the selected chunk's SHA-256. Newly explicit UUID and checkpoint-shape checks reject cross-session/inconsistent direct calls before writing. Finalization still verifies the complete file hash and length. Resumed checkpoints reuse the already-compared hash array for the admitted descriptor; mutable copies do not change the validated snapshot.

The separate main iPhone repository (`Ongaku/audio/DesktopSyncController.swift`) uses a different whole-resource path and does not use this chunk worker. Its runtime, playback, assets and protocol models are unchanged. This work does not claim that the two iOS applications share the same transfer implementation or that an installed cross-device workflow has been qualified.

## Correctness and builds

- Debug: **32 transfer/protocol tests pass**, including four new behavioral test groups (plus a separately gated benchmark). Release: the same **32 tests pass**.
- Verify raw/reused payload bytes, unchanged chunk-offer decode, copy mutation isolation, malformed admission, legacy error classification, damaged chunk/length/checkpoint rejection, changed source bytes after admission, persisted resume with a new session ID, rejection of an old session ID, empty file completion and rejection of final-file corruption.
- Existing pause/resume protocol, capacity, overlay/playlist and durable received-library tests remain passing. These model tests do not establish live controller cancellation/disconnection ordering.
- Normal Mac Debug, Universal Mac App Store Release and the `OngakuMobile` iOS Simulator companion target all build with signing disabled on Xcode 27.1 (27A9275). `git diff --check` passes. No root iPhone application build is claimed for this Desktop-only source change.

## Matched Release comparison

Run `ONGAKU_RUN_CHUNK_PREPARATION_BENCHMARK=1 swift test --build-system native -c release --scratch-path <temporary-build> --filter validatedChunkPreparationBenchmark` alone after building. Three rounds alternate checked DTO/reused snapshot order (A/B, B/A, A/B) in one process. Both paths read and SHA-256-check the same 64 requested chunks from a 4096-chunk descriptor, at the **product default 256 KiB chunk size** (16 MiB payload total per sample). The synthetic zero-filled source is 1 GiB. File creation, descriptor/hash-list construction and whole-source hash generation are outside timestamps and warm the file cache. Include one admission validation in each reused-path timing; retain per-payload file open/seek/read/hash/close in both paths. This compares the current checked DTO compatibility API with the reused API, not two complete application builds.

| Preparation path | Median wall ms | Median process CPU ms |
| --- | ---: | ---: |
| Descriptor checked per request | 244.900 | 240.775 |
| Reused validated snapshot | 13.255 | 13.219 |

The measured preparation span is **94.6% shorter**; process CPU is **94.5% lower**. Min/max and all six raw samples are retained in [evidence](../measurements/validated-chunk-snapshots-2026-10-24/). Three paired samples are not a p95 or hardware-wide claim. This is **sender payload preparation only**, not end-to-end transfer throughput. Network transport, message encoding, receiver checkpoint JSON/disk writes, missing-index/progress scans, final verification, source cold I/O and device energy are excluded. Receiver reuse is correctness-tested; no equal receiver speedup is claimed. No other compilation/benchmark was launched by this task during the timed comparison.

## Remaining priorities

- 🟢 [Done] Admit immutable validated transfer snapshots and reuse them in Desktop/companion send/receive paths, preserving data verification and wire compatibility; qualify the component with integrity tests and matched Release CPU/timing evidence.
- 🟠 [Next] Complete A4 dedicated-actor ownership of file I/O/checkpoints/session dictionaries and in-flight cancel/disconnect generations. Current locks/queues and their ordering are not replaced here. Further profile missing-index/progress scans and checkpoint persistence before changing the protocol or durability policy. Shared first audio-rack initialization and A3 installed-app memory/display goals also remain unfinished.
- ⭕️ [Pending] Real Mac/iPhone companion pairing, network loss/pause/cancel/resume and large actual audio files, installed/sandboxed storage permissions, end-to-end throughput, sustained energy and root-iPhone cross-device behavior. Unpublished local changes have no remote CI result. Audio/DAC/listening qualification is unchanged.
