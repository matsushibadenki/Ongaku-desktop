# 製品機能表の矛盾と検証記録の鮮度 — 2026-11-06

## 実装と試験による修正

- M3U/M3U8書き出しは `Sources/OngakuDesktop/PlaylistTransfer.swift` の `PlaylistTransferService.exportData` に実装され、`PlaylistTransferTests.exportsM3U` / `previewsM3UDifferences` が順序・相対パス・重複・未検出を検証する。M2のDoneとM5のLaterが矛盾していたため、M5のM3U部分をDoneへ分離。共有シート・音源パッケージはLaterを維持。
- 音響解析の永続化は `AudioFeatureAnalysis.swift` の `AudioFeatureCache.save/load` と `AudioFeatureAnalysisTests.cacheRoundTripAndInvalidation` で、SHA-256変更時の無効化を含め確認。M4のLaterから解析キャッシュ部分をDoneへ分離。波形表示キャッシュはLaterを維持。
- `docs/quality/M3_LIBRARY_QUALIFICATION.md` の古いDone表を、現在未達のRelease実画面の初回2秒・検索p95 300ms目標と区別してNextへ修正。過去のロード／索引単体の測定値は当時の記録として保持。
- DRM API可否、48時間耐久、地域・アカウント別確認は実機待ちのPending。companion能力表示の未実装UIはLater、実際のMusic資産の能力確認はPendingに分離。

## ソースハッシュ照合

両リポジトリに置かれた過去のフラットなSHA-256 JSONを、参照先リポジトリを解決して照合。各リポジトリ38参照のうち31一致、7変更、解決不能0。重複記録を含み、38個の独立した機能の検証件数ではない。ハッシュ一致は挙動の合格を意味しない。

変更された参照:

- `Ongaku-desktop/Sources/OngakuDesktop/LibraryStore.swift` — 記録 `docs/measurements/fallback-cache-retirement-2026-10-22/source-sha256.json`
- `Ongaku-desktop/Tests/OngakuDesktopTests/LibraryPresentationTests.swift` — 記録 `docs/measurements/fallback-cache-retirement-2026-10-22/source-sha256.json`
- `Ongaku-desktop/Sources/OngakuDesktop/EffectsRackView.swift` — 記録 `docs/measurements/effect-tab-retention-2026-10-28/source-hashes.json`
- `Ongaku-desktop/Sources/OngakuDesktop/DeviceChunkTransfer.swift` — 記録 `docs/measurements/validated-chunk-snapshots-2026-10-24/source-sha256.json`
- `Ongaku-desktop/Sources/OngakuDesktop/PhoneSyncController.swift` — 記録 `docs/measurements/validated-chunk-snapshots-2026-10-24/source-sha256.json`
- `Ongaku-desktop/Sources/OngakuMobile/MobileSyncController.swift` — 記録 `docs/measurements/validated-chunk-snapshots-2026-10-24/source-sha256.json`
- `Ongaku-desktop/Tests/OngakuDesktopTests/M8TransferResilienceMilestoneTests.swift` — 記録 `docs/measurements/validated-chunk-snapshots-2026-10-24/source-sha256.json`

- 🟠 [Next] これらの過去の性能値を現行の実測として再使用しない。対応試験と必要な性能測定を再確認し、元記録は上書きしない。
- ⭕️ [Pending] 実画面・実機・署名・Musicサービスが必要な確認。

[機械的な照合結果](../measurements/roadmap-audit-2026-11-06/historical-source-freshness.json)。全ROADMAPの意味的照合は未完了。
