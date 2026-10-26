# Missing-chunk request cost — 2026-10-25

## Implementation and scope

🟢 [Done] Optimize shared Desktop / same-project iOS companion request generation. The separate main iPhone application's legacy whole-resource path is unchanged. Both companion targets compile the same source; actual installed cross-device operation remains Pending.

The existing sender reads only the first requested index, while the receiver rebuilt and sent every missing index after every accepted payload. Add a session-local monotonic cursor and request one index when the sender advertises support. A new optional descriptor field `supportsCompactRequests` is set by newly prepared senders. A new optional request field `remainingChunkCount` preserves sender progress despite the one-element list. The sender checks advertised support, a one-element request and a positive bounded remaining count before reading compact requests. Old requests without the field retain the previous progress calculation.

Compatibility matrix:

| Sender | Receiver | Requests |
|---|---|---|
| Advertises compact support | Understands capability | One missing index plus total remaining count |
| Omits/declines support | New receiver | Full missing-index list; no remaining-count field |
| New sender | Old receiver | Old receiver ignores optional offer field and sends its original full list; new sender accepts it |

No global protocol-version bump or hard requirement for the new fields is introduced. Optional fields are omitted when nil. An old decoder can ignore extra keys, but compact requests are only generated after a positive sender advertisement. Physical old/new application pairing has not been tested.

The cursor advances only past received indexes; a repeated request before receipt selects the same index. Pause retains that session cursor and its authoritative checkpoint; cancellation retires it. Reconnection/recreated sessions start at zero and consult their own resumed checkpoint, so earlier holes cannot be skipped by an inherited cursor. First resumed-prefix traversal remains O(N); subsequent selection is amortized across the growing set. Legacy peers retain the previous scan/list cost. Integrity checks, per-payload persistence, one outstanding receive, connection/transfer generation fences and durable-commit boundaries are unchanged.

## Matched component measurement

Compile actual before/after `DeviceChunkTransfer.swift` and `DeviceSyncModels.swift` using `swiftc -O`; improved build also sets `-D COMPACT` to select the new helper in the harness. The before snapshot includes the preceding bitmap checkpoint optimization, which is still uncommitted; it is not claimed to equal repository HEAD. Archive that snapshot and the request-only source diff with hashes. Unused Track.ID and Playlist declarations use placeholder types solely for compilation; measured request/checkpoint/DTO code is production source.

arm64 macOS 27.0.1, Apple Swift 6.4 (swiftlang-6.4.0.34.1). Three alternating process pairs (baseline/improved, improved/baseline, baseline/improved), three repetitions per chunk count per launch: nine samples for each variant/count. Our compilation and initial functional run completed before timed pairs; application builds started afterwards. No claim of an otherwise idle machine is made.

In-memory fixtures have 4,096 / 16,384 chunks at 256 KiB (1 / 4 GiB logical file length), half marked received, then 64 simulated accepted indexes. No audio files are read/written in this benchmark. Selection timing includes request construction and the simulated Set insertion; JSON timing uses a fresh JSONEncoder per actual `DeviceSyncMessage.chunkRequest`, matching the production sender's encoding. Local IPC timing writes encoded packets to an AF_UNIX socket pair and drains them synchronously in at most 4 KiB pieces. It includes local write/read/copy overhead and excludes socket setup. This is **not MCSession or network send latency**. Checksums confirm the same selected indexes before/after. Requests/encoded packets are retained for stage isolation, unlike the production one-outstanding-request flow; this is not a peak-memory test.

Median milliseconds for 64 requests:

| Chunks | Stage | Baseline | Improved |
|---:|---|---:|---:|
| 4,096 | Selection + construction | 1.964 | 0.051 |
| 4,096 | JSON encoding | 3.389 | 0.419 |
| 4,096 | Local IPC write + drain | 0.135 | 0.064 |
| 16,384 | Selection + construction | 7.049 | 0.133 |
| 16,384 | JSON encoding | 10.891 | 0.314 |
| 16,384 | Local IPC write + drain | 0.407 | 0.064 |

| Chunks | JSON bytes for 64 requests, baseline | Improved |
|---:|---:|---:|
| 4,096 | 652,384 | 9,152 |
| 16,384 | 3,027,040 | 9,152 |

JSON encoding was the largest measured stage; avoiding the redundant list benefits encoding, selection and transport payload together. At 16,384 chunks the JSON payload reduction is 99.70%. Request **frequency** and one-payload round trips are unchanged. MCSession queueing/packaging/reliability, actual network bandwidth/latency, UI and persistence are outside the timed comparison; no end-to-end transfer speed, CPU/RSS or energy improvement is claimed. Small-file requests acquire a few optional-field bytes and are not claimed to become universally faster. Historical measurements with other fixtures/load are not directly comparable.

## Validation

- 🟢 [Done] Related suites pass 61 entries (60 functional entries plus the preceding opt-in load-measurement entry, which returns without measuring during an ordinary run). The new measurement is run separately by the archived optimized harness.
- 🟢 [Done] Cursor tests cover sparse 16,385-index checkpoints, repeated requests, completion, fresh-session restart, nil/false capability fallback and legacy/current JSON field decoding.
- 🟢 [Done] Actor tests cover compact count bounds, correct compact and legacy sender progress, full-list requests for non-advertising offers, pause/resume, preparation/read/stage cancellation, stale packets/results after disconnect, persisted missing-only recovery, failure/retry and once-only callbacks. Updated resumed-session checks require the exact compact index and remaining count.
- 🟢 [Done] Encoded loopback covers empty and 150,123-byte files, plus 600,123-byte multi-chunk files with positive and absent capability advertisements, for both directory and durable mobile-library destinations. Verify final file hashes and library visibility/checkpoint cleanup. This simulates absence of an advertisement with current code; it does not run an old application binary.
- 🟢 [Done] Signing-disabled normal Mac Debug and iOS Simulator companion Debug builds pass; whitespace checks pass. No new App Store Release build, sanitizer run, installed-device result or remote CI claim.

[Raw samples, source snapshots, harness and verification](../measurements/chunk-request-load-2026-10-25/).

## Remaining work

- 🟢 [Done] The [receipt-path follow-up](CHUNK_RECEIPT_PATH_2026-10-25.md) measures snapshots/persistence/progress/headless MainActor publication and joins those components. Actual worker event delivery, SwiftUI rendering and MCSession remain separate qualification; legacy resource-path and broader A4 ownership are unfinished.
- ⭕️ [Pending] Real MCSession encode/send/queue cost and end-to-end throughput on installed Mac/physical iPhone; actual old/new pairing, large Music files, network loss/reconnect, pause/resume/cancel under background/sleep and slow volumes; CPU/RSS and sustained energy. Development loopback and Simulator builds do not qualify these.
