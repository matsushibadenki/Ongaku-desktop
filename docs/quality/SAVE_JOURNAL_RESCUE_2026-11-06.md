# Damaged save-journal rescue — 2026-11-06

## Completed scope

Mac Settings > Storage now includes the recovery icon (`arrow.uturn.backward.circle`, help/accessibility label: Restore Last Catalog). The confirmation explains that unsaved changes can be lost, metadata is backed up, and audio is retained. It never runs automatically. The user chooses to return to the last readable current-format primary catalog, including the queue and history embedded in it. This does not reconstruct missing or uncommitted metadata.

Two previously unfinished cases are implemented:

1. Malformed catalog-write journal, or a version-1 target whose checksum is damaged: retain its raw bytes and restore the readable primary instead of trusting its target.
2. Malformed import journal: retain its raw bytes, all staging copies and all installed audio, and restore the registered primary. Unregistered copies remain available for manual reimport/recovery; they are not silently registered or deleted.

A healthy transaction is refused, including a valid import journal. Explicitly newer journal/catalog schemas, absent/unreadable primary catalogs, and other pending recovery journals are refused. Mixed or ambiguous operations remain blocked, with Export Recovery Information available.

## Transaction and concurrency

- Acquire catalog then import process locks. Validate the journal and primary under those locks.
- Copy primary/backup, queue/history plus their backups, generation information, tags and the damaged record into a unique `Recovery Backups/Catalog-UUID.partial` folder; synchronize each copied file. Only a complete copy is renamed without `.partial`. A failed copy leaves the originals intact and retains an identifiable partial backup.
- Reserve a fresh persistent generation before publishing a replacement catalog-write recovery journal. A process stopped before publication can retry the explicit operation. After publication, normal load replays the normal transaction to restore the primary's sidecars coherently.
- Import rescue records the backed-up record's SHA-256 in `discardedImportJournalDigest`. Recovery may remove only that exact import record, or continue if already removed. A different record blocks recovery. Audio and Incoming files are never removed by this rescue.
- Store rescue uses an independent repository and invalidates its storage generation, cancels the pending queue save and reloads all library state/caches. The old repository keeps its old persistent-generation baseline, so pre-rescue queued editors cannot inherit authorization to write into the rescued state. The visible queue is restored from the rescued document.

The optional import-digest field does not change the device-sync protocol or the catalog schema. Older apps which do not handle it cannot complete the broken import recovery; use the updated Mac app for rescue. The iPhone app does not own this Mac catalog/journal format; its runtime is unchanged, and its roadmap records the Mac scope and shared data-preservation policy.

## Verification

`swift test --jobs 2 --filter 'CatalogRescueTests|LibraryRepositoryTests|OverlayJournalTests|ApplicationSettingsTests|M0QualityGateTests'` — **179 tests / 6 suites PASS**. Parameterized cases are included in the test declarations, not added to this total.

New tests cover byte-preserving backups; primary metadata/queue/history; generation rejection of old writers; backup/generation/journal interruption boundaries with ENOSPC or cancellation; a real failed backup copy; actual failed sidecar publication and retry; replaced import records; staged/installed audio preservation; rejection of healthy/future/mixed recovery; checksum corruption; Store/cache reload with queued edits, and rejection of invalid rescue flags/future target schemas before any import removal.

Initial catalog Store regression exposed reuse of the old repository baseline and failed (2 issues); fixed by using an independent repository. Initial extended import test fixture omitted its audio folder and failed (6 cases); fixture corrected. An added malformed-record test initially used nested Testing macros and failed to compile; split the requirements and reran successfully. Original and final logs are retained rather than treating these failures as passes. Fault injection models interrupted boundaries; it does not prove physical power-loss durability.

- Normal Mac Debug signing-disabled Xcode build: PASS (final code).
- Mac App Store Release signing-disabled Xcode build: PASS.
- Three localization files pass plutil; localization/accessibility/privacy gate is included above. Whitespace diff checks pass.

Logs and final-source hashes: [measurement directory](../measurements/save-journal-rescue-2026-11-06/).

## Remaining work and Pending

🟠 [Next] Storage-restore, sync-overlay and media-organization damaged-journal rescue; other write paths' capacity exhaustion and retry; full roadmap semantic audit; audio/transfer/performance gates remain unfinished. The implementation above is an explicit fallback, not automatic reconstruction of broken records.

⭕️ [Pending] Signed sandbox installation, confirmation and accessibility on a real Mac, external/SMB/NAS permissions, real ENOSPC/unplug/power loss during recovery, and mixed old/new app processes. No real user library was modified or restored by these tests. iPhone/Mac pairing and audio listening checks remain separately Pending. ROADMAP as a whole is not complete.

## Follow-up

[New storage-restore recovery copies](STORAGE_RESTORE_RECOVERY_COPY_2026-11-06.md) now protect newly created restores. Old damaged records without a valid copy, sync-overlay/media-organization rescue and other ROADMAP work remain unfinished. The 179-test record above is historical and not overwritten by the later 187-test run.
