# Effect rack input verification — 2026-10-20

The user reported repeated failures with trackpad click-and-drag after earlier per-knob fixes. This revision routes input once per rack and separately protects the clip origin from focus/autoscroll changes. No audio processing or iPhone runtime code changes.

## Interaction contract

| Input | Behavior |
| --- | --- |
| Two-finger swipe starting over GUI or blank space | Scroll; lock GUI edits through the gesture and momentum |
| Hover without clicking or swiping | Hover feedback; no scroll |
| Discrete mouse wheel | Scroll directly through the containing NSScrollView, including over a control |
| Scrollbar | Native scrolling, with GUI edits locked during tracking |
| Control click / knob click-drag | Deliver GUI action; freeze scroll origin until release |
| GUI input during scrolling | Reject clicks/drags and value edits; do not change knobs, toggles or effect mode |

## Development verification

- `swift test --filter EffectRackInputTests`: all 12 tests pass, including EQ group coverage and the production-rack layout regression below.
- Actual NSWindow / NSScrollView / NSClipView objects test routing, ownership and offset protection. Injected NSEvent subclasses provide deterministic phase/precision inputs; the wheel probe counts forwarded events. These are not physical HID recordings.
- Follow-up for click-induced up/down movement: remove the SwiftUI `FocusState` assignment and focusable drag surface from the knob. Use an AppKit input view for first responder, mouse tracking and arrow keys, with existing SwiftUI drawing/accessibility.
- A rendered production RotaryKnob test sends mouse-down/drag/up through NSWindow at both normal and partially clipped positions. The value changes, the native input view takes first responder, and every observed clip origin remains unchanged through click, drag, release and a delayed observation. Double-click reset, arrow-key increments and input rejection while scrolling also pass. Events are programmatically created, not physical HID input.
- A hosted SwiftUI ScrollView verifies that the region bridge attaches to its actual native scroll view.
- Covered: blank-to-control swipe, GUI-started scroll with controls locked, discrete wheel delivery, rejected GUI clicks during scrolling, drag/focus offset protection and release, stationary fingers and momentum, scrollbar ownership, unrelated windows, partially clipped knobs, drag-generated momentum, detach cleanup and SwiftUI bridge attachment.
- Geometry reproduced before the intersection fix: control bounds `(0, 0, 84, 84)`, visible rect `(-30, -136, 383, 250)`, adjacent blank point `(220, 14)`. Testing only visibleRect incorrectly classified that blank point as GUI. The initial routing tests failed; intersecting bounds and visibleRect makes the regression pass.
- Xcode Debug app build: `OngakuDesktop`, macOS destination, code signing disabled.

## Follow-up: intermittent click-time movement

The earlier native-input revision improved the user's experience but did not eliminate intermittent movement. This follow-up declines pointer-driven reveal requests at the control instead of relying solely on restoring the clip position after a change.

- Mark pointer ownership before first-responder callbacks; block `scrollToVisible` until keyboard interaction or loss of focus, including delayed requests after mouse-up. Reject `autoscroll` during native mouse tracking. Normal two-finger scrolling still goes directly to the scroll view.
- Acquire/release rack protection from the native control as well as the event monitor. This covers click delivery before region registration or without monitor dispatch.
- Use `@Published` values and a LazyVGrid in the rendered regression fixture so parameter edits redraw live value labels and neighboring controls.
- Before the fix, the new assertion requiring a clipped, pointer-owned knob to refuse `scrollToVisible` failed. It passes after the fix. This is a reproduced unwanted acceptance of a reveal request, not a recording of the user's intermittent physical scroll jump.
- The 10-test suite passes, including normal/clipped rendering, immediate and delayed reveal rejection, autoscroll rejection, native ownership without monitor dispatch, value changes, double-click reset, arrow keys, and the previous scroll/GUI isolation cases.
- Clip-origin assertions inspect notifications and the final position; the earlier restoration observer can run before a test observer. Reveal/autoscroll return-value assertions separately establish that the control rejects those requests before forwarding them.

## Follow-up: mode toolbar and document layout

The user identified that the area labelled “エフェクトモード” grows when a knob or switch is clicked. Protecting the clip origin alone cannot prevent this: the document's contents can move while the origin remains unchanged. Earlier focus/scroll guards did not cover this defect.

Reproduction used the actual `EffectsRackView` and `PlaybackController`, not just a stand-alone knob. Before the toolbar correction, the Japanese Picker frame changed from `(40, 16, 230, 81)` to `(40, 16, 230, 33)` in a 900 pt window; the document height fell from 1656 to 1608 pt and a knob moved from y=211 to y=163. A 420 pt Japanese case and Simplified Chinese also failed geometry assertions. Separately, the original LazyVGrid changed the document height by 1–3 pt after parameter edits. These are reproduced layout defects, not recordings of physical trackpad input.

Changes:

- Lay out the localized title separately from the segmented Picker (`labelsHidden` preserves its accessibility label). Use the toolbar's natural height and a one-line title/count; put the existing localized explanation on an accessible information icon with a tooltip.
- Replace the small lazy parameter grids with an eager adaptive Layout. Measure every row before reporting the card height to the masonry layout, so offscreen estimates cannot change during an edit. Retain 84–92 pt cells and the existing spacing.
- Handle infinite proposed widths during NSHostingView size-limit probes; previously converting infinity to an integer column count crashed the real-view test.
- Preserve the existing rack input router and native knob handling. No audio processing or iPhone runtime changes.

Final verification:

- 12 actual-rack configurations: EN/JA/zh-Hans × Basic/Pro × 420/900 pt windows. Basic uses two scroll positions and Pro four, for 36 position cases, 108 knob clicks and 72 module enable/disable actions.
- Assert picker frame, document height and scroll origin remain unchanged through updates; also assert the clicked knob frame is unchanged. Subsequent knob angles must change real parameter values, and every module switch must change the enabled count. Fully visible knobs avoid testing repeated saturation at the same angle; the existing separate test retains partially clipped knob/drag coverage.
- All 11 input tests pass. The Xcode Debug app build and whitespace check pass. Japanese Basic/Pro images at 420/900 pt were rendered; Pro screenshots were inspected for the one-line title, contained controls/count and layout spacing.
- The expanded test does not play audio. Settings/language defaults are restored after testing. Optional `ONGAKU_CAPTURE_RACK=1` saves rendered Japanese fixtures in `/private/tmp`.
- [Recorded measurements and test results](measurements/effect-rack-layout-2026-10-20.txt).

## EQ grouping and metal knobs

The desktop previously flattened `EffectParameterDefinition.group` into one grid. The EQ now renders six localized sections (Filter / LF / LMF / HMF / HF / Output) while preserving the existing definitions, ordering and bindings. The coverage test checks that all 14 keys appear exactly once, with both mid-band Focus switches next to their associated Gain/Frequency/Q controls. Eager layout and the fixed mode-toolbar structure remain in use. The 900 pt layout fits each four-control mid-band group on one row; narrower cards wrap inside their section.

The visual reference is `/Users/Shared/Program/Xcode/Synth/Previews/reference-panel-metal.png`, its `assets/Volume_basic.png` and `Sources/SynthApp/MetalPanelRenderer.swift`: a black grip, ridges, reflective silver cap and ivory index. The desktop uses SwiftUI gradients/Canvas at the existing 52 pt dial / 84 pt control footprint, without adding a continuous renderer. Filled value ticks, numeric values and focus use `AppTheme.playbackAccent` (orange for the neutral themes, the matching accent for each pastel). Disabled controls retain subdued neutral ticks and values. Input handling, parameter math and audio processing are unchanged.

- All **12** focused tests pass: the new EQ coverage test plus the existing interaction and real-rack layout checks (108 knob clicks / 72 switch actions, three languages, two modes, two widths).
- Xcode Debug app build, `plutil -lint` for all three localization files and `git diff --check` pass.
- Captured the actual rack in light/dark and four pastel appearances; inspected the layouts and colors. The optional screenshot capture changes only the test window and restores the palette afterward. Values in the screenshots are test edits, not recommended EQ settings.
- Saved evidence: [test output](measurements/eq-knobs-2026-10-20/tests.txt), [light](measurements/eq-knobs-2026-10-20/light.png), [dark](measurements/eq-knobs-2026-10-20/dark.png), [pink](measurements/eq-knobs-2026-10-20/pink.png), [purple](measurements/eq-knobs-2026-10-20/purple.png), [green](measurements/eq-knobs-2026-10-20/green.png), [beige](measurements/eq-knobs-2026-10-20/beige.png).

Physical trackpad confirmation, small-text readability on other displays and sustained rendering while playing remain Pending. No iPhone runtime changes were made.

## Pending

Confirm the reported mode-toolbar growth and click-time movement are resolved on the affected physical Mac. Physical trackpad click-drag, button actions, hover and two-finger inertia under the updated interaction contract, including swipes starting over GUI remain Pending. Also check rapid window/tab changes, scrollbar thumb/page tracking, device drivers and high-resolution wheels. Routing uses macOS precision/phase flags; physical mouse hardware with touch-style event flags needs separate qualification. Automated routing tests and compilation do not establish that the user's hardware symptom is resolved.
