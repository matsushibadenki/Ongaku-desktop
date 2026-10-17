import Foundation

/// Coalesces continuous controls and protects bypass commits with the shared iPhone envelope.
/// Scheduling is on the control thread; live timing and audibility still require device testing.
@MainActor
final class EffectParameterTransition {
    typealias Settings = [RealtimeAudioEffectSetting]
    typealias Schedule = (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private enum Phase { case idle, waiting, fadingOut, fadingIn }
    private let isAudible: () -> Bool
    private let shouldDefer: () -> Bool
    private let setEnvelope: (Float) -> Void
    private let commit: (Settings) -> Void
    private let schedule: Schedule
    private(set) var applied: [RealtimeAudioEffectKind: RealtimeAudioEffectSetting] = [:]
    private var pending: Settings?
    private var remaining = 0
    private var generation: UInt64 = 0
    private var phase = Phase.idle
    private var envelope: Float = 1
    var isProtectingOutput: Bool { phase == .fadingOut || phase == .fadingIn }

    init(isAudible: @escaping () -> Bool, shouldDefer: @escaping () -> Bool,
         setEnvelope: @escaping (Float) -> Void = { _ in },
         schedule: @escaping Schedule = { delay, action in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
         }, commit: @escaping (Settings) -> Void) {
        self.isAudible = isAudible; self.shouldDefer = shouldDefer
        self.setEnvelope = setEnvelope; self.schedule = schedule; self.commit = commit
    }

    /// The host supplies the complete effective rack, including OFF intent.
    /// Stop/rebuild cancels every old callback and restores only the protection gain.
    func apply(_ settings: Settings, immediately: Bool = false, force: Bool = false) {
        if immediately || force || !isAudible() {
            generation &+= 1; pending = nil; phase = .idle
            writeEnvelope(1)
            commitChanges(settings, force: force)
            return
        }
        if phase != .idle { pending = settings; return }
        guard settings.contains(where: { $0.isEnabled && applied[$0.kind] != $0 }) || bypassChanged(settings) else {
            commitChanges(settings); return
        }
        pending = settings
        remaining = EffectTransitionPolicy.parameterSteps
        if bypassChanged(settings) && !shouldDefer() { beginFadeOut() }
        else { scheduleNext() }
    }

    private func bypassChanged(_ settings: Settings) -> Bool {
        settings.contains { (applied[$0.kind]?.isEnabled ?? false) != $0.isEnabled }
    }

    private func scheduleNext() {
        phase = .waiting
        let token = generation
        schedule(EffectTransitionPolicy.parameterInterval) { [weak self] in
            guard let self, self.generation == token, let target = self.pending else { return }
            guard self.isAudible() else { self.apply(target, immediately: true); return }
            if self.shouldDefer() { self.scheduleNext(); return }
            if self.bypassChanged(target) { self.beginFadeOut(); return }
            self.commitChanges(target.map {
                EffectTransitionPolicy.interpolate($0, from: self.applied[$0.kind], fraction: 1 / Float(self.remaining))
            })
            self.remaining -= 1
            if self.remaining > 0 { self.scheduleNext() }
            else { self.pending = nil; self.phase = .idle }
        }
    }

    private func beginFadeOut() {
        phase = .fadingOut
        ramp(to: 0, duration: EffectTransitionPolicy.protectionFadeOut) { [weak self] in
            guard let self, let target = self.pending else { return }
            self.pending = nil
            self.commitChanges(target) // Commit at zero, then restore immediately; no silent hold.
            self.beginFadeIn()
        }
    }

    private func beginFadeIn() {
        phase = .fadingIn
        ramp(to: 1, duration: EffectTransitionPolicy.protectionFadeIn) { [weak self] in
            guard let self else { return }
            self.phase = .idle
            let target = self.pending; self.pending = nil
            if let target { self.apply(target) }
        }
    }

    private func ramp(to target: Float, duration: TimeInterval, completion: @escaping () -> Void) {
        let token = generation, start = envelope
        let steps = EffectTransitionPolicy.envelopeSteps(duration: duration)
        // Absolute deadlines avoid accumulating a full step delay after each late callback.
        for step in 1...steps {
            schedule(duration * Double(step) / Double(steps)) { [weak self] in
                guard let self, self.generation == token else { return }
                if !self.isAudible() {
                    self.apply(self.pending ?? Array(self.applied.values), immediately: true)
                    return
                }
                // A pre-scheduled overlap can begin after a delayed control callback.
                // Abort the descent, restore, and retry later; never hold the song muted.
                if self.phase == .fadingOut && self.shouldDefer() {
                    self.generation &+= 1
                    self.beginFadeIn()
                    return
                }
                self.writeEnvelope(EffectTransitionPolicy.envelopeGain(from: start, to: target, step: step, steps: steps))
                if step == steps { completion() }
            }
        }
    }

    private func writeEnvelope(_ gain: Float) { envelope = gain; setEnvelope(gain) }

    private func commitChanges(_ settings: Settings, force: Bool = false) {
        let changed = settings.filter { force || applied[$0.kind] != $0 }
        guard !changed.isEmpty else { return }
        commit(changed)
        for setting in settings { applied[setting.kind] = setting }
    }
}
