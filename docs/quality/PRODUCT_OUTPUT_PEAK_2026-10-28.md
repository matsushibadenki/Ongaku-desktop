# 製品出力経路の強入力ピーク — 2026-10-28

## 目的と測定範囲

前回のVocal Presence併用比較では、Appleリミッターを既定値のまま置いた簡略経路で、強入力時の4倍補間ピークが+0.59 dBFSになった。今回は製品ソースのノード・保護設定とゲイン方針を用いたオフラインAVAudioEngineで、出力レート変換後を測定する。製品のコントローラや実デバイスを起動した試験ではない。

- 両版の全エフェクト列と製品順序を使用。OFF、Vocal Presence初期0.35＋OptoFET／Exciter／Space、Vocal Presence最大1.0＋同3種を比較。音量と遷移ゲインは1、その他のエフェクト・自動DSP・ラウドネス補正は中立。
- 両版共通の製品AudioProcessingPolicyの96 kHzラック、製品設定のApple Peak Limiter（attack 1 ms・decay 60 ms・pre-gain 0）と後段−1 dB。Macは製品EffectOutputProtectionとFinalOutputProtectionを使用し、48／96 kHz音源から出力へ変換。iPhoneは製品のゲイン計算部分と定数を試験時にソースから抽出し、実装と同じ入力EQ・安全EQ・リミッター・デクリック・出力変換を接続。ラックへ入る96 kHz PCMを使用し、診断済みと診断待ちの既定値を比較した。診断済みは入力PCMのピーク・RMS・IntegratedLoudnessMeter、測定済みエフェクト増幅・自動DSPは0、エフェクト推定値は実ノードから取得。RMSは試験側で倍精度累積する近似であり、実際の解析範囲・丸め・タイミングは再現していない。
- 両アプリの通常経路と、`ONGAKU_ENABLE_TRUE_PEAK`相当の最終保護を出力変換後に置いた経路を別々に測定。出力44.1／48／96 kHz、ステレオ、音量100%。装置固有の変換、マルチチャンネル、iOS Simulator／実機では未測定。
- 入力は声風合成ミックスを3倍した強入力の先頭1秒と、11,025／18,811 Hzの高域複合音。1秒後に無音を入れるため、切れ目を含むストレス条件。浮動小数点PCMで、入力が0 dBFSを超える場合を含む。実際の録音や実楽曲とは異なる。
- 全144ケース（iPhoneソース72、Macソース72）。16倍polyphase再構成による推定ピークとサンプルピークを出力。サンプル間ピークを持つ校正波形で検出を確認。ITU認証済みtrue-peak計ではなく、あらゆる波形の上限を保証しない。保護ありの判定は−1 dBFS相当＋振幅0.002の許容差。

## 結果

| 試験経路 | ケース | 最大16倍補間ピーク | 最大サンプルピーク |
| --- | ---: | ---: | ---: |
| iPhone通常・診断済み | 18 | −6.656 dBFS | −6.711 dBFS |
| iPhone通常・診断待ち | 18 | −0.068 dBFS | −1.058 dBFS |
| Mac通常 | 36 | −0.067 dBFS | −1.057 dBFS |
| iPhone最終true-peak保護あり | 36 | −1.296 dBFS | −1.500 dBFS |
| Mac最終true-peak保護あり | 36 | −1.296 dBFS | −1.500 dBFS |

通常経路の144件中72件は、いずれも今回の補間推定で0 dBFS未満。ただしiPhone診断待ちとMacでは強入力・OFF・96 kHz出力で0 dBFSに近づき、通常のAppleリミッター＋後段−1 dBは−1 dBTPを保証しない。サンプルピークだけでは余裕を過大評価し得る。製品の診断済みiPhoneと同一条件のMacでは、iPhone側の入力ゲイン方針が異なるので出力値の一致は期待しない。

最終true-peak保護を加えた72件はすべて判定基準内。校正波形に加え、通常経路で−1 dB目標を超える実測例も負の対照として検出した。なお、最終保護を使う場合でも、この実験だけで全入力や実機の保証にはならない。

前回の簡略経路の超過は、製品ノード設定・ゲインと出力変換を使った今回の対象条件では再現しなかった。今回の結果だけから恒常的な追加減衰や、新しいDSPへの切り替えを適用する根拠は不足している。最終true-peakは既存の実機検証待ちゲートを維持し、通常版の保護と混同しない。製品コードや初期設定は変更していない。

## 再現と残件

macOS 27.2 arm64／Xcode 27.1、Python numpy/scipy。iPhone版リポジトリから以下を実行し、Mac版は隣接する`../Ongaku-desktop`を参照する。macOS音声サービスへのアクセスが必要。PCMは一時領域に置く。

```sh
python3 tests/generate_vocal_mix_fixtures.py /private/tmp/ongaku-peak-fixtures
tests/run_product_output_peak_audit.sh /private/tmp/ongaku-peak-fixtures /private/tmp/ongaku-peak-results
```

[入力ハッシュ・全ケースの出力値とログ](../measurements/product-output-peak-2026-10-28/)を保存。ソース波形全体や機器出力を含む測定ではない。

- 🟠 [Next] 通常経路の0 dBFS近傍について、0 dBFS以下の実楽曲・高クレストの波形、44.1 kHz音源、診断の更新や曲間遷移を含めた追加測定。真のピークを一般に保証する必要性と保護を有効化した場合の遅延・負荷を評価。
- ⭕️ [Pending] iPhoneとMacの実機、内蔵スピーカー／ヘッドホン／Bluetooth／外部DAC、ハードウェアレート変化、再生開始・停止・曲間・復帰、長時間再生の聴感・途切れ・電力・発熱。iOS Simulator、Appleリミッター不在時、実際の多チャンネル経路も未測定。最終保護の通常版への有効化は実機確認後に判断する。
