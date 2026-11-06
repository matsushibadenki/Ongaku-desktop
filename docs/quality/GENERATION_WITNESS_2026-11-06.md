# 世代補助ファイルの同時消失からの復旧 — 2026-11-06

## 完了したNext

世代番号と作成済み記録の両方が消失した場合の復旧を実装した。実装課題1件の完了であり、既存の破損ジャーナル救済やその他の容量不足を完了扱いにしない。ROADMAPのNext箇条書きは46→45。同時消失の節に重複していた残課題は、冒頭の現在の優先項目へ参照を集約した。

## 実装

- `LibraryModels.swift`: `LibraryDocument.catalogGenerationEstablished`を任意フィールドとして追加。既存のschema 12と旧形式は未設定のまま読み取れ、既存の曲・ライブラリIDは変えない。
- `LibraryRepository.swift`: 通常保存時に印を台帳と同じ原子的な書込みに含める。旧台帳の読込み時は既存の台帳WALを経由して一度だけ印を保存する。移行済みの再読込みでは台帳や世代を更新しない。
- 両補助ファイルがない場合、正本・バックアップのヘッダー、または未完了台帳WALから世代管理済みと識別する。新しいUUID世代を発行し、修復前のrepositoryの保存を拒否する。未知の将来スキーマは書換えず拒否する。
- iPhoneの同期プロトコルと動作変更はない。Mobile側ROADMAPにMacの改善として同じ結果を記載する。

## 検証

`GenerationWitnessTests`を追加した。

|試験|確認したこと|
|---|---|
|simultaneousLoss(false/true)|両補助ファイル消失、正本またはバックアップからの復旧、IDとプレイリスト参照保持、旧保存拒否、再読込み時の無変更|
|legacyMigration|印のない旧schema 12を一度だけ移行し、二回目には台帳・世代を書き直さない|
|interruptedMigration(false/true)|移行WAL保存後またはキュー更新後にENOSPCを注入し、両補助ファイル消失も組み合わせて旧データを保持して復旧|

既存の`persistentGenerationMigrationAndInterruption`は、現代の台帳から補助ファイルだけ消すfixtureから、印も存在しない本当の旧形式fixtureへ修正した。移行による世代予約を含めて古い保存の拒否を検証する。

- 関連範囲: `swift test --filter 'GenerationWitnessTests|LibraryRepositoryTests|StorageDelayedFailureTests|OverlayJournalTests|ApplicationSettingsTests|M3LibraryManagementMilestoneTests|MetadataEditingTests'` — 180 tests / 7 suites成功。
- 通常unit: `swift test --skip-build --skip 'PlaybackTransportIntegrationTests|AudioThreadGainIntegrationTests|StorageDelayedFailureTests|LibraryPresentationTests|LargeLibraryPerformanceTests'` — 447 tests / 53 suites成功。
- 2つの結果は重複を含む。以前の525件の全分離試験記録は、その記録のソース状態に対するもので、今回のソースで全工程を再実行したという意味ではない。

[ログとソースSHA-256](../measurements/generation-witness-2026-11-06/)を保存。

## 保証範囲

⭕️ [Pending] 配布署名Sandbox、旧アプリとの併用、外付け／SMB／NAS、実際の電源断と媒体切断。

台帳・バックアップ・補助ファイル・WALのすべてから世代管理の証拠が消された場合は、旧形式との識別を保証しない。失われた音声や台帳自体の復元機能を追加したものではない。台帳の移行は初回に一度、既存WALによる書込みと容量を必要とする。
