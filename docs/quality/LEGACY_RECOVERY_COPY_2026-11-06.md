# Legacy damaged-record recovery copies — 2026-11-06

## Scope and behavior

Mac Storage settings now offers **Create Recovery Copy** and **Resume Recovery Copy**. The user explicitly chooses a readable catalog, an exported catalog or a retained `Previous` catalog, then a destination parent. This is an independent recovery library: it does not guess or replay an unreadable old storage-restore, sync-overlay, organization, catalog-write or import journal. Original catalog, audio, journals and backups are retained. No user's library was switched by these automated tests.

The selected catalog is decoded through the existing migration path. Its exact bytes and readable raw sync tags are retained under the new library's `Recovery Backups/Selected Catalog`. Track and playlist IDs, ratings, queue and history are preserved; the library ID is new. Decodable tags are filtered to retained track IDs. Recognized artwork folders and referenced readable playlist images are copied. Uncommitted metadata absent from the selected snapshot cannot be reconstructed, and malformed tags are retained as raw bytes rather than guessed.

Audio with a known SHA-256 must match it. The search can locate moved audio and organization backups by size and hash. Old missing fingerprints can be derived only from an existing exact path, with the count shown to the user; this does not establish that the file is unchanged since the original catalog. The default policy stops on missing/unreadable audio. Only the explicit, initially unchecked **Keep unavailable tracks as missing** option preserves unavailable metadata with `.missing` health. Such placeholders are never reported as verified playable audio.

A hidden preparation folder is published only after its checksum-protected recovery plan and pending catalog header are written. An unfinished copy is rejected by ordinary load; the intentionally unsupported pending header also makes the existing decoder fail instead of opening an empty library if it ignores the new marker. Completed copies return to the ordinary current catalog schema. A failure retains a separately identifiable copy that can be resumed or cancelled. Already verified destination audio is reusable without the original medium. Unknown destination files are not overwritten. Copied read-only audio is synchronized through a read handle; source permissions are unchanged.

Resume checks the copy's identity and location before writes and publication. Moving its parent during work stops old-path publication; Resume at the new parent rebases owned paths. While unfinished, retain the `Ongaku-Recovered-UUID` leaf name. A completed library can be renamed or moved through the existing audio relocation and the new portable playlist-artwork relocation. Store activation checks library identity and operation ownership, refuses missing targets, and does not flush the broken original's pending queue. A later profile switch wins over an older recovery-open operation.

## Cross-app consistency

The feature belongs to the Mac portable-library repository. Completed catalogs retain the existing schema; device-sync messages and the independent iPhone runtime are unchanged. Both ROADMAPs track the same implementation and verification scope. An older client must not be assumed to support every intermediate recovery artifact; signed installed-version coexistence remains Pending.

## Verification

- CI-equivalent ordinary unit/localization/layout/privacy gate: **491 test declarations / 57 suites PASS** (`swift test --jobs 2 --skip 'PlaybackTransportIntegrationTests|AudioThreadGainIntegrationTests|StorageDelayedFailureTests|LibraryPresentationTests|LargeLibraryPerformanceTests|PlayerNodeStopCoordinatorTests'`). The new serialized recovery suite has 22 declarations; parameter cases are not counted as additional declarations.
- Isolated player-node retirement/UI responsiveness suite: **3 declarations / 1 suite PASS**, without compiler or unrelated tests running.
- Normal Mac Debug signing-disabled Xcode build: PASS.
- Mac App Store Release signing-disabled Xcode build: PASS.
- English/Japanese/Simplified Chinese strings parse successfully; localization parity is included in the ordinary gate.
- The other timing-sensitive and large-library suites excluded by that CI step were not rerun for this scoped feature. No claim of full CI or release eligibility.

[Raw logs and final source hashes](../measurements/legacy-recovery-copy-2026-11-06/). Intermediate 151/204-test and 10-test successes preceded later source changes; final qualification is the final ordinary-gate log. The 209-test intermediate run failed with 35 issues because the pending sentinel preceded generation initialization; retain it as a failure record, not a success.

Tests use small synthetic byte fixtures with audio filename extensions, not decoded real music. They assert original catalog/audio/journal/tag/artwork bytes, normalized complete track and playlist metadata, queue/history, copied SHA-256, missing health and paths, library identity and switch ownership. Source snapshots exclude only independently derived SQLite indices that LibraryStore may rebuild in the background.

Coverage includes all five broken-record names, moved audio, explicit Previous selection, missing/unknown fingerprints, unavailable and unreadable audio, explicit opt-in on retry, wrong source bytes, destination collision, checksum/future-schema rejection, pre-cancelled Task creation, copy ENOSPC and injected interruption/ENOSPC at installed-audio/catalog/final-marker boundaries, disconnected originals, controlled copy-directory movement, completed-library move/rename and a competing profile switch.

Initial iterations exposed a Swift actor-transfer error in a test helper, a missing-catalog read before checking the pending digest, a String/UUID mismatch in the activation guard, and the compatibility sentinel being rejected by generation initialization. These were fixed; failure and final logs are retained. A local permission probe confirmed that a read-only handle can synchronize a readable 0400 file while a write handle is denied. The first ordinary-gate run also exposed a 5-second UI-test safety release expiring while unrelated audio audits occupied MainActor; a one-second process sample showed `AudioEffectSignalTests.frequencyAndLevelMatrix` executing there. The existing node-retirement suite was therefore placed in its own CI step and rerun independently. No production playback code, budgets or assertions were changed for that isolation.

## Remaining work

⭕️ [Pending] Signed sandbox panels/bookmarks and real screen layout in English/Japanese/Simplified Chinese; actual CD/Music/NAS/SMB media, permission and mount changes; large catalogs, cancellation during a long individual file copy and UI responsiveness at scale; full disk, physical unplug, process kill/power loss and directory-entry durability; old/new installed clients; decoding/playback/listening on both physical devices. Controlled filesystem fault injection does not replace these checks.

🟠 [Next] Other write paths' capacity/retry coverage, whole-ROADMAP semantic evidence review, audio-rack startup and remaining presentation/performance gates. A selected snapshot that is itself unreadable and has no readable backup remains unrecoverable by this path; original evidence is preserved for manual diagnosis. This scoped rescue does not complete all ROADMAP work.
