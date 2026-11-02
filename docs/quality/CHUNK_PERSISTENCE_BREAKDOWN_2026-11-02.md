# Checkpoint persistence breakdown — 2026-11-02

## Scope and method

The desktop repository's shared Mac/iOS companion checkpoint code is measured on this Mac; the independent iPhone app's bulk-resource transfer is not measured. An opt-in Swift test (`ONGAKU_CHECKPOINT_COST=1 swift test --filter CheckpointPersistenceCostTests`) separates binary property-list encoding from `Data.write(options: .atomic)` to the same local temporary directory. It runs nine alternating-order samples of 64 operations per stage. The test also decodes actual `DeviceTransferCheckpointStore.saveProgress` output and checks its bitmap, count, generation and timestamp against the benchmark model. Each component is measured separately; the sum is not an end-to-end transfer time. The benchmark is compiled in the ordinary test suite but does not run unless enabled.

| Chunks | Encoded bytes | Encoding, 64 operations median | Atomic replacement, 64 operations median |
| ---: | ---: | ---: | ---: |
| 4,096 | 684 | 0.272 ms | 13.340 ms |
| 16,384 | 2,220 | 0.382 ms | 13.383 ms |
| 65,536 | 8,366 | 0.792 ms | 15.498 ms |

These are single-run medians on a local warm filesystem, not confidence intervals or device-throughput results. An initial independent run showed 0.326–1.727 ms encoding and 20.534–28.561 ms writes, illustrating environmental variation. Atomic replacement dominates this isolated comparison; encoding reuse would not address the dominant cost. No batching, durability reduction, format change, or UI notification throttling was adopted. A successful atomic write is not a claim of fsync/power-loss durability.

- 🟢 [Done] Add a reproducible opt-in breakdown and check compatibility against the production encoder.
- 🟢 [Done] Existing checkpoint/receipt, missing-request, large-transfer, actor pause/resume/cancel/disconnect and M8 resilience suites passed: 51 tests.
- 🟠 [Next] Measure actual actor event delivery, metadata resume loading, UI history and filesystem behavior independently; explore safe improvements only with recovery and acknowledgement semantics preserved.
- ⭕️ [Pending] Physical Mac/iPhone MCSession, background/sleep, external or slow volumes, power-loss recovery, CPU/memory/energy and actual SwiftUI rendering. Simulator and local filesystem numbers do not establish those results.
