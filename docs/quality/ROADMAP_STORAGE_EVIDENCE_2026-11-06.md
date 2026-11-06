# 保存・復旧とモバイル再生準備の根拠確認 — 2026-11-06

今回の確認は下記9節の現在の実装と対応試験に限定する。過去の試験件数・配布結果を再現したものではなく、全ROADMAPの照合完了ではない。iPhone版のMac進捗記録も同じMacコードの確認結果を参照する。

## 実装と試験の対応

### 同期タグ保存の容量不足

実装: `Sources/OngakuDesktop/LibraryRepository.swift#saveSynchronizedOverlay`。

試験: `fullDiskDuringOverlay`。

### 世代ファイル消失時の復旧

実装: `Sources/OngakuDesktop/LibraryRepository.swift#persistentGeneration`, `Sources/OngakuDesktop/LibraryRepository.swift#recoverDamagedGeneration`, `Sources/OngakuDesktop/LibraryRepository.swift#ensureGenerationMarker`。

試験: `missingEstablishedGenerationRecovery`。

### 世代情報の破損復旧と保存先復元の容量不足

実装: `Sources/OngakuDesktop/LibraryRepository.swift#recoverDamagedGeneration`, `Sources/OngakuDesktop/LibraryRepository.swift#writeGeneration`, `Sources/OngakuDesktop/LibraryRepository.swift#rollbackStorageRestore`。

試験: `generationRecoveryInterruption`, `generationBackupOutOfSpace`, `futureGenerationRemainsUntouched`, `interruptedStorageRestore`。

### 復旧情報の退避とインポート容量不足

実装: `Sources/OngakuDesktop/LibraryRepository.swift#exportRecoverySnapshot`, `Sources/OngakuDesktop/LibraryRepository.swift#recoverImports`。

試験: `damagedRecoverySnapshot`, `recoverySnapshotOutOfSpace`, `importWriteRecoveryBoundaries`。

### 自己完結化の中断・救済と保存容量不足

実装: `Sources/OngakuDesktop/LibraryRepository.swift#makeLibrarySelfContained`, `Sources/OngakuDesktop/LibraryRepository.swift#recoverSelfContainmentStaging`, `Sources/OngakuDesktop/LibraryRepository.swift#preserveUnusableSelfContainmentJournal`。

試験: `selfContainedCopyOutOfSpace`, `interruptedSelfContainmentStaging`, `unsafeSelfContainmentRecovery`, `selfContainmentRecoversWithCatalogJournal`。

### 保存ロックの待機上限と容量不足の検証

実装: `Sources/OngakuDesktop/LibraryRepository.swift#acquireExclusiveLock`。

試験: `storageLockTimeoutAndRetry`, `storageLockCancellation`。

### 台帳復旧ジャーナルの内容検証

実装: `Sources/OngakuDesktop/LibraryRepository.swift#recoverCatalogWriteJournal`。

試験: `changedJournalPayloadIsRejected`。

### 復旧ジャーナル破損時の保護

実装: `Sources/OngakuDesktop/LibraryRepository.swift#recoverCatalogWriteJournal`, `Sources/OngakuDesktop/LibraryRepository.swift#recoverStorageRestoreJournal`。

試験: `damagedRecoveryJournalIsRetained`。

### 保存先復元の中断・再復旧

実装: `Sources/OngakuDesktop/LibraryRepository.swift#rollbackStorageRestore`, `Sources/OngakuDesktop/LibraryRepository.swift#recoverStorageRestoreJournal`。

試験: `interruptedStorageRestore`, `interruptedStorageRollbackRetries`。

## 今回の実行結果

- 🟢 [Done] Mac: `swift test --filter 'LibraryRepositoryTests|StorageDelayedFailureTests|OverlayJournalTests|ApplicationSettingsTests|M3LibraryManagementMilestoneTests|MetadataEditingTests'` は177 tests / 6 suites成功。
- 🟢 [Done] Mobile: `bash tests/run_playback_transport_regression.sh` 成功。再生制御ポリシーの確認であり、AVAudioSession実機の再現ではない。
- 🟢 [Done] Mobile: `bash tests/run_music_asset_preparation_regression.sh` は通常権限で成功。44.1kHz/16-bit、1/2chのWAV・AIFF・ALACの準備復旧、PCM保持、取消・上限・タイムアウトを確認。
- 制限付き実行ではAVFoundation -11800で終了した。同じコマンドが通常権限で成功したことは記録するが、OS内部の失敗理由は断定しない。
- ⭕️ [Pending] 実機Music資産、署名Sandbox、別Mac／旧バージョン、物理切断・実容量不足・電源断と聴感確認。

[実行ログ・ソースハッシュ・関数位置](../measurements/roadmap-audit-2026-11-06/)を保存した。177件は全製品テストの件数ではない。

## 未解決と優先順位

1. 🟠 [Next] P0: 世代ファイルと作成済み記録の同時消失。旧形式と識別できず、単独消失の対応で解決済みとはしない。
2. 🟠 [Next] P0: 破損した台帳・保存先復元・インポートのジャーナルは退避・安全停止まで。退避からの自動修復は未実装。
3. 🟠 [Next] P0: その他のDone項目をコードと具体的試験へ対応付ける。未確認を実装不在と同一視しない。
4. 🟠 [Next] P1: 未達の音声ラック初期化、UI／転送実経路性能を確認する。

実機試験を伴わない今回の結果から、データ損失が起きないことや電源断耐久性は保証しない。
