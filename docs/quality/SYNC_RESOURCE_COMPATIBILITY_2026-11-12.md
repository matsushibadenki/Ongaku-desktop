# 同期転送の互換性修正 — 2026-11-12

> 保存完了判定・受信の直列化・再接続は後続の[追補](SYNC_COMMIT_RECONNECT_2026-11-12.md)で修正・検証。以下は初回互換修正時点の記録。

## 原因

ユーザーはMacからiPhoneへ曲を送信後、進捗が動かないと報告。コード調査で、Mac PhoneSyncController.sendLocalItemは無条件にチャンク転送workerを起動する一方、製品iPhone audio/DesktopSyncControllerとDeviceSyncMessageはchunkOfferを実装していないことを確認。接続・manifest交換が成功しても転送プロトコルが一致せず、チャンク要求待ちになる。デスクトップリポジトリ内のSources/OngakuMobileはチャンク対応だが、製品iPhoneの実装とは異なる。

## 対応

任意BoolのsupportsChunkTransferをmanifestに追加。未指定をfalseとして旧アプリを扱い、Macは明示的trueだけにチャンク送信。製品iPhoneはfalse、Macとデスクトップ側MobileSyncControllerはtrueを広告。旧デコーダーは未知のmanifestフィールドを無視可能。

Macのresource送信は既存のresource announcement、sendResource、KVO進捗、一括転送completionへ接続。接続世代が変わった後の完了通知を無視し、メインキュー上で登録と後処理を順序付ける。旧iPhoneへの未知のtransferControl送信を抑制。

iPhoneで送受信Progressを監視し、転送中の割合を表示。完了・検証段階・失敗で監視解除、切断中の転送を失敗表示。開閉等UIの先行変更は保持。

## 検証

- Mac `swift test --filter DeviceSyncTests`: ビルド成功、16テスト／1 suite成功。
- 新規回帰: 旧manifestの対応フラグ欠落、true/false往復、旧iPhoneが受け取るresourceメッセージのkind・ID・方向・曲情報を確認。
- iPhone `xcodebuild -project Ongaku.xcodeproj -scheme audio -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/ongaku-disclosure-build CODE_SIGNING_ALLOWED=NO build`: 成功。
- 両リポジトリ `git diff --check`: 成功。
- ログ: `../measurements/sync-resource-compatibility-2026-11-12/`。

## 制限／Pending

実機のMCSession通信は未検証。単曲と一括、逆方向、接続世代を跨ぐ切断復旧、容量不足、長時間・大容量の転送と表示を確認する。互換resource転送はチャンクの永続チェックポイント再開を提供しない。Mac一括バーは曲数単位の完了率であり、最初の曲が完了するまで0のまま。曲ごとの転送率は別の進捗表示で確認する。OS側送信完了とiPhoneでのライブラリ登録完了は同義ではない。

配布・インストール版更新は未実施。今回の送信停止対策には修正後のMac版が必要。
