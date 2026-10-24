# Retire fallback search storage after SQLite recovery — 2026-10-22

## Priority and implementation

This is one bounded step of ROADMAP A3 (large-library resident-memory reduction). The production search worker can retain up to 64 MiB of derived UTF-8 search text and a snapshot of Track references while SQLite is being prepared or is unavailable. Previously, successful parity verification switched queries to SQLite but left that fallback snapshot retained until another fallback revision/library replacement. It could outlive its useful backend role.

After verified SQLite promotion, cancel/reschedule the current query through the existing routing path, then retire the superseded fallback snapshot on its own actor. The release checks cancellation, library identity and the covered tracks revision. A delayed old synchronization cannot evict a different library or a newer fallback revision. Clear both derived text and retained Track-array references; keep all SQLite parity and generation guards intact. If SQLite fails again, fallback text is reconstructed from current tracks with unchanged search semantics.

The worker can be injected into LibraryStore for an actual backend-recovery regression. No catalog schema, persisted data, query normalization, result limit, UI/localization or audio processing changes. The separate iPhone application does not use this Desktop search worker; its playback and library behavior remain unchanged. Shared sync contracts are untouched.

## Verification

- Related presentation/search-routing/SQLite suites: **26 tests pass** in 3.494 seconds after compilation. This includes the actual blocked-index → fallback → recovered-index transition and stale/cancelled worker retirement cases.
- Opt-in benchmark, Debug test host on the development Mac, Testing 2084: **100,000 tracks × three cycles** pass. Each cycle retires **7,366,666 UTF-8 bytes (7.03 MiB)** and the worker's **100,000 Track references**, leaving both counters at zero. Release durations: **3.413 / 3.882 / 7.756 ms**, including the actor call. These are cache-owned payload/reference counts, not equivalent RSS savings.
- Rebuilding after release and checking English/Japanese/Simplified Chinese queries against direct matching pass in each cycle. Cold reconstruction times are **3.629 / 3.766 / 7.003 s in Debug**, recorded as context, not a speedup or production latency result. The whole correctness benchmark takes 63.805 s.
- Raw results and measured-source hashes: [evidence](../measurements/fallback-cache-retirement-2026-10-22/).
- Normal macOS Debug and Universal Mac App Store Release app builds pass with signing disabled (Xcode 27.1 / 27A9275); `git diff --check` passes. Builds do not establish signed installed-app UI or memory qualification.

The optional 100,000-track benchmark records retained UTF-8 bytes, Track-reference count, reconstruction and release durations over three cycles. It verifies English/Japanese/Simplified Chinese queries against direct production matching after release. These are logical cache-retention counts and development-host timings, not process RSS/physical-footprint reductions, an installed-app UI benchmark, p95 results or a 512 MiB product-gate pass. The allocator and other owners can retain process memory after references are dropped.

The real LibraryStore regression begins with an unusable SQLite directory, populates fallback search, restores the index destination and edits metadata to trigger synchronization. It requires verified SQLite routing, zero retained fallback text and correct English/Japanese/Simplified Chinese results. Worker regressions cover mismatched library, newer revision, cancelled retirement, successful release and subsequent fallback reconstruction. Existing edit/reorder/delete/cancel/budget/parity tests remain required.

## Remaining work

- 🟢 [Done] Retire obsolete fallback storage after verified SQLite promotion, retaining safe fallback reconstruction and generation boundaries.
- 🟠 [Next] Continue A3 initial and steady-state memory profiling, and qualify first display/search under playback and index-update workloads; the product 512 MiB / display / search targets remain unfinished. Full first audio-rack initialization and A4 transfer actor ownership are separate unfinished priorities.
- ⭕️ [Pending] Installed-app 100,000-track RSS/physical-footprint and UI qualification, physical playback/DAC/listening, and real user libraries. No physical-device claim follows from these worker tests.
