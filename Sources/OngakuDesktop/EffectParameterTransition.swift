import Foundation

/// Coalesces continuous gestures without touching transport or output volume.
/// Bypass/topology commits remain immediate; sample-accurate bypass ramps are separate work.
@MainActor
final class EffectParameterTransition {
    typealias Settings = [RealtimeAudioEffectSetting]
    typealias Schedule = (TimeInterval, @escaping @MainActor () -> Void) -> Void

    private let isAudible: () -> Bool
    private let shouldDefer: () -> Bool
    private let commit: (Settings) -> Void
    private let schedule: Schedule
    private(set) var applied: [RealtimeAudioEffectKind: RealtimeAudioEffectSetting] = [:]
    private var pending: Settings?
    private var remaining = 0
    private var generation: UInt64 = 0
    private var isScheduled = false

    init(isAudible: @escaping () -> Bool, shouldDefer: @escaping () -> Bool,
         schedule: @escaping Schedule = { delay, action in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
         }, commit: @escaping (Settings) -> Void) {
        self.isAudible = isAudible
        self.shouldDefer = shouldDefer
        self.schedule = schedule
        self.commit = commit
    }

    /// The host supplies the complete effective rack, including OFF intent.
    /// Immediate application invalidates all older queued callbacks, including rebuilds.
    func apply(_ settings: Settings, immediately: Bool = false, force: Bool = false) {
        let changed = settings.contains { $0.isEnabled && applied[$0.kind] != $0 }
        let bypassChanged = settings.contains { (applied[$0.kind]?.isEnabled ?? false) != $0.isEnabled }
        if immediately || force || !isAudible() || bypassChanged {
            generation &+= 1
            pending = nil
            isScheduled = false
            commitChanges(settings, force: force)
            return
        }
        // Coalesce before checking equality with an intermediate applied value.
        // A gesture passing through that value must not restart the eight steps.
        if pending != nil {
            pending = settings
            return
        }
        guard changed else {
            commitChanges(settings)
            return
        }
        pending = settings
        guard !isScheduled else { return }
        remaining = EffectTransitionPolicy.parameterSteps
        scheduleNext()
    }

    private func scheduleNext() {
        isScheduled = true
        let token = generation
        schedule(EffectTransitionPolicy.parameterInterval) { [weak self] in
            guard let self, self.generation == token, let target = self.pending else { return }
            self.isScheduled = false
            guard self.isAudible() else {
                self.apply(target, immediately: true)
                return
            }
            // Both sources share the same rack. Keep its settings stable while
            // the scheduled song crossfade is actually in progress.
            if self.shouldDefer() {
                self.scheduleNext()
                return
            }
            let fraction = 1 / Float(self.remaining)
            let settings = target.map {
                EffectTransitionPolicy.interpolate($0, from: self.applied[$0.kind], fraction: fraction)
            }
            self.commitChanges(settings)
            self.remaining -= 1
            if self.remaining > 0 { self.scheduleNext() }
            else { self.pending = nil }
        }
    }

    private func commitChanges(_ settings: Settings, force: Bool = false) {
        let changed = settings.filter { force || applied[$0.kind] != $0 }
        guard !changed.isEmpty else { return }
        commit(changed)
        for setting in settings { applied[setting.kind] = setting }
    }
}
