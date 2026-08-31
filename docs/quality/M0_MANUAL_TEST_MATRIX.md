# M0 品質ゲート

この表は自動化できる基盤契約と、配布候補で人が確認する項目を分離する。`[Done]`は現在のコードとCIで検証される項目、`[Next]`は次の配布候補で実機確認する項目を表す。

## 自動ゲート

| 状態 | 対象 | 合格条件 |
|---|---|---|
| [Done] | 三言語キー | 英語、日本語、简体中文の`Localizable.strings`と`InfoPlist.strings`が同じキーを持つ |
| [Done] | 書式指定子 | `%@`、`%d`などの引数の個数と型が三言語で一致する |
| [Done] | 見出し | 主要見出しに強制改行がなく、560ptの幅予算内に収まる |
| [Done] | 操作ラベル | 主要ボタンが三言語で空でなく、幅予算内に収まる |
| [Done] | キーボード | 同期画面は⌘⇧Iで開け、主要シートはEscape、確定操作はReturnを持つ |
| [Done] | VoiceOver基盤 | メイン、端末同期、Apple Musicの主要画面と操作に安定したアクセシビリティ識別子・ラベルがある |
| [Done] | UI監査コード | XCUITestが三言語で主要画面を開き、要素検出、ヒット領域、説明監査を行う。CIでコンパイルを必須化する |
| [Done] | Privacy Manifest | trackingなし、収集データなし、Required Reason APIの理由コードを検証する |
| [Done] | 製品ビルド | macOS UIテストとiOS companionのSimulatorビルドがCIで成功する |

## 配布候補の実機確認

| 状態 | 環境 | 確認内容 |
|---|---|---|
| [Next] | macOS・VoiceOver | メイン→同期→再試行→閉じる、Apple Music→検索→閉じるの読み上げ順と操作結果 |
| [Next] | 署名済みmacOS Runner | `xcodebuild test -project OngakuDesktop.xcodeproj -scheme OngakuDesktop -destination 'platform=macOS'`を完走する。adhoc署名しかない環境ではApple System PolicyがRunnerを拒否するため、Apple Development署名環境で行う |
| [Next] | macOS・キーボードのみ | Tab／Shift-Tabの順序、Space／Return、Escape、⌘⇧I。フォーカスが見失われないこと |
| [Next] | macOS・英日中 | 1,160×620と1,320×780で見出し、ボタン、説明文に切れ・不自然な改行・重なりがないこと |
| [Next] | iPhone SE (第3世代) | Safe Area、左右16pt以上、同期許可・ライブラリ・再試行画面に横切れがないこと |
| [Next] | iPhone 16 Pro Max | 広い画面で余白が過大にならず、同期状態と主要操作の視線順が保たれること |
| [Next] | iPhone実機＋Mac | ローカルネットワーク拒否／許可、Bonjour自動検知、接続許可、切断、再試行を確認する |

実機結果はOS、端末、言語、ビルド番号、合否、スクリーンショットまたは問題番号を追記する。公開API能力の判断は[ADR-0002](../adr/0002-public-api-and-privacy-boundary.md)を参照する。
