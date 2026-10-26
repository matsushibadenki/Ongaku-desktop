# Effects page presentation — 2026-10-26

## Change

The mobile first-visit path intentionally postponed the controls by **550 ms** using a main-queue work item, even though its callback only changed view flags. No audio preparation or asynchronous asset loading completed inside that callback. Remove that wait, the placeholder branch, redundant identity token and delayed activation state. Render the existing controls directly when SwiftUI presents the page. Screen-active meter auditing still follows the selected tab and active scene; its existing 0.8-second audit cadence remains separate from control presentation.

Keep the measured-height VStack, card order, settings/actions, padding, Safe Area and scroll-to-top behavior. Do not switch to a lazy stack: earlier offset/height corrections depend on this bounded layout. Keep iPhone SE (3rd generation) and iPhone 16 Pro Max previews. No labels, translations or audio DSP/volume protection change.

Mac's EffectsRackView renders its controls directly already; it has no equivalent initial work-item delay to remove. The audio algorithms and defaults remain aligned.

## Transient feedback

The user's report that Transient is difficult to hear agrees with the existing synthetic measurement: at intensity 0.20, percussion attack/body contrast changes about +0.039 dB after loudness matching, versus +0.196 dB at maximum. These are objective fixture values, not audibility thresholds. Keep default OFF and the current protected gain range in this UI fix. A substantially stronger range requires a separate headroom/peak/click/tail qualification and real-music listening rather than simply increasing output level. See [cost and PCM comparison](TRANSIENT_COST_AND_PCM_COMPARISON_2026-10-26.md).

## Validation

- Source review: no preparation dependency in the removed callback; first/repeated visits now share the same direct controls branch. Switching tabs/background changes only the existing audit activity, without a queued controls callback that can fire later.
- 🟢 [Done] iOS Simulator arm64 Debug build succeeds (`audio` scheme, code signing disabled); both production view and narrow/wide preview declarations compile.
- Whitespace/diff validation; no production DSP changes. The fixed 550 ms scheduled wait is removed by construction. Actual tap-to-frame time is not measured; this does not claim all rendering stalls are eliminated.
- ⭕️ [Pending] Physical iPhone narrow/wide screens: first/repeated visit, fast tab switching, background/foreground, Basic/Pro/OFF scrolling and controls during playback; confirm actual responsiveness and no offset/layout regression. No new visual runtime measurement is claimed.
