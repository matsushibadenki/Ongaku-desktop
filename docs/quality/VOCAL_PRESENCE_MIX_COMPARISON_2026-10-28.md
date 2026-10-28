# Vocal Presence 併用時のPCM比較 — 2026-10-28

## 条件と範囲

同一の合成ステレオPCMを、iPhone版とMac版それぞれの実装からビルドしたネイティブmacOSのオフラインAVAudioEngineで処理した。Exciter → Vocal Presence → OptoFET → Spaceの製品ノードを実際の順序で接続し、後段にApple Peak Limiterのデフォルト設定と固定−1 dB EQを置いた。試験用の簡略経路であり、製品の全ノード、適応ゲイン、実機出力、サンプルレート変換、最終保護設定を再現したものではない。実機・iOS Simulator上の出力一致を示すものでもない。全エフェクトの既定パラメータを使い、Vocal PresenceのOFF、初期強度0.35、単独の最大強度1.0を比較した。対象以外のエフェクトは接続していない。

入力は独自生成した4秒の9種類（声風の合成音のみ／楽器入り、楽器、打楽器、減衰音、逆位相、微小ノイズ、無音、強い入力）、48／96 kHz、ステレオ。声風の信号は録音された人の声ではない。出力には1秒の無音を追加し、残響を測定。強い入力は通常の合成ミックスを3倍したストレスケースで、入力がフルスケールを超える場合を含む。

各組を製品のIntegratedLoudnessMeterで測定し、共通の−23 LUFS以下に減衰のみで一致させた。最大サンプル値が0.8を超える場合は両方に共通の減衰を追加。ゲート未満はRMS一致、無音は無加工。適用後に同メーターで再測定した84組の最大差は0.000001 LU未満。12組はRMS、12組は無音。結果は[測定値と入力ハッシュ](../measurements/vocal-presence-mix-2026-10-28/)を参照。高域は周波数帯域内のエネルギー変化であり、歯擦音や音の良し悪しを直接判定する指標ではない。4倍補間ピークはscipyのresample_polyによる参考値で、認証済みtrue-peak測定ではない。

## 結果

48 kHzの声風合成ミックスで、各行は左の条件のままVocal PresenceをOFFから初期強度0.35に変更した差。帯域は音量一致後のエネルギー差。

| 併用 | 1.5–5 kHz | 5–8 kHz | 差分RMS／基準RMS |
| --- | ---: | ---: | ---: |
| なし | +0.217 dB | +0.036 dB | −38.95 dB |
| OptoFET | +0.217 dB | +0.030 dB | −38.22 dB |
| Exciter | +0.217 dB | +0.036 dB | −38.94 dB |
| Space | +0.217 dB | +0.036 dB | −38.86 dB |
| 3種同時 | +0.216 dB | +0.028 dB | −38.13 dB |

単独で強度1.0にすると同じミックスの1.5–5 kHzは+0.624 dB、5–8 kHzは+0.100 dB。96 kHzの初期強度は1.5–5 kHzが+0.215〜+0.217 dBだった。楽器のみでも初期強度で1.5–5 kHzが+0.272 dB変化するため、声だけを持ち上げる処理ではない。合成ミックスのSpace併用時の出力末尾1秒のRMSは、OFF −56.49／ON −56.51 dBFSで、Vocal Presence追加による大きな残響増加はこの条件では見られない。これは停止・切替時の残響安全性を保証しない。

入力を3倍した48 kHzのストレス条件では、簡略経路の4倍補間ピークがVocal OFFで+0.59 dBFS、ONで+0.54 dBFSとなった。これは試験用のリミッター設定とフルスケール超の入力を含む測定であり、実アプリの出力超過を示す証拠ではない。製品の実際のゲイン・リミッター・出力変換を含む経路での追加検証が必要。

198出力ファイルずつの比較では、両ソースを同じMacのネイティブ環境で実行したPCMは全サンプル一致した。異なるOS・音声ユニット・機器上の一致は未確認。初期強度が控えめであることと伴奏にも作用することは確認できたが、効果の聴き取りや刺さり、疲労、動的歯擦音抑制の必要性は判断できない。DSPや既定OFFは変更していない。

## 再現と未確認

macOS 27.2 arm64、Xcode 27.1、Python numpy/scipy。iPhone版リポジトリのルートで `tests/run_vocal_presence_mix_comparison.sh <output-dir>` を実行すると一括再現できる。Mac版は隣接する `../Ongaku-desktop` を参照する。`python3 tests/generate_vocal_mix_fixtures.py <fixtures>`で生成し、`tests/run_vocal_presence_mix_render.sh <fixtures> <mobile-output>`、同コマンド末尾に`desktop`を付けてMac版を測定。`tests/VocalPresenceMixLoudness.swift`と製品の`IntegratedLoudnessMeter.swift`をコンパイルして各出力のLUFSを取得し、`tests/analyze_vocal_presence_mix.py <output> <levels.json> <comparison.json>`、`tests/VocalPresenceMixMatchCheck.swift`で再測定する。音声ユニット実行にはmacOS音声サービスへのアクセスが必要。

- 🟠 [Next] 製品経路の強入力時を、実際のゲイン・保護・出力レート変換を含む条件で調査。処理負荷も別途評価する。
- ⭕️ [Pending] 実録の歌・伴奏を音量一致させたiPhone／Mac実機での聴感、歯擦音・明瞭度・疲労・定位、スピーカー／ヘッドホン／Bluetooth／DAC、ON/OFF時の音と残響。iOS Simulatorでの同一PCM経路測定も未実施。
