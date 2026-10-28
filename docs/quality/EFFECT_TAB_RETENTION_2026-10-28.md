# Effect mode retention — 2026-10-28

## Cause and change

The Mac effects rack's `onAppear` previously set the selected tab to OFF if the player was bypassed, and otherwise unconditionally set it to BASIC. A Pro selection was therefore lost whenever the user left the page and returned. Mobile already saves and restores its `selectedEffectPageTab`; this particular reset is in the Mac view.

🟢 [Done] Mac `LibraryContent` stores its selected Basic/Pro/Off tab via `@AppStorage` under `audio.selectedEffectTab.v1`, with BASIC as the default. On rack appearance, preserve an existing BASIC or Pro choice. If the player's persisted bypass is true, show OFF, including installations from before the tab preference existed. If OFF is stored but bypass is false, show BASIC, avoiding a displayed OFF state for active processing. Changing tabs continues to use the existing guarded bypass control. No DSP algorithm, effect parameters, gain protection, or enabled-setting persistence is changed.

Desktop's Basic/Pro tabs currently organize which controls are displayed; the existing desktop audio routing is preserved. The mobile player uses its existing selected-tab processing policy. This fix aligns selection retention without claiming that these distinct existing routing policies are identical.

## Validation

- `swift test --filter 'EffectRackInputTests.retainedModeAcrossPageVisits|AudioEffectPresetTests'`: 5 tests pass. A real `NSHostingView` mounts the production rack with Pro selected, removes and remounts it three times, toggles OFF and back to Pro, and verifies bypass state and all effect settings. A legacy persisted bypass without a tab value opens OFF. Existing preset registry and settings round-trip tests pass. Test preferences are restored afterwards.
- Mac App Store Release build with signing disabled succeeds for arm64 and x86_64. [Test output and source hashes](../measurements/effect-tab-retention-2026-10-28/).
- Mobile selection save/restore was checked in source; no mobile code change was needed for the reported page-revisit reset.

⭕️ [Pending] Verify the installed Mac application's page navigation, complete app quit/relaunch, OFF restoration and real playback with a user's saved preferences. The automated view-remount test does not itself restart the application.

🟢 [Done] Normal-quit mode restoration was subsequently checked in an isolated Release app; see [relaunch qualification](EFFECT_MODE_RELAUNCH_2026-10-28.md). Installed-app playback remains Pending.
