# Ongaku Desktop 0.1.10 配布記録

日付: 2026-10-16

- バージョン: 0.1.10
- ビルド: 16
- 対象: macOS Desktop（Mobileのバージョンは変更しない）
- 更新情報: [日本語・英語・简体中文](../../Releases/notes-0.1.10.md)

## 検証とアーカイブ

- 🟢 [Done] Developer ID版Universalアーカイブ作成・署名検証成功。
- 🟢 [Done] App Store版Universalアーカイブ作成。署名、App Sandbox、Sparkle非同梱・非リンク、更新フィードキー非同梱の配布チェック成功。
- 🟢 [Done] 全332テストの再実行成功。初回は `warmAndExciterFiltersAreActiveAndWarmHasFourDistinctInputs` のEQ帯域bypass確認で1件失敗。単独再実行と続く全体再実行は成功した。DSPの本番コードはこのリリース作業では変更していない。初回の失敗ログも保持する。

アーカイブ:

- `Releases/build/OngakuDesktop.xcarchive`
- `Releases/build/OngakuDesktop-AppStore-0.1.10-16.xcarchive`

ログ:

- `/tmp/ongaku-pre-release-all-tests-20261016.log`
- `/tmp/ongaku-effect-release-recheck.log`
- `/tmp/ongaku-pre-release-all-tests-recheck-20261016.log`
- `/tmp/ongaku-github-0.1.10-build.log`
- `/tmp/ongaku-app-store-0.1.10-upload.log`

## 公開状態

- 🟢 [Done] App Store Connectに0.1.10の提出準備レコードを作成。前版は0.1.9（15）。
- ⭕️ [Pending] App Storeアップロード要求は開始済み。Apple側でビルドを認識・処理後に選択し、審査へ提出する必要がある。
- ⭕️ [Pending] GitHub用アーカイブの公証は `ongaku-notary` がHTTP 401を返すため停止。ユーザーへキーチェーンの認証更新を依頼済み。公証・staple・署名付きDMG・Sparkle appcastの作成完了前に配布物を公開しない。

App Store公開にはAppleの審査が必要で、アップロード成功と公開完了は区別する。既存の自動リリース設定を引き継ぐ。
