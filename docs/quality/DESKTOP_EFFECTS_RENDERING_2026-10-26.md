# Desktop effects rendering — 2026-10-26

## Changes

- 🟢 [Done] Each effect card receives an immutable setting snapshot and an unobserved controller action target, wrapped in an Equatable view boundary. It no longer subscribes directly to every PlaybackController publication (meters, elapsed position, etc.). Equality includes the complete setting and controller identity: enable/parameter changes still invalidate the card. The parent still observes the controller for toolbar/settings; this is not a claim to eliminate all rack updates. Input-router environment changes and the observable appearance palette continue to update their dependent views. Language selection recreates the application's localized view identity as before.
- 🟢 [Done] Masonry and parameter layouts retain exact existing measurements and shortest-column placement, but reuse arrangements across size/place passes at the same width. Each layout clears its cache in `updateCache` when SwiftUI updates children. Configuration changes invalidate it as well; at most four width proposals are retained. There is no fixed-height assumption, offscreen height estimation or LazyVGrid substitution. Existing scroll/drag ownership is unchanged.
- 🟢 [Done] Replace each knob's 25 Capsule view subtrees with one synchronous Canvas containing the same 25 rounded marks. Preserve positions (23 pt radius, −135…+135°), 1.25 pt width, 5/3 pt lengths and enabled/value accent logic. The 52 pt knob, pointer, hit target, native input bridge and event routing remain unchanged. Palette colors and control values are captured during view evaluation so dependent appearance updates remain observed. This reduces decorative view count; it does not change the audio pipeline.

The changes address repeated view construction/layout and initial view-tree complexity. No GPU/CPU render timing or tap-to-first-frame percentage is inferred from view counts. No audio DSP, Transient strength/default, volume protection or mobile UI change is included.

## Verification

`ONGAKU_CAPTURE_RACK=1 swift test --filter 'EffectRackRenderingTests|EffectRackInputTests'` from the Desktop repository: **15 tests / 2 suites pass**, including:

- Card value boundary: unrelated controller volume update remains equal, enable/parameter changes and different action-controller identity compare unequal.
- Exact cache behavior: 200 repeated two-width requests require two measurement closures, rather than one per request. Explicit child invalidation, spacing changes and 100 distinct window widths remeasure correctly. This is a cache-contract result, not an end-to-end speed ratio.
- Actual NSHostingView production rack in English/Japanese/Simplified Chinese, 420/900 pt widths, Basic/Pro, multiple scroll fractions and repeated parameter clicks. Existing assertions cover actual parameter updates, knob/control/picker positions, document height and clip origin during input. Tests also cover wheel, two-finger gestures, momentum, scrollbar, GUI press/drag, viewport edges and detach/reattach.
- Existing capture path exercises light/dark/pink/purple/green/beige; visually inspected [narrow Japanese rack](../measurements/desktop-effects-rendering-2026-10-26/pro-ja-420.png) and [green wide rack](../measurements/desktop-effects-rendering-2026-10-26/pro-ja-green-900.png). Marks, pointers and text remain aligned in these captures. This is not pixel identity or every-screen certification.
- Package Debug compilation succeeds with the tests. Mac App Store Release build succeeds with signing disabled; `lipo -archs` confirms arm64 + x86_64. Whitespace validation passes.

[Raw test output and changed-source hashes](../measurements/desktop-effects-rendering-2026-10-26/). Tests restore the preferences they modify and use test windows; no installed application is replaced. The App Store build uses signing disabled and a dedicated temporary derived-data directory.

## Remaining qualification

- 🟠 [Next] Profile installed Release cold-open and sustained playback/UI rendering with Instruments before attributing remaining stalls to GPU shading, localization, or the parent publication cadence. A repeatable frame-time baseline is still needed; the current evidence establishes eliminated work and regression behavior.
- ⭕️ [Pending] Real mouse/trackpad interaction with actual playback, Retina/external-display scaling, window resize/live locale/appearance changes in the installed app, Intel execution and sustained frame pacing. Keep existing iPhone sound/listening qualification unchanged.
