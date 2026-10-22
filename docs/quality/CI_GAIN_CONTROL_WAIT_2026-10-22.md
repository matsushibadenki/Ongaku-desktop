# Connected gain CI control-state synchronization — 2026-10-22

The [reported run](https://github.com/matsushibadenki/Ongaku-desktop/actions/runs/39752196693/job/119735237954) fails in `Connected gain acknowledgement and tail integration tests`, with eight assertions across two of four tests. The runner-capacity notice is separate from those assertion failures.

The manual-render test used fixed 12–40 ms sleeps to assume MainActor/dispatch callbacks had completed. Effect restoration also has a scheduled settle stage: rendering the fade-in frames before that callback issues the ramp leaves the waveform muted. Transport completion likewise needs both acknowledgement polling and a delayed drain callback. The no-render fallback test used 350 sleeps while the production poll has up to 500 callbacks; their relative scheduling differs, so the test could finish before the fallback callback under CI load.

Replace positive completion sleeps with bounded observed-state waits (30-second monotonic deadline). Before rendering fade-in, require both the topology commit and the new gain target to be issued; after rendering, require transition completion. Wait for actual transport and retarget completion. Preserve exact render-frame counts, no-early-commit assertions, zero-PCM checks, restored amplitude tolerance, retained reverb tail, stale-completion rejection and physical pause-before-fallback-commit checks. Add 50 ms of deliberate delay to effect control scheduling so the old timing assumption is exercised on fast developer machines too.

Only the Desktop test harness changes. There is no app/runtime/DSP change, no iPhone algorithm divergence and no relaxation of waveform/safety tolerances. The deadline is test failure containment, not a new production audio timeout.

## Validation

- `swift test --filter AudioThreadGainIntegrationTests`: four tests pass (2.984 s after compilation).
- Exact CI command `swift test --skip-build --filter AudioThreadGainIntegrationTests`: three additional consecutive runs pass, four tests each, with intentional delayed effect scheduling enabled throughout.
- `git diff --check`: pass. Developer toolchain is Xcode 27.1 / Testing 2084; reported CI used Xcode 26.6 / Testing 1902. Local success does not establish remote runner success.
- Raw local logs are preserved in `docs/measurements/ci-gain-control-2026-10-22/`.

Remote GitHub CI after publication remains unverified. Physical-device listening remains in the existing roadmap qualification scope; this test-only correction makes no new device claim.
