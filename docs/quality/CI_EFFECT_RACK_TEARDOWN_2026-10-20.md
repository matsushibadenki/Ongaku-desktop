# Effect rack teardown CI repair — 2026-10-20

Reported job: https://github.com/matsushibadenki/Ongaku-desktop/actions/runs/39376273006/job/118475011601

The failure is a runtime exclusivity trap, not the runner-capacity notice. The stack is `GraphHost.invalidate` → `EffectRackInputRegion.dismantleNSView` → `EffectRackInputRouter.detach/reset` → `isScrolling.setter` → `ObservableObjectPublisher.send` → `GraphHost.asyncTransaction`. Publishing into the same SwiftUI graph while it is being destroyed causes the conflicting access on the Xcode 26.6 runner.

The router now keeps native scroll state separate from observation. Teardown removes monitors/observers, cancels timers and clears ownership immediately without sending `objectWillChange`; normal live state changes still publish, and redundant assignments do not. The ObservableObject conformance is explicitly MainActor-isolated. Reattachment continues to notify its new graph normally.

## Evidence

- The added regression fails before the repair: one notification during detach, a second during repeated detach. After repair, both are silent, the state is reset immediately, and a reattached live scroll sends one update.
- All 13 input/layout regression tests pass locally, including the production rack's existing three-language/two-mode/two-width interaction matrix.
- Before this repair, the full 382-test run hit the previously recorded EQ-band-state flake. Its isolated rerun and the full 382-test rerun passed. This is separate from the reported GitHub exclusivity trap.
- GitHub's Xcode 26.6 confirmation and final whole-suite result are tracked in the 0.1.11 release record.

The upload of 0.1.11 (17) predates this repair and must not be selected for review. The repaired release uses 0.1.11 (18).
