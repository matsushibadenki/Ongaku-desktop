# Reproduce the component audit

Run from `/Users/Shared/Program/Xcode/Ongaku` on an Apple Silicon Mac with Xcode and the iOS 27.0 Simulator runtime. Use a new temporary work directory and a dedicated Simulator. The runner does not create/delete devices, install apps, or alter product apps. It only launches/terminates the fixed **audit** bundle and replaces its own Documents/status and result files. Never point it at a product bundle or a shared audit run.

```sh
AUDIT_WORK=$(mktemp -d /private/tmp/ongaku-transient-cost.XXXXXX)
python3 tests/generate_transient_cost_pcm.py "$AUDIT_WORK/fixtures"
xcrun clang++ -std=c++20 -Os -fobjc-arc -mmacosx-version-min=14.0 tests/TransientCostAudit.mm audio/SpectralTransientAudioUnit.mm -framework AVFoundation -framework AudioToolbox -framework Foundation -o "$AUDIT_WORK/mac-audit"
xcrun swiftc -O -swift-version 6 audio/IntegratedLoudnessMeter.swift tests/TransientLoudnessComparison.swift -o "$AUDIT_WORK/compare"
mkdir "$AUDIT_WORK/TransientCostAudit.app"
cp tests/TransientCostAudit-Info.plist "$AUDIT_WORK/TransientCostAudit.app/Info.plist"
cp -R "$AUDIT_WORK/fixtures" "$AUDIT_WORK/TransientCostAudit.app/fixtures"
xcrun --sdk iphonesimulator clang++ -target arm64-apple-ios17.0-simulator -isysroot "$(xcrun --sdk iphonesimulator --show-sdk-path)" -std=c++20 -Os -fobjc-arc tests/TransientCostAudit.mm audio/SpectralTransientAudioUnit.mm -framework UIKit -framework AVFoundation -framework AudioToolbox -framework Foundation -o "$AUDIT_WORK/TransientCostAudit.app/TransientCostAudit"
codesign --force --sign - "$AUDIT_WORK/TransientCostAudit.app"
AUDIT_DEVICE=$(xcrun simctl create 'Ongaku Transient Cost Audit' com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation com.apple.CoreSimulator.SimRuntime.iOS-27-0)
xcrun simctl boot "$AUDIT_DEVICE"
xcrun simctl bootstatus "$AUDIT_DEVICE" -b
xcrun simctl install "$AUDIT_DEVICE" "$AUDIT_WORK/TransientCostAudit.app"
python3 tests/run_transient_cost_samples.py "$AUDIT_WORK" "$AUDIT_DEVICE"
xcrun simctl shutdown "$AUDIT_DEVICE"
xcrun simctl delete "$AUDIT_DEVICE"
```

Preserve `mac/*.json`, `ios/*.json`, `comparison/*` and the fixture manifest before removing the temporary work directory. Raw per-mode PCM is intentionally not committed: it can be regenerated from the deterministic generator and hashes. The published `summary.json` groups the three raw samples by platform/rate/mode, reporting min/median/max; CPU µs/block = renderCPUms × 1000 / 2000, CPU% one core = renderCPUms / virtualSeconds / 10. RSS values are bytes; divide by 1,048,576 for MiB.

Do not build or run other audits during the timed series. Startup samples are process-first at 44.1 kHz, then framework-warm at 48/96/192 kHz; the entire product launch is not measured. Fixture export occurs only after each process's timed graphs. Clock/RSS checks, render status, nonzero first PCM and finite comparison output fail the audit rather than silently accepting invalid data. All direct-AU comparisons use the production DSP; normalization uses the production BS.1770 meter.
