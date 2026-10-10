# A3: SQLite検索のキャンセル伝播（2026-10-10）

## 問題と変更

`LibraryStore`は入力変更時に検索Taskをキャンセルしていたが、`SQLiteCatalogPrototype.search`はその状態を確認していなかった。同じactor上の古い検索が完了するまで次の検索が待たされ、結果の世代照合だけでは連続入力時の不要な処理を止められなかった。

検索開始前と各結果行の取得前後にキャンセルを確認する。最初の結果行が返るまでに行われる全件走査・並べ替えも止めるため、検索専用のSQLite接続に1,000 VM命令ごとのprogress handlerを設定する。同期callbackは実行中のSwift Taskのキャンセル状態を参照する。処理を抜ける際は必ずhandlerを解除し、キャンセルは`CancellationError`として返す。既存の`LibraryStore`のキャンセル判定によりJSON fallbackへの誤切替を防ぐ。

SQL、検索結果の並び、件数上限、短い英日中検索、ライブラリ正本・スキーマは変更しない。

## 回帰試験

- 実SQLiteの再帰SQLで、handler設置後にTaskをキャンセルし、最初の結果前に`SQLITE_INTERRUPT`となることを確認する。タイマーには依存しない。
- キャンセル済みTask内でも、handler解除後は同じ接続でSQLを完了できることを確認する。
- キャンセル済み検索が`CancellationError`を返し、続く英語・日本語・简体中文の検索がJSON検索と一致することを確認する。
- 既存のSQLite移行・差分更新・parity・検索routing試験も実行する。

## 検証結果

- 🟢 [Done] `swift test --filter 'SQLiteCatalogPrototypeTests|LibrarySearchRoutingTests'`: 2 suite・9テスト成功（新規2テストを含む）。
- 🟢 [Done] App Store版の署名なしReleaseビルド成功。
- 🟢 [Done] `git diff --check`成功。
- 全テスト・Mobileビルド・UI性能計測は今回の検証範囲外。

検証コマンド:

```sh
swift test --filter 'SQLiteCatalogPrototypeTests|LibrarySearchRoutingTests'
xcodebuild build -project OngakuDesktop.xcodeproj \
  -scheme OngakuDesktopAppStore -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath /tmp/Ongaku-SearchCancellation-AppStore CODE_SIGNING_ALLOWED=NO
```

## 残りのゲート

- 🟠 [Next] 再生中・索引差分更新中・両者同時の検索性能を計測する。
- ⭕️ [Pending] 署名・UIオートメーションを利用できる環境で、Release実画面の初回表示2秒、入力→結果p95 300ms、ピーク512MiBを検証する。この変更だけで製品目標の合格とは判定しない。
