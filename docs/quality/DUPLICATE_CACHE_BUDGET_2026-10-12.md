# 重複判定キャッシュの保持上限（2026-10-12）

## 実装

A3のメモリ目標に向け、LibraryPresentationWorkerが保持する重複判定用の正規化キーにUTF-8総量16MiBの上限を設定した。上限内で不変のキーを再利用し、上限に収まらない曲のキーは保持しない。判定時にはDuplicateTrackAnalyzerが不足したキーを計算するため、曲を判定対象から除外しない。空のカタログではキャッシュを解放する。

予算を0にすれば保持なしで動作する。新しいキャッシュのバイト数は完全な判定後に確定する。個別キー生成の一時文字列、Dictionary／Stringの管理領域、グループ構築、Track、他のキャッシュはこの予算に含めない。上限超過時には正規化の再計算が増えるため、保持メモリとCPU処理のトレードオフがある。

## 検証

`swift test --filter 'LibraryPresentationTests|StandardLibraryResolverTests|LibrarySearchRoutingTests'`: 36テスト／3 suite成功。ログ: /tmp/ongaku-bounded-duplicate-tests.log。

0バイト・32バイト・既定予算で、アクセント／全角の可能性重複、ハッシュによる完全重複、長い英日中メタデータ、並べ替えと編集、空のカタログについて、全グループID・種別・Track・推奨曲が直接計算と一致することを確認した。

実機で観測した保存先説明の誤りも補修した。profile再接続先が実際のApplication Support配下の場合だけその分類とし、外部などの保存先をuserSelectedとして表示する。場所自体は変更しない。

`swift test --filter ApplicationSettingsTests`: 23テスト成功。ログ: /tmp/ongaku-storage-source-final-tests.log。

ローカル署名付きApp Store Debugビルド成功。ログ: /tmp/ongaku-cache-budget-final-build.log。同日の追加検証で `/Applications/OngakuDesktop.app` に反映した。以前の版は `/Applications/OngakuDesktop-pre-performance-20261012.app` に保存した。10万曲の実画面検証は `RELEASE_UI_100K_2026-10-12.md` に記録する。

🟢 [Done] 重複判定キーの保持上限と上限超過時の結果一致、保存先分類の修正。

🟠 [Next] 10万曲・再生／索引更新中のRelease計測で、残るメモリと時間の大きい処理を切り分ける。

⭕️ [Pending] 実画面の検索p95 300ms・初回2秒・ピークRSS 512MiB。16MiBの保持上限だけで全体メモリ目標を合格と判定しない。保存先説明の変更後の実画面も未確認。
