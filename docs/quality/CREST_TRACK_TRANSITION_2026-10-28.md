# 44.1 kHz高クレスト・診断更新・切替の出力ピーク — 2026-10-28

## 条件と結果

44.1 kHzステレオの独自合成PCMは、短い正負のピークを含む1秒で、最大サンプル0.99、RMS約0.0196、クレスト約34.1 dB。実楽曲ではない。Mac版はこのPCMを製品の96 kHzラックへ変換。iPhone版は製品ソースから抽出したchunked Precision Sinc（apodizing／eco）で96 kHzへ事前変換し、通常の96 kHzラックへ入力した。準備PCMのサンプルピークは0.882。準備処理のDSPを実行したが、iPhone実機のファイル読込・スケジューリングは実行していない。

製品の全エフェクト列・通常Apple Peak Limiterの設定・−1 dB余裕・出力変換を使うMacネイティブのオフライン再構成。iPhoneは製品のゲイン計算をソースから抽出し、診断前の既定値と診断済みを比較。Macは製品のEffectOutputProtectionと通常のFinalOutputProtectionを使用。自動DSP・ラウドネス補正は中立、音量100%、44.1／48／96 kHz出力。OFFおよびVocal Presence初期強度＋OptoFET／Exciter／Spaceを実行し、各入力を単独と切替モデルで測定。計36ケース。

| 条件 | 最大サンプルピーク | 最大16倍補間ピーク |
| --- | ---: | ---: |
| iPhone側、診断待ち・96 kHz出力 | −1.004 dBFS | −0.868 dBFS |
| Mac側、44.1 kHz音源・96 kHz出力 | −1.024 dBFS | −0.852 dBFS |

全36ケースで16倍補間推定は0 dBFS未満。ただし両条件とも−1 dBFSを超えるため、通常経路に−1 dBTPの保証はない。別のFFmpeg ebur128測定は上記2出力をそれぞれ−0.9 dBFSと表示（0.1 dB刻み）。どちらもITU認証済み計測ではない。汎用polyphaseでiPhone入力を事前変換した追加36ケースでも0 dBFSを超えず、iPhone側の最大は−0.251 dBFS。製品のPrecision Sincと汎用変換器で波形が異なるため、数値を同一視しない。

切替モデルは、2つのプレーヤーで同期した同一PCMを流し、iPhoneの高音質データ差し替えの線形ゲイン、またはMacソースから抽出した`CrossfadePolicy.clippingProtectedGains`（クリッピング防止ON・両曲の正規化1）を256フレームごとに適用。単独再生との差の最大絶対値はiPhone側0.000220、Mac側0.00000012。同期した同一波形に対する検証であり、異なる楽曲・音声時計のずれや実際のタイマー動作、クリックの不在を保証しない。iPhoneのこれは同一曲の高音質データ差し替えモデルであり、別曲への遷移を再現したものではない。

## 診断・切替の回帰確認

- iPhoneの製品メソッドを抽出した参照保持テストで、診断済み／未診断の両ケースに対し静かな・大きな後発解析が同一曲の入力ゲインを変えず、次曲では新しい診断を採用することを確認。参照を置き換える負の対照は検出した。
- iPhoneの製品transportメソッドを抽出した状態テストは、旧処理を無効化して次の準備を保持し、停止フェードとドレイン後に資源を解放することを確認。44.1／48／96 kHzの6組の簡易PCMフェードと、急な開始・停止の負の対照も成功。これは実機の曲間出力ピーク測定ではない。
- Macの実際の`PlaybackController`統合テストではクロスフェード中に両曲の解析値を更新し、停止・再開後も次曲の確定した正規化参照を保つことを確認。実コントローラーの状態確認であり、上表のピークは別のオフライン再構成による。

初回のiPhone transportテストはサンドボックスで音声サービスに接続できず終了したが、アクセスを許可した再実行はすべて成功した。[入力ハッシュ、全測定値とログ](../measurements/crest-track-transition-2026-10-28/)を保存。通常経路の上限を保証する証拠は得られていない一方、この条件で0 dBFS超過はなく、実機検証前に全体の音量やDSPを変更する根拠もない。製品の動作・設定は変更せず、測定と回帰テストを追加した。

## 再現と残件

macOS 27.2 arm64／Xcode 27.1、Python numpy/scipy。iPhone版リポジトリで実行し、Mac版は隣接する`../Ongaku-desktop`を参照。音声サービスへのアクセスが必要。

```sh
tests/prepare_crest_shipping_fixtures.sh /private/tmp/ongaku-crest-fixtures
tests/run_crest_output_peak_audit.sh /private/tmp/ongaku-crest-fixtures /private/tmp/ongaku-crest-results
bash tests/run_quality_gain_reference_regression.sh
bash tests/run_transport_continuity_regression.sh
```

Mac側は`swift test --filter PlaybackTransportIntegrationTests/crossfade`。FFmpegは96 kHz stereo float32出力を`ebur128=peak=true`で再測定した。

- 🟠 [Next] 異なる曲・位相・レベル、クリッピング防止OFF、実楽曲、別曲へのiPhone遷移、および診断更新を伴う出力波形を同時に捕捉し、通常版でのtrue-peak保護の必要性と遅延・負荷を評価。
- ⭕️ [Pending] iPhone／Mac実機の内蔵出力・ヘッドホン・Bluetooth・DAC、レート変更、曲間・診断完了・停止再開、途切れ・音量・聴感・発熱・電力。iOS Simulatorでの今回の一連のPCM測定と認証済みtrue-peak計による検証も未実施。
