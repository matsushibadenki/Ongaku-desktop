# Desktop CD playback / meter availability — 2026-10-21

## Routing review

Desktop imports Music XML file locations into its local managed library and reads CD-ripped files using AVAudioFile / PlaybackController. Its MusicKit catalog controller is a separate path. A local file-open failure reports an error and stops; it does not silently hand a CD file to MusicKit. The mobile source-open/system-fallback gap therefore does not apply directly and its export retry should not be copied into this synchronous desktop pipeline without need.

## Reproduced defect and repair

The generated mono CD test exposed a separate channel-layout defect. The desktop rack used the source channel count directly, while mobile already expands mono to at least two channels. Stereo-only Audio Units in the rack reject a one-channel bus with Core Audio -10868, including when the module is bypassed.

First reproduce the unsupported mono bus in the real Equalizer graph, then make the offline test graph stereo and reproduce the same exception in the unmodified PlaybackController.configureEngine. Negative logs: `/private/tmp/ongaku-desktop-cd-availability.log`, `/private/tmp/ongaku-desktop-cd-controller-negative.log`.

The source mixer now expands mono to two channels before the 96 kHz effect rack, matching mobile. File scheduling, EOF, duration, source metadata and seeking retain the original source format. The signal-path snapshot reports the actual two-channel DSP format; stereo and wider-source policy are otherwise unchanged. This is a runtime mono-layout repair, not an implementation of MusicKit audio capture.

## Verification

The new test extends PlaybackTransportIntegrationTests so CI's existing real-engine isolation includes it automatically. Generate 44.1 kHz / 16-bit mono and stereo AIFF sources, rip them through production AudioCDRipper into AIFF, WAV, ALAC and AAC (8 conditions), then:

- Load each result through real muted PlaybackController; verify local playback, source/processing format and installed meter tap.
- Render the decoded file through a real production EQ at 96 kHz offline. Verify nonzero left/right RMS and spectrum, and measurable attenuation with the EQ enabled. No audible hardware output is needed for the signal checks.
- Run the existing serialized transport/track-end suite alongside the new case, then build ordinary and Mac App Store app configurations.

- 🟢 [Done] All 8 production-rip conditions pass: ALAC/AIFF/WAV/AAC × mono/stereo. The new test passes in 18.127 seconds; the full isolated 12-test real-engine transport/EOF suite passes in 84.074 seconds. Log: `/private/tmp/ongaku-desktop-cd-fixed.log`.
- 🟢 [Done] Ordinary Xcode Debug and Universal Mac App Store Release app builds succeed; whitespace checks pass. Logs: `/private/tmp/ongaku-desktop-cd-debug-build.log`, `/private/tmp/ongaku-desktop-cd-store-build.log`. Results are reflected in both roadmaps.

## Pending

- ⭕️ [Pending] Qualify real optical-disc reads and the user's Music-managed/imported CD files, physical output devices and listening, mono centering/level, Music XML migration, DAC/rate changes, sleep/wake, next/repeat/crossfade and iPhone transfer. Generated fixtures and muted/offline development-Mac renders do not establish those device scenarios.
- ⭕️ [Pending] The mobile user's exact source-open failure remains unconfirmed without device logs. Mobile's compatibility snapshot retry and the desktop mono repair address distinct evidenced paths while keeping local PCM-based meters/effects consistent.
