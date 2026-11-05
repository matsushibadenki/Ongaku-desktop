# 同期オーバーレイと保存先の所有権 — 2026-11-03

- 🟢 [Done] Mac版の楽曲同期適用・取り消しは、開始時のRepository、タグURL、変更後トラック・タグを捕捉する。旧Repositoryの完了後も旧URLにタグを保存し、世代が変わった場合は新画面に成功・失敗・巻き戻しを反映しない。切替中は新たな操作を開始しない。
- 🟢 [Done] 同期画面側は操作開始時の世代を記録し、待機後に確認する。切替をまたいで旧Undoの次のプレイリスト処理や監査・送信を新しいライブラリに続行しない。
- 🟢 [Done] `swift test --filter 'StorageDelayedFailureTests|DeviceSyncTests|LibraryRepositoryTests|ApplicationSettingsTests|ArtworkResolverTests'` は5スイート102テスト成功。独立した一時ライブラリで、楽曲適用・取り消しそれぞれの遅延成功／保存失敗の4条件を注入し、両Repositoryとタグファイル、新画面の分離を確認。通常同期・取り消しも回帰確認。ログ `/tmp/ongaku-overlay-ownership-regression.log`。
- 🟠 [Next] 今回は切替が成功する競合を対象とする。切替失敗時に世代が変わり旧ライブラリが残る場合の遅延結果と、台帳保存後のタグ保存失敗による部分保存は未検証・未解決。2つの保存は単一トランザクションではない。重複整理・メディア整理も別途対応する。
- ⭕️ [Pending] インストール版・Sandbox・実機間の同期中に保存先を切り替え、切断・再接続および同期画面を確認。iPhone本体への変更はない。
