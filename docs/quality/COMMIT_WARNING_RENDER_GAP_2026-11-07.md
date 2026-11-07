# Desktop commit warning and iPhone render-gap follow-up — 2026-11-07

## User evidence

Desktop reports a new `Invalid attempt to open a new transaction during CA commit` warning, plus entangle/fence/pre-commit messages, after source-rate changes and before a bypass transition. The previous layoutSubtreeIfNeeded warning is not in this sample; absence does not prove all layout paths fixed. The source/processing/output log (44.1/48→96→88.2kHz, bypassed then effects enabled) reports graph configuration, not output waveform validation. `finalTruePeak=off` is the ordinary configuration, not evidence that the warning is caused by true-peak behavior.

On iPhone, the preflight log precedes Effects navigation; the worker ends with cancellation before the logged render gap. The independent render observer records **400.8ms**, and the meter tap records **434.8ms**. Route is Speaker and active effects are none. This corroborates a gap in audio callback scheduling during the page transition even with effects OFF. It is not a calibrated measurement of exactly 400.8ms of silent output or a proof of the underlying blocking stack. The later OFF→BASIC→Pro→OFF changes are logged user intents; they occur after the first gap.

The local asset's direct open fails with domain/code 259 and the snapshot route later becomes ready (6464ms). This sample shows recovery, not an unrecovered stop or proof of a corrupted original file. The worker's `elapsed=2.06` is its lifetime, **not** cancellation request-to-exit latency. System sandbox/PointerUI/factory/CoreMedia/DetachedSignatures messages alone do not identify the audible problem or justify modifying OS files. No OS log suppression or system-file change was made.

## Desktop defensive changes and tracing limits

SpectrumGlassView still opened an explicit CATransaction to size/install its mask, even though that update had been deferred from layout. Its owned gradient mask now disables implicit bounds/position actions directly, updates its frame without opening that explicit transaction and is assigned only when the backing layer does not already own it. Filter values and geometry remain unchanged. Progress-slider appearance is set before attachment and later assigned only when the requested appearance actually differs, avoiding a repeated AppKit style setter on every progress refresh.

These remove concrete unnecessary transaction/style mutations; **no captured stack establishes that either was the user's warning origin**. The requested NSCGSTransactionCreatedDuringCommitError marker resolves on this local OS to an address shown by LLDB as `_NSReturnCarbonMenu`. The initial stop is NSApplication/menu initialization, not the warning. A naive transaction-name filter also stopped in NavigationSplitView constraint setup because a SwiftUI function signature contains Transaction. Neither is treated as a positive warning reproduction. Raw traces are retained to make that limitation explicit.

A final debugger-launched isolated two-track library startup uses no active breakpoint (the harness's dummy symbol has zero locations), runs for 15 seconds and captures app output. It remains running until the harness deliberately kills it (exit 9 is cleanup, not a crash); no pre-commit warning appears in that captured startup. This is only a local idle startup check, not the user's two-file/bypass workflow or a negative guarantee for the installed app.

## iPhone cancellation diagnostic

The quality worker now logs `cancelLatencyMs` from the first observed cancellation request to its end-of-work diagnostic, using a locked monotonic nanosecond timestamp. The timestamp is set before forwarding cancellation to the detached worker. Existing `elapsed` remains unchanged, allowing lifetime and cancellation latency to be distinguished. It does not measure caller/MainActor resumption or explain a render gap by itself.

`unknown` means no request timestamp was observed (including direct worker cancellation paths not using that forwarding handler); it is never fabricated from elapsed time. The helper is not accessed by any audio render callback. No effect/rate/gain, playback graph, UI mounting or optional-work deadline is changed by this logging patch. The first Effects presentation already cancels current/next work and the independent cache writer; the supplied gap proves that these mitigations cannot yet be called an audible fix.

## Verification

- Desktop `WindowBridgeLayoutTests|ApplicationSettingsTests|SpectrumGlassLayoutTests|EffectRackInputTests`: **52 tests / 4 suites PASS**. The mask regression additionally checks disabled geometry actions, with resize/theme/identity and input/mini-player regressions preserved. The later idempotent progress appearance edit is covered by the final build/startup, not a separate direct slider test.
- iPhone monotonic cancellation timing fixture extracted from shipping source: **2 groups PASS** (unobserved request, first request retained, unit conversion, invalid interval and concurrent recording). Source checks verify that the request is recorded before worker.cancel and the new log field is wired.
- Existing presentation/preflight/resume/source-wiring fixture: **4 groups PASS**.
- Mac ordinary Debug and iPhone ordinary Debug Simulator signing-disabled Xcode builds: **PASS**. Release/signing/distribution and the broad DSP matrices were not repeated for this UI/diagnostic-only patch.
- Both apps' ROADMAPs share scope and evidence. No shared audio algorithm or sync protocol changed.

⭕️ [Pending] Capture the real Mac warning's stack together with the emitted warning while loading 44.1/48kHz sources at 88.2kHz output and changing bypass, window size/theme and tabs. The aliased marker alone cannot establish the source. Verify masks/progress style in the installed signed app and other supported macOS versions.

⭕️ [Pending] Repeat the exact first/repeated Effects tap on the physical iPhone speaker, collect the new cancelLatencyMs and a device system/time profile with render callbacks, main-thread/UI construction, framework initialization and allocator/worker activity. The 400.8ms render-gap root cause and audible resolution remain unconfirmed. Actual Music snapshot preparation time, source handoff, signed builds, temperature/power and external framework diagnostics also remain device/session checks.

[Evidence and final-source hashes](../measurements/commit-warning-render-gap-2026-11-07/).
