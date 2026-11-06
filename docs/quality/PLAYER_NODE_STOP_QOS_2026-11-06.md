# Macプレイヤーノード停止のQoS境界 — 2026-11-06

## 受信した警告と範囲

ユーザーのThread Performance Checker警告はPlaybackController.swiftの旧2428行、`primaryPlayerNode.stop()`を指す。MainActorから同期停止し、内部のDefault QoS処理を待つ経路を確認した。下位スレッドの完全なスタックは提供されておらず、実際の停止時間やOS内部の待機理由を断定しない。

Appleの[AVAudioPlayerNode仕様](https://developer.apple.com/documentation/avfaudio/avaudioplayernode)では、stopはスケジュールを取り消す操作であり、完了コールバックから直接stopしない注意がある。元のコールバックもMainActorへ非同期配送していたため、この注意への違反が原因だったとは扱わない。

## 変更

- `PlayerNodeStopCoordinator`を追加。MainActorは停止要求・完了状態を所有し、`AVAudioPlayerNode.stop()`だけを専用のDefault QoSキューで行う。UIからsync／semaphore／joinによる待機を追加しない。
- バッチはengine・node・audio fileを停止完了まで保持する。`@unchecked Sendable`はこの停止専用バッチだけに限定し、同じノードのschedule・detach・reconnectは停止完了まで行わない。
- 既知の未スケジュールノードは重複停止しない。各scheduleSegmentの前に所有権を更新し、重なった停止要求はノード単位で統合する。
- TransportOutputEnvelopeのbusy状態に資源退役を含め、排出後の停止完了まで次のグラフ操作を待つ。操作IDで古いseek/load/pause完了を拒否し、最新操作だけを反映する。
- クロスフェードは終了側を無音にして非同期停止し、再生中の次曲は継続する。終了側の停止完了前に再利用しない。停止中のノードへのrender-clock／audible照会やゲイン更新も避ける。
- 通常版とApp Store版のXcodeプロジェクトへ新しい実装を登録。新しいUI文言・同期プロトコル・DSPアルゴリズム変更はない。iPhone版は独自のセッション経路を使用するため動作変更なし。

## 最終コードの検証

- 🟢 [Done] `swift test --jobs 2 --filter 'PlayerNodeStopCoordinatorTests|TransportOutputEnvelopeTests'` — 8 tests / 2 suites成功。停止を人工的にブロックしても別のMainActor操作が進むこと、重複・重なった要求が必要なノードすべての停止完了を待つことを確認。
- 🟢 [Done] 通常／true-peakの44.1/48/96kHz PCMのフェード・無音排出を含む既存試験が成功。
- 🟢 [Done] `swift test --skip-build --filter PlaybackTransportIntegrationTests` — 16 tests成功。実エンジンで停止再開、seek/load/pause競合、旧EOF、曲末・リピート・クロスフェード、解析後のゲイン参照、グラフ再利用を検証。
- 🟢 [Done] 新しい`delayedPlayerStopOwnership`は停止ワーカーの実行を保留し、ソース保持、UIからの追加操作、最新選曲の一時停止のみが反映されることを確認。
- 🟢 [Done] XcodeのOngakuDesktop／OngakuDesktopAppStore両scheme、Debug、CODE_SIGNING_ALLOWED=NO、並列数2でbuild成功。pbxprojのplutil検証とdiffチェック成功。

初回の実エンジン16件実行では、1つのクロスフェード試験の2条件で8 issuesが発生した。その後の単独実行と最終コードの16件再実行は成功。初回中にホストの高負荷を観測したが、失敗原因を負荷だけと断定しない。試験の期待値・期限は緩和していない。[初回失敗と最終結果のログ・ソースハッシュ](../measurements/player-node-stop-qos-2026-11-06/)を保持する。

## 実機確認

⭕️ [Pending] ユーザーのMacでXcode Thread Performance Checkerを有効にして、連続再生／一時停止・seek・曲替え・クロスフェード・終了を確認し、同じ警告が再発しないことを確かめる。署名済み配布版、実際の出力機器・スリープ／復帰も未確認。自動試験成功からOS内部の優先度警告が一切発生しないことは保証しない。
