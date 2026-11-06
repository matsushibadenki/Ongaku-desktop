# Storage-restore recovery copy — 2026-11-06

## Implemented scope

New Mac preserved-library restores write a synchronized `storage-restore-journal-v1.recovery.json` before the primary restore journal and before moving any active catalog data. The version-1 wrapper contains the exact journal payload, its SHA-256 and the persistent generation token (counter and optional epoch). The original primary journal format is unchanged. There is no change to iPhone runtime or device-sync messages.

During load, a differing/damaged primary may be replaced only by a readable, checksum-valid, supported recovery payload bound to the current generation. The journal's entry whitelist, unique names and required prepared primary manifest are validated before any replacement or rollback. A syntactically valid but changed transaction ID is detected as well as invalid JSON. An explicit future primary version is refused, not downgraded.

Before repairing the primary, both its exact damaged bytes and the good recovery wrapper are copied and synchronized into `Recovery Backups/Storage-Journal-UUID`. A failure to preserve either prevents replacement. The existing rollback then restores the previous catalog and sidecars using copies of retained backup files; interrupted new files remain in its Interrupted directories. Another interruption can resume the normal rollback.

On success the secondary record is removed before removing the primary. A recovery copy alone is deliberately inert: it cannot prove that a transaction was active, and must never undo a completed restore. A healthy legacy primary without a recovery copy still uses the existing rollback. If both records are unusable, the generation differs, the primary is missing, or the older damaged primary has no valid copy, the implementation does not invent a restore plan. Keep the data and export recovery information.

## Verification

`swift test --jobs 2 --filter 'StorageRestoreRecordTests|CatalogRescueTests|LibraryRepositoryTests|OverlayJournalTests|ApplicationSettingsTests|M0QualityGateTests'`: **187 tests / 7 suites PASS**.

New cases cover four catalog/sidecar move boundaries × malformed/decodable-altered records; ENOSPC after secondary/primary publication; an orphan secondary after a completed restore; a different generation; a damaged checksum; a future primary version; actual failure to copy either the damaged bytes or the good wrapper for backup; a second interruption during rollback; an empty invalid legacy plan; and valid legacy rollback. They assert the original library ID, catalog/queue bytes and preserved source catalog, retry twice, and check byte-exact preservation of both backup records. These are local filesystem fault-injection tests, not real power-loss tests.

The initial compile found a throwing expression inside a short-circuit guard; the generation check was separated into the repair branch. Initial and final logs are retained. No test expectations or timeout budgets were relaxed.

- Normal Mac Debug signing-disabled Xcode build: PASS.
- Mac App Store Release signing-disabled Xcode build: PASS.
- No user library was repaired or switched during these tests.

[Logs and final-source SHA-256](../measurements/storage-restore-recovery-copy-2026-11-06/).

## Remaining work

🟠 [Next] Safe manual rescue of old damaged storage-restore records without a usable copy, damaged sync-overlay/media-organization records, remaining write-path capacity/retry checks, and other ROADMAP groups. This change protects newly created restores; it is not recovery of all historical damaged journals. Whole-roadmap semantic review is still unfinished.

⭕️ [Pending] Signed sandbox installation; actual external/SMB/NAS mount and permission changes; real full disk, unplug, process kill/power loss and directory-entry durability; old/new installed app coexistence. Physical iPhone/Mac audio and networking checks remain separately Pending.

Final capacity follow-up: both damaged-record-copy and good-wrapper-copy ENOSPC cases pass, with retry to the original catalog. The final 187-declaration / 7-suite run is `capacity-final.log`; parameterized cases are not added as separate declarations. Product source did not change in this follow-up.

Follow-up: [Legacy recovery copies](LEGACY_RECOVERY_COPY_2026-11-06.md) now implements explicit independent rescue from a readable selected catalog/backup for the old damaged-record group above. It does not replay an unreadable journal. Remaining capacity paths and physical checks stay open.
