import AVFoundation
import Foundation
#if canImport(OngakuAudioDSP)
import OngakuAudioDSP
#endif

/// Control-thread owner; the Audio Unit alone advances the per-sample envelope.
/// Enabled only in the internal qualification build until device qualification.
@MainActor
final class AudioThreadGainStage {
    let node = OngakuGainEnvelopeAudioUnit.makeNode()
    private var unit: OngakuGainEnvelopeAudioUnit { node.auAudioUnit as! OngakuGainEnvelopeAudioUnit }
    private(set) var gain: Float
    private var generation: UInt64 = 0

    typealias Schedule = (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private let now: () -> TimeInterval
    private let schedule: Schedule

    init(gain: Float, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedule: @escaping Schedule = { delay, action in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
         }) {
        self.gain = gain
        self.now = now
        self.schedule = schedule
    }

    func setImmediate(_ value: Float) {
        generation &+= 1
        gain = value.isFinite ? min(1, max(0, value)) : 0
        _ = unit.ramp(toGain: gain, durationFrames: 0)
    }

    /// Allocation/reconnection resets the AU muted. Reapply retained intent only
    /// after engine.start has allocated resources; never reset a running AU.
    func synchronizeAfterStart() { setImmediate(gain) }

    func ramp(to value: Float, duration: TimeInterval,
              isRunning: @escaping () -> Bool, isCurrent: @escaping () -> Bool,
              stalled: @escaping () -> Void, cancelled: @escaping () -> Void = {},
              completion: @escaping () -> Void) {
        generation &+= 1
        let request = generation
        gain = value.isFinite ? min(1, max(0, value)) : 0
        let rate = node.outputFormat(forBus: 0).sampleRate
        guard rate.isFinite, (8_000...384_000).contains(rate) else {
            stalled()
            setImmediate(0)
            completion()
            return
        }
        let frames = UInt64((max(0, min(1, duration.isFinite ? duration : 0)) * rate).rounded())
        let token = unit.ramp(toGain: gain, durationFrames: frames)
        poll(request: request, token: token, deadline: now() + 2, isRunning: isRunning,
             isCurrent: isCurrent, stalled: stalled, cancelled: cancelled, completion: completion)
    }

    private func poll(request: UInt64, token: UInt64, deadline: TimeInterval,
                      isRunning: @escaping () -> Bool, isCurrent: @escaping () -> Bool,
                      stalled: @escaping () -> Void, cancelled: @escaping () -> Void,
                      completion: @escaping () -> Void) {
        guard generation == request, isCurrent() else { cancelled(); return }
        if token != 0, unit.isRampComplete(token) { completion(); return }
        if !isRunning() {
            // A physically stopped graph is silent; a transport commit is safe.
            setImmediate(gain)
            completion()
            return
        }
        // Callback count is not elapsed time: a busy control queue can turn
        // 500 nominal 4 ms polls into many seconds. Check monotonic time at
        // the first available callback; actual rendered acknowledgement wins.
        guard token != 0, now() < deadline else {
            // No rendered-zero acknowledgement: stop I/O before committing.
            stalled()
            setImmediate(gain)
            completion()
            return
        }
        schedule(0.004) { [weak self] in
            guard let self else { cancelled(); return }
            self.poll(request: request, token: token, deadline: deadline,
                      isRunning: isRunning, isCurrent: isCurrent, stalled: stalled,
                      cancelled: cancelled, completion: completion)
        }
    }
}

#if ONGAKU_STARTUP_AUDIT
import Darwin

/// Internal audit only: no allocation, logging or clock reads in distribution builds.
@MainActor enum StartupCostAudit {
    static var rows: [[String: Any]] = []
    static var configuration: String {
#if ONGAKU_ENABLE_AUDIO_THREAD_GAIN
#if ONGAKU_ENABLE_TRUE_PEAK
        "gain-truepeak"
#else
        "gain"
#endif
#else
        "ordinary"
#endif
    }
    struct Stamp { let wall: UInt64; let cpu: Double }
    static func cpu() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
    }
    static func begin() -> Stamp { Stamp(wall: DispatchTime.now().uptimeNanoseconds, cpu: cpu()) }
    static func end(_ stage: String, _ stamp: Stamp) {
        let wall = DispatchTime.now().uptimeNanoseconds
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        rows.append(["stage": stage, "wall_ms": Double(wall - stamp.wall) / 1_000_000,
                     "cpu_ms": max(0, cpu() - stamp.cpu), "process_peak_rss_bytes": usage.ru_maxrss])
    }
    static func measure<T>(_ stage: String, _ work: () throws -> T) rethrows -> T {
        let stamp = begin(); defer { end(stage, stamp) }; return try work()
    }
}
#endif
