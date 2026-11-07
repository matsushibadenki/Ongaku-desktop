import Accelerate
import Foundation

/// Test-only reconstruction meter. No production detector state or coefficients.
/// Kaiser-windowed sinc, Double precision; positive filter stride is correlation.
struct IndependentIntersampleMeter {
    let radius: Int
    let phases: Int
    private let kernels: [[Double]]

    init(radius: Int = 96, phases: Int = 32) {
        precondition(radius >= 16 && phases >= 4)
        self.radius = radius; self.phases = phases
        func i0(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0
            for n in 1...50 {
                term *= x * x / (4 * Double(n * n)); sum += term
                if term < sum * 1e-16 { break }
            }
            return sum
        }
        let beta = 9.0, denominator = i0(9)
        kernels = (1..<phases).map { phase in
            let fraction = Double(phase) / Double(phases)
            var kernel = (-radius...radius).map { offset -> Double in
                let x = fraction - Double(offset)
                guard abs(x) < Double(radius) else { return 0 }
                let sinc = abs(x) < 1e-14 ? 1 : sin(.pi * x) / (.pi * x)
                return sinc * i0(beta * sqrt(max(0, 1 - pow(x / Double(radius), 2)))) / denominator
            }
            let sum = kernel.reduce(0, +)
            for i in kernel.indices { kernel[i] /= sum }
            return kernel
        }
    }

    func peak(_ channels: [[Float]], trimming: Int = 0) -> Double {
        var peak = 0.0
        for channel in channels {
            precondition(channel.allSatisfy(\.isFinite))
            guard channel.count > trimming * 2 else { continue }
            let count = channel.count - trimming * 2
            let padded = Array(repeating: 0.0, count: radius) + channel.map(Double.init)
                + Array(repeating: 0.0, count: radius)
            for v in channel[trimming..<(channel.count - trimming)] { peak = max(peak, abs(Double(v))) }
            var interpolated = [Double](repeating: 0, count: count)
            for kernel in kernels {
                padded.withUnsafeBufferPointer { input in
                    kernel.withUnsafeBufferPointer { coefficients in
                        interpolated.withUnsafeMutableBufferPointer { output in
                            vDSP_convD(input.baseAddress!.advanced(by: trimming), 1, coefficients.baseAddress!, 1,
                                       output.baseAddress!, 1, vDSP_Length(count), vDSP_Length(kernel.count))
                        }
                    }
                }
                var maximum = 0.0
                vDSP_maxmgvD(interpolated, 1, &maximum, vDSP_Length(count))
                peak = max(peak, maximum)
            }
        }
        return peak
    }
}
