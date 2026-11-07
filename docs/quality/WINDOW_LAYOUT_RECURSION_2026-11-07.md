# Window bridge layout recursion — 2026-11-07

## Confirmed origin and previous gap

The actual Desktop Debug executable was launched with a symbolic breakpoint at `_NSDetectedLayoutRecursion`, using `--ongaku-qualification-root <process temporary directory> --ongaku-qualification-prepare 2`. This builds an isolated two-track fixture; it does not open or migrate the user's music library. Before the fix the breakpoint stopped on the main thread with this stack (full trace retained):

```
_NSDetectedLayoutRecursion
NSView.layoutSubtreeIfNeeded
NSWindow._layoutViewTree / _setFrameCommon
NSWindow.setStyleMask
WindowPresentationController.attach(to:)
WindowMiniaturizeBridge.Coordinator.connect(to:)
WindowMiniaturizeBridge.makeNSView callback
WindowProbeView.viewDidMoveToWindow
NSView.addSubview
NSHostingView.swiftui_addManagedSubview
NSHostingView.layout
```

SwiftUI was inserting the native probe while laying out the hosting view. The synchronous window notification applied window style during that same layout. The style setter forces a second window layout. Even removing an absent OptionSet flag invokes the setter. The existing managed-window identity guard protected repeated attachment, not the first attachment.

Earlier background-filter/appearance deferral and scroll-reflection fixes covered different native-view paths. Their isolated tests did not include first attachment of this actual window bridge. They could therefore pass without removing this launch-time warning. This trace identifies one concrete production path; it does not establish that every possible warning on every OS shares it.

## Fix

`WindowProbeView` coalesces window notifications onto the next main-queue turn, after the hosting-layout stack unwinds. Both insertion and SwiftUI updates use the same scheduling path. The callback reads the latest owner window, preventing a queued update for a window the view has already left. A weak capture avoids extending the probe lifetime. Dismantling clears the callback before disconnecting, so queued work cannot reattach retired UI.

The controller writes style/title transparency only when needed. The bridge obtains and hooks the current miniaturize button after applying window style, because a style change can rebuild standard buttons. Direct controller attachment outside the SwiftUI bridge remains immediate. Mini-player sizing/restoration, pass-through hit testing and original button target restoration remain covered.

This is a Desktop window-lifecycle change. iPhone runtime and the common audio DSP, protection, sample-rate conversion and sync protocol are unchanged; both ROADMAPs share this evidence and scope. No iPhone rebuild was required for this Desktop-only implementation.

## Verification

- Final `swift test --jobs 2 --filter 'WindowBridgeLayoutTests|ApplicationSettingsTests|SpectrumGlassLayoutTests|EffectRackInputTests'`: **52 tests / 4 suites PASS** in 53.934 seconds. Four new tests cover actual NSHostingView with the shipping bridge (zero style writes inside hosting layout), deferred/coalesced notifications, moving between windows before delivery, mini-player round trip/current button ownership and dismantling before queued attachment. Existing settings, backdrop and rack click/scroll regressions also pass. The retained intermediate run has 51 tests before the real-host integration test was added.
- Mac ordinary Debug Xcode build: **PASS**, signing disabled.
- Mac App Store Release Xcode build: **PASS**, signing disabled. This is compilation, not signed distribution qualification.
- With the rebuilt Debug application, two isolated launches no longer hit the same symbolic breakpoint. The final run records one resolved breakpoint location, **35.05 seconds** of observation, `lastState=6` (running), `hit=False`, and no layout recursion warning in captured output. The harness then deliberately kills the process; exit status 9 is that cleanup, not a spontaneous app crash. The first clean run used the same 35-second timeout but predates explicit observation-duration logging.
- Original positive backtrace, negative traces, debugger harness, app output, regression/build logs and current source SHA-256 values are retained in [measurements](../measurements/window-layout-recursion-2026-11-07/). The harness names its Debug executable path explicitly; adjust that path when reproducing elsewhere.

## Remaining qualification

⭕️ [Pending] Installed signed app with the user's full library: ordinary launch, repeated tab changes, theme changes, resizing, sheets, mini-player/restore and multi-window/display lifetimes across supported macOS versions. If recursion returns in these conditions, collect another symbolic-breakpoint stack rather than assuming this path. The local fixture startup is verified, not a blanket guarantee for all screens.

⭕️ [Pending] Real audio output/88.2 kHz device changes, iPhone speaker noise, connection refusal and OS/CoreMedia/factory diagnostics remain independent items. This UI fix does not claim to resolve them or the entire prior log.
