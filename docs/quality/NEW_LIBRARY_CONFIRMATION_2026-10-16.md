# 新規ライブラリ作成確認・インストール検証

検証日: 2026-10-16

## 結果

- 🟢 [Done] 署名付きReleaseアプリの移行エラー画面から「フォルダを選択して自動修復…」を操作。空フォルダを指定すると「新しいライブラリを作成しますか？」の確認画面が表示された。
- 🟢 [Done] 「キャンセル」でエラー画面へ戻り、選択フォルダ内の項目が0件のままであることをファイルシステム上でも確認。
- 🟢 [Done] 同じフォルダを再指定して「作成」を押し、通常のライブラリ画面（0曲、読み込みボタンあり）が開くことを確認。
- 🟢 [Done] 新しいサブフォルダの識別マーカーとmanifestが同じUUIDを持ち、manifestの曲数が0であることを確認。元の失敗再現ファイルも保持されている。
- 🟢 [Done] 不透明な背景で移行エラー画面が表示されることをスクリーンショットで確認。
- 🟢 [Done] `/Applications/OngakuDesktop.app` を更新し、作成済みの検証用ライブラリが再起動後も開くことをネイティブUIで確認。
- 🟢 [Done] 検証モードを終了して通常起動し、ユーザーの現在のライブラリ14曲／149.6 MBが表示されることを確認。通常モードでは新規作成操作を行っていない。

## 検証の分離

検証ルート:
`/Users/littlebuddha/Library/Containers/com.ongaku.desktop.uitests.xctrunner/Data/tmp/OngakuNewLibraryQA-20261016-b73e`

選択先はこの中の `Selected Empty Folder`。作成されたライブラリUUIDは `BD0D653D-9725-4A31-9D28-A2A22C163BC9`。
起動引数 `--ongaku-qualification-recovery` を追加し、一時ディレクトリに限定された既存のqualificationルートと専用UserDefaultsで、通常の復旧・プロフィール切替・読み込みを検証できるようにした。このモードでもPhone同期の自動起動は抑止する。
過去の検証設定が残っていた試行は合格証拠に含めず、未使用のルート名で確認し直した。

## ビルド・回帰確認

- macOS Universal Releaseビルド成功: `/tmp/ongaku-create-install-build-20261016.log`
- `swift test --filter 'ApplicationSettingsTests|M5LocalCompleteMilestoneTests|M0QualityGateTests'`: 45件成功。ログ: `/tmp/ongaku-recovery-ui-tests-20261016.log`
- `codesign --verify --deep --strict` 成功。本体とSparkleの同梱コードを同じDeveloper IDで署名。Hardened Runtimeは有効のまま。
- インストールした実行ファイルは検証済み実行ファイルとSHA-256が一致:
  `afdff1f1e0e30912e38b2a9e92b3c99c6621292ab33bad12704ff167264ba401`
- 旧インストール版の退避先: `/tmp/OngakuDesktop-before-new-library-20261016.app`

これはローカルインストールの検証記録。App Storeへの提出、公証・配布版の公開、10万曲性能の再計測は今回行っていない。
