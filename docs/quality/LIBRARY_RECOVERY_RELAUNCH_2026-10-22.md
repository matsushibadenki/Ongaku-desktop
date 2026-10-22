# Restart after library recovery — 2026-10-22

## Behavior

After “Choose a folder and repair automatically…” successfully repairs the library and saves the profile/security-scoped folder authorization, Desktop launches a fresh instance of its own app bundle through `NSWorkspace`. It exits the old instance only after Launch Services returns a different, running process. The existing startup path then reads the repaired library.

The recovery screen shows a localized restart progress indicator. Recovery-induced reload tasks are suppressed in the outgoing process. Repeated restart requests are coalesced. A launch failure leaves the old app open and offers Restart/Cancel, clearly distinguishing successful repair from failed restart. Folder cancellation or failed repair does not restart. The explicitly confirmed new-library creation branch also restarts after success.

Use the same implementation for direct distribution and App Store builds; no shell helper, Sparkle relaunch API or new sandbox entitlement is required. Isolated qualification launches retain their temporary root/recovery mode but do not repeat fixture creation. Mobile runtime is unchanged.

## Completed verification

- `swift test --scratch-path /private/tmp/OngakuDesktop-Recovery-Tests --filter 'ApplicationSettingsTests|LibraryRecoveryRelaunchTests'`: **26 tests / 2 suites pass**. Existing migration discovery, data preservation, saved profile reopening and storage switching tests pass. New tests hold launch completion to prove termination waits, reject concurrent/subsequent duplicate restart calls, and verify failed launch keeps the current app alive and can retry without repeating repair.
- Ordinary Xcode `OngakuDesktop` Debug and `OngakuDesktopAppStore` Release builds: **pass**, with signing disabled for compilation checks. Only the existing AppIntents extraction notice appears.
- Real macOS Launch Services smoke tests: an isolated temporary app runs the extracted production relauncher with its default launch/terminate closures. Unrestricted probe: parent PID **58517**, replacement PID **58518**. Ad-hoc-signed App Sandbox probe: parent PID **58762**, replacement PID **58763**. Each records a distinct replacement process, no error receipt, and normal parent exit; the child self-exits after the observation window. The user's running Ongaku app/library is not launched, terminated or modified by these probes.
- EN/JA/zh-Hans strings pass `plutil -lint`; `git diff --check` passes.

Logs are retained in `/private/tmp/ongaku-desktop-recovery-tests-2026-10-22.log`, `ongaku-desktop-recovery-build-2026-10-22.log`, `ongaku-desktop-recovery-store-2026-10-22.log` and `ongaku-desktop-relaunch-sandbox-2026-10-22.json`. Temporary compiled test/build/probe bundles are removed after verification to limit SSD usage.

## Qualification still required

⭕️ [Pending] Complete the folder-picker → repair → automatic restart → populated main window flow using the user's affected library, including external-volume reconnect and persistent sandbox bookmarks, on the installed signed distribution/App Store app. The actual reported folder/permission state was not reproduced. The sandbox probe establishes the restart API/process handoff, not the user's entire library recovery or Apple distribution signing. No release upload/version bump is included.
