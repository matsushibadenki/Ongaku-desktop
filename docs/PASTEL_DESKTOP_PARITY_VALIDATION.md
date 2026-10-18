# パステルアピアランス・文字盤の両アプリ整合 — 2026-10-18

## 実装

| 色 | 背景（sRGB） | 再生アクセント |
| --- | --- | --- |
| ピンク / Pink / 粉色 | `#fbeefa` | `#a83f79` |
| パープル / Purple / 紫色 | `#eeecfe` | `#7051b4` |
| グリーン / Green / 绿色 | `#e1fff4` | `#24765b` |
| ベージュ / Beige / 米色 | `#faf7e3` | `#856122` |

MacにiPhoneと同じ4色を追加。選択を保存し、ライトの文字色で背景・ツールバー・パネル・再生操作部へ反映する。設定の選択肢は7項目が無理なく収まるメニューに変更し、英語・日本語・简体中文を追加した。配色更新はObservableな状態を参照し、画面や選択中の曲を作り直さない。

文字盤はiPhoneのリアル・ライト画像を参照し、細かな主目盛りと副目盛り、赤い0…+3 VU域、`PROFESSIONAL VU METER`、`VU / dB`を反映。全ての文字・数字はSwiftUIのrounded書体を使用する。

- iPhone: 前回生成した4色の筐体画像を維持。文字盤だけをコードで更新し、浅い曲線の目盛りと針を同じ座標から描く。支点は画像座標(426, 664)、目盛りは x=218…634、y=516−34×sin(π×position)。
- Mac: 既存の高さ106 ptの再生バーを維持し、横長の表示枠に合わせた丸い筐体、クリーム色の縁、小さな留め具をSwiftUIで描く。画像の引き伸ばしは行わない。L/Rと選択したバックライト色のランプを表示する。
- 両アプリ: `PastelVUMeterScale.swift`を同一内容で配置。−18 dBFS RMS = 0 VU、表示域−20…+3 VU、0 VUの目盛り位置0.73を共通化。印刷する数値と針の変換を同じ定義に基づけ、非有限値・範囲外値を制限する。音声処理・ゲインは変更しない。

Macの既存System/Light/Darkメーターと、iPhoneの既存Original/Light/Dark画像は従来の表示を維持する。

## Macの筐体グラデーション調整

白を起点にしたハイライトを廃止し、枠・縁・留め具の全体に同じ色相を残す。不透明な3段階の明るい色を使い、背景色との混色で主体が曖昧にならないようにした。

| 色 | 明部 | 中間 | 暗部 |
| --- | --- | --- | --- |
| ピンク | `#fce3f2` | `#f5d0e6` | `#ebbedb` |
| パープル | `#eee7fd` | `#ded3f9` | `#cfc0f0` |
| グリーン | `#ddf8ea` | `#c7eed9` | `#afe1c6` |
| ベージュ | `#faf2d8` | `#f0e5be` | `#e5d5a6` |

4色を再描画し、グリーン・ピンクの明部もそれぞれの色として見えることを確認。変更後にMac両製品を再ビルドし、28テストを再実行した。文字盤・針の位置は維持する。

## 検証結果

- 🟢 [Done] Mac通常版・Mac App Store版・iPhone通常構成（Simulator）のDebugビルド成功。
- 🟢 [Done] Macのパステル追加テストと既存メーター等、計28テスト成功。4色のRGB、保存後の設定オブジェクト再生成、全11主目盛りの入力値との一致、非有限値、針先の表示範囲を確認。
- 🟢 [Done] Macの実装を使い、4色×2サイズ（幅218/328 pt、高さ80 pt）×L/R×最小/0 VU/+3 VUを描画。幅1000 ptの再生バー4色、既存3種類も描画し、代表画像を確認。0 VUと最大位置で針先が対応する目盛りに一致する。
- 🟢 [Done] Macの独立した12曲検証ライブラリでメイン画面と設定を実際に開き、ピンク→グリーンの切替を確認。メニューの7項目、日本語表示、配色の即時反映、曲選択の維持、左右メーターの収まりを確認。
- 🟢 [Done] iPhone SE（第3世代）と16 Pro Maxで各6検証群が成功。各18枚の画像を取得し、4色の主目盛り・文字盤、最小/0 VU/最大の針、実装のプレーヤー画面を確認。ラベルの3言語解決も再検証した。通常ビルドには検証用の初期表示変更を含めない。
- 🟢 [Done] 共通目盛りソースのバイト一致と、両リポジトリの`git diff --check`を確認。
- ⭕️ [Pending] 実音源再生中の追従・停止後の戻り方、長時間描画の負荷、iPhone実機および別のMacディスプレイでの色味・小さな文字の視認性（True Tone/Night Shift、表示倍率を含む）。今回のMac実画面確認は静止した検証ライブラリで、音声は再生していない。

Macの再現コマンド: `ONGAKU_PASTEL_AUDIT_OUTPUT=/private/tmp/ongaku-mac-pastel-renders swift test --filter 'PastelAppearanceTests|StereoLevelMeterTests'`。

iPhoneの再現コマンド: `bash tests/run_pastel_appearance_audit.sh <simulator-uuid> <output-directory>`。SEでビルドした同じ検証バイナリをPro Maxにも導入した。撮影後のソース整理は不要になった半径オフセットの除去のみで、針の座標は同一。最終コードで通常ビルドを再確認した。

## 証跡

- Mac文字盤: [ピンク](measurements/pastel-parity-2026-10-18/mac-pink-meters-218.png) / [パープル](measurements/pastel-parity-2026-10-18/mac-purple-meters-218.png) / [グリーン](measurements/pastel-parity-2026-10-18/mac-green-meters-218.png) / [ベージュ](measurements/pastel-parity-2026-10-18/mac-beige-meters-218.png)
- Mac実画面: [メイン](measurements/pastel-parity-2026-10-18/mac-main-green.png) / [設定](measurements/pastel-parity-2026-10-18/mac-settings-green.png)。この実画面は切替動作の証跡。撮影後に設定説明を3言語でパステル対応へ更新し、筐体の白いハイライトを同色相へ変更した。最終の枠色は上記Mac文字盤画像を参照。
- iPhone: [SE・0 VU](measurements/pastel-parity-2026-10-18/se-dial-pink-20.png) / [SE・最小](measurements/pastel-parity-2026-10-18/se-dial-green-0.png) / [Pro Max・最大](measurements/pastel-parity-2026-10-18/promax-dial-beige-23.png) / [Pro Max・プレーヤー](measurements/pastel-parity-2026-10-18/promax-now-playing-purple.png)
- 検証出力: [Mac](measurements/pastel-parity-2026-10-18/mac-checks.txt) / [SE](measurements/pastel-parity-2026-10-18/se-pastel-result.txt) / [Pro Max](measurements/pastel-parity-2026-10-18/promax-pastel-result.txt)
