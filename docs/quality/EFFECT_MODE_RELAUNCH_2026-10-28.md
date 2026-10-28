# Mac effect-mode relaunch qualification — 2026-10-28

## Method and isolation

🟢 [Done] Built the current desktop source as a **separate Release arm64 app** on an Apple M4 Mac (macOS 27.2, Xcode 27.1), with signing disabled and a unique bundle identifier. All 106 application source files in the temporary copy were checked against the current desktop workspace. The qualification launch used a temporary empty library and isolated preference domain; the installed production app was not launched or modified. The unique bundle ID isolates `UserDefaults.standard`; qualification-specific storage used a temporary suite. No actual tracks or audio playback were used.

The app was operated through its actual macOS accessibility UI. Each normal exit used Command-Q, followed by a check that the specific temporary executable was no longer running. It was launched again as a new process with the same isolated preferences. UI selection/controls were observed manually; preference content was separately read and asserted from the test domain. This was not an automated XCTest and is not a test of an installed App Store binary.

## Results

| Scenario | Observation |
|---|---|
| Pro, one effect enabled → quit → launch | Pro remained selected; Simulation remained ON at intensity 75%; one active effect shown. Stored mode was `pro` and bypass was false/default. |
| OFF → quit → launch | OFF remained selected and the bypass panel showed zero active. The saved Simulation setting remained enabled in preferences. |
| OFF → Pro → quit → launch | Pro and Simulation ON at 75% returned; saved bypass was false. |
| BASIC → quit → launch | BASIC and its controls returned; the Pro Simulation setting stayed saved. |
| Legacy saved bypass true, no mode key | On launch the rack showed OFF and saved the mode as `off`; the prior effect setting remained intact. |
| Saved mode `off` with bypass false | On launch the rack showed BASIC, corrected the saved mode to `basic`, and retained the prior Simulation setting. |

The legacy and inconsistent preference combinations were injected **only in the isolated test domain**. The 75% value is the default for Simulation; the non-default saved state tested here is its ON state. No new product behavior or DSP code was changed in this qualification.

[Structured observations, source hashes and build evidence](../measurements/effect-mode-relaunch-2026-10-28/). See also the original [retention fix and view-remount tests](EFFECT_TAB_RETENTION_2026-10-28.md).

## Pending

⭕️ [Pending] Verify on the user's installed Mac App Store/direct-release app with existing real preferences and actual playback: Pro/OFF sound and output protection after relaunch, live device routes, Intel, and abrupt termination/power loss. This test establishes normal-quit restoration in an isolated arm64 Release build, not these physical playback or installed-app scenarios.
