# Checkpoint resume and stale-pruning scan — 2026-11-02

## Scope

The desktop repository shares `DeviceChunkTransfer.swift` and `DeviceChunkTransferWorker.swift` between the Mac app and its iOS companion. The independent iPhone app's bulk-resource transfer is unaffected. A refresh that prunes stale checkpoints while no transfer is active previously loaded and decoded every checkpoint once to find stale files, deleted them, then loaded and decoded the survivors again. `pruneStaleAndSummarize` now returns the retained entries from the same sorted snapshot after the same deletions; errors still propagate and refresh without pruning remains unchanged. Files changed externally during a scan are picked up by a later refresh; the returned listing is a snapshot, not a new atomic multi-file transaction.

## Measurement

On this Mac, use `ONGAKU_CHECKPOINT_RESUME_COST=1 swift test --filter CheckpointPersistenceCostTests/measureResumeMetadata`. The fixture contains eight fresh checkpoints, each with half its chunks acknowledged, fixed JSON metadata saved at creation and a matching compact progress sidecar. Seven alternating-order samples compare the previous two-pass procedure with the new single-pass procedure; times below are medians for the whole refresh. No stale files are deleted in these timing samples. The test checks the eight summaries and completed byte counts; no MCSession transport or UI rendering is included.

| Chunks per checkpoint | One load | Previous prune + reload | Single-pass prune | Reduction |
| ---: | ---: | ---: | ---: | ---: |
| 4,096 | 0.894 ms | 14.462 ms | 7.207 ms | 50.2% |
| 16,384 | 3.241 ms | 53.094 ms | 26.652 ms | 49.8% |
| 65,536 | 13.236 ms | 212.716 ms | 106.055 ms | 50.1% |

These are warm local-filesystem component measurements, not end-to-end transfer or installed-device results. Generation validation, on-disk formats, per-chunk atomic progress saves and SHA-256 checks remain unchanged. The single snapshot avoids a redundant read but does not reduce the first JSON decode itself.

## Validation and next work

- 🟢 [Done] 55 test entries passed across the checkpoint, receipt, cursor, large-transfer, M8 and actor suites, including pause, resume, cancellation and disconnect recovery. This count includes two opt-in benchmark entries that return without timing when not enabled. The new functional tests verify stale removal, the exact cutoff boundary, remaining order/progress, removal of metadata, sidecar and partial files, and publication through the actual transfer actor. The iOS companion Debug build for the arm64 iOS Simulator also succeeded.
- 🟠 [Next] Measure worker event delivery and numerous UI histories independently, and investigate first-read metadata decoding without weakening legacy compatibility, validation or recovery.
- ⭕️ [Pending] Physical Mac/iPhone MCSession, background/sleep, concurrent external storage changes, slow/external volumes, memory/energy, and actual SwiftUI rendering; validate installed builds and long-running real transfers.
