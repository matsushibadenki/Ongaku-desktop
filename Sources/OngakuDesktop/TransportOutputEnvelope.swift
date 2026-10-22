import Foundation

/// Independent transport attenuation, using the iPhone cosine policy.
/// Timer scheduling is deliberately injectable; hardware timing remains a device gate.
@MainActor
final class TransportOutputEnvelope {
    typealias Schedule = (TimeInterval, @escaping @MainActor () -> Void) -> Void
    typealias Ramp = (Float, TimeInterval, @escaping () -> Bool, @escaping () -> Void) -> Void
    private let audioRamp: Ramp?
    private let schedule: Schedule
    private let setGain: (Float) -> Void
    private var generation: UInt64 = 0
    private var stopped: (() -> Void)?
    private(set) var gain: Float = 0
    private(set) var isStopping = false
    private(set) var isStarting = false
    var isBusy: Bool { isStopping || isStarting }

    init(schedule: @escaping Schedule = { delay, action in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
    }, audioRamp: Ramp? = nil, setGain: @escaping (Float) -> Void) {
        self.audioRamp = audioRamp
        self.schedule = schedule; self.setGain = setGain
    }

    /// A superseding request replaces the commit without extending an ongoing drain.
    func stop(running: Bool, drain: TimeInterval, completion: @escaping () -> Void) {
        stopped = completion
        guard !isStopping else { return }
        generation &+= 1
        let token = generation
        isStopping = true; isStarting = false
        guard running else { finishStop(token); return }
        ramp(to: 0, token: token) { [weak self] in
            guard let self else { return }
            self.schedule(max(0.012, drain)) { [weak self] in self?.finishStop(token) }
        }
    }

    private func finishStop(_ token: UInt64) {
        guard generation == token, isStopping else { return }
        write(0); isStopping = false
        let completion = stopped; stopped = nil
        completion?()
    }

    /// Keep output silent until fresh source frames traverse the downstream path.
    func start(ready: @escaping () -> Bool, failed: @escaping () -> Void,
               completion: @escaping () -> Void = {}) {
        generation &+= 1
        let token = generation
        stopped = nil; isStopping = false; isStarting = true
        write(0)
        waitForRender(token, attempts: 250, ready: ready, failed: failed, completion: completion)
    }

    private func waitForRender(_ token: UInt64, attempts: Int, ready: @escaping () -> Bool,
                               failed: @escaping () -> Void, completion: @escaping () -> Void) {
        guard generation == token, isStarting else { return }
        if ready() {
            ramp(to: 1, token: token) { [weak self] in
                guard let self, self.generation == token else { return }
                self.isStarting = false; completion()
            }
        } else if attempts > 0 {
            schedule(0.004) { [weak self] in
                self?.waitForRender(token, attempts: attempts - 1, ready: ready,
                                    failed: failed, completion: completion)
            }
        } else {
            isStarting = false; write(0); failed()
        }
    }

    private func ramp(to target: Float, token: UInt64, completion: @escaping () -> Void) {
        if let audioRamp {
            audioRamp(target, 0.024, { [weak self] in self?.generation == token }, { [weak self] in
                guard let self, self.generation == token else { return }
                self.gain = target
                completion()
            })
            return
        }
        let from = gain
        for step in 1...EffectTransitionPolicy.transportSteps {
            schedule(0.024 * Double(step) / Double(EffectTransitionPolicy.transportSteps)) { [weak self] in
                guard let self, self.generation == token else { return }
                self.write(EffectTransitionPolicy.transportGain(from: from, to: target, step: step))
                if step == EffectTransitionPolicy.transportSteps { completion() }
            }
        }
    }
    private func write(_ value: Float) { gain = value; setGain(value) }
}
