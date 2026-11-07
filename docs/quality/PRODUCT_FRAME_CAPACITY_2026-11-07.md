# Product graph frame capacity — 2026-11-07

The Debug-only driver invokes PlaybackController.configureEngine, the shipping graph builder, using a manual-render output format override. It uses the actual registry pipeline, source mixer, both player nodes, effect-output protection and ordinary final output path. All effect settings are enabled and every normalized parameter is set to 0.5 so default zero strength does not silently bypass wet branches. These settings are local to the test controller; no preferences are written.

One test declaration runs 16 scenarios: maximum output block 512/2048 × output sequence 88.2→48→96→88.2 kHz × 44.1/48 kHz source. The same controller is retained, with a forced graph rebuild for each simulated route/source change. Each case renders four gain stages with four block sizes; the 512 limit uses 128/256/512/512, and the 2048 limit uses 512/558/1024/2048. The 48 kHz-source cases schedule both players and use the shipping CrossfadePolicy gains from overlap start to finish. All renders succeed, contain finite PCM and are non-silent. Forty-four mixer capacities are logged per scenario. At 512 output frames/88.2 kHz, the 96 kHz mixers report 576 frames, enough for the approximately 558-frame conversion pull; a 512 entry is also present in the recorded graph. This shows why a blanket claim that every 512 value is invalid would be wrong.

Final intermediate-strength matrix: **16/16 scenarios PASS (1 test declaration)**. Earlier default-parameter and 2048-only trials are retained as intermediate logs. The independent shipping PlaybackTransportIntegrationTests.crossfade test also passes: both schedules survive pause/drain and the incoming normalization reference survives late analysis. Debug and App Store Release signing-disabled builds pass. The diagnostic driver is excluded from Release.

No further DSP/capacity change is justified by these results. This does not reproduce the reported live-device -10874. The common AudioProcessingPolicy source is byte-identical in iPhone and Mac; iPhone runtime and sync formats are unchanged in this follow-up. A new independent iPhone build was not needed for these Mac-only test changes.

## Limits and Pending

The output override simulates sample-rate reconnection, not a physical CoreAudio device switch or delivery of AVAudioEngineConfigurationChange. Forced rebuilds do not qualify cached-graph reuse. Synthetic 0.02-amplitude stereo CAF fixtures are used; they do not cover mono/multichannel, every preset, maximum parameters or real music. This is the ordinary build (final true-peak and audio-thread-gain experiment flags are not enabled), not qualification of every compile-time variant. The offline crossfade drive does not itself exercise automatic queue advancement or real-time end callbacks; the separate transport regression covers its stated scope only.

⭕️ [Pending] Physical 88.2 kHz output, actual route-change events and device-buffer negotiation, internal mixer identity at the original failing moment, real song boundaries/repeat, device removal/reconnection, and iPhone speaker/listening verification. The original render error remains unresolved on physical hardware until reproduced and retested. No runtime Audio Unit limits are forced after allocation.

[Raw logs](../measurements/product-frame-capacity-2026-11-07/).

Follow-up: [Retained graph verification](PRODUCT_FRAME_REUSE_2026-11-07.md) now covers compatible graph reuse, separately from the forced-rebuild scope above. Physical device cases remain Pending.
