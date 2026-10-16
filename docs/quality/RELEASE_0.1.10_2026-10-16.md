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
- 🟢 [Done] App Storeアップロード成功（`EXPORT SUCCEEDED`）。TestFlightが0.1.10（16）を認識した。
- 🟢 [Done] GitHub mainへ配布準備コミット `2758fc5c4878fb52f4940df4f93847adcaca6f7f` を反映し、v0.1.10の下書きリリースを作成。
- 🟢 [Done] 日本語・英語・简体中文の更新情報を保存。ローカル機能の利用にサインイン不要であることを審査情報へ反映。
- ⭕️ [Pending] Apple側のビルド処理完了後、暗号化申告を操作中にブラウザセッションが再ログイン待ちへ遷移。申告の確定状態を再確認し、ビルドをバージョンへ関連付けて審査へ提出する必要がある。再ログイン用のタブを保持してユーザーへ依頼済み。
- ⭕️ [Pending] GitHub用アーカイブの公証は `ongaku-notary` がHTTP 401を返すため停止。ユーザーへキーチェーンの認証更新を依頼済み。公証・staple・署名付きDMG・Sparkle appcastの作成完了前に配布物を公開しない。

App Store公開にはAppleの審査が必要で、アップロード成功と公開完了は区別する。既存の自動リリース設定を引き継ぐ。
