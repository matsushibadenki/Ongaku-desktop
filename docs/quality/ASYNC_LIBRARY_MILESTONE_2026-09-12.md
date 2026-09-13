# 非同期ライブラリ表示の節目 — 2026-09-12

## 完了範囲

[Done] 主要な表示用集計を `LibraryPresentationWorker` actorへ分離した。MainActorは不変のリクエストを渡し、現在の世代と一致する結果だけを公開する。同じターンの複数変更はまとめる。処理中は別の条件の曲を操作させず、表示準備中と0件を区別する。

[Done] 対象は標準ビュー、スマートプレイリスト、詳細フィルタ、検索IDとの照合、アルバム／アーティスト分類・並び順・再生時間・アルバム数、重複グループ、再生統計、Ongaku Mix候補。全曲の辞書・サイズ・要確認数・重複は楽曲revisionで、再生統計は楽曲と履歴のrevisionで再利用する。曲表のソートは公開された表示revisionを監視する。

[Done] 設定ウィンドウの `ArtworkPrivacySettings` 引き渡し漏れと、Control Center経由の画像要求が既定で外部通信を許す経路を修正した。画像の設定切替時に表示を再評価し、無効時は期限切れの保存画像を利用できる。

## GitHub Actionsの失敗

対象: [run 34678611788 / quality](https://github.com/matsushibadenki/Ongaku-desktop/actions/runs/34678611788/job/103512872428)

`swift test` の8件のアサーション失敗だった。内訳はスマートプレイリスト3件、SQLite検索2件、検索解除1件、JSON fallback検索2件。表示の非同期化後も、旧試験が変更直後または索引完了直後の `filteredTracks` を検査していたため、準備中の空配列を読んでいた。

楽曲の編集開始時は古い索引結果を無効化し、保存失敗によるrollback後も追加の入力なしでJSON検索結果を復元する。検索の世代は表示用の全般revisionとは独立した楽曲revisionで照合する。

索引と表示の両方が完了した状態を待って、結果の曲ID・件数を従来どおり検証する。テストを削除せず、時間制限や期待値を緩和していない。新規試験は分類・集計値、同じ曲数の編集、履歴消去、キャンセル後の再要求、検索・フィルタ・セクション連続変更、選択維持、ライブラリ切替を確認する。

## 検証結果

| 検証 | 結果 |
|---|---|
| `swift test` | 最終追試291 tests / 33 suites成功、60.332秒。保存失敗後の検索復旧試験を含む |
| `ONGAKU_ENFORCE_M3_PERFORMANCE=1 swift test --filter m3PerformanceGate` | 成功。10万曲の既存CIゲート。所要7.718秒は準備・索引構築込みのテスト全体時間 |
| 通常macOS Debug `build-for-testing` | 成功。UIテストターゲットのコンパイルを含む |
| Mac App Store Universal Release build | 成功。Sparkle framework・動的リンク・更新設定なし、clientのみのnetwork entitlementを確認 |
| iOS companion Simulator Debug build | 成功。CIと同じtarget・SDK指定 |
| Releaseの検索・プレイリスト・非同期表示・集計benchmark | 11 tests / 4 suites成功、9.420秒 |
| 日本語・ライトモード・開発版の実画面 | 4曲のライブラリでアルバム3件、アーティスト3件、詳細の曲数と時間、検索1曲への絞り込み、検索解除、元の曲選択の維持を確認。設定画面もクラッシュせず開き、説明文が表示範囲に収まる |

最終の全体試験で測ったM3の内訳は、再読込と先頭ページ準備1.303秒、SQLite検索p95 1.168ms。これらは製品の実画面ゲートとは別の数値である。GitHub側の新しいrunはまだ実行しておらず、成功はローカルの検証結果を示す。

### Releaseの集計計測

実行コマンド:

```sh
ONGAKU_RUN_PRESENTATION_BENCHMARK=1 swift test -c release \
  --filter 'presentationBenchmark|LibraryPresentationTests|LibrarySearchRoutingTests|SmartPlaylistTests'
```

10万曲・1万アルバム・5千アーティストの固定fixture。初回の1回を除き、各条件10回のp95。ライブラリ読み込み・SQLite検索・SwiftUI描画・メモリの数値ではなく、専用actorの計算時間を測ったもの。

| 計算 | 時間 |
|---|---:|
| 初回の全曲辞書・統計・重複等の準備 | 1.533秒（1回） |
| アルバム分類・詳細用集計・見出し作成 | p95 235.3ms |
| アーティスト分類・アルバムと曲の詳細用集計 | p95 377.8ms |
| 検索済みIDからの表示用絞り込み | p95 119.1ms |

同じ開発端末上の測定であり、低性能端末や実画面の配布判定は別途必要。未完了のUI性能ゲートは下記に残す。

## 未完了の配布ゲート

[Next] SwiftUIの実描画を含むRelease初回表示2秒、入力から結果表示p95 300ms、アプリのピーク512MiB。既存M3試験はrepositoryの再読込と先頭100件準備、SQLite検索を別々に測るもので、実描画の検証ではない。

[Next] 再生中・索引更新中の実画面計測、三言語・VoiceOver・ライト／ダークの操作確認、音声経路・実端末同期・署名構成のA6ゲート。

[Later] A6通過後の配布。今回の変更はApp Storeへアップロードしていない。
