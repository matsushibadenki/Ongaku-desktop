# 実楽曲・極性・診断更新・曲間の出力ピーク — 2026-10-28

## 音源と共通条件

ローカルにある2曲のうち、それぞれ25秒地点から1.4秒を使用。元ファイルはステレオMP3で48／44.1 kHz。FFmpegで44.1 kHz float PCMへ変換し、iPhone側の96 kHz入力は製品から抽出したchunked Precision Sinc（apodizing／eco）で用意した。元の44.1 kHz PCMのサンプルピーク／RMSはAが0.811／0.226、Bが0.588／0.144。Bを0.6倍し、同極性と符号反転（180度）を試験した。曲名・元ファイル名・音源・出力PCMはリポジトリに保存していない。2曲の短い断片の結果であり、実楽曲一般を代表するものではない。

両アプリの製品ソースをMac nativeのオフラインAVAudioEngineに組み、96 kHzエフェクト列、通常設定のApple Peak Limiter、後段−1 dB、44.1／48／96 kHz出力への変換を実行。Vocal Presence初期値＋OptoFET／Exciter／Spaceの併用と、全エフェクトOFFを分け、各18ケース、計36ケース。音量は100%、自動DSPは中立。最大値は16倍polyphase補間の推定で、認証済みtrue-peak計ではない。iPhoneとMacのゲイン・ルーティングは実際に異なるので数値一致を要求しない。

Macの2プレーヤーには異なる曲を同時に入力し、製品ソースから抽出した`CrossfadePolicy.clippingProtectedGains`を256出力フレームごとに適用。両トラックの正規化値は1、クリッピング防止ON／OFFを比較。OFFはクロスフェードの合計振幅の事前制限を外す設定であり、後段のApple Peak Limiter自体はOFFにならない。

iPhone側は同じ2曲を使い、旧曲をフェードアウトし、両プレーヤーの入力がゼロとなる区間で新曲の診断値を使う製品のゲイン計算結果を適用し、次の曲をフェードインするオフラインモデル。iPhoneにMacと同じクリッピング防止切替はない。このモデルは実ViewModelのスケジューリングや全ての診断更新の順序を再現しない。実経路は後述のSimulatorで別に観察した。

| 条件 | iPhoneモデル 全体最大 | Mac ON 全体最大 | Mac OFF 全体最大 |
| --- | ---: | ---: | ---: |
| 4エフェクト併用 | −8.668 dBFS | −8.618 dBFS | −8.618 dBFS |
| エフェクトOFF | −3.217 dBFS | −3.217 dBFS | −3.217 dBFS |

全36ケースで0 dBFS未満。全体最大は重なり以外の音にも左右される。Macの重なり区間0.4〜0.8秒について、同じ出力レート・極性のON／OFFを比較すると、OFF側の最大ピークはエフェクト併用で最大1.77 dB、エフェクトOFFで最大2.91 dB高かった。全ケースの測定値は[匿名の記録](../measurements/real-music-transition-2026-10-28/)を参照。FFmpeg ebur128の独立測定は併用時の全体最大に近いiPhone／Macの2出力をそれぞれ−8.7／−8.6 dBFS（0.1 dB刻み）と表示。いずれも一般的な上限保証ではない。

## iPhone Simulatorの実再生・診断更新

上記とは別に、同じ2曲の25秒地点から4秒ずつを一時CAFにし、iPhone 17 Pro／iOS 26.2 Simulatorで実際の`HiResPlaybackEngine`と`AudioPlayerViewModel`を実行。テスト専用コピーのエンジンに計測用フックを加え、既存の最終main-mixer tapから96 kHz PCMを採取した。フックによるコピーとロックが実時間の負荷・タイミングを変える可能性があり、実機測定ではない。

製品エンジン単体では高音質データを事前準備し、再生中に`seamlessUpgrade`を実行。診断値が未取得から取得済みに変わったことを確認した。続けて実ViewModelで2曲を連続再生し、1曲目の診断値が未取得から取得済みになること、別曲に移り最終曲で停止することを確認した。13.82秒の採取全体の16倍補間推定は−2.051 dBFS、次曲状態を観測した位置の前後0.2秒は−5.500 dBFS、診断取得を観測した位置の前後0.2秒は−2.864 dBFS。FFmpeg ebur128による全体値は−2.1 dBFS。

位置は20 ms間隔のUI状態ポーリングとtapバッファから記録した観測位置で、正確な切替・診断更新サンプルではない。各窓の最大隣接サンプル差は次曲付近0.0242、診断取得付近0.0577だが、音楽中の通常の高周波成分も含むため、これだけではクリックの有無を判定できない。初回の直接更新試行はViewModel側の並行準備と競合してキャンセルされ、短い素材を事前準備せず試した単体更新も曲末到達でキャンセルされた。成功した測定では事前準備とエンジン単体の更新を使った。

別途、実ViewModel／エンジンのSimulator回帰テストで、完了通知を落とした場合の次曲・最終停止・単曲／アルバムリピートが成功。これは合成信号の制御テストである。

## 判断と残件

今回の実曲断片・条件では0 dBFS超過が再現せず、標準音量やDSPを変更する根拠は得られなかった。Macのクリッピング防止OFFでは重なりのレベルが増え、後段の通常リミッターや出力変換も一般的なtrue-peak上限を保証しない。製品の初期設定・保護方式は変えていない。測定と再現用テストを追加した。

- 🟠 [Next] より多様な音源・ピークに近い箇所・位相／タイミング、複数の正規化ゲイン、クリッピング防止OFFでの実コントローラーの出力、iPhoneの診断更新が曲間と重なるケースを検証。波形・聴感・音量を合わせた副作用から通常版の最終true-peak保護を判断する。
- ⭕️ [Pending] iPhone／Mac実機、内蔵スピーカー・ヘッドホン・Bluetooth／DAC、レート変更、曲末・割り込み・背景復帰、クリック・聴感・熱・電力。計測フックのない製品ビルドおよび認証済みtrue-peak計での確認。

## 再現

ローカルにある権利処理済みの2音源を引数に指定し、一時領域を出力先にする。個人の音源・PCMは共有リポジトリに追加しない。Mac版は隣接する`../Ongaku-desktop`を参照し、macOS音声サービスが必要。

```sh
tests/prepare_music_transition_fixtures.sh <track-a> <track-b> /private/tmp/ongaku-music-fixtures
tests/run_music_transition_peak_audit.sh /private/tmp/ongaku-music-fixtures /private/tmp/ongaku-music-effects-on
MUSIC_FX_OFF=1 tests/run_music_transition_peak_audit.sh /private/tmp/ongaku-music-fixtures /private/tmp/ongaku-music-effects-off
```

Simulatorでは2つの一時CAFと専用の一時端末を用意し、`tests/run_real_music_simulator_audit.sh <device-id> <track-a.caf> <track-b.caf> <temporary-output>`、続けて`tests/analyze_real_music_simulator_capture.py <temporary-output>`。テスト終了後に端末とPCMを削除する。計測結果は匿名化した数値とログのみ保存する。
