# ノードの色分けメーターとクリップ警告

- 🟢 [Done] アプリ入力・メーター・出力デバイスで共通の3色メーターを使用。−6 dBFS以下は緑、−6 dBFS超〜−3 dBFS以下は黄、−3 dBFS超は赤。点灯部分を帯域ごとに色分けし、現在のdBFS値も対応色で表示。
- 🟢 [Done] 各メーターの横にクリップ警告ランプを追加。サンプルの絶対値が1を超えたとき（0 dBFS超）に赤く点灯し、その後の無音・停止・画面切替でも保持。クリックで個別に解除し、新しい入力セッションで全解除。
- 🟢 [Done] Native DSPのノードごとにatomicフラグを保持し、UIの100ms更新の間に発生した短いピークも検出。停止直前の未取得フラグも回収する。警告解除時は未取得フラグも消費し、解除済みのイベントを再表示しない。
- 🟢 [Done] 音声コールバックの確保・ロックを追加せず、ピークと時計の細粒度Observationを維持。録音・試聴サンプルには変更を加えない。英語・日本語・简体中文のホバー説明とアクセシビリティ表示に対応。

これはデジタル信号のオーバーレベル検出。入力元ですでに歪んだ音や、アナログ機器で生じる歪みの判定は含まない。

## 検証

- 🟢 [Done] 56テスト／9 suite成功。−6／−3 dBFSの境界値、正負の1サンプルだけの過大ピーク、100ブロックの無音後にも残るフラグ、分岐ごとの独立性、解除・再検出・停止後保持・新セッションのリセットを確認。
- 🟢 [Done] ライト／ダーク両モードのSwiftUI描画を確認。ライトモードの数値コントラストを調整後、メーター関連4テストとDebug最終ビルド成功。
- 🟢 [Done] [描画・検証記録](../measurements/audio-meter-alerts-2026-11-11/verification.json)、[ライト](../measurements/audio-meter-alerts-2026-11-11/light.png)、[ダーク](../measurements/audio-meter-alerts-2026-11-11/dark.png)。

検証ログ：`/tmp/meter-alert-tests.log`、`/tmp/meter-alert-build-final.log`、`/tmp/meter-alert-visual-tests.log`。SwiftUI描画サンプル：`/tmp/ongaku-meter-alert-review/light.png`、`/tmp/ongaku-meter-alert-review/dark.png`。

- ⭕️ [Pending] 実機入力キャプチャでのクリップ警告の確認、インストール版への反映。
