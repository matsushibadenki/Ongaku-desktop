# Desktop layout warning and nearby-session diagnostics — 2026-11-07

## User evidence

The latest log configures 44.1/48 kHz source, 96 kHz processing and 88.2 kHz output, including effect/bypass changes, without the earlier -10874/cannot-play messages. That absence does not prove the original live-device issue fixed. `finalTruePeak=off` describes the ordinary build; previous ON/ON qualification remains a separate configuration.

The layout recursion warning is still present in the user's app. A concrete remaining hazard was found in SpectrumGlassView.layout: assigning the layer mask and constructing background filters synchronously within layout. SpectrumBackdropBlur.updateNSView also unconditionally assigned NSAppearance, allowing repeated native style/layout invalidation from SwiftUI updates. No symbolic-breakpoint backtrace establishes that either was the specific source of the user's warning, so physical reproduction stays open.

## Change

Initial style is set while constructing the native backdrop. Later theme/opacity requests are stored and coalesced onto the next main-queue turn; identical style requests are ignored. Layout schedules a coalesced filter update rather than mutating mask/filters within layout. At execution, the latest style and bounds are used. Appearance changes invalidate the cached filter size so the mask/filter geometry is reapplied. A weak closure does not keep a retired view alive. Click pass-through/window dragging and the original gradient/filter parameters are retained. This builds on, rather than reverses, the previous fix that keeps click-position ownership immediate while deferring scroller reflection.

The latest network error reports Connection refused on interface awdl0. It lacks a service identifier tying it to an application session, so it must not be attributed to audio or to iPhone pairing solely from that line. Existing MCSession notConnected handling interrupts transfers and returns to searching; manual reconnect and conservative browser retry remain unchanged. No aggressive browser restarts or automatic repeated invitations were introduced.

Both apps now emit `sync.session.state state=N connectedPeers=N` at their nearby-session delegate boundary (state 0=notConnected, 1=connecting, 2=connected). Mac also emits `sync.invitation.started automatic=...`. These logs disclose only enum values/counts/automatic intent, not peer names or pairing codes. They help correlate a future Network.framework refusal with actual session transitions, but are not a network fix or proof that the current refusal belongs to that session.

DetachedSignatures, CoreMedia permission and factory warnings remain unidentified OS/framework diagnostics. This change neither modifies system files nor suppresses those messages. The supplied log does not establish catalog corruption or a crash from them.

## Verification and limits

- Final `swift test --jobs 2 --filter 'SpectrumGlassLayoutTests|EffectRackInputTests|DeviceSyncTests'`: **30 declarations / 3 suites PASS**. New native-view tests verify no immediate filter mutation inside layout, latest resize/style coalescing with production backdrop material/state, light/dark updates, mask bounds, zero-size handling, unchanged click pass-through and retired-view lifetime. Existing rack click/scroll and sync model regressions pass. The earlier filter-only trial log is retained as intermediate; final evidence includes appearance coalescing.
- `bash tests/run_pairing_invitation_regression.sh`: **6 logical groups PASS**. These isolate shipping invitation ownership/deadline logic; they are not real peer networking.
- Final Mac ordinary Debug and App Store Release signing-disabled Xcode builds: PASS.
- iPhone Debug Simulator signing-disabled build with matching session logging: PASS.
- No audio algorithm, limiter, file-format or sync-message change. Mac backdrop scheduling and local diagnostics differ appropriately from the iPhone UI. Physical audio/route and iPhone page-noise items remain separately Pending.

⭕️ [Pending] Launch the installed app with the user's actual spectrum/backdrop/theme and use a symbolic breakpoint at _NSDetectedLayoutRecursion if the warning persists. These isolated views do not prove the complete SwiftUI window no longer triggers it. Real Mac/iPhone connect/refuse/retry/disconnect, actual source of awdl0 failures, 88.2 kHz device behavior, code-sign/framework factory warnings and user-reported audible symptoms also require reproduction. Do not classify this as resolution of every logged warning.

[Raw logs and final-source hashes](../measurements/desktop-layout-warning-2026-11-07/).

## Follow-up: confirmed window-bridge origin

The later [symbolic-breakpoint investigation and fix](WINDOW_LAYOUT_RECURSION_2026-11-07.md) reproduces startup recursion in the actual app and identifies synchronous initial window-style application from the SwiftUI probe. That startup path is fixed and locally verified; the earlier unconfirmed background-origin hypothesis above remains historical. Installed-user-library and broader OS/UI qualification remain Pending.
