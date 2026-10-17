import Foundation

/// Offline/worker-only BS.1770 K-weighted integrated measurement for mono/stereo.
/// Channel energies are summed (never mono-downmixed). Complete 400 ms windows
/// advance by 100 ms; incomplete tails, clips <400 ms and all-gated silence have
/// no integrated result. Unsupported layouts must not be normalized as stereo.
/// Coefficient parameterization follows BS.1770 / libebur128's rate adaptation:
/// https://github.com/jiixyj/libebur128/blob/master/ebur128/ebur128.c
nonisolated struct IntegratedLoudnessMeter {
    private struct Biquad {
        let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
        var z1 = 0.0, z2 = 0.0
        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    let channelCount: Int
    private var shelf: [Biquad]
    private var highPass: [Biquad]
    private let hopFrames: Int
    private var hopEnergy = 0.0
    private var hopPosition = 0
    private var recentHops: [Double] = []
    private(set) var blockEnergies: [Double] = []
    private(set) var samplePeak: Double = 0
    private(set) var containsInvalidSamples = false

    init?(sampleRate: Double, channelCount: Int) {
        guard sampleRate.isFinite, (8_000...384_000).contains(sampleRate),
              (1...2).contains(channelCount) else { return nil }
        self.channelCount = channelCount
        hopFrames = Int((sampleRate * 0.1).rounded())
        let k = tan(.pi * 1681.974450955533 / sampleRate)
        let q = 0.7071752369554196
        let vh = pow(10, 3.999843853973347 / 20)
        let vb = pow(vh, 0.4996667741545416)
        let denominator = 1 + k / q + k * k
        let first = Biquad(b0: (vh + vb * k / q + k * k) / denominator,
                           b1: 2 * (k * k - vh) / denominator,
                           b2: (vh - vb * k / q + k * k) / denominator,
                           a1: 2 * (k * k - 1) / denominator,
                           a2: (1 - k / q + k * k) / denominator)
        let r = tan(.pi * 38.13547087602444 / sampleRate)
        let rq = 0.5003270373238773
        let rd = 1 + r / rq + r * r
        let second = Biquad(b0: 1, b1: -2, b2: 1,
                            a1: 2 * (r * r - 1) / rd,
                            a2: (1 - r / rq + r * r) / rd)
        shelf = Array(repeating: first, count: channelCount)
        highPass = Array(repeating: second, count: channelCount)
        recentHops.reserveCapacity(4)
    }

    /// Input access is synchronous; filter/window state survives arbitrary chunks.
    mutating func process(frameCount: Int, sample: (Int, Int) -> Float) {
        guard frameCount > 0 else { return }
        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                let input = Double(sample(channel, frame))
                if !input.isFinite { containsInvalidSamples = true }
                let finite = input.isFinite ? input : 0
                samplePeak = max(samplePeak, abs(finite))
                let filtered = highPass[channel].process(shelf[channel].process(finite))
                hopEnergy += filtered * filtered
            }
            hopPosition += 1
            if hopPosition == hopFrames {
                recentHops.append(hopEnergy / Double(hopFrames))
                if recentHops.count == 4 {
                    blockEnergies.append(recentHops.reduce(0, +) / 4)
                    recentHops.removeFirst()
                }
                hopPosition = 0
                hopEnergy = 0
            }
        }
    }

    var integratedLUFS: Double? {
        containsInvalidSamples ? nil : Self.integratedLUFS(blockEnergies: blockEnergies)
    }

    static func integratedLUFS(blockEnergies: [Double]) -> Double? {
        let absolute = pow(10, (-70.0 + 0.691) / 10)
        let first = blockEnergies.filter { $0.isFinite && $0 > absolute }
        guard !first.isEmpty else { return nil }
        let relative = first.reduce(0, +) / Double(first.count) * 0.1
        let gated = first.filter { $0 > relative }
        guard !gated.isEmpty else { return nil }
        return -0.691 + 10 * log10(gated.reduce(0, +) / Double(gated.count))
    }
}
