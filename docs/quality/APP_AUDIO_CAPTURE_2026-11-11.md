# アプリ音声取り込み — 仕様・検証（2026-11-11）

この文書は初期capture実装の検証記録。後続の[Synth / UNGEノード経路](AUDIO_NODE_ROUTING_2026-11-11.md)で自由配線・自動保存・専用DSPを追加した。以下の初期実装時点の検証値は維持し、既存エフェクトラック／モニター出力は引き続き未接続とする。

## 目的と参考

左サイドバーの「オーディオ処理」に「アプリ音声」を追加する。Audio Hijackの入力・メーター・録音ブロック、明示的なRun/Stop、録音ファイルへのアクセスを参考に、OngakuのコンパクトなネイティブUIへ合わせる。自由配線のキャンバスや製品固有の外観・コードは流用しない。

- [Audio Hijack公式マニュアル](https://www.rogueamoeba.com/support/manuals/audiohijack/?print=true)
- [Apple: Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- SDK `ExtendedAudioFile.h`: `ExtAudioFileWriteAsync`は初回を非リアルタイム文脈で初期化した後、内部ring bufferとworkerで非同期保存する。確定には`ExtAudioFileDispose`が必要。

## 初期実装の操作契約

1. macOS 14.2以降。14.0/14.1では必要OSを表示して取り込みを開始しない。
2. Core Audioに登録された、起動中のアプリから入力を1つ選択する。音声の初期化前で一覧に出ないアプリは再生して更新する。Ongaku自身・Ongaku別起動とシステムdaemonは対象外。
3. プロセスのbundle IDを起動中アプリのbundle IDへ完全一致／ドット境界付きprefixで対応付け、同じアプリ配下のhelperをまとめる。共有WebKitプロセスなど、ホストに対応付けられない入力の捕捉を保証しない。
4. 「録音…」で新規WAV保存先を選ぶと開始する。選択キャンセルでTapもファイルも作らない。起動時やページ表示だけでは取り込まず、OSのシステム音声録音許可は初回開始時に要求される。
5. 音声はステレオmixdown。Float32 PCM・入力サンプルレートを維持してWAV保存し、録音時間・入力ピークを10Hzで表示する。元アプリの再生音は維持する。追加モニター出力・ミュート・既存エフェクトへの接続は行わない。
6. 「停止」でAudioDevice/IOProc/Tapを解放し、書込待ち音声をflushしてWAVを確定する。Finder表示と明示的な「ライブラリへ追加」が可能。タグのない録音には既存のアーティスト/アルバム入力シートを表示し、確認後に管理コピー経路を使う。
7. セッションは画面・ライブラリの寿命から独立して保持する。ページ移動中も録音し、サイドバーの停止ボタンから止められる。アプリ再起動では自動再開しない。
8. 入力プロセス構成・形式を1秒周期で確認し、変更・終了時は停止して途中ファイルを残す。スリープ前・通常終了時も停止。アプリ再起動や新しいhelperの追加時に、別の音を無断で取り込み直さない。
9. 既存ファイルは上書きしない。書込失敗・内部バッファ不足・不正PCM・WAV上限手前（3.8 GB）で停止してエラーを表示する。途中ファイルを成功扱いで隠さない。無音のみでは権限拒否と断定せず、再生状態とOS許可の確認を案内する。
10. 英語・日本語・简体中文。常設の長文説明は避け、infoアイコンのhelpへ移す。Safe Areaを維持し、横padding 24ptと縦スクロールを使う。

## 実装構成

- `ApplicationAudioCapture.swift`: アプリ一覧・セッション寿命・選択/保存シート・メーター・停止/取り込みUI。
- `ApplicationAudioCapture.mm`: public Core Audio Process Tap、private aggregate device、C IOProc、非同期PCM writer。
- 音声コールバックでSwiftUI、ファイル同期IO、Task生成、メモリ確保、ロックを使わない。WAV writerの初回非同期初期化をAudioDeviceStartより前に完了する。軽量なPCM検証とピーク計測、lock-free atomicの状態公開だけを行う。
- 通常配布版・App Store版のInfo.plistに`NSAudioCaptureUsageDescription`と3言語訳を追加。両署名構成にaudio-input entitlementを追加。マイク入力や画面画像の取得は実装していない。

## 検証

- 🟢 [Done] `ApplicationAudioCaptureTests`: 7テスト（stereo interleaved/planarの2ケースを含む）。PCM一致、サンプル数・レート・チャンネル数、停止後読取、二重finish、既存ファイル非破壊、不正形式・短いbuffer・NaNの拒否、bundle境界、空入力の拒否を確認。
- 🟢 [Done] 最終回帰は`ApplicationAudioCaptureTests|LibraryRepositoryTests|LibraryPresentationTests`で133テスト／4 suite成功（同じソース内のstorage failure suiteも実行）。DebugアプリおよびApp Store Release署名なしビルド成功。
- 🟢 [Done] 隔離ライブラリ・別bundle IDの実起動。空のライブラリから入力アプリ選択→保存シート→録音、ページ移動中の録音継続→サイドバー停止、再録音→必須タグ入力→ライブラリ追加→再生完了まで実UIで確認。入力一覧からシステムdaemonを除き、通常アプリにhelperをまとめた状態を確認。
- 🟢 [Done] 自作の別アプリから左440 Hz／右660 Hzの小音量信号を入力し、45.333秒と7.456秒のWAVを保存。48 kHz／2 ch／Float32、最初の1秒の正方向ゼロクロス440／660、peak約0.01526を確認。後者のライブラリ管理コピーは元WAVとバイト単位で一致し、アプリで再生位置7.456秒・再生回数1まで進んだ。測定値は[recording-verification.json](../measurements/app-audio-capture-2026-11-11/recording-verification.json)。
- 🟢 [Done] 日本語ライト画面を画像でも確認。録音中・登録後のボタン、矢印、レベル、ファイル操作は中央カラム内に収まり、背景や既存プレイヤーの配置を維持。
- ⭕️ [Pending] 初回OS権限許可/拒否の両分岐、入力アプリ終了/プロセス増減、スリープ・デバイス変更・異常終了。今回の環境で実入力を受信できたことを、全権限/中断状態の検証とは扱わない。
- ⭕️ [Pending] 署名済み配布/App Store sandbox構成、長時間・空き容量不足・高速な入力変更、44.1/48/96 kHz、Bluetooth/USB、Chrome/Brave/Safari/会議アプリなどのhelper識別を実機確認。
- ⭕️ [Pending] ダーク・狭幅・英語/简体中文の画像比較。日本語ライトでの確認と分けて管理する。

開発ログ: `/tmp/ongaku-capture-final-tests.log`、`/tmp/ongaku-app-audio-xcode.log`、`/tmp/ongaku-app-audio-store.log`。検証音源は一時ディレクトリの自作440/660 Hz・低振幅PCMを使用し、ユーザーのブラウザ・会話・音楽はテスト録音対象にしない。

## 次の段階

- 🟠 [Next] OS許可・拒否・中断とsandboxを検証して配布可否を判断する。
- 🟠 [Next] 入力 → 既存エフェクト → 出力/録音の専用グラフ。ライブラリ再生と同時に同じnode/engineを共有しない。bounded buffer、レート変換、出力ルート変更、元音のmuteと復旧を設計してから接続する。
- 🔴 [Later] セッション保存、AAC/FLAC、長時間分割録音、複数アプリ/マイクのミックス、スケジュール、自由配線。録音対象・保存先・開始条件が利用者に分かる形で追加する。

## 実画面で見つけた修正

- 同期`NSSavePanel.runModal`はAXから押した際にモーダルの操作取得が不安定になったため、非同期シートに変更し、同時に複数の保存シートを開かない状態を追加。実シートで保存先・名前・保存操作を確認。
- 最初の録音追加では、既存LibraryStoreがタグなしWAVを拒否した。既存の`RequiredImportMetadataView`を共有し、不足タグを入力して追加する動線へ修正。実録音で再検証して登録・再生まで成功。
- 日本語AXのヘッダーに曲数0が読まれていたため、音声ページでは信号経路の説明を読み上げるよう修正。存在しないシンボルを`waveform`/`app`に置換し、画像上でも確認。

インストール済みアプリや本番ライブラリを置換していない。検証版は`/tmp/ongaku-app-audio-build/Build/Products/Debug/OngakuCaptureQA.app`。App Storeビルド成功はsandboxでの実音成功を意味しない。
