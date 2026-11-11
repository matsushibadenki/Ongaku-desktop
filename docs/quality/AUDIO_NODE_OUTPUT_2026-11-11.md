# スピーカー／イヤホン出力 — 2026-11-11

## 操作

「アプリ音声」のテンプレートで「スピーカー／イヤホン」を選び、「出力デバイス」ノードをクリックして機器を選ぶ。「開始」で処理音を出力する。録音ノードがない場合は保存シートを出さない。録音経路へ出力ノードを追加して分岐することも可能。

録音・出力は各1ノード。双方がある場合は全終端の接続を必須とし、異なる処理経路を接続できる。最後の終端の削除を拒否する。出力機器を永続UIDで保存・復元し、不在時に別機器へ自動変更しない。機器一覧は入力欄の更新ボタンから更新する。編集／機器変更は停止中に行う。EN/JA/简体中文対応。

## 実装

- 全終端の祖先の和集合を一度だけ処理し、録音／出力のPCMを別バッファへ送る。共有ディレイを二重に進めない。
- 選択デバイス専用AUHAL。入力IOは無効でマイクは取得しない。システム既定出力やライブラリ再生の設定は変更しない。AUHALが入力サンプルレートを機器のレートへ変換する。
- Capture → 32,768 stereo frameの固定SPSC ring → AUHAL。開始前に確保し、音声コールバックでSwift・動的確保・ロック・同期ファイルIOを使わない。満杯時は停止、不足時は無音にして再充填する。
- 目標約30 msの充填量に対し、最大±0.2%の線形補間でクロック差を補正。機器バッファ／変換の遅延も加わるため、bit-perfect出力や固定遅延を保証しない。出力は±1のsample clamp、録音はFloat32 headroomを保持。true-peak limiterではない。
- 出力ノード使用時は`CATapMutedWhenTapped`で元アプリの通常出力を実行中だけミュート。停止・開始失敗時にTapとAUHALを解放して元音を復元する。録音専用は元音を維持。
- UID、device alive、機器レート、Tap形式、入力プロセスを監視し、変化時は停止する。入力が進むのに出力が進まない場合も停止。Ongakuの処理音を別機器に自動転送しない。停止後の元アプリの出力先はOS／元アプリの設定に従う。

参照：[Apple Core Audio taps](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps)、[CATapMuteBehavior](https://developer.apple.com/documentation/coreaudio/catapmutebehavior)、SDK AudioHardware.h／AudioUnitProperties.h。UID変換はqualifierにCFString、返却データにAudioDeviceIDを使う。

## 検証

- 🟢 [Done] 27テスト／5 suite成功。既存処理に加え、出力専用／二重終端、独立枝のPCM値、終端の方向・接続必須・削除rollback、UID保存／Undo、SPSC初期無音・不足・回復・容量上限・clamp、実列挙UIDの解決／不在UID拒否を確認。
- 🟢 [Done] Debug／App Store Release署名なしビルド成功。
- 🟢 [Done] 日本語ライトの隔離QAアプリで内蔵スピーカー出力専用の開始→停止を確認。16.619秒、AUHALへ795,904 framesを供給、underrun 0、status 0。
- 🟢 [Done] 停止後に外部ヘッドフォンへ変更して開始→停止。21.824秒、1,046,012 frames、underrun 0、status 0。機器設定の再起動復元、実行中の編集無効化も確認。
- 🟢 [Done] 実UIで録音ノードを追加しメーターから分岐。ヘッドフォン＋録音中に自作入力アプリを終了すると自動停止し、WAVを確定。20.202667秒、969,728録音frames、出力967,993 frames、underrun 0、status 0。WAVは48 kHz／2ch／Float32、1秒の正方向ゼロクロス440/660、peak約0.01526。初期充填とクロック補正のため録音と出力のframe数は一致しない。
- 🟢 [Done] 初回実機試験のUID解決エラー`!siz`をSDK契約に合わせて修正し、回帰テストを追加。OS内部の一時aggregateを機器一覧から除外。
- ⭕️ [Pending] 物理的な抜き差し、Bluetooth／USB／AirPlay、異なるレート／長時間クロック差、過負荷・最大構成、OS権限拒否／署名済みsandbox、ダーク／狭幅／他言語の実画面。今回の確認は実機AUHALへのPCM供給と録音であり、耳での聴取やDAC後の音響測定ではない。

[測定値](../measurements/audio-node-output-2026-11-11/verification.json)。ログ：`/tmp/ongaku-output-tests.log`、`/tmp/ongaku-output-build.log`、`/tmp/ongaku-output-store.log`、`/tmp/ongaku-output-qa.log`。自作の小振幅440/660 Hzのみを使い、個人の会話・ブラウザ音声は対象にしていない。

インストール版・本番ライブラリは置換していない。検証版：`/tmp/ongaku-routing-build/Build/Products/Debug/OngakuRoutingQA.app`。
