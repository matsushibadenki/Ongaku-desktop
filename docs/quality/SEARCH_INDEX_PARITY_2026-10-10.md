# A3: 索引検証の一括処理と検索負荷計測（2026-10-10）

## 変更

検索索引の初回移行と差分更新後のparity確認で、クエリごとに全曲の検索用テキストを再生成・正規化していた。複数の短い検索で英語・日本語・简体中文の一致を確認するため、10万曲では同じメタデータ処理を繰り返していた。

`SQLiteCatalogPrototype.verifySearchParity`は全曲を一度だけ走査し、1曲につき一度生成した検索用テキストを各クエリへ照合する。クエリも一度だけ正規化する。検索用テキストの全件コピーを保持せず、一致したIDだけを保存し、SQLiteとの比較が終わったクエリから解放する。各曲と各クエリの境界でキャンセルを確認する。

`verifyParity`も同じ実装を使用する。検索SQL、正規化規則、比較する曲IDの集合、不一致クエリの順序と重複は維持する。SQLiteスキーマと保存形式の変更はない。

## 回帰試験

- 英語のアクセント・全角文字、短い日本語・简体中文、歌詞、該当なし、重複クエリの一致を確認。
- 未同期の名称変更について、旧名称と新名称の不一致を順序・重複ごと報告し、差分更新後に一致へ戻ることを確認。
- 空の検証リスト、キャンセル、キャンセル後の再検証を確認。
- 既存の検索中断、移行・rollback、差分更新、production `LibraryStore`の検索routingも検証。

## 10万曲の負荷計測

`LargeLibraryPerformanceTests.searchWorkloadBenchmark`は明示的な環境変数でのみ実行する。専用一時フォルダに10万曲と180秒の44.1kHz・stereo PCMを作り、実際の`LibraryStore`・`LibraryRepository`・SQLite索引・`PlaybackController`を使う。

13クエリで、以前のクエリごとのテキスト生成と一括parityの時間を同じデータ・SQLite検索結果との比較を含めて1回ずつ測定する。これはp95ではない。

検索は「再生中」「索引更新中」「両者同時」を各10回測り、入力設定から最新の対象曲だけがproduction表示snapshotに公開されるまでのp95を記録する。索引更新は実際のメタデータ保存経路を使用し、`.synchronizing`を確認してから入力する。更新後にSQLiteへ戻っても対象曲が一致することを確認する。音声は実エンジンで再生し、音量0、再生状態と経過時間の進行を確認する。180秒以内に状態へ到達しなければ失敗とする。

SwiftUI描画、UI入力の遅延、音声のドロップアウト、アプリのピークRSSを測る試験ではない。テストプロセスの音声出力環境が必要であり、CIでは既定で実行しない。ユーザー設定のDSP・出力条件を使用するため、計測には出力レートも記録する。

```sh
swift test --filter 'SQLiteCatalogPrototypeTests|LibrarySearchRoutingTests|searchWorkloadBenchmark'
ONGAKU_RUN_SEARCH_WORKLOAD_BENCHMARK=1 swift test -c release --filter searchWorkloadBenchmark
```

## 検証結果

- 🟢 [Done] Debugの関連試験: 3 suite・11テスト成功（検索回帰10件と、既定で負荷実行しないbenchmark entry 1件）。
- Releaseの10万曲負荷計測を実行中。

## 残り

- 🟠 [Next] 負荷計測で遅い経路を特定し、索引更新中の検索応答性を改善する。
- ⭕️ [Pending] 署名・UIオートメーション環境で、3条件をSwiftUIのRelease実画面ゲートへ統合し、入力→結果p95 300ms・ピーク512MiBを判定する。
