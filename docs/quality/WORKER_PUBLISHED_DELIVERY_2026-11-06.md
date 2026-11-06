# Actual worker to Published-state delivery — 2026-11-06

## Measurement path and decision

Added an optional worker dependency to the existing Mac `PhoneSyncController` initializer. Its default path still creates the same MCSession sender, checkpoint directory and destination. The existing event reducer is module-internal and MainActor-isolated, so the fixture can populate prior history through that same reducer rather than substituting a second model. The actual controller event-consumer task and `@Published transfers` property perform every timed publication. No worker, wire format, projection algorithm, throttling or recovery policy changed.

The fixture uses an isolated checkpoint/destination and unique UserDefaults suite, four different synthetic 4 MiB files, 64 KiB chunks, and compact requests. It encodes/decodes offer/request/payload DTOs, runs actual receiver file writes/checkpoints/final verification/commit, delivers actual worker events via its AsyncStream to the production MainActor reducer, and observes the production publisher. All 256 chunk progress updates arrive, with 280 total publications including phases. Four completed files have their full SHA-256 verified, all transfer counters equal their sizes, and history order/count is retained.

The receiver's input timestamp is recorded immediately before `client.submit(.payload)`, after fixture JSON decoding. Receipt-to-Published latency therefore includes receiver admission, chunk validation, checkpoint I/O, disk replies, mailbox processing, MainActor delivery and projection. It is not an isolated event-emission-to-main measurement. Wall/process CPU include offer JSON and the fixture's synthetic request/payload responder. Offer JSON codec placement is a fixture boundary, not the real MC delegate queue. Sender-file I/O, MCSession/radio/network RTT, library import after verified commit and actual SwiftUI layout/frames are excluded. Capacity preflight is a constant accepting closure; recovery/capacity behavior is covered separately by regressions.

## Results

SwiftPM Debug, macOS 27.2 build 26B123, Apple Swift 6.4.2, arm64. Each history size runs in a fresh test process, three rounds, 16 MiB/256 chunks per round. Histories are synthetic repeated-item states; initialization/population is outside timing. No other builds or benchmarks ran during timed samples. Host caches were not flushed; case order was 50, 500, 5000, so these are descriptive samples, not a causal claim that a larger history is faster.

| History rows | Wall ms median | Process CPU ms median | Median of run p95 ms | Process peak RSS MiB max |
|---:|---:|---:|---:|---:|
| 50 | 130.319 | 206.343 | 2.193 | 92.97 |
| 500 | 109.402 | 180.763 | 1.212 | 92.38 |
| 5000 | 108.422 | 212.207 | 1.385 | 103.00 |

All individual run p95 values are 1.183–2.470 ms, with maximum observed receipt age 4.212 ms. RSS is whole-process high-water after verification and includes frameworks, fixtures and history; it is not per-transfer memory or an isolated allocation delta. Reported CPU is the whole process, including the responder, not receiver-only energy. Small differences cannot establish device UI performance.

The current indexed reducer does not show a material history-size delivery penalty in this fixture. No additional buffering, delayed UI update or data-structure optimization was adopted from these results. Actual frame behavior, larger descriptors/chunk counts and real transport remain qualification work; 280 publications is not 280 rendered frames.

## Verification and reproduction

- `swift test --jobs 2 --filter 'WorkerDeliveryPerformanceTests|ChunkTransferWorkerTests|DeviceSyncTests|TransferProjectionPerformanceTests'`: final **40 test declarations / 4 suites PASS**. Opt-in measurement bodies return early without their environment flag; these ordinary results are not counted as benchmark samples. Existing cases cover pause/resume/cancel, stale connection contexts, reconnect/restart and encoded loopback to Mac-directory and mobile durable-library destinations.
- Run in separate test processes, sequentially after compilation: `env ONGAKU_WORKER_DELIVERY_COST=1 ONGAKU_WORKER_HISTORY_ROWS=50 swift test --skip-build --filter WorkerDeliveryPerformanceTests`, repeating with `500` and `5000`. Each process runs one measurement test with three rounds; all nine records pass their receipt/file/state checks. Do not run builds or other audits concurrently.
- Normal Mac Debug signing-disabled Xcode build: PASS. Mac App Store Release signing-disabled Xcode build: PASS.
- Measurement fixtures and final controller regressions use temporary paths and isolated app defaults; no product sync session was started. Existing controller tests had used default construction; these were moved to injected temporary workers/defaults so initialization cannot prune product checkpoints. The first and final regression logs are retained. iPhone's independent bulk-resource implementation is unchanged; the common worker remains the same source used by Mac and companion, with mobile durable-destination behavior covered by existing loopback regressions.

[Raw logs, nine records, summary and final-source hashes](../measurements/worker-published-delivery-2026-11-06/).

## Remaining work

🟠 [Next] Real SwiftUI view rendering/initial display and larger metadata/chunk-count profiling. The complete transfer UI/transport qualification and other ROADMAP groups remain unfinished.

⭕️ [Pending] Signed physical Mac/iPhone MCSession throughput, MainActor/display contention, real network and storage latency, pause/resume/cancel/disconnect under actual radio transport, background/sleep, memory/thermal/energy and real libraries. Publisher delivery measurements are not physical-display or real-network results.
