# ROADMAP検証の再実行と機能表修正 — 2026-11-06

## 現行コードでの検証

Macの`.github/workflows/m0-quality-gate.yml`に定義されたSwiftの分離条件に従い、ローカルで順次実行した。GitHub Actionsの実行結果ではなく、Archive・署名・UI資格試験・Sanitizerなど他のCI工程は含まない。

|分離範囲|件数|結果|
|---|---:|---|
|通常unit（5 suiteをskip）|444 / 52 suites|成功|
|StorageDelayedFailureTests|38|成功|
|LibraryPresentationTests|15|成功|
|LargeLibraryPerformanceTests|9|成功|
|AudioThreadGainIntegrationTests|4|成功|
|PlaybackTransportIntegrationTests|15|成功|
|合計|525 / 57 suites|成功|

通常unitは `swift test --skip-build --skip 'PlaybackTransportIntegrationTests|AudioThreadGainIntegrationTests|StorageDelayedFailureTests|LibraryPresentationTests|LargeLibraryPerformanceTests'`。後続5工程は `swift test --skip-build --filter <suite名>`。測定用のopt-in試験は環境変数がないと測定せずreturnするものを含むため、この件数だけで全性能ゲート合格とは扱わない。

最初の無分離`swift test`は525件中4 issuesで失敗。音量保護suiteの3 issuesと保存切替suiteの1 issue。CI定義には重いDSPとMainActor依存試験を分離する理由が明記されており、既存の分離条件で再実行した上表は全成功。無分離実行の失敗もログを保持し、試験閾値やアプリ実装は変更していない。無分離実行を合格にしたわけではない。

## 10万曲の独立したCI予算

`env ONGAKU_ENFORCE_M3_PERFORMANCE=1 swift test --skip-build --filter m3PerformanceGate` が1件成功。ロードと先頭ページ準備1.104542333秒、4クエリの索引検索p95 0.001340875秒。Debugの単発測定で、SwiftUIの描画・入力応答・RSSは測定していない。CI予算4秒／300msへの合格であり、Release実画面2秒／300ms／512MiBの製品目標を完了にしない。

## モバイル側

`run_playback_transport_regression.sh`、`run_music_asset_preparation_regression.sh`（通常権限）、`run_transport_continuity_regression.sh`が成功。連続性の試験は抽出した製品制御・仮想スケジュールと44.1/48/96kHzの6 PCMフェードケース、急な開始停止と早期解放の負例を含む。実機のOSセッションや非DRM/DRM実資産の再現ではない。

## 更新と残作業

- 🟢 [Done] [保存・復旧9節の実装／試験対応](ROADMAP_STORAGE_EVIDENCE_2026-11-06.md)と[機能表の矛盾修正](ROADMAP_FEATURE_RECONCILIATION_2026-11-06.md)を記録。
- 🟠 [Next] その他のDone項目の一件ごとの意味的照合、変更済みソースに対する過去の性能測定の再確認、製品の実画面性能目標。
- 🟠 [Next] 破損ジャーナルの自動救済。世代記録の同時消失は[後続実装](GENERATION_WITNESS_2026-11-06.md)で対応。
- ⭕️ [Pending] 署名済みMac/iPhone、Musicサービス／実資産、実機の切断・容量不足・電源断・長時間耐久・聴感と地域差。

[実行ログと全対象ソースハッシュ](../measurements/roadmap-audit-2026-11-06/)を保存。これは全ROADMAPの意味的監査完了の宣言ではない。
