# Ongaku Desktop 0.1.11 配布記録 — 2026-10-20

- バージョン: 0.1.11 / 修正版ビルド: 18
- 更新情報: [日本語・英語・简体中文](../../Releases/notes-0.1.11.md)

## 検証と修正

- 🟢 [Done] 直近のUI・曲末処理の差分、版番号、三言語の構文と空白を確認。
- 🟢 [Done] 初回全382テストは以前にも記録されたEQ-band-state確認で1件失敗。単独と全382テストの再確認は成功。
- 🟢 [Done] 報告されたCIのFatal access conflictを特定。SwiftUIグラフ破棄中の状態通知を止め、再接続後の通常通知を維持する修正を追加。修正前に失敗する回帰を含む13入力テストに成功。[原因と証拠](CI_EFFECT_RACK_TEARDOWN_2026-10-20.md)。
- 🟢 [Done] 修正版の署名付きUniversal Archive、App Store Release、アップロード18が成功。GitHub run 39378632312では全383テスト、M3予算、Mac両構成、Sandbox検査が成功。最後の同梱iOSターゲットで測定ファイルの登録漏れを検出し、2行のターゲット登録修正後にSimulatorビルド成功。
- ローカルの高負荷並列実行ではPlaybackTransportIntegrationTestsの再生状態確認が1件失敗した。GitHubの全383テストは成功したが、実機・高負荷の再生確認の代替とはしない。
- 後続のdocs/feedコミットのrun 39384131607でも同じ再生状態確認が失敗。全テストを維持して実時間の再生統合suiteを別プロセスに分離した。[切り分けと検証](CI_TRANSPORT_ISOLATION_2026-10-20.md)。配布済みビルド18の実装は変更しない。

## 配布

- 🟢 [Done] 0.1.11 (17) のApp Store Connectアップロードは成功。このビルドはCI修正前のため審査に選択しない。
- 🟢 [Done] 修正版0.1.11 (18) をアップロードし、三言語の更新情報とレビュー情報を保存。承認済み暗号化申告を保存し、ビルド18でApp Reviewに提出。「審査待ち」を確認、承認後自動公開。
- 🟢 [Done] 署名・公証・Gatekeeper・Sparkle署名を検証したUniversal DMGと5差分更新・チェックサムを[GitHub v0.1.11](https://github.com/matsushibadenki/Ongaku-desktop/releases/tag/v0.1.11)で公開。全7配布物のサイズとSHA-256をGitHubと照合し、公開後に更新フィードへビルド18を反映。
- 🟢 [Done] [GitHub Xcode 26.6 CI run 39382386097](https://github.com/matsushibadenki/Ongaku-desktop/actions/runs/39382386097)の全項目成功を確認。全テスト・性能予算・Mac両構成・Sandbox検査・同梱iOSコンパイルが成功。
- ⭕️ [Pending] Apple審査/一般公開、既存の実機音声/入力/ディスプレイの確認。

同名のDeveloper IDが2件あるため、GitHub配布では既存の有効な証明書を公開SHA-1フィンガープリントで一意に指定する。秘密鍵は書き出さない。
