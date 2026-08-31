# ADR-0002: Apple公開API境界とプライバシーデータフロー

- Status: Accepted
- Date: 2026-08-31
- Review cadence: 四半期ごと、およびApple SDK更新時
- Scope: Ongaku Desktop / Ongaku Mobile / Apple Music連携 / 端末同期

## Context

Ongakuはローカル音源、Apple Music、外部メタデータサービス、同一利用者のMacとiPhone間同期を扱う。機能差を隠すと、DRM保護曲を転送できる、Apple Musicのファイルを直接管理できる、またはOngakuが利用者の再生情報を収集するという誤解につながる。このADRで公開APIの能力境界、送信データ、保存場所、削除方法を固定する。

判断根拠はApple公式の [MusicKit](https://developer.apple.com/documentation/musickit)、[MusicLibraryRequest](https://developer.apple.com/documentation/musickit/musiclibraryrequest)、[MusicLibrary](https://developer.apple.com/documentation/musickit/musiclibrary)、[MPMediaItem.hasProtectedAsset](https://developer.apple.com/documentation/mediaplayer/mpmediaitem/hasprotectedasset)、[ローカルネットワーク利用目的](https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription)、[Privacy Manifest](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files) とする。

## Decision

### 公開API能力表

| 領域 | 判定 | 採用する公開API／方式 | Ongakuの挙動 | 禁止事項・縮退 |
|---|---|---|---|---|
| Apple Music認証・能力 | 対応 | `MusicAuthorization`、`MusicSubscription` | 利用者操作後だけ認証し、拒否・制限・未加入・クラウドライブラリ無効を別状態で表示 | 認証状態を推測しない。拒否時もローカル機能を維持 |
| カタログ検索・チャート・推薦 | 対応 | MusicKit request | 検索語をAppleへ送信し、応答を画面表示 | 独自推薦をApple推薦として表示しない |
| カタログ再生 | 条件付き | `ApplicationMusicPlayer` | 加入・地域・再生可能状態を確認し、ローカル再生と排他的に切り替え | DRMストリームをAVAudioEngineへ抽出しない |
| 利用者ライブラリ閲覧 | 対応 | `MusicLibraryRequest` / `MusicLibrarySearchRequest` | 曲・アルバム・プレイリストをページング取得 | Apple Musicアカウント識別子やトークンを独自保存しない |
| ライブラリ・プレイリスト更新 | 条件付き | `MusicLibrary` またはApple Music APIの公開`me/library`操作 | 明示操作で追加・作成し、部分失敗を監査表示 | 他アプリ作成プレイリストの破壊的更新は実機検証完了まで行わない |
| Apple Musicオフライン音源 | 非対応 | 公式Musicアプリへのハンドオフ | ストリーミング／公式ダウンロード導線だけ提供 | DRM回避、保護音源の書き出し、キャッシュ抽出を行わない |
| iOSシステム音楽 | 条件付き | `MPMediaQuery`、`assetURL`、`hasProtectedAsset`、`isCloudItem` | 非保護で端末上にあり、URLを取得できる音源だけ能力判定 | 保護・クラウドのみ・URLなしの項目は音声転送しない |
| 端末探索・同期 | 対応 | Bonjour / MultipeerConnectivity、暗号化必須セッション | 同一ローカルネットワーク上で利用者が承認した端末とmanifest・選択音源を交換 | インターネット中継、無断バックグラウンド転送、権限拒否の迂回を行わない |
| USB接続 | 検知・導線のみ | IOKitによる接続表示、Finderファイル共有へのハンドオフ | 接続端末を表示して公式導線を開く | Finder同期プロトコルを模倣しない |
| Store購入 | 公式導線 | iTunes Search API、Store URL | 検索結果からAppleの購入画面を開く | 購入UI、決済、購入履歴をOngakuが代理実装しない |
| 歌詞 | 条件付き | LRCLIB HTTPS API | 曲名・アーティスト・アルバム・再生時間を検索要求時だけ送信 | 自動大量収集を行わない。失敗状態を区別する |
| 書誌・画像 | 条件付き | MusicBrainz、Cover Art Archive、WikidataのHTTPS API | 利用者が候補検索したメタデータだけ送信し、候補確認後に保存 | 類似一致だけで自動上書きしない |
| 更新 | 対応 | Sparkle | 公開appcastを確認し、署名検証した更新だけ案内 | 音楽ライブラリ内容を更新確認へ添付しない |

### データフロー

| データ | 発生元 | 保存先／送信先 | 保存期間 | 利用者による削除 |
|---|---|---|---|---|
| 音源ファイル | 利用者が選択したファイル、CD、URL、共有フォルダ、端末転送 | 選択したOngaku Mediaまたは参照元。端末同期時のみ承認済み端末へ暗号化転送 | 利用者が登録解除／ゴミ箱移動するまで | ライブラリから登録解除。管理コピーは確認後にゴミ箱へ移動 |
| カタログ・プレイリスト・履歴 | ローカル操作 | 選択ライブラリ配下のJSON／SQLite | ライブラリ削除まで | ライブラリ管理、履歴消去、プレイリスト削除 |
| 音響特徴量 | ローカルPCM解析 | ライブラリ配下キャッシュ | 元音源fingerprintが変わるまで | キャッシュ再生成／ライブラリ削除 |
| 表示タグ・端末同期監査 | Mac／iPhoneのOngaku | 各端末のアプリ領域。同期時のみ相手端末 | タグは削除まで、監査は最大50件 | タグ編集、履歴消去機能（未提供画面は設定実装時の必須項目） |
| Apple Music検索語・操作 | 利用者の検索・追加・再生操作 | Apple Music / MusicKit | Appleの方針に従う。Ongaku独自サーバーには送信しない | Apple Music側の履歴・ライブラリ管理。Ongakuは認証トークンを保持しない |
| 歌詞検索メタデータ | 選択曲の曲名等 | LRCLIB | サービス方針に従う。Ongakuは結果のみローカル保存 | 保存歌詞を編集／削除 |
| 書誌・アート検索メタデータ | 利用者が候補検索した曲・アルバム | MusicBrainz / Cover Art Archive / Wikidata | サービス方針に従う。承認結果と画像キャッシュのみローカル保存 | メタデータ／アート編集、キャッシュ削除 |
| URL取り込み先URL | 利用者入力 | 指定HTTPSホスト | ダウンロード処理中のみ。履歴収集なし | 処理終了でセッション破棄 |
| 端末名・ペアリング情報 | Mac／iPhoneの端末名 | 同一LAN上の相手端末、ローカル監査 | 接続中および最大50件の監査 | 同期履歴の消去（設定画面実装まで既知制約） |
| 設定 | 利用者操作 | アプリ専用`UserDefaults` | アプリ設定のリセット／削除まで | 設定の初期値復元、アプリデータ削除 |

### データ最小化とログ

1. 独自の分析、広告、トラッキングSDKは導入しない。
2. 音楽ライブラリ、検索履歴、再生履歴をOngaku運営者のサーバーへ送信しない。
3. 外部検索には要求を成立させる最小限の曲メタデータだけを送る。
4. ログへ音源内容、認証情報、完全なローカルパス、検索語を恒常的に記録しない。
5. Privacy Manifestは`NSPrivacyTracking = false`、収集データなしを宣言する。外部サービスがリアルタイム要求を超えて保持する場合は、配布前にApp Privacy回答と本ADRを更新する。

### UI要件

- 権限要求の前に目的を三言語で説明する。
- 利用不可機能は消さず、理由と公式の代替導線を表示する。
- 外部送信を伴う検索・取り込み・書き出しは利用者の明示操作で開始する。
- 破壊的操作は対象・結果・復旧可否を実行前に表示する。

## Consequences

- ローカル再生と管理はApple Music認証なしで完全に利用できる。
- Apple MusicやiOSシステム音楽との完全なファイル互換は保証しない。
- API能力が増えても自動的には利用せず、三言語UI、プライバシー、失敗時縮退、実機試験を通してから有効化する。
- M6までに地域差、加入状態、DRM／クラウドのみ項目を実機マトリクスで再確認する。

## Verification

- CIでPrivacy Manifest、InfoPlist利用目的、三言語キー一致を検証する。
- MusicKitモックで未認証・拒否・未加入・オフライン・競合・レート制限を検証する。
- 実機依存項目は`docs/quality/M0_MANUAL_TEST_MATRIX.md`へ結果を記録し、未実施を`[Done]`扱いしない。
