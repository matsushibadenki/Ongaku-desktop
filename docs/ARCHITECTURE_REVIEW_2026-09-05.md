# 全体設計レビュー — 2026-09-05

対象: `2a78ec4` のアプリ実装、Package.swift、Xcodeターゲット、全テストの構成、CI、README、roadmap、ADR、品質記録。Vendor/Sparkleの内部監査は対象外。

## 判断

**SwiftUIのネイティブアプリ、ローカル優先、検証コピーとジャーナル、ローカル再生とMusicKitの分離は継続する。現在の機能追加中心の進め方は変更する。** 全面書き直しやサーバー導入は必要ない。まず保存成功の定義、大規模ライブラリの実操作、テスト境界を整え、配布可能な範囲を確定する。

既存のテストと復旧コードには投資価値がある。一方、「関数の試験が通る」「アプリ全体が使える」「署名した配布物が実機で動く」は別の証拠であり、現在の完了表記では区別できていない。実装量から完成率を算出しない。

## 根拠と優先度

### R1 / 高 → [Done] repository修正: iPhoneの転送完了が永続化成功を意味しない

`Sources/OngakuMobile/MobileSyncController.swift` の `finishIncomingChunkTransfer` は、検証済み一時ファイルをコピーした後、チェックポイントを削除し、`.completed` と `chunkCompletion` を送る。その後にmain queueへ登録・manifest保存を投入する。`saveManifest` は書き込み失敗を `try?` で捨てる。

保存失敗、または通知後から保存までの強制終了で、送信側には成功が見えても再起動後のライブラリに曲が残らない経路がある。コピー済みファイルは残り得るが、自動復旧の根拠となるチェックポイントは既にない。これはコード上の処理順から確認した問題で、今回実機のデータ消失を再現したという意味ではない。

`copyIntoLibrary` もコピー元だけをハッシュし、コピー先を再照合していない。`loadStoredLibrary` は破損manifestを空のライブラリと同じ結果にし、その後の保存で記録を置き換え得る。

2026-09-05に保存専用repositoryを実装し、検証→音源配置→manifest確定→成功通知→チェックポイント掃除を順序付けた。確定後・通知前の再送はSHA-256で冪等化し、保存失敗をUIへ返す。破損manifestの退避、直前バックアップからの復元、保存失敗時のコピーrollbackを追加した。repositoryの永続化・失敗注入・再送・再起動4試験を含む全263テスト、macOS Debug、iOS Simulator Debugが成功した。実機での強制終了・再接続はA6に残る。

### R2 / 高 → [Done]: 再生位置の保存に10万曲全体の書き直しが必要

`PlaybackController.publishQueueState` は再生位置を5秒区切りで発行し、`OngakuDesktopApp` → `LibraryStore.schedulePlaybackQueueSave` → `LibraryRepository.save(playbackQueue:)` へ渡す。最後は `persistDocument` でカタログ全体をencodeし、旧manifestの読み込み・decode・バックアップ・新manifestの書き込みを行う。再生イベントも同じ全体保存経路である。

頻度の高い小さな更新が楽曲数に比例するI/Oになる。repository actorは同時書き込みの保護に役立つが、このコストそのものは減らさない。

2026-09-05に再生キューと履歴をライブラリUUID付きの原子的sidecarへ分離した。既存manifestの値を初期移行元として維持し、別ライブラリのsidecarを拒否し、破損時は直前バックアップへ復旧する。10万曲のRelease計測で、位置保存p95 1.022ms、sidecar 237バイト、全曲manifest書込0バイトを確認した。SQLiteとの恒久的な二重書き込みは導入していない。

### R3 / 高: SQLite単体の検索速度が画面応答を代表しない

レビュー時の `LibraryStore` は `@MainActor` で、`filteredTracks` は現在の索引結果がないと `CatalogSearch.matches` による全件検索を同期実行していた。2026-09-05にこのfallbackをデタッチした処理へ移し、キャンセルとカタログrevision／query照合を追加した。結果の確定前は検索中として表示し、0件とは区別する。`scheduleSearchIndexSynchronization` は依然としてカタログからSQLiteを全再生成・照合するため、差分更新と実画面計測は残っている。

`LargeLibraryPerformanceTests.m3PerformanceGate` はrepository読込とグルーピング、独立したSQLiteへの4クエリを測る。SwiftUIの初回描画、入力から結果表示、索引更新中の検索、再生保存との競合は測らない。CIはDebug構成で、表示予算も4秒に対してADRはReleaseの2秒であり、同じゲートではない。

対策: 検索・集計をUIから切り出し、キャンセルとリビジョン検証を持つ非同期処理へ移す。検索対象フィールドの変更だけを索引へ差分適用し、短い日本語／中国語、歌詞、評価・履歴更新との整合性を維持する。起動・文字入力・取り込み・再生を重ねた実経路のRelease計測を追加する。SQLite全面移行は移行・復旧試験が通ってから決める。

### R4 / 高: 実装台帳と配布判定、別製品の範囲が混在

レビュー前のroadmapではM0〜M7が完了である一方、VoiceOver、署名付きUIテスト、音声耐久、端末間の実転送は未確認だった。M8の実機記録は署名・インストール・起動の確認であり、転送の合格証拠ではない。

さらに、このリポジトリのMobileは `OngakuMobileApp`、`MobileContentView`、`MobileSyncController` を中心とする同期companionである。roadmapの「MPMediaQueryによる統合再生」「システム楽曲の評価・タグ・プレイリスト編集」は、対象ソースとXcodeターゲットから確認できない。共有モデルとMac側の受信・プレビュー実装だけで、iPhone側の機能を完了扱いにできない。別リポジトリのOngakuに存在する可能性はあるが、本レビューでは未検証。

対策: roadmapを当該リポジトリに限定し、実装状態と配布証拠を別に記録する。旧日付ベースの長期計画を廃止し、依存関係と終了条件で進める。

### R5 / 高: アートの自動外部検索とプライバシー方針が不一致

`ArtworkThumbnail` の `.task(id:)` はローカル画像がなければ `ArtworkResolver.shared.artworkData` を呼ぶ。READMEは自動検索を説明するが、ADR-0002とPRIVACYは外部検索を明示操作時だけと説明していた。

対策: まず現状の説明を正す。続いて自動取得の明示的な設定、送信前の説明、無効時には画面表示から送信されないことの通信テストを実装する。承認前の候補と利用者が確定した書誌情報を引き続き区別する。設定が未実装の間、明示操作限定という保証を配布説明に使わない。

### R6 / 中: UI・サービス・状態更新の結合が大きい

Swift実装は約4万行。`AppleMusicStoreView.swift` は3,645行でモデル・HTTP client・controller・画面を同居させ、`LibraryStore.swift` は3,089行で検索・移行・編集・解析・同期適用・保存を扱う。`PlaybackController.swift` は2,262行。行数そのものを欠陥とはしないが、障害注入や変更範囲の限定を難しくしている。

Mac/Mobileの同期controllerは `@unchecked Sendable`、lock、複数queue、main queueへの配送を併用する。これだけで競合を断定はしないが、共有状態の保護責任をコンパイラが検証できない。[Swift公式のData Race Safety](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/dataracesafety/)も、この適合は実装側がスレッド安全性を保証するものとしている。

対策: 保存・検索・転送commitを先に境界化し、UIはMainActor、可変業務状態はactorまたは明記した単一queueへ集約する。リアルタイム音声コールバックにactor待ちや同期I/Oを持ち込まない。ファイル分割だけを完了条件にしない。

### R7 / 配布前確認: Storeのネットワーク権限と実機証拠

Store版はnetwork.clientのみで、CIはnetwork.serverがないことを合格条件にしている。一方、音声転送は双方向MCSessionである。「Browserとして開始するから受信権限不要」とは、このコードのコンパイルだけで証明できない。[AppleのSandbox設定](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)と照合し、署名したStore構成でペアリング・双方向転送・再接続を確認する。

これは今回確認した実行不良ではなく、配布前に解消すべき未検証事項。権限を推測で増減せず、必要な通信に対する最小権限を実動作で決める。

## 検証結果と限界

- Xcode 26.6 / build 17F113、当該Macで実行。
- 初回評価時の `swift test`: 通常のmacOS環境で259テスト / 31 suite成功。R1・R2、R3第1段階、ウィンドウSafe Area修正、エフェクト数のモード別集計修正、ツールバー配置修正後は **271テスト / 31 suite成功**。
- 制限環境では初回にキャッシュ書き込み不可、キャッシュを移した試行ではAVFAudio初期化例外で停止。通常環境での成功により、ここでの停止を製品不具合とは判定しない。
- `ONGAKU_RUN_LARGE_LIBRARY_BENCHMARK=1 swift test -c release --filter LargeLibraryPerformanceTests.catalogBenchmark`: Releaseビルドと10万曲・10サンプルの計測に成功。

| 計測対象 | 今回のp95 | ADR-0001予算 | 判定 |
|---|---:|---:|---|
| カタログ全体保存 | 1.770秒 | 1.5秒 | 超過 |
| コールドロード | 1.031秒 | 2.0秒 | 範囲内。ただし画面表示は含まない |
| 線形一般検索 | 0.460秒 | 300ms | 超過 |
| グルーピング | 0.059秒 | 500ms | 範囲内 |

manifestは48,967,905バイト。今回の計測は1回の10サンプルであり、3回連続超過を新たに確認したものではない。検索はbenchmarkの曲名・アーティスト・アルバムの線形検索で、SwiftUIや全メタデータ検索そのものではない。ピークメモリはこの試験で取得していない。ベンチマークのテスト成功は性能予算合格を意味しない（数値を出力するが上記予算はassertしない）。

- opt-inのベンチマークは通常の全テストでは実行されないため、全テスト成功と性能予算達成を同一視しない。
- 今回は実画面の三言語QA、VoiceOver、iPhone転送、署名Archive、Store通信、Intel／最小OS、実音声の長時間測定を実施していない。
- R1のMobile保存・転送commit、R2の再生状態sidecar、R3のMainActor上の同期fallbackは同日に修正した。R3の差分索引・実画面計測とその他の個別課題、機能の非表示化はこの時点では未実装。次の実装順は [ROADMAP](ROADMAP.md)、拘束する設計判断は [ADR-0003](adr/0003-stabilization-and-component-boundaries.md) に置く。
