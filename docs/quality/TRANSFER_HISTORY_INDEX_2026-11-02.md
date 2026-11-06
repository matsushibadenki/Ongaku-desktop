# Transfer history projection index — 2026-11-02

## Change

The Mac and iOS companion controllers used a linear search of the complete transfer history for each state, phase and progress update. Both now use `DeviceTransferProjectionIndex`, shared by their existing model source. It caches positions as offsets from the array's end so a new transfer inserted at the front does not invalidate existing offsets. Every cache hit checks the current array bounds and identifier; a miss or stale entry falls back to the original first-match scan. New entries still appear at the front, existing entries stay in place, and every previous `@Published` mutation still occurs. Neither event delivery nor updates are throttled. Reordering or removal triggers validated fallback; the controllers maintain unique transfer IDs.

## Measurement

`ONGAKU_TRANSFER_PROJECTION_COST=1 swift test --filter TransferProjectionPerformanceTests` runs on the main actor with an actual `@Published` array and Combine subscriber. Seven alternating-order samples each update four existing rows near the end of histories of 50, 500 and 5,000 rows, 128 times. The indexed measurement includes initial cache misses; both paths publish 128 notifications and produce equal final arrays.

| History rows | Linear median | Indexed median | Reduction |
| ---: | ---: | ---: | ---: |
| 50 | 1.622 ms | 0.378 ms | 76.7% |
| 500 | 10.344 ms | 2.509 ms | 75.7% |
| 5,000 | 102.337 ms | 25.556 ms | 75.0% |

These are local Debug-build component measurements for a deliberately unfavorable history position, not SwiftUI frame times, worker queue latency, MCSession throughput, or battery measurements. Array copies and rendering remain; the index also uses memory proportional to distinct accessed IDs. The initial insertion or first lookup can still scan the array.

## Validation

- 🟢 [Done] 71 test entries in eight suites passed, including projection equivalence across 800 updates, front insertions, reversal, removal and stale indexes; cancellation, resume and disconnect actor tests and protocol tests. Three opt-in benchmark entries return without measuring in an ordinary run. The timed comparison additionally asserts identical arrays and 128 notifications.
- 🟢 [Done] Mac test build and arm64 iOS Simulator companion Debug build succeeded.
- 🟠 [Next] Measure actual worker event delivery, real SwiftUI histories and initial metadata decode independently; assess memory use and optimization only with recovery semantics intact.
- ⭕️ [Pending] Physical Mac/iPhone MCSession throughput, MainActor contention, real-device SwiftUI frame cadence, background/sleep, connection loss, large libraries, CPU, memory and energy. The independent iPhone app's bulk-resource transfer is not affected.

## Follow-up — 2026-11-06

[Actual worker to Published delivery](WORKER_PUBLISHED_DELIVERY_2026-11-06.md) now measures receiver checkpoint I/O and controller publication with 50/500/5000 history rows. The earlier component numbers remain historical; actual SwiftUI frames, larger descriptors/chunk counts and physical transport still need qualification.
