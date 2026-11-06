# Pairing invitation response — 2026-11-06

## Diagnosis and change

The user clarified that the unresponsive button was the iPhone pairing permission button. Previously, the SwiftUI presentation binding rejected the invitation when the dialog dismissed. Dismissal can precede the Allow action, consuming its one-shot handler before acceptance. The changed binding only dismisses presentation; explicit Allow/Cancel or the deadline resolves the invitation. This is a reproducible control-flow defect; the original physical-device incident has not been reproduced here.

The controller checks handler ownership before changing state or cancelling a timer. Late actions cannot affect a newer request; a hidden unresolved request still rejects overlapping invitations and expires correctly. Discovery resume cannot restart advertising while permission or connection is pending. Late delegate invitations after stop are rejected. No pairing code or device name is added to diagnostic events.

Both products define decision/invitation/UI deadlines as 25/30/35 seconds. Mac formerly showed failure at 20 seconds, before iPhone's 25-second permission deadline. This is an application policy, not a guarantee about network latency.

## Verification

- `bash tests/run_pairing_invitation_regression.sh`: six scenarios PASS. Extracts current production methods and checks the SwiftUI setter and Mac constants/use. Covers dismissal before Allow/Cancel, exactly-once response, hidden expiry, stale actions, overlapping invitations, stopped lifecycle and ordered deadlines. Network/session/presentation rendering are substitutes, not real-device tests.
- Desktop `swift test --jobs 2 --filter DeviceSyncTests`: 14 tests PASS; compiles the changed Mac controller.
- English/Japanese/Simplified Chinese localization plutil lint PASS. Diff whitespace check PASS.
- iPhone Debug Simulator build (arm64/x86_64, signing disabled): final BUILD SUCCEEDED. Initial restricted build failed on simulator/macro services; unrestricted retry found a missing explicit `self` in the retry closure. Fixed that reference and rebuilt successfully. No device launch or signed build was performed. All attempt logs are retained. Logs are in `../measurements/pairing-invitation-2026-11-06/`.

## Effect OFF report

No direct pairing-to-effect-settings mutation was found. The existing DSP/default behavior is unchanged. Added `audio.effect.user_intent` and `audio.effects.mode_intent` events to distinguish user input and mode changes from `effect.highQuality.apply`. This does not establish or fix the cause of spontaneous OFF.

## Pending

Signed physical iPhone and Mac pairing: Allow/Cancel/expiry, repeated invites, foreground changes and real network connection. Confirm consent remains explicit, and check effect settings across these actions. The spontaneous effect OFF report remains Pending until reproduced with intent/application logs. No claim is made that mocked control-flow tests prove a working MultipeerConnectivity connection.
