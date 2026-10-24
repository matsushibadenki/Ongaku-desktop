# Ongaku Desktop ロードマップ

## Validated chunk transfer snapshots — 2026-10-24

- 🟢 [Done] A4 preparation: admit one immutable validated descriptor per Desktop/iOS companion chunk session and reuse it for payload reads/checkpoint accepts. Preserve per-chunk SHA-256, size/index checks, final whole-file verification and unchanged wire DTOs. Add session/checkpoint-shape rejection and keep legacy receive error classification. The separate main iPhone app uses another whole-resource path and has no runtime changes. See [scope, integrity tests and measurements](quality/VALIDATED_CHUNK_SNAPSHOTS_2026-10-24.md).
- 🟢 [Done] Debug and Release each pass 32 transfer/protocol tests, including mutable-copy isolation, malformed/corrupt inputs, source changes, persisted resume/new session ID, empty files and final-file corruption. Normal Mac Debug, Universal Mac App Store Release and same-project iOS Simulator companion builds pass with signing disabled; whitespace checks pass.
- 🟢 [Done] Matched Release sender-preparation comparison at default 256 KiB / 4096 chunks / 64 requests: median wall 244.900 → 13.255 ms (94.6% shorter), CPU 240.775 → 13.219 ms (94.5% lower), three alternating paired samples. This excludes network/encoding/receiver persistence and is not an end-to-end transfer speedup or device-energy result.
- 🟠 [Next] Complete A4 actor ownership of file I/O/checkpoints/session state and cancel/disconnect generations. Missing-index/progress scans and checkpoint persistence still need profiling. First full audio-rack startup and A3 memory/UI targets remain separate unfinished work.
- ⭕️ [Pending] Installed Mac/physical iPhone companion transfer of actual large music files, pairing/network loss/pause/cancel/resume, storage permissions, end-to-end throughput and sustained energy. Main-iPhone cross-device behavior and existing audio/DAC qualification are not established by the shared-model tests. No remote CI result is claimed for unpublished changes.


## Monotonic gain acknowledgement and PCM startup qualification — 2026-10-22

- 🟢 [Done] Both candidate gain hosts now use a two-second monotonic uptime deadline instead of 500 nominal 4 ms callbacks. At the next available control callback, reject stale ownership, prefer an actually rendered endpoint, and stop I/O before committing if acknowledgement is still missing after expiry. This does not provide a hard real-time stop while MainActor is blocked; ordinary activation remains gated. Shared Swift source stays byte-identical. See [implementation, rejected startup alternatives and evidence](GAIN_DEADLINE_AND_STARTUP_2026-10-22.md).
- 🟢 [Done] Both source copies pass five actual-AU delayed-control/zero/ownership/pause cases and a deadline-removal negative control; add/run the portable Desktop CI gate locally. Default connected/output suites pass nine tests. The combined Mac Release candidate passes four gain, five output and fourteen actual transport/CD/EOF tests in isolated processes. The optimized iPhone Simulator candidate completes all four phases with 35 PASS observations.
- 🟢 [Done] Extend initial-rack audit through actual engine/player start and PCM, including two-channel EQ attenuation. Both host racks pass all ten prefixes. Reject slower incremental/preallocation trials and disconnected-island apparent speedups; no experimental routing was adopted and no cold-start speedup is claimed.
- 🟠 [Next] Reduce the remaining first full-rack initialization with a valid source/route design and complete gain/tail/EOF gates. Other callback-count recovery loops and ordinary activation still require their own qualification.
- ⭕️ [Pending] Physical iPhone/Mac/DAC listening, output/rate/session/sleep/background/UI contention and sustained thermal qualification. Published CI and installed-app results are not established by local tests.


## Retire fallback search memory after verified SQLite recovery — 2026-10-22

- 🟢 [Done] A3: retire obsolete fallback text and Track snapshot storage after SQLite passes parity and routing returns to the index. Check cancellation, library identity and covered tracks revision so old completion cannot evict a newer/different snapshot. Index failure can reconstruct fallback normally. No audio, catalog schema, localization or separate iPhone-runtime change. See [implementation and evidence](quality/FALLBACK_CACHE_RETIREMENT_2026-10-22.md).
- 🟢 [Done] Pass 26 presentation/search-routing/SQLite tests, including actual index failure/recovery and stale/cancelled retirement. In three Debug 100,000-track cycles, retire 7,366,666 retained UTF-8 bytes and 100,000 worker-owned Track references in 3.4–7.8 ms; verify EN/JA/zh-Hans reconstruction. These are logical cache counts, not RSS savings or the 512 MiB product gate.
- 🟢 [Done] Normal Mac Debug and Universal Mac App Store Release builds pass with signing disabled; whitespace checks pass.
- 🟠 [Next] Continue A3 initial/steady-state memory and actual display/search profiling under playback/index updates. Keep first full audio-rack initialization and A4 transfer actor ownership as separate unfinished work.
- ⭕️ [Pending] Installed-app large-library RSS/physical-footprint and UI qualification, real user libraries and existing physical-audio checks. Remote CI is not claimed for unpushed local changes.


## Connected gain CI state waits — 2026-10-22

- 🟢 [Done] Fix the reported GitHub run's fixed-sleep assumptions in the Desktop manual-render gain tests. Wait for actual ramp issuance/completion and transport/fallback state with bounded deadlines; deliberately delay effect control callbacks by 50 ms. Preserve exact PCM/frame/zero/retained-tail/cancellation safety assertions. No app/runtime/DSP or iPhone algorithm changes. See [cause and verification](quality/CI_GAIN_CONTROL_WAIT_2026-10-22.md).
- 🟢 [Done] Pass all four connected-gain tests after compilation, then pass three consecutive runs of the exact CI skip-build command; whitespace checks pass. Preserve local evidence and distinguish developer versus runner toolchains.
- ⭕️ [Pending] GitHub rerun after publication; existing physical iPhone/Mac/DAC qualification remains unchanged.


## Initial graph setup and compatible reload reuse — 2026-10-22

- 🟢 [Done] Remove premature Mac constructor parameter writes and iPhone's nil-format constructor connection; connect/apply once with the actual format. Share complete format/route identity and paused-state reset verbatim. Mac compatible explicit reloads retain the prepared graph, but replace source schedules, normalization and EOF ownership; format/route/recovery/destructive changes rebuild. Final output uses the device-side format rather than the previously negotiated engine input. See [implementation, matched timings and evidence](GRAPH_REUSE_AND_COLD_START_2026-10-22.md).
- 🟢 [Done] Preserve transport zero acknowledgement/downstream drain; clear retired source/SRC/reverb/peak state without deallocating compatible render resources. Factory-reverb preset/mix/bypass remain unchanged; unknown presets require reconstruction. Both host copies pass 12 full-rack silence-after-reload cases with exact zero residual and a required failing no-reset control, plus 12 live-tail cases and negative controls. Add/run the Desktop portable retained-state CI gate locally; remote CI is not claimed.
- 🟢 [Done] Pass final 14 actual Mac controller/CD/transport/EOF tests in ordinary and gain+true-peak configurations, nine connected-gain/output tests in both builds, shared format-key regressions and 35 observations across four completed iPhone Simulator engine/ViewModel phases. Correct the prepared-PCM format-miss path to stop prepared I/O before reconnecting. Retain existing gain/true-peak activation gates.
- 🟢 [Done] Complete three-process rotated before/current timing matrices and a same-source/output-format current-controller retained-versus-forced-rebuild control. Mac retained reload is approximately 0.1 s; report exact control results and CPU/process peak RSS in linked evidence. Mobile now connects once per fresh instance; total first-ready improvement is not established.
- 🟠 [Next] Reduce remaining first full-rack initialization/traversal cost (multi-second and variable; see report), preserving all waveform/gain/tail/transport/EOF gates. Constructor cleanup and reload reuse do not complete cold-start optimization; a unity-mixer removal experiment showed no useful benefit and was not adopted.
- ⭕️ [Pending] Physical iPhone/installed Mac/DAC launch and listening, actual Music-managed CD files, route/rate/session changes, sleep/background/UI contention and sustained thermal/energy qualification. Development results do not establish resolution of intermittent physical-device symptoms.

## Matched startup cost and retained render resources — 2026-10-22

- 🟢 [Done] Compare ordinary / common gain / gain+true-peak under matched optimized, sequential rotated runs: three process launches per variant, 44.1/96 kHz stereo sources, fixed 96 kHz rack, initial load/reload/pause/resume, wall/CPU time and process peak RSS. Repeat the full Mac matrix after correction; complete the Simulator matrix. See [method, raw evidence and results](STARTUP_COST_COMPARISON_2026-10-22.md).
- 🟢 [Done] Remove Mac true-peak's repeated initialization: pause I/O and reset lookahead while retaining prepared resources during protected rescheduling. At 44.1 kHz, initial-ready median improves 5064 → 2468 ms and resume 2934 → 64 ms; at 96 kHz, 5589 → 2419 ms and 2703 → 66 ms. Preserve zero acknowledgement/drain, tails, fresh-render and EOF ownership; destructive cleanup still stops the engine. iPhone already uses the compatible pause policy (Simulator resume about 90–100 ms). Pass 9 gain/output tests and all 12 actual Mac controller/CD/EOF tests, including paused-resource retention and silence-after-reset checks. No physical-device claim.
- 🟢 [Done] Complete compatible Mac reload reuse and shared format/route/state qualification in the follow-up above. Remaining first full-rack initialization is explicitly tracked there as [Next]; ordinary activation remains gated.
- ⭕️ [Pending] Physical iPhone/Mac/DAC cold launch, real Music-managed tracks, output-rate/route/session changes, sleep/background/UI contention, listening and sustained thermal/energy qualification before ordinary activation. Simulator and muted fixture timing do not qualify these.

## Connected audio-thread protection — 2026-10-22

- 🟢 [Done] Connect independent common effect/transport gain Audio Units to both actual playback graphs under `ONGAKU_ENABLE_AUDIO_THREAD_GAIN`. Preserve user/normalization gain, SRC and peak protection; release topology/drain only after rendered-zero acknowledgement, retain wet history and reject stale completions. Restore allocation intent behind a muted transport gate; stop I/O before committing if acknowledgement never arrives. Ordinary activation remains gated. See [integration contract/results](AUDIO_THREAD_GAIN_INTEGRATION_2026-10-22.md).
- 🟢 [Done] Pass 4 connected-graph/Space/cancellation/fallback tests and all 12 real Mac controller/EOF tests in gain-only and gain+true-peak builds; both apps' connected 144-case handoff and 12-case tail matrices with negative controls; 36 observations across four actual iPhone engine/ViewModel Simulator phases; normal-path regressions and candidate/ordinary builds. Isolate the new real-time polling suite in Desktop CI. The aggregate Simulator budget is extended for four unchanged audits; initial 180 s wrapper timeouts are documented rather than counted as passes.
- 🟢 [Done] Include downstream SRC/true-peak latency in the post-zero drain. Final follow-up passes 8 combined output/connected-stage tests, 2 actual Mac pause/crossfade tests, 9 actual iPhone Simulator recovery observations and the legacy transport/PCM guards; retain source resources until draining completes. Full-matrix versus final targeted verification is distinguished in the integration report.
- 🟢 [Done] Complete matched sequential ordinary/gain/gain+true-peak startup profiling and remove repeated Mac initialization; see the startup-cost section above. Earlier unmatched suite totals are retained as historical correctness results.
- ⭕️ [Pending] Physical iPhone speaker/headphone and Mac/DAC listening, live route/session/sleep/background contention and sustained thermal/energy checks, including actual Music-managed CD files. Keep ordinary gain and true-peak activation behind their qualification gates; development results do not establish resolution of the prior intermittent physical-iPhone report.


## Shared audio-thread gain stage — 2026-10-22

- 🟢 [Done] Implement and link a byte-identical mono/stereo gain Audio Unit in both apps as the first stage of the common audio-thread protection priority. Per-frame cosine attenuation continues without UI timer updates, retargets from the last rendered gain, acknowledges actual rendered endpoints and invalidates stale completion across reset. This component is not yet connected to the normal playback graphs. See [contract and evidence](AUDIO_THREAD_GAIN_VALIDATION_2026-10-22.md).
- 🟢 [Done] Both copies pass the same 72 real-AU waveform cases, concurrency/sanitizer and control-step negative checks; the shared core passes ThreadSanitizer. Existing true-peak checks, mobile/Desktop Debug, Desktop App Store Release and Swift Package builds pass. Add the portable Desktop waveform gate to its GitHub workflow; remote CI is not claimed for unpushed changes.
- 🟢 [Done] Complete the internal candidate-path controller integration and connected-graph gates on 2026-10-22; see the integration section above. Ordinary activation still requires startup-cost and physical-device qualification.
- ⭕️ [Pending] Qualify connected graphs on physical iPhone/Mac outputs under gestures, interruption/background/route changes and sustained thermal/energy load. Offline AU tests and iPhone compilation do not establish those results.


## Restart after automatic library repair — 2026-10-22

- 🟢 [Done] After successful folder-based automatic repair and saved folder authorization, launch a fresh Desktop instance and terminate the old instance only after launch succeeds. Show localized restart progress; coalesce duplicate requests, suppress recovery-triggered reloads in the outgoing process, and keep the app open with retry when launching fails. Cancellation/repair failure does not restart; confirmed recovery creation follows the same success flow.
- 🟢 [Done] Pass 26 application-settings/relaunch tests, ordinary Debug and App Store Release builds, EN/JA/zh-Hans/whitespace checks, and real macOS process handoff probes both outside and inside App Sandbox. See [verification](quality/LIBRARY_RECOVERY_RELAUNCH_2026-10-22.md). Mobile runtime is unchanged.
- ⭕️ [Pending] Verify the user's affected folder, external-volume/bookmark restoration and main-window library contents across the automatic restart in the installed signed app. Isolated process probes do not establish the complete user-library recovery flow.

## Mobile foreground track-end follow-up — 2026-10-21

- 🟢 [Done] Mobile's continued foreground-stop report led to a common-mode EOF timer, separate source-progress monitoring when output rendering remains healthy, and consumption of accepted EOF before an unexpected-stop recovery seek. Desktop already uses a common-mode timer and schedule-scoped completion; no Desktop runtime change is made in this follow-up.
- 🟢 [Done] Mobile passes production timer/progress/queue tests with negative controls, recovery-delay/session-activation EOF checks, existing queue/prepared-EOF regressions, ordinary Simulator builds and actual ViewModel/engine next/repeat/final-stop verification with completion delivery removed. Evidence: mobile `docs/TRACK_PROGRESS_RECOVERY_2026-10-21.md`.
- ⭕️ [Pending] Verify the actual iPhone Music-managed CD tracks and identify local/system playback on recurrence. Desktop frozen-source behavior, physical-device/route/session parity and Music-owned playback are not established by the mobile generated-file tests. The reported iPhone occurrence is not yet reproduced on hardware.

## Original source information in track details — 2026-10-21

- 🟢 [Done] Add original extension/codec, source sample rate/bit depth/channels, estimated bitrate, file size, protected-content status and metadata-read outcome/error to TrackInspector. Show the current DSP rate/channels separately for the playing track. Mobile shows the same source metadata plus Music source-URL presence. Both use a byte-identical asynchronous reader; unavailable metadata is Unknown and never substituted with the decoded/processing format.
- 🟢 [Done] Pass mobile's eight mono/stereo WAV/AIFF/AAC/ALAC source-metadata cases, missing URL/file and misleading-extension checks; verify shared-source parity, mobile/desktop Debug and desktop Store Release builds, all three locales and whitespace. Inspect mobile SE / 16 Pro Max success/error layouts. Mobile validation: `docs/SOURCE_FILE_INFORMATION_2026-10-21.md`.
- ⭕️ [Pending] Real Music/CD/cloud/protected/provider asset metadata, relinking, permissions and physical-device/accessibility qualification. Metadata availability does not establish playback/effect availability.

## Desktop CD-import mono / meter availability — 2026-10-21

- 🟢 [Done] Confirm desktop local-file failures report an error rather than silently switching into MusicKit. Reproduce a different defect: mono CD files enter a one-channel rack and stereo-only Audio Units raise Core Audio -10868, even when bypassed. Reproduce in the unmodified PlaybackController, then match iPhone's minimum-two-channel source-mixer policy and correct DSP channel diagnostics while preserving original source metadata/seek/EOF clocks.
- 🟢 [Done] Rip generated CD-quality sources through production AudioCDRipper into ALAC/AIFF/WAV/AAC × mono/stereo (8 conditions). Verify real muted local playback and meter-tap attachment; offline production EQ renders yield nonzero RMS/spectrum and measured effect attenuation. All 12 isolated transport/EOF tests pass. See [evidence](quality/CD_PLAYBACK_AVAILABILITY_2026-10-21.md).
- 🟢 [Done] Pass ordinary Xcode Debug and Universal Mac App Store Release app builds and whitespace checks.
- ⭕️ [Pending] Physical CD-drive/Music-library assets, speaker/headphone/DAC listening, mono centering/level, migration/sync, route/rate changes and real EOF/crossfade qualification. The mobile user's exact asset-open failure remains unconfirmed; the two fixes address distinct demonstrated paths.

## Mobile CD-import availability coordination — 2026-10-21

- 🟢 [Done] Mobile now retries an unprotected source-open failure through the existing lossless/PCM snapshot path before handing playback to Music. Retain the successful copy for playback and quality upgrades; reject stale/cancelled graph loads, preserve DRM/error-stage boundaries and distinguish unprotected system playback in all three locales. Desktop runtime/DSP and shared effect algorithms are unchanged.
- 🟢 [Done] Mobile passes retry/lifetime/cancellation tests and six generated 44.1 kHz / 16-bit mono/stereo WAV/AIFF/ALAC PCM comparisons, prepared-EOF/foreground recovery regressions with negative controls, the ordinary iOS Simulator Debug build and localization/whitespace checks. See mobile `docs/CD_IMPORT_METER_RECOVERY_2026-10-21.md`.
- ⭕️ [Pending] Verify the user's actual Music-managed CD songs on iPhone, including real meter samples, audible effects, source-open diagnostics, next/repeat and quality handoff. Generated assets do not establish the exact device/provider failure or the availability of cloud-only assets.

## Mobile VU response coordination — 2026-10-20

- 🟢 [Done] Mobile adopts Desktop-inspired 60 Hz meter polling and 65 ms attack / 220 ms release, plus monotonic timing and common-mode timer delivery during tracking. Its 15 Hz spectrum publication, fixed -18 dBFS alignment, face geometry and audio DSP/tap windows are retained. Desktop meter runtime remains unchanged; differing scales/mono-stereo aggregation and tap windows still prevent a claim of identical readings.
- 🟢 [Done] Mobile passes the production timer tracking/invalidation and analytical 30/60/120 Hz step-response regression, calibration/budget checks and ordinary arm64/x86_64 iOS Simulator Debug build. See the mobile repository's `docs/VU_METER_RESPONSE_VALIDATION_2026-10-20.md`.
- ⭕️ [Pending] Matched-signal Mac/iPhone measurement and physical iPhone motion, gestures, playback transitions, frame pacing and power/thermal qualification. Mobile's 4096-frame tap and Mac's 1024-frame tap remain distinct.

## CI real-engine test isolation — 2026-10-20

- 🟢 [Done] Diagnose run 39384131607: the resume assertion fails while a 10-second real audio fixture overlaps roughly 140-second cross-suite MainActor work; the unchanged failing test passes alone in 4.388 seconds. Separate all real-engine transport/track-end tests into a sequential CI process, retaining every test/assertion and all other quality gates. App binaries and shared iPhone audio behavior are unchanged. See [evidence](quality/CI_TRANSPORT_ISOLATION_2026-10-20.md).
- 🟢 [Done] Pass both local partitions: 372 non-real-engine tests plus all 11 serialized real-engine tests, preserving the complete 383-test scope.
- 🟢 [Done] GitHub Xcode 26.6 run 39385620014 completes successfully: all 372 + 11 tests, M3 performance budget, Mac UI/App Store builds, Sandbox/updater checks and iOS companion compile gate pass.
- ⭕️ [Pending] Existing physical playback, competing-app interruption, EOF and high-load listening qualification.

## Release 0.1.11 / CI effect-rack teardown — 2026-10-20

- 🟢 [Done] Bump desktop 0.1.10 (16) to 0.1.11; after the reported CI crash, reserve repaired build 18 and do not submit the already uploaded build 17. Prepare EN/JA/zh-Hans release notes.
- 🟢 [Done] Identify the CI runtime exclusivity trap in SwiftUI graph destruction: detach synchronously published scroll state into the invalidating graph. Clear native ownership silently at teardown; retain change notifications for the live/reconnected graph. The new regression fails before repair and all 13 input tests pass after repair. See [CI evidence](quality/CI_EFFECT_RACK_TEARDOWN_2026-10-20.md).
- 🟢 [Done] Verify repaired archives and all GitHub Xcode 26.6 CI gates (run 39382386097), including 383 tests, M3 budgets, both Mac builds, Sandbox checks and the repaired iOS companion target. Publish v0.1.11 signed/notarized Universal DMG and five deltas after comparing all seven asset sizes/SHA-256 digests; update the Sparkle feed after asset publication. See [release record](quality/RELEASE_0.1.11_2026-10-20.md).
- 🟢 [Done] Upload repaired build 18, save EN/JA/zh-Hans release information and the explicitly approved export-compliance response, and submit to App Review. Confirm Waiting for Review with automatic release after approval.
- ⭕️ [Pending] Apple review/public availability and existing physical-device qualification.

## EQ grouping and Synth-inspired knobs — 2026-10-20

- 🟢 [Done] Refine pastel panel gradients to start at the opaque 50% white/theme midpoint and end at the original theme color, with two evenly distributed stops. Apply the tinted highlight to shared surface edges too; keep neutral light/dark gradients and metal knob caps unchanged. Pass the existing production-rack rendering/interaction test and Xcode Debug build. Capture all four pastel themes and inspect green/pink. See [updated green](measurements/pastel-gradient-2026-10-20/green.png), [pink](measurements/pastel-gradient-2026-10-20/pink.png) and [validation](measurements/pastel-gradient-2026-10-20/validation.txt).
- 🟢 [Done] Group all 14 EQ parameters into Filter, LF, LMF, HMF, HF and Output using the existing parameter-group metadata. Add EN/JA/zh-Hans section labels and separators; keep each band's Gain/Frequency/Q/Focus together, with four controls on one row when width permits and wrapping within its section on narrow cards.
- 🟢 [Done] Reference Synth's rendered panel and Metal knob construction: black ridged grip, machined silver cap and ivory index. Draw the appearance in SwiftUI at the existing control size; use the current appearance's playback accent for active value ticks, numeric values and keyboard focus. Preserve neutral disabled states, native input ownership and eager layout. Shared parameter keys, values, DSP and iPhone runtime are unchanged.
- 🟢 [Done] Pass all 12 input/layout tests, including complete EQ membership and the production-rack 108 knob / 72 switch action matrix across EN/JA/zh-Hans, Basic/Pro and 420/900 pt windows. Pass Xcode Debug build, localization syntax and whitespace checks. Render light/dark and all four pastel appearances; inspect section layout and accent rendering. See [validation and screenshots](EFFECT_RACK_INPUT_VALIDATION.md#eq-grouping-and-metal-knobs).
- ⭕️ [Pending] Confirm physical trackpad operation, display readability and live-playback rendering load on the affected Mac. The existing click-time movement confirmation remains Pending.

## Effect rack input ownership — 2026-10-20

- 🟢 [Done] Reproduce actual layout movement after parameter clicks: the Japanese mode Picker changes from 81 pt to 33 pt high and shifts the controls below it; the lazy parameter grid also changes document height by 1–3 pt. Separate the mode title from the segmented Picker, give the toolbar its natural fixed height, move the explanation to an accessible information tooltip, and measure all parameter rows eagerly. Also handle unbounded hosting-view width probes without crashing.
- 🟢 [Done] Validate the production EffectsRackView with PlaybackController in EN/JA/zh-Hans, Basic/Pro and 420/900 pt windows: 108 knob clicks and 72 module-switch actions across 36 scroll positions preserve picker geometry, document height and scroll origin, with knob position checks and actual value/action assertions. All 11 input regression tests and the Xcode Debug build pass. Inspect Japanese Basic/Pro renders at both widths. See [layout evidence](EFFECT_RACK_INPUT_VALIDATION.md#follow-up-mode-toolbar-and-document-layout).
- ⭕️ [Pending] Confirm that clicking knobs and switches no longer grows the mode toolbar or moves the screen on the affected physical Mac. Previous focus/scroll-only fixes were incomplete; passing injected-event tests is not physical-device confirmation.
- 🟢 [Done] Replace the unsuccessful per-knob event guards with a single rack input router. Following the updated interaction request, two-finger gestures scroll from both GUI and non-control space, while GUI values/clicks stay locked through the gesture and momentum. GUI hover remains responsive while idle; GUI clicks/drags freeze the clip origin, including focus-driven movement. Discrete mouse wheels and scrollbars scroll; all GUI value changes/clicks are blocked while scrolling.
- 🟢 [Done] Reproduce the overbroad hit-region defect with real AppKit geometry: an 84 × 84 control's `visibleRect` extended to 383 × 250, including adjacent space. Intersect `bounds` with `visibleRect`, including partially clipped controls. Keep the ScrollView configuration stable, cancel ownership on window deactivation/detach, and constrain frozen positions when a tab changes document size.
- 🟢 [Done] Replace the knob's SwiftUI focus/drag gesture path with an AppKit input surface, removing the click-triggered SwiftUI scroll-to-focus request. Preserve circular drag, double-click reset, arrow keys and SwiftUI accessibility adjustments. A rendered-knob test dispatches clicks/drags through NSWindow at normal and partially clipped positions and checks every observed clip origin, not just the final position.
- 🟢 [Done] Follow up on intermittent click-time movement: pointer-owned knobs now reject `scrollToVisible` requests through mouse-up and delayed focus callbacks, and reject drag autoscroll. Acquire router protection from the native control before focusing, including clicks that bypass the event monitor. Strengthen the rendered test with a published value and LazyVGrid redraws; the pre-fix reveal-rejection assertion fails and the repaired version passes. The physical symptom remains Pending.
- 🟢 [Done] Earlier verification passed 10 input-routing regression tests with AppKit views and injected events, including actual SwiftUI/NSScrollView bridge attachment, plus the Xcode Debug app build and whitespace checks. See [verification and limits](EFFECT_RACK_INPUT_VALIDATION.md). Earlier marker/routing tests did not exercise the actual knob click/focus path and did not establish physical resolution.
- ⭕️ [Pending] Confirm the updated interactions (including two-finger scrolling starting over GUI) on the user's physical trackpad, including click-drag, hover, momentum, clipped controls, fast tab changes and ordinary scrolling. Qualify mouse hardware/driver variants: phased or precise events use touch-style routing; discrete wheel events use wheel routing. AppKit event flags do not identify every physical device unambiguously.

このファイルをOngaku Desktopの唯一の開発ロードマップとして管理する。

2026-09-05再設計: [全体設計レビュー](ARCHITECTURE_REVIEW_2026-09-05.md)と[ADR-0003](adr/0003-stabilization-and-component-boundaries.md)に基づき、機能拡張より保存・応答性・実機品質を優先する。

## Mac / iPhone track-end ownership parity — 2026-10-20

- 🟢 [Done] Reproduce and repair four Mac local-playback defects: incoming EOF discarded before preroll promotion, a duplicate callback advancing another same-node repeat, delayed configuration recovery applying the old song's position to a new song, and an empty paused schedule selecting the next song. Give every segment a distinct ID, retain early incoming EOF, scope/cancel recovery per segment and honor newer pause/stop/selection intent.
- 🟢 [Done] Align both apps on one completion per schedule and rejection of stale work. Verify rejected Mac preroll preserves audible EOF; retain Mac AVAudioEngine SRC / file-preroll and iPhone CPU Precision Sinc ownership. No iPhone runtime changes are needed in this follow-up.
- 🟢 [Done] Pass all 370 Mac Swift tests, including the expanded 11-test serialized real-controller suite, and the same 11 tests under the existing true-peak candidate flag. Confirm real 10 ms tails reach next/repeat-one/queue-wrap/album-wrap/final stop. Pass ordinary Debug and App Store Release builds; rerun iPhone's 3 prepared-EOF groups, 10 queue/intent cases and 13 recovery groups with their negative controls. See [results, pre-fix evidence and limits](TRACK_END_PARITY_VALIDATION.md).
- ⭕️ [Pending] Confirm the user's physical-iPhone Music-managed non-DRM failure is resolved. On Mac, qualify real output/rate changes, sleep/wake at EOF, competing apps, MusicKit/account playback, speaker/headphone/DAC listening and heavy UI/CPU load. Development-Mac tests used muted generated local files and injected notification/callback ordering; they do not establish those physical/OS scenarios or authorize ordinary true-peak activation.

## CI playback completion concurrency repair — 2026-10-19

- 🟢 [Done] Fix the [quality job failure](https://github.com/matsushibadenki/Ongaku-desktop/actions/runs/39193024718/job/117869722607): Xcode 26.6 rejected non-Sendable `AVAudioPlayerNode` captures in normal and prerolled completion callbacks. Pass `ObjectIdentifier` values across callbacks and compare identity on MainActor; retain generation, track and stopping guards. Audio nodes remain owned by the controller. The runner-capacity notice is separate from the compiler failure.
- 🟢 [Done] On local Xcode 27.1, pass the CI `build-for-testing` command and Mac App Store Release build with fresh derived-data directories; the reported node-capture/data-race diagnostics are absent. Pass all 363 Swift tests across 40 suites, including real-controller transport, crossfade/repeat-one and stale outgoing-EOF checks. This does not claim completion of every CI step or the Xcode 26.6 run.
- 🟢 [Done] GitHub Xcode 26.6 run 39382386097 confirms the completion-callback concurrency repair and all compile gates. Physical playback/listening qualification remains Pending in the audio sections below.

## Effect tails and latency-change protection — 2026-10-19

- 🟢 [Done] Mark the stateless tail scheduler `nonisolated` in both apps so default-argument evaluation is valid under iPhone default MainActor isolation; callbacks still execute on the main queue. Rebuild iPhone Simulator and Mac Debug successfully with no `scheduleOnMain` actor-isolation diagnostic (2026-10-19). Device listening checks below remain Pending.
- 🟢 [Done] Retain CPU upsampling. Share Space/Gloss/Body/Warm wet-input gating and bounded tail release: 24 ms input fade, 160 ms history hold, 240 ms wet release; cancel stale callbacks on ON/rebuild and clear history after silent transport drain. Idle wet units are bypassed.
- 🟢 [Done] Protect changed algorithmic latency at zero output before restoring; include intensity-zero and Space-amount-zero boundaries. Align Mac Warm's direct bypass and Flutter gain behavior with iPhone; keep Mac's final sample limiter/−1 dB trim fixed during user-effect OFF, preserving safety and latency through tails.
- 🟢 [Done] Qualify 144 shared-rack Sinc/Space/Gloss handoffs, 12 effect/rate tail cases from each repository, latency-state/cancellation regressions, 96 Mac transition PCM cases, transport/gain-reference regressions and all three app builds. Correlation lag is 0 output samples at measured resolution; completed-window level difference stays within 0.039 dB. See [verification, evidence and scope](TAIL_LATENCY_VALIDATION.md).
- 🟢 [Done] Implement and qualify the first shared audio-thread gain component on 2026-10-22; controller integration remains Next in the section above. Current shipping mixer writes remain sensitive to UI scheduling delays until that integration is qualified.
- 🔴 [Later] Extend aligned references to simultaneous nonlinear changes, moving Flutter and different headphone spatial/HRTF preparations; evaluate longer natural tails only with bounded resource ownership.
- ⭕️ [Pending] Physical iPhone speaker/headphone and Mac/DAC listening, rapid toggles under UI load, background/sleep/route changes, device-specific latency/drain sufficiency, sustained CPU/thermal/energy use and ordinary true-peak activation. A 424 ms bounded release does not preserve an arbitrarily long natural reverb decay.

## CPU / Metal upsampling comparison — 2026-10-19

- 🟢 [Done] Benchmark the shipping iPhone CPU Precision Sinc arithmetic against an equivalent Metal prototype on the real M4 development Mac: 29 stereo settings, two complete runs, seven warm repeats plus first-use timing, separate peak RSS/physical-footprint/Metal-allocation readings. Share the exact harness and evidence with Mac; no production audio path changes.
- 🟢 [Done] Pass all 58 CPU/GPU pair comparisons and sampled Float64-reference gates, both corrupted-shader negative controls and the shipping file-reader/throttle probe. Maximum CPU/GPU error is 2.98e-7 FS. See [full results, scope and reproduction](CPU_METAL_UPSAMPLING_VALIDATION.md).
- 🟢 [Done] Keep CPU as the shipping default. Non-tiny GPU speedups range from 0.765× to 2.948×; tiny jobs are about 9–11× slower, setup adds 22.58–53.47 ms and memory rises. Mac's existing AVAudioEngine SRC remains distinct from iPhone Precision Sinc; the benchmark does not claim otherwise.
- 🟢 [Done] Qualify the first shared-rack latency/residual and bounded-tail stage; see [effect-tail validation](TAIL_LATENCY_VALIDATION.md). GPU integration remains Later.
- 🔴 [Later] Revisit an optional GPU backend for large repeated offline jobs only after a measured device-specific benefit, with bounded buffers, CPU fallback and transport/cancellation ownership.
- ⭕️ [Pending] Physical iPhone speed/memory/energy/thermal testing, sustained playback and UI/GPU contention, other Mac families, long-song memory pressure and any future GPU handoff/cancellation/listening qualification. M4 standalone compute measurements above are complete; they do not establish app-level device qualification.

## Mac transport and late-analysis parity — 2026-10-19

- 🟢 [Done] Add independent Mac start/pause/resume/seek/stop/load/recovery protection using iPhone's byte-identical 24 ms / 48-step cosine policy. Retain both overlap schedules until zero output and drain; coalesce requests, gate startup on rendering and reject stale EOF/transport callbacks.
- 🟢 [Done] Freeze current and incoming track/album normalization references, including missing measurements and repeat-one. Late analysis updates caches without changing the playing gain; new loads/schedules and explicit normalization changes adopt available analysis.
- 🟢 [Done] Pass 43 regressions plus 4 real-controller tests in each ordinary/true-peak candidate configuration, 6 stereo PCM cases at 44.1/48/96 kHz and two fault-injection controls. Recheck iPhone transport/gain-reference regressions and all three app builds. See [verification, measurements and scope](MAC_TRANSPORT_PARITY_VALIDATION.md).
- 🟢 [Done] Complete the shared-rack Space/Gloss residual and bounded-tail stage; see [effect-tail validation](TAIL_LATENCY_VALIDATION.md). Sample-accurate envelopes remain Next.
- ⭕️ [Pending] Physical iPhone/Mac listening, rapid operations under UI load, live route/rate changes, sleep/wake and sustained CPU/thermal/energy behavior. Ordinary true-peak activation remains gated by device qualification.
- 🟢 [Done] Complete the development-Mac CPU/Metal comparison and retain CPU as default; see [measured results and remaining device qualification](CPU_METAL_UPSAMPLING_VALIDATION.md). Optional production GPU integration remains Later.

## iPhone foreground recovery coordination — 2026-10-19

- 🟢 [Done] Record iPhone recovery for Music-managed non-DRM tracks after other-app audio: retain original playing intent before foreground refresh, allow a guarded missing-end retry when other audio has stopped, and require fresh source progress before reporting resumed playback. Preserve user pause/selection and keep failed recovery paused with retry intent.
- 🟢 [Done] Record 10 production-method regression groups plus a negative control, 5 production-engine Simulator groups, transport/session/render/fade regressions and the ordinary iPhone build. See [verification and scope](FOREGROUND_RECOVERY_VALIDATION.md). This entry records the iPhone change; Mac parity is now implemented in the section above.
- ⭕️ [Pending] Physical iPhone reproduction with the affected Music-managed non-DRM songs, other-app ownership transfer, long suspension, calls/routes and pause/track changes during recovery. Simulator success does not establish device recovery.

## iPhone destructive shutdown coordination — 2026-10-18

- 🟢 [Done] Record iPhone destructive stop/load/recovery protection: retain active files/PCM and both handoff schedules until the final-mixer fade and silent drain finish, then pause/reset and release the session. Coalesce stops, reject stale/cancelled loads and honor a newer pause during reload.
- 🟢 [Done] Record 11 transport state groups, 6 PCM cases with negative controls, 6 final production-engine Simulator groups, gain-reference/session regressions, 48 effect and 72 gain cases, and the ordinary iPhone build. Shared `EffectTransitionPolicy` remains byte-identical. See [verification and limits](DESTRUCTIVE_STOP_VALIDATION.md). Mac runtime code is unchanged in this step.
- 🟢 [Done] Mac transport and late-analysis gain protection now implement the shared acceptance criteria; see [2026-10-19 validation](MAC_TRANSPORT_PARITY_VALIDATION.md).
- 🟢 [Done] Complete the first latency/residual and bounded-tail stage; see [effect-tail validation](TAIL_LATENCY_VALIDATION.md).
- ⭕️ [Pending] Physical iPhone speaker stop/start, track/quality changes, recovery, Music session transfers, UI load and route changes; corresponding Mac listening and sustained resource use.

## Pastel appearance and shared dial detail — 2026-10-18

- 🟢 [Done] Add iPhone-identical Pink `#fbeefa`, Purple `#eeecfe`, Green `#e1fff4` and Beige `#faf7e3`, with coordinated playback accents, persisted selection and EN/JA/zh-Hans labels. Update the seven-choice appearance picker to a menu and preserve the current view/track state during color changes.
- 🟢 [Done] Add rounded ceramic-style desktop VU enclosures with cream bezels and small fasteners. Keep the entire frame in its chosen hue using three opaque light tones, including highlights and fasteners; remove white-to-color frame shading. Retain the compact player dimensions and L/R/status lamps.
- 🟢 [Done] Match the pastel dial detail to iPhone Realistic Light: main/sub scales, red overload arc, professional-meter legend and VU/dB labels in rounded typography. Update the iPhone pastel face too; keep `PastelVUMeterScale.swift` byte-identical and derive each dial/needle from the common -18 dBFS = 0 VU reference.
- 🟢 [Done] Pass 28 Mac focused/regression tests and both Mac product builds after the final frame-color refinement. Verify four colors at two meter widths, L/R minimum/0 VU/maximum, full player rendering, persisted RGB values and all main marks. Verify the actual Mac settings-to-main color change with a separate 12-track library. Recheck iPhone SE / 16 Pro Max and its ordinary Simulator build. See [validation and screenshots](PASTEL_DESKTOP_PARITY_VALIDATION.md).
- ⭕️ [Pending] Live playback needle motion/settling, sustained rendering cost, physical iPhone and other Mac displays, small-text readability and True Tone/Night Shift color appearance. The completed Mac window check used a static fixture without playing audio.

## iPhone speaker continuity coordination — 2026-10-17

- 🟢 [Done] Coordinate the reported iPhone built-in-speaker volume jumps/clicks: retain normalization and applied automatic EQ through same-track quality replacement, defer new automatic analysis until explicit tuning/new prepared playback, and add independent start/pause/seek protection with stale-callback and EOF guards.
- 🟢 [Done] Keep `EffectTransitionPolicy` byte-identical across both apps. Pass Mac's 19 focused effect-transition/final-output/fidelity tests; record iPhone transport PCM/state/gain-reference regressions, 17 production-engine Simulator checks, the ordinary app build and the 48 effect / 72 gain cases. See [shared evidence and scope](PLAYBACK_CONTINUITY_VALIDATION.md).
- 🟢 [Done] iPhone destructive stop/load/recovery now defers resource/session release until after the fade and drain; see [2026-10-18 validation](DESTRUCTIVE_STOP_VALIDATION.md).
- 🟢 [Done] Mac transport and late-analysis gain protection now implement the shared acceptance criteria; see [2026-10-19 validation](MAC_TRANSPORT_PARITY_VALIDATION.md).
- 🟢 [Done] Complete the first latency/residual and bounded-tail stage; see [effect-tail validation](TAIL_LATENCY_VALIDATION.md).
- ⭕️ [Pending] Confirm the reported symptom on a physical iPhone built-in speaker, then verify applicable Mac/output-route behavior. Validate audible start/stop, real overlap, UI load, session changes and sustained CPU/energy. Shared math and offline tests do not establish physical inaudibility.

## iPhone preparation diagnostics coordination — 2026-10-17

- 🟢 [Done] Track the iPhone native-first/Precision Sinc diagnostic update: actual streaming and offline stages, explicit capacity limits versus other failures, original error domain/code and prepared/failed/cancelled worker outcomes. The Mac app has no equivalent Precision Sinc preparation pipeline; this does not change its audio routing or ON/OFF protection.
- 🟢 [Done] Record passing diagnostic/streaming/asset/remote regressions, the 12-check iPhone production-engine Simulator audit and Simulator build. See [shared verification record and scope](PREPARATION_DIAGNOSTICS_VALIDATION.md).
- ⭕️ [Pending] Physical iPhone Music assets, account/session timing and live memory-pressure diagnostics. Existing Mac/iPhone acoustic, output-device and true-peak qualification gates remain Pending.

## Effect ON/OFF protection — 2026-10-17

- 🟢 [Done] Protect Mac module ON/OFF and global OFF/restore with the iPhone-identical envelope policy: nominal 8 ms descent, commit at zero, 16 ms recovery without a silent hold. Multiply the latest user volume by an independent protection gain before the final true-peak candidate; keep its downstream mixer at unity.
- 🟢 [Done] Coalesce rapid toggles, defer shared-rack commits around song crossfades, recover and retry if overlap begins during descent, and cancel queued gains/settings on stop/pause/seek/rebuild. Stop/resume cannot leave the protection gain attenuated. Continuous controls retain their existing interpolation.
- 🟢 [Done] Pass 96 Mac PCM cases covering Basic/Pro, 44.1/48/96 kHz, ordinary/candidate output, OFF/edit/restore, overlap and stop/resume in both ramp phases. Reject 3 intentional faults. Pass 19 focused tests in each Mac build, iPhone 48 effect and 72 gain cases, and all three app builds. See [verification, measurements and scope](EFFECT_BYPASS_PROTECTION_VALIDATION.md).
- 🟢 [Done] Complete the first latency-aligned bypass/reference/residual and bounded-tail measurement stage on 2026-10-19; see TAIL_LATENCY_VALIDATION.md. The shared audio-thread gain component is qualified on 2026-10-22; connected-graph integration remains Next above.
- ⭕️ [Pending] Physical iPhone/Mac listening for clicks and brief attenuation, live file crossfades, stop/resume/seek tails, main-queue/UI contention, output changes and sustained CPU/energy/thermal behavior. Keep ordinary true-peak activation pending its existing device gates.
- 🔴 [Later] Sample-accurate ramps on both platforms and residual/alias-driven nonlinear oversampling.

## Effect parameter parity — 2026-10-17

- 🟢 [Done] Prioritize Mac continuous-control parity after final true-peak integration. Share the exact eight-step / nominal 10 ms interpolation policy with iPhone, coalesce rapid gestures, skip unchanged module writes, preserve output volume, hold continuous updates during active song overlaps, and reject queued updates after OFF/stop/seek/rebuild. iPhone's existing interpolation behavior is retained.
- 🟢 [Done] Pass 48 Mac waveform cases across Basic/Pro, 44.1/48/96 kHz output and ordinary/true-peak paths, plus immediate-write/mute negative controls. Pass 4 Mac state tests and 14 integrated qualification tests; recheck iPhone 48 effect cases, 72 gain cases, meter freshness and 3 combined feedback cases. Both Mac products and the iPhone Simulator build pass. See [validation and measured limits](EFFECT_PARAMETER_PARITY_VALIDATION.md).
- 🟢 [Done] Mac ON/OFF protection now shares iPhone’s nominal 8 ms descent / 16 ms recovery policy, keeps user volume independent, defers during song overlap and cancels on stop/rebuild. See [current bypass implementation and validation](EFFECT_BYPASS_PROTECTION_VALIDATION.md). Latency compensation and device audibility remain separate work.
- ⭕️ [Pending] Physical iPhone/Mac listening during gestures, OFF/restore, seek and song transitions; device clock/tap timing, UI-load scheduling and sustained CPU/energy behavior. Keep ordinary true-peak activation pending the existing device gates.
- 🔴 [Later] Replace control-rate updates with validated sample-accurate parameter/bypass ramps on both platforms; measure residual/alias behavior before nonlinear oversampling.

## Audio fidelity policy — 2026-10-17

- 🟢 [Done] Use the same 96 kHz effect-rack policy as iPhone, keeping file clocks and actual hardware output separate. The source mixer converts into the rack; 192 kHz files retain Space. Controller coverage and nine offline source/Space/output paths passed.
- 🟢 [Done] Add full-track, original-rate mono/stereo K-weighted LUFS and per-channel sample peaks, separate from first-60-second mono musical features. Forward worker cancellation, invalidate version-4 caches, use an independent LUFS target preference (-16 default), and gate combined album block energies. Missing/old measurements do not normalize. UI units are updated in English/Japanese/Simplified Chinese.
- 🟢 [Done] Share the meter/policy source with iPhone. 24 reference signals agree with FFmpeg ebur128 within 0.12 LU (maximum 0.053101 LU). Fifteen focused desktop tests passed, including asynchronous album aggregation and stale-result rejection. See [validation and scope](AUDIO_FIDELITY_POLICY_VALIDATION.md), including iPhone output classification and per-device settings.
- 🟢 [Done] Integrate the iPhone-identical true-peak AU after Mac final SRC/channel mapping and user volume, independent of effect bypass. Keep the downstream mixer at unity, report latency, and reset lookahead only on abrupt transport changes. SwiftPM and both desktop Xcode products include the stage. See [qualification details](MAC_TRUE_PEAK_VALIDATION.md).
- 🟢 [Done] Pass 168 Mac peak probes, 168 independent FFmpeg measurements, 72 controlled overlap pairs, shared DSP/AU sanitizers, and 10 focused tests in each of ordinary/qualification builds. Repeat iPhone 84-probe and 18-overlap checks with the same criteria.
- ⭕️ [Pending] Enable the protector in ordinary builds only after physical Mac/iPhone playback, pause/seek/final tails, output switching, visualization timing and sustained CPU/thermal/energy qualification. It currently requires `ONGAKU_ENABLE_TRUE_PEAK`.
- ⭕️ [Pending] Physical DAC/Bluetooth/output-rate changes, matched-loudness listening, long-file analysis and 96 kHz rack CPU/thermal/energy behavior. Ordinary output protection remains sample-based; do not claim -1 dBTP or bit-perfect output.
- 🔴 [Later] Multichannel loudness layouts, exact concatenated-album boundary windows, measured spatial responses and alias/distortion measurements before optional nonlinear oversampling.


## 1. 目的

Ongaku Desktopを、ローカル音源の安全性と高品質再生を保ちながら、macOSの「ミュージック」で日常的に利用できる機能を網羅する音楽管理・再生アプリへ発展させる。

最初の配布範囲は、安全なローカル音源管理と日常再生とする。Apple MusicとMobile同期は、それぞれの品質ゲートを通過した範囲だけ配布対象とする。

長期的な機能比較はApple公式の[macOS版Apple Musicユーザガイド](https://support.apple.com/guide/music/welcome-apd3f44c7709/mac)を基準とする。Apple Musicサービスとの連携には[MusicKit](https://developer.apple.com/documentation/musickit)を使用し、公開API、利用者の認証、サブスクリプション、地域ごとの提供状況、DRMを尊重する。

「全て実装」は、次のいずれかを満たすことと定義する。

1. 公開APIで実現できる機能は、利用者から見た操作と結果を同等にする。
2. Apple固有の非公開サービスは、合法かつ保守可能な同等機能または公式画面へのハンドオフを提供する。
3. 実現不能な機能は隠さず、制約、代替手段、再評価条件を本書に残す。

Appleの画面を複製すること、非公開APIの利用、DRMの回避、Appleの推薦・ソーシャルグラフの模倣は対象外とする。

## 2. ステータス

- 🟢 `[Done]` 現在のコードベースに実装済み
- 🟠 `[Next]` 最優先で着手する未完了項目
- 🔴 `[Later]` 計画済みだが、直近の着手対象ではない項目
- ⭕️ `[Pending]` 開発環境で検証できず、実機・署名・権限などの条件待ちの項目

`[Done]` は当該リポジトリで実装を確認できる範囲、`[Next]` は下記の現在の6作業、`[Later]` はその後の作業を表す。実装済みと配布確認済みは分ける。配布可能と判定するには「13. 完了条件」の証拠を全て必要とし、未実施は合格に数えない。旧品質文書の「終了判定」は、その文書に記載された自動試験範囲の記録として読む。

## 3. 現在地

- 🟢 [Done] 0.1.10（build 16）へ更新し、Developer ID版とApp Store版のUniversalアーカイブを作成。全332テストの再実行に成功。
- 🟢 [Done] 0.1.10のDeveloper ID版をApple公証・staple・Gatekeeper検証後、GitHubへ公開。署名済みSparkle更新フィードと差分5件を生成。
- 🟢 [Done] App Store 0.1.10（16）の審査提出完了をユーザーから確認。[配布記録](quality/RELEASE_0.1.10_2026-10-16.md)。
- ⭕️ [Pending] Appleの審査結果とApp Storeでの公開確認を待つ。

- 🟢 [Done] VUメーターの黒い外枠を中間グレーのグラデーションへ変更し、内縁も無彩色へ統一。Releaseビルド成功、インストール版の左右VUメーターで実画面確認済み。

- 🟢 [Done] ダーク背景を明るめのチャコールへ調整。環境設定のサイドバーを不透明な専用背景にし、右側よりわずかに明るい濃度へ統一。署名付きReleaseビルドとインストール版のメイン／設定実画面で確認済み。

- 🟢 [Done] ライトモードの再生・前後スキップボタンに専用の溝色を設け、明度を0.925から0.820へ下げた。ダークモードの明度は0.150を維持。

- 🟢 [Done] 通常の操作色をライト／ダーク対応の無彩色へ統一し、オレンジを再生ボタンのリングと再生位置バーの経過部分に限定。設定・メイン画面の両テーマ、メイン／ミニプレーヤーの進捗表示とシーク連携を実画面で確認し、インストール版へ反映。[検証記録](quality/NEUTRAL_PALETTE_2026-10-16.md)。

- 🟢 [Done] 移行先の探索で関連ライブラリがない場合、新規作成を三言語で確認する。承認後に選択フォルダの新しいサブフォルダへ管理用ディレクトリ・空のmanifest・識別マーカーを作成し、別ライブラリとして開く。旧プロフィールと既存データは保持。複数候補・別ID・不完全な関連データ・探索エラーでは新規作成へ進めない。
- 🟢 [Done] 新規作成確認を署名付きReleaseの実画面で操作し、キャンセル時の無変更、承認後のファイル作成と0曲画面、インストール版での再オープンを確認。設定／M5／M0テスト45件成功。通常起動でも現在の14曲のライブラリが開くことを確認。[検証・インストール記録](quality/NEW_LIBRARY_CONFIRMATION_2026-10-16.md)。

- 🟢 [Done] 移行エラー画面にウインドウ全体を覆う不透明な背景を追加。プレーヤー用の透明ウインドウ設定によって背後が透ける問題を修正。

- 🟢 [Done] モバイル版のハードウェア調デザインをDesktopへ導入。シルバー／グラファイトの配色、オレンジのアクセント、同心円の再生操作、16pt角丸パネルと余白を反映。Releaseビルドと分離した12曲ライブラリのライト・ダーク実画面、英語・日本語表示、日本語検索を確認。[検証記録](quality/MOBILE_DESIGN_DESKTOP_2026-10-16.md)を参照。

### 現在の6作業（2026-09-05再設定）

次はA3を優先する。A4はこの実装で必要になった境界だけ段階的に切り出し、A5を終えてからA6の配布判定を行う。期日は先行ゲートが通過し、実測工数が得られた時点で設定する。

| 状態   | 作業                                        | 終了条件                                                                                                                                                                                                                    |
| ------ | ------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [Done] | A1 Mobileの保存・転送commitを修正           | コピー先再検証、原子的manifestと直前バックアップ、保存成功後のACK、チェックサム単位の冪等再送、破損正本の退避・バックアップ復旧、保存失敗時のコピーrollbackを実repositoryの失敗注入試験で確認。実機の終了・再接続はA6で確認 |
| [Done] | A2 再生位置・履歴の高頻度保存を分離         | ライブラリUUID付きのキュー／履歴sidecar、直前バックアップ、旧manifestからの移行を実装。10万曲の位置保存p95 1.022ms、sidecar 237バイト、全曲manifest書込0バイトをReleaseで確認                                               |
| [Next] | A3 検索・集計を非同期化し索引を差分更新     | メインスレッドの全件検索を除去し、キャンセル・世代照合・英日中の短い検索を保証。Releaseで実際の初回表示2秒、入力→結果p95 300ms、ピーク512MiBを確認し、索引更新中と再生中も計測                                              |
| [Next] | A4 保存・検索・転送の責務とテスト境界を分離 | UIはMainActor、更新の所有者を一本化。Mobile保存経路を自動試験対象へ追加し、音声／MusicKit adapterへ障害注入できる。SPM・Mac両構成・Mobileのビルドを維持                                                                     |
| [Done] | A5 外部画像取得の同意・説明を統一           | 自動取得を既定で無効にする設定と、手動検索の送信前説明を三言語で実装。無効時にURLSession要求が0件である通信試験を追加し、PRIVACY・ADR・READMEを実動作へ更新                                                                 |
| [Next] | A6 機能別の配布資格を確認                   | 署名UI、三言語・VoiceOver、音声経路、Mobile切断再開、Store双方向通信を証拠付きで判定。未合格機能は配布対象から外すか公開を延期し、その構成も検証                                                                            |

- 🟢 [Done] エフェクト10種の信号監査で接続・時間単位・出力保護を修正。278テストとApp Store Debugビルド成功。実機試聴と高レート制限は[検証記録](quality/EFFECT_SIGNAL_AUDIT_2026-09-05.md)を参照。
- 🟢 [Done] App Store版の起動時更新確認を英語・日本語・简体中文で実装。0.1.7は承認済み。0.1.9 build 15のUniversal Binaryを検証してApp Store Connectへアップロードし、署名・公証済みDeveloper ID版とSparkle差分更新をGitHub Releaseへ公開
- 🟢 [Done] 横長・縦長のアートワークがアルバム一覧などの隣接項目へはみ出さないよう、共通サムネイルを正方形の表示領域内で中央クロップする
- 🟢 [Done] 曲リストの単曲ドラッグ準備から全曲走査を除去。フィルタなしのアルバム・アーティスト分類をライブラリrevision単位で再利用し、サムネイルはUIスレッド外で最大1024pxに縮小デコードする。表示処理の回帰テスト6件とmacOS Debugビルド成功。実画面での速度改善幅は未計測
- 🟢 [Done] 楽曲・アルバム・アーティストの写真編集で画像のドロップ登録、ドラッグによる切り抜き位置調整、1〜3倍の拡大率調整を追加。「保存」で正方形画像を既存の保存経路へ反映し、操作案内は英語・日本語・简体中文で提供
- 🟢 [Done] iPhone同期画面の曲・アーティスト・アルバム一覧をキャッシュし、ライブラリ変更時だけ再生成する。同期済み判定を全曲走査からSHA-256索引へ変更。同期テスト14件とmacOS Debugビルド成功。実機接続時の表示時間は未計測
- 🟢 [Done] macOS 26.6.2でControl Center同期中に発生したMainActor executorのクラッシュを解析し、Combine購読から明示的にMainActorへ移る通知境界へ修正。バックグラウンドexecutorからの通知を含む全281テストが成功。
- 🟢 [Done] 歌詞追加画面にLRCLIBの直接検索欄を追加。曲名・アーティスト・アルバム等の自由入力、Enter検索、候補比較と選択を英語・日本語・简体中文で提供。
- 🟢 [Done] 2026-09-05に全体設計を評価し、このリポジトリの実装範囲と配布判定を分離した
- 🟢 [Done] A1のrepository契約4試験を追加し、全263テスト、macOS Debug、iOS Simulator Debug、三言語strings検証を完了した
- 🟢 [Done] A2の非全体書込・ライブラリ分離・バックアップ復旧3試験と10万曲benchmarkを追加し、全267テスト、macOS Debug、Mac App Store Universal Releaseを確認した
- 🟢 [Done] A3の第1段階として、索引準備中・障害時のJSON検索をMainActor外へ移し、キャンセルとカタログrevision／query照合を実装した。検索中と0件を分けた三言語表示、1万曲の非同期fallback試験を追加し、全268テスト、macOS Debug、Mac App Store Universal Releaseを確認した
- 🟢 [Done] A3の第2段階として、SQLite検索索引を楽曲編集のたびに全再構築する処理を廃止し、変更された検索フィールドだけを原子的に差分更新する。追加・削除・ライブラリ変更時は全移行へ安全に戻し、検索parityを再確認する。全282テストで追加・更新なし・既存検索経路を確認した
- 🟢 [Done] A5として、オンライン画像の自動取得を初期状態で無効化し、設定で明示的に有効化できるようにした。手動のアルバム／アーティスト画像検索には送信先と送信内容の三言語説明を表示し、無効時の外部要求0件と設定永続化を自動試験で確認した。10万曲性能ゲートを除く283テスト、通常macOS／App Store／Mobile Simulatorの3構成ビルドに成功
- 🟢 [Done] macOSの共通ウィンドウからfull-size透明タイトルバーを解除し、3カラムすべての先頭行をタイトルバー／ツールバー下の可視領域へ配置した。専用回帰試験を追加し、全269テストで確認した
- 🟢 [Done] エフェクト画面の有効数を選択中モードへ限定し、BASIC・Pro・OFFの集計を共通化した。専用回帰試験を追加し、全270テスト / 31 suiteの成功を確認した
- 🟢 [Done] サイドバー切替を左側、その他のツールバー操作を右側へ明示配置した。標準切替ボタンの除去を各カラムへ適用し、修正版Debugアプリで開く→閉じる→開くを操作して、ボタンが1つだけで左右の位置が変わらないことを実画面で確認した。先行する全271テスト成功は静的配置検査を含むが、表示保証にはこの実画面確認を用いる
- 🟢 [Done] サイドバーのSF Symbolを外観へ明示的に追従させ、ライトモードは黒、ダークモードは白の単色表示に統一した。プレイリストのカスタムアートワークは元画像の色を維持する。Xcode 27.0（Swift 6.4／macOS 27 SDK）でDebugビルドと専用回帰試験に成功
- 🟢 [Done] プレイリストだけが専用アートワークViewのフォールバックSF Symbolを使い、アクセントの青が残る経路を修正した。画像設定済みプレイリストは原色を維持し、未設定時の音符アイコンだけをライト黒／ダーク白へ明示する
- 🟢 [Done] A3の第3段階として、標準ビュー・スマートプレイリスト・詳細フィルタ・検索結果の絞り込み、アルバム／アーティスト分類、重複・再生統計・Ongaku Mixの表示用集計を専用actorへ移した。同一ターンの変更をまとめ、キャンセル・世代照合で古い結果の反映を防ぐ。曲表は集計結果のrevisionで再ソートし、再生中インスペクタの曲参照もキャッシュを使う。[検証記録](quality/ASYNC_LIBRARY_MILESTONE_2026-09-12.md)を参照
- 🟢 [Done] GitHub Actions run 34678611788の失敗8件を特定。検索索引の完了と表示集計の完了を区別し、スマートプレイリスト・検索の試験を表示完了後の値で検証するよう修正。保存失敗時の検索復旧も追加し、全291テストが成功。待機時間の固定延長や性能閾値の緩和は行っていない
- 🟢 [Done] A5の補修として、設定画面へ画像取得設定を渡し、Control Centerの画像取得経路も既定で通信しない設定へ変更。取得設定の切替でサムネイルを再評価し、自動取得無効時は期限切れの保存済み画像も表示する。三言語の説明にアーティスト画像の取得先も含めた
- 🟢 [Done] A3の検索中断をSQLite内部へ伝播する。入力変更で不要になった検索は、開始前・結果取得中・SQLite VM実行中に中断し、索引障害とは区別する。中断後の接続再利用と三言語検索の回帰試験を追加した。検証範囲は[記録](quality/SQLITE_SEARCH_CANCELLATION_2026-10-10.md)を参照。
- 🟢 [Done] A3の索引更新後のparity検証を全曲1回のテキスト生成へまとめ、英日中・歌詞・古い索引・キャンセルの一致契約を維持する。10万曲の実再生中／索引更新中／両者同時のproduction snapshot計測も追加した。実画面の製品目標とは分けて[検証記録](quality/SEARCH_INDEX_PARITY_2026-10-10.md)で管理する。
- 🟢 [Done] A3の負荷計測で索引更新中のJSON検索を特定し、専用actorのテキストキャッシュへ移した。クエリ変更では再生成せず、編集時は不変の行を再利用する。UTF-8換算64MiBを上限にし、超過時は全曲検索を維持して保持をやめる。編集・並べ替え・削除・ライブラリ切替・キャンセル・上限超過を含む関連18テストが成功。Releaseの10万曲計測も成功。同時実行の内部検索p95は参考比較で6.952秒→0.811秒、初回キャッシュ準備を含む更新中は3.414秒で未達。初回準備・表示集計を次に改善する。性能と残りの製品ゲートは[記録](quality/SEARCH_INDEX_PARITY_2026-10-10.md)を参照。
- 🟢 [Done] A3の表示集計を改善し、重複判定のタイトル／アーティスト正規化キーを曲ID単位で再利用する。変更行だけ再生成し、ハッシュ・長さ・推奨曲は最新データで再計算する。初回正規化の文字ごとの文字列生成も除去した。関連27テストで編集・並べ替え・削除と従来判定の一致を確認。今回の速度・ピークメモリの実測は未実施で、製品性能ゲートは引き続き保留。[検証記録](quality/SEARCH_INDEX_PARITY_2026-10-10.md)を参照。
- 🟢 [Done] A3の再生統計を履歴由来と曲側の同期済み値に分離し、曲編集だけなら履歴集計を再利用する。履歴置換・削除、曲削除、最終再生日時を含む関連32テストに成功。Releaseの10万曲・10万履歴で10回編集する負荷試験も成功し、編集後のworker集計p95 3.325秒、履歴なし初回4.754秒を記録した。改善率は未測定。残る重複グループ再構築と集計の再計算範囲縮小を優先する。[記録](quality/SEARCH_INDEX_PARITY_2026-10-10.md)を参照。
- 🟢 [Done] A3の重複グループ構成を、曲ID・タイトル・アーティスト・ハッシュ・長さが不変なら再利用する。最新Trackと推奨曲は毎回更新し、関連32テストで直接計算との一致を確認。Releaseの10万曲・10万履歴の編集集計p95は同条件の参考比較で3.325秒→0.277秒。初回JSON検索と構成を変える編集の全体再構築を次に改善する。実画面とピークメモリの製品ゲートは保留。[記録](quality/SEARCH_INDEX_PARITY_2026-10-10.md)を参照。
- 🟢 [Done] A3の検索正規化にASCII専用経路を追加し、非ASCIIは従来のPOSIX foldingを維持する。全ASCII・英日中・アクセント・全角・結合文字の一致を含む関連21テストが成功。Releaseの10万曲JSONフォールバック単独試験は初回準備＋検索の最大0.793秒、キャッシュ済み最大0.196秒（各3回）。ASCII10万件の同一入力比較は参考値0.074秒→0.021秒。実画面の製品ゲートとは区別し、初回準備の残る負荷を次に改善する。[記録](quality/SEARCH_INDEX_PARITY_2026-10-10.md)を参照。
- 🟢 [Done] A3の検索テキスト組立てで数値用の中間配列と配列結合を省き、従来の区切り／順序を関連22テストで確認した。Releaseの10万曲試験も成功し、生成0.912秒・走査＋ID集合0.188秒・UTF-8総量7,366,666 bytesを分離計測。今回の初回最大1.230秒は前回より遅く、負荷未統制のため実時間改善は未確認。次は負荷の大きいテキスト生成の内訳と再利用を優先する。[記録](quality/SEARCH_INDEX_PARITY_2026-10-10.md)を参照。
- 🟢 [Done] A3の検索テキスト生成で、通常の絶対パスのASCIIファイル名はURL生成を省く。非ASCIIのUnicode分解表現、相対パス、特殊パスは従来処理を維持し、関連23テストでUTF-8一致を確認。Releaseの10万曲・同一実行内の交互比較で生成最大0.296秒→0.184秒、初回worker検索最大0.296秒・キャッシュ済み最大0.112秒を記録。実再生／索引更新を伴う負荷の再計測を次に優先する。製品の描画・メモリゲートは保留。[記録](quality/SEARCH_INDEX_PARITY_2026-10-10.md)を参照。
- 🟢 [Done] 起動時のライブラリ移行エラー画面に、同じメディアフォルダを選択して権限を再取得し移行を再試行する復旧操作を追加。別フォルダの拒否、失敗時の元データ保持、繰り返し復旧と再起動を含む設定19テストが成功。成功後はライブラリ読み込みを再開し、説明を三言語で更新した。実sandboxの権限回復と実画面は保留。[検証記録](quality/LIBRARY_MIGRATION_RECOVERY_2026-10-11.md)を参照。
- 🟢 [Done] 移行復旧のフォルダ判定を補修。保存先そのものと親フォルダを認可対象にし、リンク解決とディレクトリ境界で別フォルダを拒否する。親を選んでも保存先は変えず、認可bookmarkを起動時の移行前に復元する。見出しと詳細の省略も修正。設定19テストで親・リンク・誤選択と保存先維持を検証。実sandboxの権限回復は保留。[記録](quality/LIBRARY_MIGRATION_RECOVERY_2026-10-11.md)を参照。
- 🟢 [Done] 移行復旧を選択フォルダ内の自動検出へ拡張。深さ5／最大4,096フォルダを確認し、既存カタログを照合して保存先参照を修正する。複数候補・未検出時は空のライブラリを作らない。復旧したカタログから読み込みを再開し、別profileの移行失敗による起動停止も防ぐ。設定20テストで内容保持・移動・候補判定・再起動を検証。実sandboxの権限回復は保留。[記録](quality/LIBRARY_MIGRATION_RECOVERY_2026-10-11.md)を参照。
- 🟢 [Done] 2026-10-12に最新のローカル署名付きsandboxアプリで自動修復を実操作。通常のストレージ設定にも修復ボタンを追加し、親フォルダ選択で既存カタログを検出・再読み込みする。SUBの4,356曲・29.38GBを実画面で確認し、/Applications版更新後の再起動でも同じ一覧表示を確認した。設定20テスト成功。ボリューム改名・実データ移動・起動時エラー再現・配布署名の実機試験は保留。[検証記録](quality/LIBRARY_MIGRATION_RECOVERY_2026-10-11.md)を参照。
- 🟢 [Done] 再接続時の復旧bookmarkが別の場所に解決される場合へ対応。認可した親の相対位置と保存したlibraryIDを照合し、同じカタログが範囲内にある場合だけ参照を更新する。設定21テストと署名付きビルドに成功し、インストール版も更新。実ボリューム改名を伴う動作確認は保留。[記録](quality/LIBRARY_MIGRATION_RECOVERY_2026-10-11.md)を参照。
- 🟢 [Done] 再接続時に親配下の階層が変わった場合も、認可範囲内を保存済みlibraryIDで再探索する。旧位置の別IDや同一IDの複数候補は選択しない。認可情報が欠落・破損した際は移行を止め、空のライブラリを作らず元カタログを保持する。設定22テスト成功。実ボリューム改名による再接続試験は保留。[記録](quality/LIBRARY_MIGRATION_RECOVERY_2026-10-11.md)を参照。
- 🟢 [Done] 2026-10-12に実ライブラリの保存先フォルダを認可済み親内で一時改名し、起動時に手動選択なしで新パスへ追従して4,356曲・29.38GBを表示することを確認。元の名前へ戻した後も自動追従し、libraryIDと全曲IDを保持。音楽フォルダは移動していない。ボリューム改名・認可範囲外への移動は別途保留。[実機記録](quality/LIBRARY_MIGRATION_RECOVERY_2026-10-11.md)を参照。
- 🟢 [Done] A3の重複判定キー保持をUTF-8換算16MiBに制限。超過したキーは判定時に計算し、全曲の判定を維持する。0／32バイト予算・長い多言語メタデータ・編集・並べ替え・空カタログを関連36テストで確認。実機で見つかった外付けprofileの誤ったApplication Support説明も補修し、設定23テスト成功。署名付きビルド成功。全体RSSと表示性能は引き続き保留。[検証記録](quality/DUPLICATE_CACHE_BUDGET_2026-10-12.md)を参照。
- 🟠[Next] A3の残りとして、実画面のRelease初回表示2秒・入力から結果表示p95 300ms・ピーク512MiBを計測し、再生中／索引更新中の条件で改善する。2026-09-08のDebug測定11.27秒はJSON再読込と先頭ページ準備の時間で、事前の保存時間とSwiftUI描画は含まない。2026-09-12に同じCIゲートは通過したが、実画面の製品目標の合格には数えない
- 🟢 [Done] A3の常駐メモリ削減としてTrackをcopy-on-writeで共有化。値・JSON互換性を含む全332テスト成功。10万曲のRelease実画面で、大量行変更時の表再構築も追加し、英日中の1曲検索から全曲へ復帰する停止を修正。検索後physical footprintは参考比較577.7→270.1MiB、観測RSS最大1269.8→603.6MiB。10検索すべて正しく、観測p95は749→811ms（入力・AX待ち込みで速度改善の判定には使わない）。[記録](quality/COW_TRACK_100K_2026-10-15.md)。
- 🟠 [Next] A3の起動時RSSピークをさらに削減し、512MiBを達成する。ツール待ちを除く検索時間と、再生／索引更新中の実画面も計測する。単発RSSはOS圧縮の影響が大きいためphysical footprintを併記する。
- 🟢 [Done] A3の読み込み負荷を減らすため、現行カタログのスキーマ確認と本体復元を同じDecoderに統合した。全曲JSONの二重解析を除去。整合性51テストとReleaseの10万曲CI試験に成功。読み込み＋先頭ページ準備4.691秒（1回）、索引検索p95 3.39ms（4クエリ）で、変更前との改善率と実画面RSSは未測定。旧形式の移行・未知スキーマの拒否・破損時の復旧経路は維持する。検証は[記録](quality/CATALOG_SINGLE_PARSE_2026-10-15.md)を参照。常駐RSS目標の達成とは分けて扱う。
- 🟢 [Done] 2026-10-12、重複キー保持上限などをインストール版に反映し既存4,356曲を再確認。10万曲のRelease実画面をCUAで操作し、再起動後の10検索すべてで正しい1曲表示を確認。操作／観測待ち込みp95 1067ms、観測RSS最大1250.44MiB／検索後1079.64MiB。512MiB目標は未達。詳細は[測定記録](quality/RELEASE_UI_100K_2026-10-12.md)。
- 🟠 [Next] 上記10万曲の常駐メモリ削減と、観測ツールの待ちを除く検索時間の計測。XCTestのAX階層取得が滞留するため、初回2秒・検索300msの自動ゲートは未完了。
- 🟢 [Done] A3実画面ゲートの計測基盤として、一時ディレクトリだけを受け付ける専用起動モードと決定論的な10万曲fixture生成を追加した。計測時はユーザーのライブラリ、更新確認、ファイル存在確認、端末同期、外部ストア通信から分離する。Release UIテストは初回表示、10検索のp95、各計測点のRSSを製品目標に対して判定し、通常のUIテストでは明示的にスキップする
- 🟢 [Done] A3のUI性能ゲートで、初回表示は曲表の先頭曲が実際に描画されるまで、検索は最後の文字を入力した時点から各クエリ固有の曲が描画されるまで計測する。前回の検索結果が残った「1件」表示による誤合格を防ぐ。計測値の取得と製品目標の判定は引き続き[Next]。
- 🟢 [Done] A4の音声境界の第1段階として、通常再生と次曲先読みで使う音声ファイルopen処理を`PlaybackController`へ注入可能にした。実エンジンを起動せずopen失敗を発生させ、対象曲・停止状態・ユーザー向けエラーを検証する自動試験を追加した
- 🟢 [Done] A4のMusicKit境界の第1段階として、再生開始・再開・前曲・次曲・キュー項目再生の非同期transport操作を`AppleMusicPlaybackOperations`へ分離した。ネットワーク再生を行わず各操作へ同一障害を注入でき、production controllerにも差し替え可能なことを自動試験で確認した
- 🟢 [Done] A4のUI更新境界として、Mac／MobileのMultipeerConnectivityデリゲートとProgress監視コールバックからUI状態へ触れる前に、明示的にMainActorへ橋渡しする。コントローラー全体のMainActor化はバックグラウンド転送を誤って隔離するため採用せず、Xcode 27の実行時queue検査で停止しない境界を回帰ゲートにした
- 🟢 [Done] A4のcheckpoint読書きでは初期化時に固定したSendable storeを転送キューへ値として渡す。破棄・期限切れ整理・一覧取得後の`resumableTransfers`更新はMainActorへ明示的に戻す
- 🟢 [Done] A4の転送状態分離として、Mac／Mobileで重複していた一時停止IDと保留チャンク要求を共通の`DeviceChunkTransferPauseCoordinator`へ移した。停止判定と要求保存を同じロック内で原子的に実行し、同時再開で要求が取り残される競合を除去した
- 🟢 [Done] アルバムのイニシャル分類で、日本語文字を含むタイトルに`albumSortName`がある場合は読み仮名の先頭を優先する。読みがない既存データと英字タイトルは従来の分類を維持する
- 🟠 [Next] A4の次段階として、チャンク転送のファイルI/O・checkpoint・転送中辞書を専用actorへ移し、現在Xcode 27が警告するDispatchQueueクロージャーからMainActor状態への参照を解消する
- 🟢 [Done] 上記A4境界変更をXcode 27.0で全296テスト、通常macOS Debug、Mac App Store Release、iOS Simulator Debugの順に検証した。並列Xcodeビルドは同一DerivedDataのDBロックを起こすため構成ビルドを直列化し、3構成すべて成功した
- ⭕️ [Pending] `TEST_RUNNER_ONGAKU_RUN_UI_PERFORMANCE=1 xcodebuild test -project OngakuDesktop.xcodeproj -scheme OngakuDesktop -configuration Release -destination 'platform=macOS' -only-testing:OngakuDesktopUITests/OngakuDesktopUITests/testReleaseLargeLibraryQualification` を署名済みローカル環境で実行し、初回表示2秒・検索p95 300ms・RSS 512MiBの実測値を記録する。その後、実音声fixtureを加えて再生中、索引差分更新中、両者同時の3条件を同じゲートへ統合する
- ⭕️ [Pending] 2026-09-15の実行ではReleaseアプリ／UIテストのビルドは成功したが、XcodeのUIテストランナーがAutomation Modeの有効化でタイムアウトし、計測本体の開始前に終了した。macOSのUIオートメーション権限を復旧後に上記コマンドを再実行し、数値が得られるまではA3の製品目標を合格扱いにしない
- ⭕️ [Pending] 2026-09-23のRelease UI計測再実行は、UIテストランナーがアプリへ接続する前にsignal killで終了したため数値なし。ローカルkeychainに有効な開発用署名IDは0件だった。署名可能な環境で実画面ゲートを再実行して判定する。
- 🟢 [Done] 曲・アーティスト・アルバムのセルクリックでTableのFocusStateも更新し、選択だけ変わって非アクティブのグレー表示になる経路を修正した。Debugビルド成功。実画面検証はユーザー操作との競合により未完了
- 🟢 [Done] 曲・アルバム・アーティストの曲表でウィンドウ活動状態に基づく白文字固定を撤去し、行の文字・状態アイコンを標準Tableの配色へ統一した。Debugビルド成功。曲一覧でライト／ダークの選択・選択解除と非アクティブ選択を実画面確認し、外観設定を元のライトへ戻した
- 🟢 [Done] 曲一覧、アルバム詳細、アーティスト詳細のすべてで、楽曲行のダブルクリックをTable標準のprimary actionへ統一し、対象曲を選択してその画面の並び順を再生キューとして再生する。単クリック選択とダブルクリックの競合を除去した
- 🟢 [Done] アーティスト・アルバム詳細の曲表にセル全体のクリック選択を追加し、表内選択とインスペクタのフォーカスを同期する。表示切替時の一時的なnil選択で全体フォーカスを消さない。macOS Debugビルドを確認。実画面での再現操作確認は歌詞編集中のため未実施
- 🟢 [Done] 起動時に旧Application Support/Ongaku Desktopの管理データを音楽フォルダ内のOngaku Library Dataへ移行する。既にportable設定でも旧保存先を確認し、新規ライブラリ・旧既定音楽フォルダも旧Application Supportへの新規保存を避ける。競合台帳はLegacy Importsへ再生履歴と一緒に保持し、移行失敗時は三言語のエラー画面で通常起動を停止する。再試行・競合・保存先の回帰試験を含む全272テスト成功。Store配布後の実コンテナでの移行確認はA6に含める
- 🟢 [Done] ストレージ選択をフォルダ固有のライブラリの作成／読み込みへ変更。新規フォルダには台帳・再生キュー・履歴・画像用ディレクトリを作成し、再選択では既存の楽曲・プレイリスト・再生位置を復元する。通常の選択で旧フォルダのデータは移動せず、読み込み失敗時は現在の設定を維持する。Musicライブラリはメディア内のOngaku Mediaに専用台帳を用意し、原本を参照登録する。必要時のメディアフォルダ選択とアクセス権の保存を三言語で追加。往復切り替え・失敗時の保持・Music原本の保持・バックアップ復旧を含む全304テストと通常版／App Store構成のDebugビルドが成功（2026-09-23）。署名済みStore版での外付けディスクの権限復元確認はA6に含める。
- 🟢 [Done] 空の台帳とLegacy Imports内の既存台帳が併存する場合に、ストレージ再選択から楽曲・プレイリスト・再生キュー・画像を復元する。Ongaku Desktop配下の従来構成も検出し、元台帳と置換前のデータは保存する。既に内容がある台帳は優先し、複数候補は自動選択せず三言語で通知する。登録解除後の再登録防止と、復元途中の書込失敗時のロールバックを含む全308テストに成功（2026-09-23）。
- 🔴 [Later] A6で対象構成が合格した後、App Store Connect情報・実署名Archiveを完成して提出する
- 🔴 [Later] 監視フォルダ、Mobile統合プレイヤー、CloudKit、共同編集、SharePlay、推薦拡張、M9の製品拡張
- 🔴 [Later] Google DriveとSMB/NASを読み取り専用の外部音源として登録し、先読みキャッシュ付きストリーミング再生を提供する。詳細はM11で管理する

### 実装台帳（配布資格を示すものではない）

- 🟢 [Done] SwiftUIによるネイティブmacOSライブラリ、アルバム、アーティスト、楽曲一覧
- 🟢 [Done] メインウインドウへの複数ファイル／フォルダのドラッグ＆ドロップ取り込み、アーティスト／アルバム別の管理コピー、原本参照、SHA-256重複検出
- 🟢 [Done] 原子的なカタログ保存、バックアップ、取り込みジャーナル、整合性検証
- 🟢 [Done] 再生、一時停止、シーク、音量、順次・1曲リピート・全曲リピート・アルバムリピート・シャッフル
- 🟢 [Done] 出力機器に応じた最大384 kHzのサンプルレート選択
- 🟢 [Done] 10種類のリアルタイムDSP、プリセット、ステレオレベル表示
- 🟢 [Done] ミニプレイヤーと通常プレイヤーバー
- 🟢 [Done] 埋め込み、オンライン、自動キャッシュ、手動指定によるアルバム／アーティスト画像
- 🟢 [Done] 楽曲・アルバム・アーティスト単位の情報／画像編集、M4A・M4B・MP4へのタグ優先埋め込みと安全なカタログフォールバック
- 🟢 [Done] 英語、日本語、简体中文のローカライズ基盤
- 🟢 [Done] Universal Binary、Developer ID署名・公証済みDMG、Sparkle更新、macOS AppIcon
- 🟢 [Done] GitHub向けDeveloper ID／Sparkle版と、App Sandbox・Store更新専用のMac App Store版を別ターゲット・別Info.plist・別entitlementsで分離
- 🟢 [Done] Mac App Store版からSparkle、独自アップデート、直接USB検出、CD取り込み導線を除外し、CIでStore版のコンパイルとSparkle非混入を検査
- 🔴 [Later] App Store Connectのアプリ登録、提出情報・スクリーンショット・プライバシー回答を完成し、実署名Archiveをアップロードして審査へ提出
- 🔴 [Later] 審査承認済みStore版の手動／予約公開とGitHub DMG公開を同一リリース日に連携するリリース運用の自動化

### 直近の不足

- 🟢 [Done] 永続的な再生キュー、次はこちら、挿入、末尾追加、削除、並べ替え、戻る操作
- 🟢 [Done] 再生セッション単位の開始・完了・スキップ履歴、履歴表示・消去、キューのドラッグによる直接並べ替え
- 🟢 [Done] 同一処理フォーマット曲の5秒プリロールとギャップレス切り替え、異種フォーマットの安全な再構築、再生中の割り込み・出力機器変更への復旧
- 🟢 [Done] 0〜12秒クロスフェード、等電力60 Hzフェード、アルバム内ギャップレス優先、三言語の再生設定
- 🟢 [Done] 曲頭・曲末12秒の非同期無音解析、解析キャッシュ、20 msの安全余白を残したクロスフェード遷移位置の最適化
- 🟢 [Done] 通常プレイリスト、フォルダ、スマートプレイリスト、読み込み・書き出し
- 🟢 [Done] お気に入り、0〜5星評価、再生回数、スキップ回数、最終再生日、自動再生対象外
- 🟢 [Done] ピン留め、最近追加、よく再生、最近再生、お気に入りの標準ビュー
- 🟢 [Done] 通常プレイリストの作成、名称変更、説明、画像、複製、削除
- 🟢 [Done] 複数選択、チェック式の一括メタデータ編集、混在値表示、保存前の変更プレビュー
- 🟢 [Done] 歌詞の表示・編集、LRC読み込み、タイム同期表示、対応ファイルへのプレーン歌詞埋め込み
- 🟢 [Done] LRCLIB完全一致取得、候補検索、信頼度付き確認、選択後のローカル保存
- 🟢 [Done] MusicBrainz書誌情報候補とCover Art Archive画像候補の確認・保存
- 🟢 [Done] 参加者クレジット、作品・楽章、BPM、著作権、ISRCの追加メタデータ
- 🟢 [Done] SHA-256による完全重複とメタデータ／再生時間による候補重複の比較、保持対象選択、安全な登録解除と管理ファイルのゴミ箱移動
- 🟢 [Done] 曲一覧の表示列カスタマイズと並べ替え列／昇順・降順の永続化
- 🟢 [Done] アーティスト・アルバム・作曲者・ジャンル・発売年・評価・お気に入り・コンピレーション・ファイル状態の詳細フィルタと全メタデータ全文検索
- 🟢 [Done] 複数ライブラリの作成・切り替え・名称変更・アーカイブ
- 🟢 [Done] ファイル参照切れの自動探索と手動再リンク
- 🟢 [Done] 監視フォルダの自動取り込みと変更検出
- 🟢 [Done] MusicKitの権限・加入能力判定、カタログ検索、クラウドライブラリ追加とiTunes Store購入ページへの公式ハンドオフ
- 🟢 [Done] Apple Musicカタログの単曲再生と、再生元切り替え時のローカル／カタログ二重再生防止
- 🟢 [Done] Apple Musicのアルバム／プレイリスト再生キューと、画面・メディアキーの再生元別自動ルーティング
- 🟢 [Done] Apple Musicキューの現在曲・残り曲・再生時間をローカルキューと同じキュー画面へ表示
- 🟢 [Done] Apple Musicキューへの「次に再生」「あとで再生」、再生中項目を保護した曲移動、選択再生
- 🟢 [Done] Apple Musicのミュージックビデオ／ステーション検索、ステーション再生、チャート取得、未加入時のApple公式加入案内
- 🟢 [Done] Apple Music利用者ライブラリの曲／アルバム／プレイリスト閲覧、プレイリスト作成、検索結果の曲追加
- 🟢 [Done] Apple Musicライブラリのお気に入り追加／解除、100件単位のページング、認証・地域差・競合・レート制限エラーの三言語表示
- 🟢 [Done] Apple Musicプレイリスト内容の閲覧、同期ライブラリ内検索、曲／アルバム／プレイリスト絞り込み
- 🟢 [Done] メイン検索欄からローカル・Apple Musicカタログ・同期ライブラリを横断する統合検索と出所表示
- 🟢 [Done] Apple Musicキューの単一／複数選択削除、再生中項目の保護、一括消去、通信失敗時の同一操作再試行
- 🟢 [Done] Apple Musicのホーム、個人向けおすすめ棚、最近再生、公開おすすめ／チャートの発売日から構成する新着リリース棚
- 🟢 [Done] Apple Musicおすすめ棚のページング、棚IDを維持する差分更新、アルバム／プレイリストの項目詳細画面
- 🟢 [Done] ストアフロントの都市別／ジャンル別チャート、関連アルバム／掲載プレイリスト／同一キュレーター項目の探索導線
- 🟢 [Done] Apple公式Replayサイトへの導線、チャート項目のページング、取得済み都市名による絞り込み
- 🟢 [Done] Ongaku Mixの基礎特徴量モデル、候補選定、説明可能な選曲理由の表示
- 🟢 [Done] PCM解析によるラウドネス、スペクトル重心、テンポ信頼度とSHA-256連動キャッシュ
- 🟢 [Done] 調性、オンセット、拍位置解析とライブラリ全体の解析・中止・進捗管理
- 🟢 [Done] 音響解析ジョブの手動一時停止・再開、低電力モード／高温時の自動停止・復帰
- 🟢 [Done] 相対調・平行調・五度関係の互換評価と、近いテンポの拍位置に揃えるOngaku Mix遷移
- 🟢 [Done] 平均ラウドネスとサンプルピークの世代管理付き解析、曲／アルバム単位のSound Check相当、目標音量、ピーク／クロスフェードのクリッピング保護
- 🟢 [Done] MusicBrainz Disc ID／TOC検索、リリース候補の明示選択、ALAC・AIFF・WAV・AAC品質選択、最大3回の再読込一致検証と変換後検証
- 🟢 [Done] 公開HTTPS URLからの対応音声取り込み、リダイレクト先・MIME／拡張子・512 MB上限・実音声内容の事前検証
- 🟢 [Done] Music.app／iTunesのライブラリXML事前プレビュー、原本非変更の検証コピー、詳細メタデータ／通常プレイリスト移行、再実行時の重複防止
- 🟢 [Done] 他のOngakuライブラリの非破壊プレビュー、検証コピー、詳細メタデータ、通常／スマートプレイリスト、フォルダ統合、再実行時の重複防止
- 🟢 [Done] マウント済み共有フォルダの再帰プレビュー、アクセス権保持、SHA-256検証コピー、登録済み判定、原本非変更、再実行時の重複防止
- 🟢 [Done] MediaフォルダのArtist／Album整理と移動を、dry-run、競合回避、SHA-256再検証、永続ジャーナル、失敗／異常終了時ロールバック付きで実装
- 🟢 [Done] 外付けボリューム用ライブラリとライブラリUUID照合付き再接続アシスタント
- 🟢 [Done] MediaPlayerによるシステムNow Playing、メディアキー、Control Center連携

### Ongaku Mobile — このリポジトリの実装範囲

本リポジトリのiOSターゲットは同期companionである。別のOngakuアプリに関する実装主張を引き継がない。`Sources/OngakuMobile`とXcodeターゲットで確認できない統合再生・システム楽曲編集を完了台帳から外した。

- 🟢 [Done] Mobileのファイル読み込み、管理ファイルの一覧、Macとのペアリング、個別送受信、進捗・制御・永続チャンクチェックポイント
- 🟢 [Done] 英語・日本語・简体中文のリソース、SE第3世代と16 Pro MaxのPreview定義
- 🟢 [Done] Mac側の評価・タグ・プレイリスト同期モデル、差分プレビュー、選択適用と監査・保守的Undo。共有モデルの存在はMobileの編集UI完成を意味しない
- 🟢 [Done] Mac側のApple MusicプレイリストからOngakuへの変換プレビューとOngakuからApple Musicへの書き出し・部分失敗記録
- 🔴 [Later] `MPMediaQuery`によるシステム楽曲と管理楽曲の統合検索・再生、出所と能力表示、変更監視・メタデータキャッシュ
- 🔴 [Later] Mobile側の評価・お気に入り・表示タグ・独自プレイリスト編集、オーバーレイ送受信・適用・監査UI
- 🔴 [Later] 既存Apple Musicプレイリストの安全な更新・削除・並べ替え

保存成功前の完了通知と保存失敗の握りつぶしはA1で修正済み。実機の強制終了・再接続はA6の配布ゲートに残る。

## 4. 機能網羅表

| 領域           | 対象機能                                                                                                 | 実装方針                                                                                                                                                          | 予定                                                                                                                                        |
| -------------- | -------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| アカウント     | Apple Account認証、MusicKit権限、サブスクリプション状態、利用不可地域の表示                              | MusicKitの正規認証と能力判定                                                                                                                                      | [Done] 基礎、[Later] 地域差 M6                                                                                                              |
| Apple Music    | ホーム、新着、検索、カタログ、チャート、推薦、最近再生、Replay、ラジオ、ステーション、ミュージックビデオ | MusicKit / Apple Music API。取得不能な棚は非表示ではなく理由を表示                                                                                                | [Done] ホーム・新着・個人向け推薦・最近再生・基礎検索・チャート・ステーション再生、[Later] Replay／詳細発見棚 M7                            |
| 同期ライブラリ | Apple Musicライブラリの参照、追加、プレイリスト更新、端末間同期                                          | MusicKitで許可された操作を実装。Ongaku独自データのクラウド同期は未導入。必要性と正本・競合設計を確認して方式決定                                                  | [Done] 閲覧・追加・お気に入り・ページング・内容表示・検索、配布資格はA6                                                                     |
| オフライン     | ローカル音源のダウンロード管理、空き容量、削除                                                           | 自前管理音源は完全対応。Apple Music DRM曲の任意ダウンロードは公開API可否をゲート判定                                                                              | [Later] M5–M6                                                                                                                               |
| 購入           | iTunes Store検索、購入、購入済み曲の再取得                                                               | 購入UIは公式Storeへハンドオフ。取得済みローカルファイルを安全に取り込む                                                                                           | [Done] 検索・公式ハンドオフ、[Later] 再取得 M8                                                                                              |
| 取り込み       | ファイル、フォルダ、URL、CD、他ライブラリ、Home Sharing                                                  | 対応形式を拡張し、取り込み前プレビューと衝突解決を共通化                                                                                                          | [Done] ファイル・フォルダ・URL・CD・Music/iTunes XML・Ongaku・共有フォルダ・Mediaフォルダ整理、[Done] 外付けボリューム対応 M5、実機品質はA6 |
| 検索           | 曲名、アーティスト、アルバム、作曲者、ジャンル、歌詞、全メタデータ、Apple Musicカタログ                  | ローカル全文検索インデックスとMusicKit検索を統合                                                                                                                  | [Done] ローカル・カタログ・同期ライブラリ横断検索と出所表示、[Later] 推薦順位統合 M7                                                        |
| 再生           | キュー、履歴、シャッフル、リピート、ギャップレス、クロスフェード、AutoMix相当、自動再生                  | ローカル再生エンジンを先に完成。AutoMix相当はテンポ・無音・拍位置解析で段階導入                                                                                   | [Done] 基本再生・キュー、[Later] 追加解析。配布資格はA6                                                                                     |
| 音質           | Lossless、空間オーディオ、EQ、Sound Check相当、音量制限、出力先、AirPlay、HDMI                           | AVFoundation/Core Audioの公開範囲で対応し、排他条件を明示                                                                                                         | [Done] Sound Check相当・正規化段のクリッピング保護、[Later] Lossless経路・出力先 M4                                                         |
| 表示           | 曲、アルバム、アーティスト、作曲者、ジャンル、コンピレーション、最近追加、ミニプレイヤー、フルスクリーン | 保存可能な表示設定、列、並べ替え、ピン留めを追加                                                                                                                  | [Later] M3, M9                                                                                                                              |
| プレイリスト   | 作成、編集、削除、画像、説明、並べ替え、フォルダ、スマート、読み書き、曲から逆引き                       | 安定IDとルールエンジンをデータモデルへ追加                                                                                                                        | [Done] M2                                                                                                                                   |
| Genius         | Geniusプレイリスト、Genius Shuffle相当                                                                   | Appleの非公開アルゴリズムではなく、ローカル音響特徴と履歴による「Ongaku Mix」として提供                                                                           | [Done] メタデータ・履歴・PCM特徴量・拍位置・調性遷移 M7                                                                                     |
| ライブラリ管理 | 歌詞、情報、アート、評価、お気に入り、重複、削除、ピン、複数ライブラリ                                   | 非破壊編集を維持。歌詞はLRCLIB、書誌情報はMusicBrainz、ジャケットはCover Art Archiveから候補を取得し、出典と信頼度を確認後にローカル保存                          | [Done] M2–M3                                                                                                                                |
| ファイル管理   | Mediaフォルダ、整理、統合、場所変更、変換、ファイル参照切れ修復                                          | トランザクション、チェックサム、dry-run、ロールバックを必須化                                                                                                     | [Done] 整理・移動・再リンク、[Later] 未実装形式・復元。配布資格はA6                                                                         |
| 共有           | 共有シート、リンク、書き出し、Home Sharing相当、CD/DVD作成                                               | 標準共有シート、標準LAN共有、M3U/XML、DiscRecording可否調査                                                                                                       | [Later] M5, M8                                                                                                                              |
| ソーシャル     | プロフィール、友達、視聴履歴共有、共同プレイリスト、絵文字リアクション                                   | Apple Music APIで可能な範囲を優先し、不足分は同意制の独自バックエンド                                                                                             | [Later] M7                                                                                                                                  |
| SharePlay      | FaceTime中の同期再生、参加、退出、操作権限                                                               | GroupActivitiesで再生位置とキュー操作を同期                                                                                                                       | [Later] M7                                                                                                                                  |
| ファミリー     | Family Sharing加入状態に沿ったサービス利用                                                               | Appleの権限状態を尊重し、独自の契約共有は実装しない                                                                                                               | [Later] M6                                                                                                                                  |
| 端末連携       | iPhone/iPad接続、差分取り込み、同期、書き出し、Remote操作                                                | Ongaku companionアプリとNetwork framework／Bonjourで接続し、転送可能な非保護音源だけをチェックサム照合して取り込む。Finder同期とApple Music保護曲は公式導線へ分離 | [Later] M8                                                                                                                                  |
| 設定           | 一般、再生、ファイル、詳細、アカウント、通知、制限、プライバシー                                         | 設定スキーマをバージョン管理し、検索と初期値復元を提供                                                                                                            | [Later] M4, M9                                                                                                                              |
| システム統合   | Now Playing、メディアキー、Siri候補、通知、Spotlight、ショートカット、アクセシビリティ                   | MediaPlayer、App Intents、Core Spotlight、UserNotifications                                                                                                       | [Done] Now Playing・メディアキー; [Later] M9                                                                                                |
| その他         | ビジュアライザ、キーボードショートカット、メニュー、ヘルプ、記号説明                                     | Metal/SwiftUI、Commands、Help Book                                                                                                                                | [Later] M9                                                                                                                                  |

## 5. 制約がある機能

| Apple Musicの機能                     | 制約                                                                                                                                                                   | Ongaku Desktopでの着地点                                                                                                                                                                                                             |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| iTunes Storeでの購入                  | 第三者アプリがAppleの購入画面を複製する公開APIはない                                                                                                                   | 検索結果から公式Storeを開き、購入後のファイルを取り込む                                                                                                                                                                              |
| Apple Music DRM曲の任意オフライン保存 | MusicKitはカタログ検索・再生・ライブラリ追加を提供するが、任意のDRMファイル管理は保証されない                                                                          | M6で実機検証し、不可ならストリーミングのみ。誤解を招くダウンロードボタンは置かない                                                                                                                                                   |
| Genius                                | アルゴリズムと学習データは非公開                                                                                                                                       | 「Ongaku Mix」として独自実装し、Genius互換を名乗らない                                                                                                                                                                               |
| Appleの友達・フォロワー機能           | 公開APIで取得・更新できる範囲が限定的                                                                                                                                  | Apple側で可能な操作と、独自プロフィール／共同編集を明確に分離                                                                                                                                                                        |
| Home Sharing                          | Apple固有の共有プロトコル全体は公開されていない                                                                                                                        | ローカルネットワーク上の標準的な読み取り専用共有とライブラリ移行を提供                                                                                                                                                               |
| iPhone/iPadへのMusic同期              | macOSではFinderが同期主体                                                                                                                                              | Finderを開くハンドオフ、M3U/音源書き出し、将来のcompanion同期を提供                                                                                                                                                                  |
| iPhone/iPadからの音源取り込み         | 公開APIでは端末のMusicライブラリ全体をFinderのように読み出せず、Apple MusicのDRM保護曲、`assetURL`を取得できない曲、クラウド上だけの曲は音声ファイルとして転送できない | companionアプリのDocuments内、ファイル選択で明示許可された音源、実機判定で読み出せる非保護音源だけを対象にする。対象外は「DRM保護」「クラウドのみ」「転送不可」を表示し、メタデータ照合とApple Music公式再生／ダウンロード導線を提供 |
| AutoMix                               | Apple Musicカタログ、Apple silicon、対応OS等の条件がある                                                                                                               | ローカル曲向けの無音除去、クロスフェード、BPM/拍合わせを独自実装                                                                                                                                                                     |

公開APIが増えた場合は四半期ごとに再評価し、代替実装から正規連携へ移行する。

## 6. リリースゲート

旧2026〜2028年の固定日程・バージョン割当は、実装台帳と一致しないため取り下げる。M0〜M10は機能分類のIDとして残す。バージョンと公開日は配布資格が確定してから割り当てる。

| 順序 | 範囲               | 必要な証拠                                        | 現在の判定 |
| ---- | ------------------ | ------------------------------------------------- | ---------- |
| G1   | 保存の安全性       | A1・A2・必要なA4、失敗注入、移行と復旧            | 未合格     |
| G2   | 大規模の実操作     | A3、Releaseの起動・入力・同時更新・書込量・メモリ | 未合格     |
| G3   | 配布構成ごとの資格 | A5・A6、署名UI・音声・権限・通信                  | 未合格     |
| G4   | 提出／公開         | 対象範囲のG1〜G3、配布情報、更新／復旧手順        | G3の後     |
| G5   | 次の機能拡張       | 利用実績、必要性、追加範囲のAPI・保存設計         | G4の後     |

Mobileの未合格だけでローカル専用版を永久に止めない。ただし対象外機能の入口と説明を含む配布構成を検証し、未検証機能を同梱して完成と表現しない。

## 7. 機能分類別の実装台帳

### M0 — 基盤固定（実装台帳・配布判定未了）

- 🟢 [Done] `Library`、`Track`、`Album`、`Artist`の永続IDとカタログスキーマ2を定義
- 🟢 [Done] スキーマ1／無バージョン形式からの原子的マイグレーションと安全なバックアップ復旧を実装
- 🟢 [Done] 旧形式、無バージョン、破損形式、将来バージョンのfixtureをテスト資産化
- 🟢 [Done] `Playlist`、`PlaylistEntry`、`PlaybackEvent`の安定IDと保存モデルをカタログスキーマ3へ追加
- 🟢 [Done] スキーマ2からの原子的マイグレーションと、楽曲保存時にプレイリスト／履歴を失わない永続化を実装
- 🟢 [Done] カタログスキーマ4へ永続キューを追加し、スキーマ3からの移行・順序・現在曲・再生位置の復元テストを追加
- 🟢 [Done] カタログスキーマ5へお気に入り、0〜5星評価、自動再生対象外を追加し、再生イベントから再生回数、スキップ回数、最終再生日を集計
- 🟢 [Done] カタログスキーマ6へプレイリストフォルダ、フォルダ所属、サイドバー表示順を追加し、スキーマ5以前の配列順を保持して移行
- 🟢 [Done] カタログスキーマ7へスマートプレイリストの再帰条件モデルと件数上限を追加し、スキーマ6から互換移行
- 🟢 [Done] カタログスキーマ8へMusic.app相当の詳細タグ、読みがな、作品整理、トラック／ディスク、評価、基準再生回数、コメントを追加し、スキーマ7から互換移行
- 🟢 [Done] カタログスキーマ9へ楽曲のピン留め状態を追加し、スキーマ8から未設定を安全な既定値として互換移行
- 🟢 [Done] カタログスキーマ10へプレーン／時間同期歌詞、取得元、更新日時、手動編集状態を追加し、スキーマ9から歌詞未設定として互換移行
- 🟢 [Done] 決定論的な10万曲性能fixtureと任意実行ベンチマークを追加
- 🟢 [Done] [ADR-0001](adr/0001-large-library-storage.md)で性能予算とSQLite移行条件を確定
- 🟢 [Done] 10万曲検索の予算超過に対し、[ADR-0001](adr/0001-large-library-storage.md)準拠のSQLiteカタログ、FTS5検索、JSON移行・ロールバック検証を実装
- 🟢 [Done] JSON／SQLiteのdual-read一致検証を追加し、一致確認後のアプリ内検索をSQLiteへ切り替え（同期中・失敗時はJSON検索へ自動フォールバック）
- 🟢 [Done] MusicKit App Service対応、三言語の利用目的、認証状態、加入能力、クラウドライブラリ能力、曲・アルバム・アーティスト検索、曲のライブラリ追加を実装
- 🟢 [Done] MusicKitカタログ単曲再生とローカル曲を安全に切り替える出所別プレイヤーadapterの技術スパイク
- 🟢 [Done] [ADR-0002](adr/0002-public-api-and-privacy-boundary.md)で公開API制約表とプライバシーデータフローを確定し、macOS／iOSのPrivacy Manifestと利用者向け[プライバシー概要](PRIVACY.md)を追加
- 🟢 [Done] [M0品質ゲート](quality/M0_MANUAL_TEST_MATRIX.md)としてXCUITestターゲット、主要画面のVoiceOver識別子、キーボード操作、英日中キー／書式／見出し幅、Privacy Manifest、macOS／iOSビルドのCIゲートを追加

終了条件: 既存データを失わず新旧スキーマを往復検証でき、M6の実現可能範囲が意思決定済みであること。

### M1 — 再生パリティ（実装台帳・配布判定未了）

- 🟢 [Done] 永続キュー、「次はこちら」、挿入、末尾追加、削除、並べ替え、元に戻す、現在曲と再生位置の復元
- 🟢 [Done] 再生セッション単位の開始・完了・スキップ履歴、履歴表示・消去、キューのドラッグによる直接並べ替え
- 🟢 [Done] 前の曲、次の曲、曲途中での「前へ」挙動、キュー枯渇、自動再生
- 🟢 [Done] 終了5秒前の次曲プリロール、同一処理フォーマット曲のAVAudioPlayerNode連続予約によるギャップレス再生、異なるサンプルレート・チャンネル・PCM形式の安全なエンジン再構築
- 🟢 [Done] スリープ前の位置と再生意図を保持した復帰、AVAudioEngine構成変更・ヘッドホン抜去・出力機器変更時のデバウンス付き再構築、同一再生セッションの継続
- 🟢 [Done] お気に入り、0〜5星評価、再生回数、スキップ回数、最終再生日、自動再生対象外
- 🟢 [Done] `MPNowPlayingInfoCenter`へ曲名、アーティスト、アルバム、アート、再生位置、再生状態、キュー位置を同期し、remote command centerの再生、一時停止、切り替え、前後移動、シークへ対応
- 🟢 [Done] [M1再生パリティ終了判定](quality/M1_PLAYBACK_QUALIFICATION.md)として1,000曲の連続／シャッフル試験、新規プロセスでのキュー・現在曲・位置復元、音源一時不在時の位置保持をCIへ追加

終了条件: 1,000曲の連続・シャッフル試験を完走し、キューと再生位置がクラッシュ後も復元されること。

### M2 — プレイリストと整理（実装台帳・配布判定未了）

- 🟢 [Done] 通常プレイリストの作成、名称変更、説明、画像、複製、削除
- 🟢 [Done] サイドバーへのドラッグ＆ドロップ、曲一覧の複数選択、重複を無視する追加ポリシー、曲から所属プレイリストを表示
- 🟢 [Done] プレイリスト内の曲順を行へのドラッグで直接並べ替え、作成・編集・複製・削除・曲追加・曲削除・曲順変更のUndo／Redo
- 🟢 [Done] プレイリストフォルダの作成・名称変更・削除、所属変更、フォルダ／プレイリストのサイドバー直接並べ替え、Undo／Redo
- 🟢 [Done] スマートプレイリストの条件ビルダー、AND/OR、入れ子、上限、メタデータ・お気に入り・評価・再生統計のライブ更新
- 🟢 [Done] M3U/M3U8/JSONの読み込み・書き出し、相対／絶対パス・曲ID・メタデータ照合、一致・重複・未検出の差分プレビュー
- 🟢 [Done] ピン留め、最近追加、よく再生、最近再生、お気に入りの標準ビュー。最近系は既定の時系列／再生回数順を維持し、列操作後のみ手動ソート
- 🟢 [Done] [M2プレイリストと整理の終了判定](quality/M2_PLAYLIST_QUALIFICATION.md)として全編集のUndo／Redo、再起動、チェックサム再リンク、メタデータ変更後の楽曲ID参照維持をCIへ追加

終了条件: プレイリスト操作が全てUndo可能で、再起動・楽曲移動・メタデータ変更後も参照が壊れないこと。

### M3 — ライブラリ管理（実装台帳・配布判定未了）

- 🟢 [Done] 任意の複数楽曲に対するチェック式の一括メタデータ編集、混在値表示、変更プレビュー、対応音声ファイルへのタグ埋め込み
- 🟢 [Done] アーティスト名／アルバム名の保存時に確認を表示し、承認された管理ファイルだけを新しいArtist／Albumディレクトリへチェックサム検証・ロールバック付きで移動
- 🟢 [Done] 歌詞の表示・編集、LRC読み込み、複数タイムスタンプとoffset対応、再生位置への追従、行クリックによるシーク
- 🟢 [Done] [LRCLIB API](https://lrclib.net/docs)の`/api/get`による曲名・アーティスト・アルバム・再生時間の完全一致取得と、`/api/search`による候補検索
- 🟢 [Done] LRCLIBの`plainLyrics`／`syncedLyrics`／`instrumental`を統一歌詞モデルへ変換し、取得元、LRCLIB ID、取得日時、手動修正の有無とともにカタログへ保存してオフライン表示
- 🟢 [Done] 完全一致と検索候補へ再生時間の差を含む信頼度を表示し、利用者が候補を確認してから保存。埋め込み歌詞と手動編集を優先
- 🟢 [Done] Ongaku Desktopの名前・実行中のバージョン・GitHub URLを含む`User-Agent`を送信し、リクエストを直列化して350 ms間隔を確保。HTTP 429では`Retry-After`を厳守
- 🔴 [Later] 初期対応は読み取り専用とし、実験的な`/api/publish`とproof-of-work challengeによる投稿は、権利・同意・誤投稿防止の設計を別途確定するまで対象外
- 🟢 [Done] [MusicBrainz Web Service](https://musicbrainz.org/doc/MusicBrainz_API)から録音と発売版を検索し、録音・リリース・リリースグループ・アーティストID、ISRC、曲名、アルバム名、アーティスト名、日付、トラック／ディスク番号、国、媒体を編集候補として取得
- 🟢 [Done] 既存のISRCを最優先し、曲名、アーティスト、アルバム、再生時間とMusicBrainz検索スコアを段階的に照合して信頼度と再生時間差を表示し、利用者の承認後だけ非破壊保存
- 🟢 [Done] [Cover Art Archive](https://coverartarchive.org/)から選択したリリースIDに紐づくfront／back画像とサムネイルを取得し、画像種別を比較して任意の画像を保存。現在の埋め込み画像・手動設定を維持する選択肢も提供
- 🟢 [Done] MusicBrainzの識別可能な`User-Agent`、1.1秒の直列レート制御、503再試行、HTTPキャッシュと同一ID候補の重複排除をサービス層へ実装
- 🟢 [Done] カタログスキーマ11へMusicBrainzの録音・リリース・リリースグループ・アーティストID、ISRC、国、媒体、取得日時を追加し、スキーマ10から未設定として互換移行
- 🟢 [Done] 楽曲・アルバム編集へアーティスト／アルバム／アルバムアーティスト／作曲者の読みがな、グループ、ジャンル、発売年、トラック／ディスク番号、コンピレーション、評価、再生回数、コメントを追加し、M4A／M4B／MP4の対応タグを優先して埋め込み
- 🟢 [Done] 参加者クレジット、作品名、楽章名／番号、BPM、著作権、ISRCを楽曲・一括編集へ追加。アルバム編集では楽曲固有値を維持し、M4A／M4B／MP4のCredits、Track Subtitle、BPM、Copyright、ISRCタグへ可能な範囲で埋め込み
- 🟢 [Done] カタログスキーマ12へ追加メタデータを保存し、スキーマ11から未設定として互換移行。読み込み時もiTunes／ID3の対応タグを優先取得
- 🟢 [Done] SHA-256一致を完全重複、正規化した曲名・アーティストと3秒以内の再生時間差を候補重複として一覧化。保持曲を明示的に選び、プレイリスト・再生履歴・キュー参照を統合してから不要な登録を解除
- 🟢 [Done] ファイル操作はOngaku Media内の管理ファイルだけをゴミ箱へ移動し、外部参照ファイルと保持曲が共有するパスは変更しない。登録解除のみの非破壊操作も選択可能
- 🟢 [Done] アピアランス設定からアーティスト、アルバム、時間、ファイル列を個別に切り替え、曲名列を常時表示。最後に選んだ曲名／アーティスト／アルバムの並べ替えと昇順／降順を次回起動時に復元
- 🟢 [Done] アピアランス設定からスペクトラムのガラス背景を0〜100%で調整し、バー色を自動・白・黒・水色・緑・オレンジから選択。選択値を再起動後も復元
- 🟢 [Done] 作曲者、ジャンル、読みがな、グループ、参加者、作品・楽章、コメント、歌詞、ISRC、MusicBrainz識別子、ファイル名を含む全文検索をJSON／SQLite双方へ実装
- 🟢 [Done] アーティスト、アルバム、作曲者、ジャンル、発売年範囲、最低評価、お気に入り、コンピレーション、ファイル状態をAND条件で組み合わせる詳細フィルタ
- 🟢 [Done] 複数ライブラリの作成・切り替え・名称変更・アーカイブ。各ライブラリに独立したカタログ、メディア保存先、プレイリスト、再生履歴、再生キューを割り当て、サイドバーから切り替え
- 🟢 [Done] 検証時に現在のメディア保存先から参照切れファイルを自動探索。任意フォルダの探索と曲単位の手動再リンクにも対応し、SHA-256が一致した場合だけカタログ参照を非破壊で更新
- 🔴 [Later] 監視フォルダの自動取り込み、変更検出、重複・競合の明示的な解決は、永続セキュリティスコープと変更中ファイルの安定待ちを含めてローカル機能版1.0後に実装
- 🟢 [Done] [M3ライブラリ管理の終了判定](quality/M3_LIBRARY_QUALIFICATION.md)として10万曲のコールド表示・SQLite検索性能、削除対象件数、管理ファイルのゴミ箱復旧、外部参照保護をCIへ追加

終了条件: 10万曲で初期表示2秒以内、一般検索300 ms以内を目標とし、削除操作に対象と復旧可否が明示されること。

### M4 — 音質と出力（実装台帳・配布判定未了）

- 🟢 [Done] 0〜12秒クロスフェード、アルバム内の無効化、同一処理フォーマット曲の二重プレイヤーノード遷移
- 🟢 [Done] 曲頭・曲末12秒の非同期無音解析、-50 dB基準の10 ms RMS判定、解析結果を反映した遷移
- 🟢 [Done] 平均ラウドネスとサンプルピークをSHA-256連動キャッシュへ保存し、曲／アルバム単位の正規化、目標音量、実適用ゲイン表示、ピーク／クロスフェード保護を実装
- 🔴 [Later] Lossless／Hi-Res Lossless経路の表示と実フォーマット検証
- 🔴 [Later] マルチチャンネル／空間音声ファイルの再生可否検証と明示的フォールバック
- 🔴 [Later] 出力機器選択、AirPlayルート、HDMI passthrough可否、機器ごとの設定
- 🔴 [Later] EQプリセット、利用者プリセット、DSP順序、バイパス、A/B、CPU負荷表示
- 🔴 [Later] 波形キャッシュと再利用可能な音響解析結果の永続化
- 🟢 [Done] AutoMix相当の第1段階として、同一アルバムの原音を維持する無音除去と解析ベースの遷移を実装
- 🟢 [Done] [M4音質と出力の終了判定](quality/M4_AUDIO_PATH_QUALIFICATION.md)として入力・内部処理・DSP・正規化・実出力・原音非変更を同じスナップショットからUIとOSログへ提示し、実音声ファイルでCI検証

終了条件: 音源を変更せず、サンプルレート、チャンネル、DSP、音量正規化の実経路をUIとログで説明できること。

### M5 — ローカル完全版（実装台帳・配布判定未了）

- 🟢 [Done] macOSにマウントされたオーディオCDの検出、トラック選択、曲名・アーティスト・アルバム編集、原本非変更のAIFF取り込み、SHA-256コピー検証
- 🟢 [Done] MusicBrainz Disc ID／TOC検索、複数リリース候補の選択、曲名・曲別アーティスト・MusicBrainz識別子の保存、ALAC・AIFF・WAV・AAC品質選択、最大3回の再読込一致検証と変換後再検証
- 🟢 [Done] 公開HTTPS URLからの対応音声取り込み、リダイレクト先・MIME／拡張子・512 MB上限・実音声内容の事前検証
- 🟢 [Done] Music.app／iTunesのライブラリXML事前プレビュー、原本非変更の検証コピー、詳細メタデータ／通常プレイリスト移行、再実行時の重複防止
- 🟢 [Done] 他のOngakuライブラリの非破壊プレビュー、検証コピー、詳細メタデータ、通常／スマートプレイリスト、フォルダ統合、再実行時の重複防止
- 🟢 [Done] マウント済み共有フォルダの再帰プレビュー、アクセス権保持、SHA-256検証コピー、登録済み判定、原本非変更、再実行時の重複防止
- 🟢 [Done] MediaフォルダのArtist／Album整理と移動を、dry-run、競合回避、SHA-256再検証、永続ジャーナル、失敗／異常終了時ロールバック付きで実装
- 🟢 [Done] 外付けボリュームにカタログとMediaをまとめたライブラリを作成し、マウント状態の自動更新、切断表示、選択禁止、永続セキュリティスコープ、ライブラリUUID照合付き再接続アシスタントを実装
- 🟢 [Done] CD取り込みのAAC、ALAC、AIFF、WAV変換と、AIFF原音コピー／変換用一時ファイルの明示的な原本保持ポリシー
- 🔴[Later] ポータブル書き出し
- 🔴[Later] LAN上の読み取り専用ライブラリ共有と接続認証
- 🔴 [Later] 共有シート、M3U、音源パッケージ、CD/DVD作成の実現性に応じた提供
- 🔴 [Later] バックアップ先とチェックサム付き復元
- 🟢 [Done] [M5ローカル完全版の終了判定](quality/M5_LOCAL_COMPLETE_QUALIFICATION.md)として主要移行経路の原本非変更・チェックサム一致と、外付けライブラリの切断・誤接続拒否・再接続をCIで検証

終了条件: 主要移行経路ごとに原本非変更とチェックサム一致を自動テストし、ローカル機能版1.0を公開できること。

### M6 — Apple Music基盤（実装台帳・配布判定未了）

- 🟢[Done] MusicKit認証、三言語の権限説明、未決定・拒否・制限状態の安全な縮退
- 🟢[Done] サブスクリプションの再生・加入可能・クラウドライブラリ能力判定
- 🟢 [Done] カタログの曲、アルバム、アーティスト検索とApple Music公式ページへのハンドオフ
- 🟢 [Done] プレイリスト検索とアルバム／プレイリストのMusicKitキュー再生
- 🟢 [Done] ミュージックビデオ／ステーション検索、ステーション再生、曲／アルバム／プレイリスト／ミュージックビデオのチャート取得
- 🟢 [Done] 未加入状態の能力判定とApple公式加入ページへの三言語対応ハンドオフ
- 🟢 [Done] Apple Music曲とローカル曲の再生状態を分離し、切り替え時の二重再生を防止
- 🟢 [Done] カタログ単曲再生、一時停止、再開、ローカル再生への安全な復帰
- 🟢 [Done] カタログのアルバム／プレイリストキューとローカル再生を画面・メディアキーから排他的に操作
- 🟢 [Done] カタログキューの現在曲・残り曲・再生時間をローカルキューと同じ画面へ出所別表示
- 🟢 [Done] カタログキューの追加・移動・選択再生
- 🟢 [Done] カタログキューの単項目／複数選択削除、並べ替え、現在曲を保護した全消去と、検索・読み込み・再生の通信エラーからの再試行
- 🔴 [Later] ミュージックビデオ再生、フルスクリーン、画質設定、音声のみへの安全な縮退
- 🟢 [Done] クラウドライブラリ有効時のカタログ曲追加
- 🟢 [Done] 利用者ライブラリの曲／アルバム／プレイリスト閲覧とMusicKitキュー再生
- 🟢 [Done] Apple Music APIによるプレイリスト作成と、カタログ曲／ライブラリ曲の末尾追加
- 🟢 [Done] 個人評価APIによるお気に入り追加／解除と既存評価の一括取得
- 🟢 [Done] 100件単位の追加読み込みと、ページ間の安定ID重複排除
- 🟢 [Done] 認証失効、地域／アカウント制限、更新競合、レート制限、サーバー障害の三言語エラー表示
- 🟢 [Done] プレイリストの曲／ミュージックビデオ内容表示
- 🟢 [Done] 同期ライブラリ専用検索と、曲／アルバム／プレイリストの種類別絞り込み
- 🟢 [Done] メイン検索欄の入力を350ミリ秒でまとめ、ローカル・カタログ・同期ライブラリを横断検索
- 🟢 [Done] 同期ライブラリ／Apple Musicカタログの出所バッジと、未認証時の安全なアクセス導線
- 🔴 [Later] DRMオフライン機能の公開API可否を実機で最終判定
- 🟢 [Done] [M6 Apple Music基盤の終了判定](quality/M6_APPLE_MUSIC_QUALIFICATION.md)として未加入、加入、権限未決定／拒否／制限、オフライン、地域差の能力縮退とローカル再生維持を共通ポリシーとCIで検証

終了条件: 未加入者、加入者、権限拒否、オフライン、地域差の全シナリオで安全に縮退すること。

### M7 — 発見、推薦、共有（実装台帳・配布判定未了）

- 🟢 [Done] 曲、アルバム、プレイリスト、ミュージックビデオの基礎チャート
- 🟢 [Done] ホーム、個人向け推薦棚、最近再生、公開おすすめ／チャート由来の新着リリース
- 🟢 [Done] おすすめ棚ページングとアルバム／プレイリスト詳細
- 🟢 [Done] 都市別／ジャンル別チャートと関連項目
- 🟢 [Done] Replayの公式導線、チャートページング、都市名フィルタ
- 🟢 [Done] Ongaku Mixの基礎特徴量モデル、候補順位、選曲理由表示
- 🟢 [Done] PCM解析によるラウドネス、スペクトル重心、テンポ信頼度と永続キャッシュ
- 🟢 [Done] 調性、オンセット、拍位置解析とライブラリ全体の解析・中止・進捗管理
- 🟢 [Done] 解析ジョブの一時停止・再開、進捗更新、低電力モード／高温時の自動停止・復帰
- 🟢 [Done] 調性互換を候補順位と選曲理由へ反映し、近いテンポでは拍位置へ揃えてクロスフェード
- 🟢 [Done] 平均ラウドネス／サンプルピーク解析、曲／アルバム単位のSound Check相当、正規化段のクリッピング防止
- 🟢 [Done] ステーション検索と直接再生
- 🔴 [Later] ラジオ棚、無限再生、自動再生
- 🟢 [Done] 初期非公開のプロフィール公開範囲と、公開範囲から独立した視聴履歴共有の明示的オプトイン、三言語の設定画面を実装
- 🟢 [Done] 共同プレイリストの期限付き招待、閲覧／編集権限、承認、手動失効、ブロックによる即時失効、最大200件の監査ログ、ソーシャルデータ全削除を実装
- 🔴 [Later] 共同編集バックエンドとの送受信、リアルタイム競合解決、絵文字リアクション
- 🔴 [Later] GroupActivitiesによるSharePlay同期再生
- 🔴 [Later] Family Sharing状態に応じたApple Music機能の表示
- 🟢 [Done] [M7 発見、推薦、共有の終了判定](quality/M7_DISCOVERY_SHARING_QUALIFICATION.md)として初期非公開、履歴共有同意、招待期限、ブロック、監査上限、完全削除をCIで検証

終了条件: ソーシャル機能は初期状態で非公開とし、データ削除・招待失効・ブロック・監査ログが提供されること。

### M8 — Appleエコシステムと共有（実装台帳・配布判定未了）

- 🟢 [Done] iTunes Search APIによる地域別の楽曲・価格検索と公式購入ページへのハンドオフ
- 🔴 [Later] 購入済み項目の再取得後にローカルファイルを検出して取り込む案内
- 🔴 [Later] Finderの端末同期画面を開く導線と、端末向け書き出しプリセット
- 🟢 [Done] 本リポジトリのOngakuMobile companionでDocuments/Ongakuの管理音源を転送対象にする。別製品への統合は未検証
- 🟢 [Done] Bonjour探索、暗号化必須のMultipeer Connectivity、端末上の確認コードを用いる明示承認ペアリングを実装し、非公開の端末同期APIを使用しない
- 🟢 [Done] Mac App Store版はnetwork.clientのみの設定と権限検査を実装。双方向MCSessionに必要な最小権限は署名済み実機通信でA6にて判定し、現設定の妥当性をコンパイルだけで保証しない
- 🟢 [Done] 両アプリ起動中の自動検出・自動接続要求、iPhone全画面からの許可表示、要求の失効と連続表示抑制を実装
- 🟢 [Done] 公開IOKit情報によるUSB接続中のiPhone/iPad検知、状態表示、Finderファイル共有への導線を実装（音声転送は安全なローカルネットワークを使用）
- 🟢 [Done] iPhone/iPadとMacで安定ID、ファイルサイズ、更新日時、SHA-256を含むmanifestを交換し、チェックサムに基づく保有状態を差分表示する
- 🟢 [Done] Mac・iPhoneの両側で楽曲単位の個別アップロード／個別ダウンロードを提供し、受信後のファイルサイズとSHA-256一致を必須にする
- 🟢 [Done] 全曲／アーティスト／アルバム／曲単位の一括同期、重複除外、容量内同期の優先順と安全余白、削除なしの双方向統合プレビューを実装
- 🟢 [Done] Mac・iPhone双方の実転送進捗、一時停止・同一接続内での再開・キャンセル、256MB安全余白を含む容量事前判定、接続断の明示状態を共通プロトコルと三言語UIへ実装
- 🟢 [Done] 受信ファイルのサイズ・SHA-256とコピー先を検証し、Mobileの原子的カタログ保存成功後だけ完了通知する。保存失敗時のrollback、冪等再送、破損正本の退避・バックアップ復旧を実装
- 🟢 [Done] 256KiBチャンク転送、チャンクごとのSHA-256検証、永続チェックポイント、不足チャンクだけの再要求を実装し、接続後に同じ曲を再要求すると検証済み位置から再開する
- 🔴 [Later] MacとiPhone/iPad実機でWi-Fi切断、アプリ再起動、バックグラウンド遷移を挟むチャンク再開と大容量曲を検証する
- 🟢 [Done] iPhone 13 Pro（iOS 26.6.1、開発者モード有効）向け署名ビルド、既存App Store版と異なるBundle IDでのインストール、実機起動を確認
- 🟢 [Done] Macで受信した検証済みファイルを既存の安全な取り込みパイプラインへ渡し、確定前は一時領域に隔離して原本と既存ライブラリを変更しない
- 🔴 [Later] MediaPlayerの`hasProtectedAsset`、`assetURL`、クラウド状態を実機で判定し、「転送可能」「DRM保護」「クラウドのみ」「読み出し不可」を一覧に表示する
- 🔴 [Later] Apple Music保護曲と読み出し不可曲は音声転送せず、MusicKit／カタログIDによるメタデータ照合とMac側のApple Music公式再生・ダウンロード導線に限定する
- 🟢 [Done] 端末名、接続許可、確認コード、接続待ち案内とタイムアウト、個別／一括転送状態を英語、日本語、简体中文で提供する
- 🟢 [Done] 未完了転送の曲名・保存容量・進捗を表示し、30日後の自動失効と利用者による一括破棄をMac／iPhone双方へ実装
- 🔴 [Later] 完了済み転送の永続履歴、ペアリング解除、端末ライブラリ内の曲削除
- 🟢 [Done] iOSアプリのDocumentsをFinderファイル共有へ公開し、ネットワーク転送を使わない手動取り出し経路を用意する
- 🔴 [Later] MacとiPhone/iPad実機でペアリング、双方向個別転送、ローカルネットワーク権限拒否、破損転送を検証する
- 🟢 [Done] [M8転送堅牢化チェックポイント](quality/M8_TRANSFER_RESILIENCE_CHECKPOINT.md)として制御メッセージ、進捗境界、容量安全余白、接続断時の未確定維持を自動試験で検証
- 🟢 [Done] [M8実機スモークテスト](quality/M8_PHYSICAL_DEVICE_SMOKE.md)として署名、インストール、起動、既存Ongakuとの共存を確認
- 🔴 [Later] Home Sharing相当のLANブラウズ、アクセス制御、読み取り専用再生
- 🔴 [Later] CD/DVD作成、印刷可能な曲一覧、プレイリスト共有
- 🔴 [Later] iTunes Remote相当の安全なローカルリモコンAPI

終了条件: Apple非公開機能との差をUIとヘルプで明確にして非公開APIを一切利用せず、1,000曲の差分検出、転送中断・再開、重複、容量不足、DRM／クラウド曲混在を実機で検証し、転送済みファイルのチェックサム不一致とデータ損失が0件であること。

### M9 — 製品完成度 [Later]

- 🔴 [Later] 一般、再生、ファイル、詳細、アカウント設定の網羅と設定検索
- 🔴 [Later] 通知、コンテンツ制限、明示的コンテンツ、プライバシー、MusicKitアクセス管理
- 🔴 [Later] サイドバー、列、アートサイズ、テーマ、フルスクリーン、ミニプレイヤーのカスタマイズ
- 🔴 [Later] アニメーションアートの表示、データ通信量・省電力・Reduce Motionに応じた停止
- 🔴 [Later] Metalベースのビジュアライザと省電力設定
- 🔴 [Later] キーボードショートカット、メニューバー、Touch Bar代替、コンテキストメニューの網羅
- 🔴 [Later] Spotlight、App Intents、Siri候補、共有シート、通知アクション
- 🔴 [Later] VoiceOver、Voice Control、Full Keyboard Access、Reduce Motion、Increase Contrast
- 🔴 [Later] 英語、日本語、简体中文のヘルプと機能説明

終了条件: キーボードのみで全主要操作を完了でき、三言語とアクセシビリティ設定で重大な表示・操作欠陥がないこと。

### M10 — 拡張後の安定化 [Later]

- 🔴 [Later] 10万曲、1万項目キュー、1,000プレイリストの性能・メモリ試験
- 🔴 [Later] 長時間再生、スリープ復帰、ネットワーク変動、出力機器変更の48時間耐久試験
- 🔴 [Later] 全カタログバージョンからの移行とロールバック試験
- 🔴 [Later] セキュリティ、プライバシー、依存関係、クラッシュ、データ損失リスクの監査
- 🔴 [Later] Apple Music機能の地域・アカウント・サブスクリプション別テスト
- 🔴 [Later] 機能網羅表の最終監査、既知の制約、ヘルプ、リリースノート

### M11 — Google Drive・SMB/NASストリーミング [Later]

目的: 利用者が所有・アクセスを許可した外部音源を、ローカルライブラリと区別しながら安全に参照・再生する。外部側の原本は更新・移動・削除しない。

- 🔴 [Later] `AudioSource`をローカル、Google Drive、マウント済みSMBへ抽象化し、カタログID、ETag／更新日時、ファイルサイズ、MIME type、取得可能範囲、オフライン状態を共通モデルで表す
- 🔴 [Later] 現在の`AVAudioFile`中心の再生経路とは分離して、HTTP Range／ファイル読み出し、先読み、シーク、デコード、PCM供給を担当する読み取り専用ストリーミング層を追加する
- 🔴 [Later] 再生開始前バッファ、メモリー上限付きディスクキャッシュ、LRU削除、同一ファイルの重複取得防止、ETag変更時のキャッシュ破棄を実装する。キャッシュはライブラリ原本として扱わない
- 🔴 [Later] ネットワーク切断、NASスリープ、OAuth失効、HTTP 401／403／416／429、ファイル移動・削除、Range非対応、容量不足を三言語で表示し、再接続後は検証済み位置から再開する
- 🔴 [Later] ローカル、Drive、NASの出所を一覧と再生画面に常時表示し、ダウンロード済み／ストリーミング中／オフライン利用不可を区別する

#### Google Drive

- 🔴 [Later] Google OAuth 2.0のDesktop appフローをシステムブラウザとPKCE、loopback redirectで実装する。Client secretを秘密としてアプリへ埋め込まず、refresh tokenはKeychainへ保存し、切断操作で失効・削除する
- 🔴 [Later] 標準構成はアプリ管理のOAuth client IDとGoogle Picker、最小権限の`drive.file`を使用し、利用者が明示選択した音声ファイルだけへアクセスする。全Drive走査を必要とする`drive.readonly`には依存しない
- 🔴 [Later] 利用者自身のDesktop OAuth client IDを入力する高度な設定を追加できるよう境界を設計する。redirect URI、同意画面、テストユーザー／公開状態、API有効化はそのGoogle Cloudプロジェクト側の設定と一致する必要があるため、client IDの入力だけで認証が完了するとは案内しない
- 🔴 [Later] Drive API `files.get?alt=media`と`Range`を用いる認証付きbyte sourceを実装し、`capabilities.canDownload`、音声MIME type、サイズ、MD5 checksum／ETagを取得前に検証する
- 🔴 [Later] 広い`drive.readonly`を将来採用する場合は、Restricted Scopeの利用資格、OAuth App Verification、プライバシーポリシー、データ利用開示を配布前ゲートとする。サーバーへDriveデータやtokenを送らず端末内だけで処理する設計を基本とする

#### SMB/NAS

- 🔴 [Later] Finderの「サーバへ接続」でマウント済みの`/Volumes`配下を標準フォルダ選択画面から登録し、App Sandboxのsecurity-scoped bookmarkを読み取り専用で保存する。資格情報はmacOS／FinderとKeychainに任せ、アプリ内へNASパスワードを保存しない
- 🔴 [Later] stale bookmark、未マウント、共有名変更、資格情報失効を検出し、Finderでの再接続とフォルダ再承認を案内する。アプリ独自のSMBクライアントは初期実装に含めない
- 🔴 [Later] NAS読み出しを音声レンダリングスレッドから分離し、連続読み出しとシーク用の先読みキャッシュを経由する。SMB上へカタログ、キャッシュ、一時ファイルを書き込まない

#### 完了条件

- 🔴 [Later] MP3、AAC／M4A、ALAC、WAV、AIFF、FLACで再生・一時停止・シーク・次曲先読みが動作し、ローカル再生と同じエフェクト／音量／最終出力保護を通る
- 🔴 [Later] 低速・高遅延・パケット損失・切断復帰、token失効、NASスリープ、アプリ再起動、10GB超ファイル、44.1〜192kHz、キャッシュ上限到達を自動試験と実機で確認する
- 🔴 [Later] 権限拒否・アカウント切断・登録解除で新規取得を停止し、tokenとbookmarkを破棄できる。外部原本の変更・削除が0件であることを監査する

終了条件: P0/P1欠陥0件、移行失敗0件、データ損失試験0件、クラッシュフリー率99.9%以上を満たすこと。

## 8. 短い工程で進める運用

1. 現在の6作業から最上位の未完了契約を一つ選び、再現条件・失敗条件を固定する。
2. repositoryやadapterの実経路に接続したテストを用意し、小さな変更で完結する。
3. 関連テストと対象構成を検証し、証拠・制約・実装パスを品質文書へ記録する。
4. 既存データへの移行と復旧が通ってから次へ進む。実機確認待ちの間は独立した文書・テスト境界を進める。
5. 各作業終了時に残りの優先順位を見直す。旧マイルストーンの完了数を進捗率に使わない。

## 9. アーキテクチャ方針

具体的な責務と保存契約は[ADR-0003](adr/0003-stabilization-and-component-boundaries.md)に従う。以下は維持する原則であり、全て実装済みという意味ではない。

### データ

- JSONを現在の楽曲・プレイリスト正本として保持する。高頻度の再生キュー・履歴はライブラリUUID付きsidecarへ分離済み。検索を次に分離し、SQLite正本化は検証可能な移行・復旧経路が完成してから判断する。
- 10万曲、スマートプレイリスト、全文検索、再生履歴の性能は[ADR-0001](adr/0001-large-library-storage.md)の予算と手順で計測し、条件成立時にSQLiteへ段階移行する。
- 楽曲、アルバム、アーティスト、プレイリストは表示文字列ではなく安定IDで関連付ける。
- Apple Music ID、MusicBrainz ID、ローカルSHA-256を別namespaceとして保持する。
- ファイル操作は常に計画、実行、検証、確定の4段階とし、ジャーナルから再開できるようにする。

### 再生

- ローカル音源のAVAudioEngine経路とMusicKitの再生経路を抽象化し、キューは出所に依存しないモデルにする。
- DSP、クロスフェード、ギャップレス、ラウドネス解析の責務を分離する。
- [MediaPlayerのNow Playing API](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter)へ、曲情報、アート、経過時間、キュー位置、再生状態を同期する。

### サービス

- LRCLIB連携は歌詞プロバイダープロトコルの一実装として分離し、URLSession、応答デコード、レート制限、再試行、キャッシュをUIから切り離す。
- LRCLIBの完全一致が404の場合だけ候補検索へ進み、ネットワーク障害、429、該当なし、インストゥルメンタルを異なる状態として扱う。
- MusicBrainz連携はメタデータプロバイダー、Cover Art Archive連携はアートワークプロバイダーとして分離し、検索候補、信頼度、出典、キャッシュ状態を共通モデルでUIへ渡す。
- MusicBrainzのrecording、release、release-group、artist IDは種類別namespaceで保持し、文字列だけの類似一致からリリースやジャケットを自動確定しない。
- メタデータと画像は「手動設定／埋め込み」「承認済み外部候補」「未確認の外部候補」の優先順を維持し、更新前の値へUndoできるようにする。

- MusicKitは利用者の明示許可後だけ利用し、`NSAppleMusicUsageDescription`を三言語で提供する。
- Apple Music未加入、未認証、オフラインでもローカルライブラリの全機能を維持する。
- 共同編集バックエンドは、認証、レート制限、暗号化、削除、監査、データエクスポートを設計完了後に導入する。
- SharePlayは[Group Activities](https://developer.apple.com/documentation/groupactivities)を使用し、音源ファイルそのものを参加者へ無断転送しない。

### 端末連携

- iPhone/iPadからMacへの音源転送は、iOS/iPadOS companionアプリとmacOSアプリ間の明示的な利用者承認を必須とする。
- 現行の端末探索と通信にはBonjour／MultipeerConnectivityを使用し、端末識別、manifest交換、ファイル転送をUIやライブラリ保存処理から分離する。
- manifestの差分判定は表示名ではなく安定IDとSHA-256を優先し、同一ファイルの再転送と別音源の誤統合を防ぐ。
- 現行MCSessionは暗号化必須で使用する。将来Network frameworkを採用する場合はTLSを必須とし、確認コードによる初回ペアリング、保存済み端末の失効、転送履歴の消去を提供する。
- Apple MusicのDRM保護曲、クラウドのみの曲、公開APIで読み出せない曲は転送プロトコルへ渡さず、状態と代替操作だけを同期する。
- 転送完了後は既存の取り込みジャーナル、SHA-256検証、重複検出、アーティスト／アルバム別整理を再利用する。

### UI

- 画面固有の操作だけでなく、メニュー、右クリック、ドラッグ＆ドロップ、キーボード、VoiceOverに同じ機能を提供する。
- 長い曲名、混在言語、右から左の文字、狭いウインドウ、表示倍率をテストする。
- ネットワーク機能には読み込み中、空、拒否、未加入、オフライン、再試行の全状態を持たせる。

## 10. テスト戦略

- Unit: キュー遷移、スマートルール、ID解決、メタデータ、マイグレーション、競合解決
- Integration: AVAudioEngine、MusicKitモック、ファイルジャーナル、CloudKit／共同編集API
- Device integration: iPhone/iPad実機でのペアリング、差分manifest、1,000曲転送、中断再開、DRM／クラウド／非保護音源の混在、Finderファイル共有
- UI: 主要ユーザーフロー、三言語、キーボード、VoiceOver、権限拒否
- Audio: ギャップ、クリックノイズ、ラウドネス、サンプルレート、チャンネル、DSPクリッピング
- Data safety: 電源断相当、容量不足、権限喪失、外付け切断、破損manifest、部分コピー
- Performance: 1万／5万／10万曲、巨大アート、1万曲キュー、複合スマート条件
- Compatibility: macOS 14から現行macOS、Apple siliconとIntel、主要出力機器

## 11. 品質ゲート

各マイルストーンで次を満たさない場合、次の大型機能へ進まない。

1. ビルド、Unit、Integration、UIテストが成功する。
2. カタログ移行にバックアップ、検証、失敗時復元がある。
3. 元音源を変更・削除する操作は、対象、結果、復旧可否を事前表示する。
4. 新規UIが英語、日本語、简体中文で完了している。
5. キーボード操作、VoiceOverラベル、フォーカス順が完了している。
6. ネットワーク・認証機能がオフラインと権限拒否で安全に縮退する。
7. プライバシー説明、収集データ、保存期間、削除方法が文書化されている。
8. 主要操作の性能予算とメモリ予算を超えていない。

## 12. リスクと対策

| リスク                                   | 影響                                                      | 対策                                                                                                     |
| ---------------------------------------- | --------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| MusicKitで期待機能が公開されていない     | Apple Musicパリティが未達                                 | M0で最小実機スパイク。代替／ハンドオフをM6前に確定                                                       |
| JSONカタログの性能限界                   | 大規模ライブラリで操作不能                                | 計測基準を先に置き、段階的SQLite移行を準備                                                               |
| 再生経路がローカルとMusicKitで分裂       | キュー、DSP、状態表示が不整合                             | 共通の再生状態機械と出所別adapterを採用                                                                  |
| メタデータ編集とファイル管理でデータ損失 | 信頼性の毀損                                              | 非破壊既定、dry-run、ジャーナル、チェックサム、Undo                                                      |
| ソーシャル機能の運用負荷                 | セキュリティ・プライバシー事故                            | M7までバックエンドを開始せず、脅威モデルをゲート化                                                       |
| スコープ過大                             | 長期未リリース                                            | 各Mを利用可能なリリースにし、ローカル1.0を先に完成                                                       |
| Intelと新OS機能の差                      | 条件分岐とQA増大                                          | capability判定、機能別フォールバック、M10で支援範囲再評価                                                |
| iOS端末内音源の公開API制限               | Apple Music保護曲やクラウド曲をファイルとして取り込めない | 非保護音源だけを実機で能力判定し、対象外理由と公式再生／ダウンロード導線を表示。非公開APIとDRM回避を禁止 |
| 端末間転送の切断・容量不足・なりすまし   | 部分ファイル、重複、データ漏えい                          | TLS、確認コード、チャンク再開、転送前容量確認、転送後SHA-256検証、未確定領域への隔離を必須化             |

## 13. 完了条件

機能単位の実装状態とは別に、配布可能という判定は次の全条件と証拠が揃った状態を指す。実装済みでも未実機確認・未署名確認・未計測は明記し、条件を免除しない。

- 受け入れ条件と異常系が文書化されている。
- 実装、データ移行、Unit／Integration／必要なUIテストが完了している。
- 英語、日本語、简体中文が揃っている。
- VoiceOver、キーボード、コントラスト、拡大表示を確認している。
- オフライン、権限拒否、データなし、破損、容量不足を処理できる。
- データを変更する場合はバックアップまたはUndoと監査可能な結果を持つ。
- ヘルプ、設定説明、既知の制約、リリースノートが更新されている。
- DebugとReleaseのビルドが成功し、対象macOS／CPUで確認済みである。

## 14. 進捗運用

- スプリント開始時に本書の `[Next]` を最大6項目へ絞る。
- 作業終了時に実装パスと試験結果を添えて `[Done]` へ変更し、配布資格はG1〜G3として別途判定する。
- 月次で日程、依存関係、リスクを更新する。
- 四半期ごとにApple公式ガイド、MusicKit、OS要件、API制限との差分を再監査する。
- マイルストーン終了時に機能網羅表へ実装画面、テスト、制約文書へのリンクを追加する。
- G1〜G3通過前の割り込みは、保存安全性・回帰・配布障害の解消を優先し、新しい大型機能を追加しない。

## 15. 参照資料

- [Apple Musicユーザガイド（macOS Tahoe）](https://support.apple.com/guide/music/welcome-apd3f44c7709/mac)
- [Musicの設定項目](https://support.apple.com/guide/music/mus0fb1b421b/mac)
- [曲間トランジション、AutoMix、Crossfade](https://support.apple.com/guide/music/transition-songs-muse5e9ec085/mac)
- [共同プレイリスト](https://support.apple.com/guide/music/mus848746294/mac)
- [MusicKit](https://developer.apple.com/documentation/musickit)
- [MusicKit / Apple Music API概要](https://developer.apple.com/musickit/)
- [MPNowPlayingInfoCenter](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter)
- [Group Activities / SharePlay](https://developer.apple.com/documentation/groupactivities)
- [Network framework](https://developer.apple.com/documentation/network)
- [TN3151: Choosing the right networking API](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api)
- [MPMediaItem assetURL](https://developer.apple.com/documentation/mediaplayer/mpmediaitem/asseturl)
- [MPMediaItem hasProtectedAsset](https://developer.apple.com/documentation/mediaplayer/mpmediaitem/hasprotectedasset)
- [UIFileSharingEnabled](https://developer.apple.com/documentation/bundleresources/information-property-list/uifilesharingenabled)
- [LRCLIB API Documentation](https://lrclib.net/docs)
- [MusicBrainz API](https://musicbrainz.org/doc/MusicBrainz_API)
- [Cover Art Archive API](https://musicbrainz.org/doc/Cover_Art_Archive/API)
