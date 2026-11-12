# エフェクトカードの中央揃えと折りたたみ — 2026-11-12

## 実装

- iPhoneのEffectCard／HeadphoneSpatialCardとMacのEffectModuleCardで、タイトルとON/OFFを独立した中央揃えの見出し行に変更。
- タイトル左に淡い丸背景のシェブロンを配置。初期値は展開。カードごとの表示状態のみ変更し、折りたたむと説明文とパラメーターを取り除く。ON/OFFとMacのリセットは操作可能。
- 開閉状態はViewのローカルStateであり、アプリ再起動を跨ぐ保存は行わない。DSP設定・音声グラフ・パラメーターは変更しない。レイアウト全体のアニメーションは追加しない。
- iPhoneは44ptの開閉タップ領域、タイトル折り返し、固定サイズのON/OFFを使用。既存のSE／16 Pro Maxプレビュー構成を維持。
- Macは既存のEffectRackInputRouterへ開閉ボタンを登録。スクロール中の誤操作を抑制。
- エフェクト名は英語のまま。開閉の説明・アクセシビリティ値は英語・日本語・简体中文。

## 検証

- iPhone: `xcodebuild -project Ongaku.xcodeproj -scheme audio -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/ongaku-disclosure-build CODE_SIGNING_ALLOWED=NO build` 成功。
- Mac: `swift test --filter 'EffectRackRenderingTests|EffectRackInputTests'` ビルド成功、17テスト／2 suite成功。既存の値更新・モード維持・レイアウトキャッシュ・実NSHostingView上のクリック／スクロール位置保持を確認。
- 両アプリ3言語、計6ファイルの `plutil -lint`、両リポジトリの `git diff --check` 成功。
- ログ: `../measurements/effect-disclosure-2026-11-12/`。

## Pending

- 今回の開閉ボタン自体をクリックする目視確認、折りたたんだ状態でのON/OFF、狭い幅・Dynamic Type・ライト／ダーク・VoiceOverの実画面比較は未完了。既存17テストの成功を新規開閉操作の実画面確認とは扱わない。
- Simulatorサービス上でiPhone SE検証端末へのインストール・起動は成功したが、Simulator.appのGUI実体が見つからず画面操作できなかった。Mac一時検証アプリもCUA接続がタイムアウトし、目視確認は未実施。
- 実機で再生中に繰り返し開閉した場合のノイズ・スクロール・描画負荷。配布／インストール済みアプリへの反映は今回実施していない。
