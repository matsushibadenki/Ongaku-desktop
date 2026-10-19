import Foundation
import Metal
import Darwin

private func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "SincBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
private func peakRSS() -> Int64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int64(usage.ru_maxrss) // Darwin reports bytes, not Linux KiB.
}
private func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS ? info.phys_footprint : 0
}
private func quantile(_ values: [Double], _ fraction: Double) -> Double {
    let sorted = values.sorted()
    return sorted[Int(ceil(Double(sorted.count - 1) * fraction))]
}
private struct Spec {
    let rate: Int, target: Int, frames: Int
    let phase: PrecisionSincPhaseMode, quality: PrecisionSincQualityMode
    var ratio: Double { Double(target) / Double(rate) }
    var outputFrames: Int { Int(ceil(Double(frames) * ratio)) }
}
private struct Kernel {
    let values: [Float], radius: Int, size: Int, phases: Int
    init(_ spec: Spec) {
        let k = ShippingSincMeasurement.benchmarkKernels(ratio: spec.ratio, phase: spec.phase, quality: spec.quality)
        (values, radius, size, phases) = (k.values, k.radius, k.size, k.phases)
    }
}
private func position(_ frame: Int, ratio: Double, phases: Int) -> SIMD2<Int32> {
    let value = Double(frame) / ratio
    let center = Int(value)
    let phase = Int(min(Double(phases - 1), max(0, (value - Double(center)) * Double(phases))))
    return SIMD2(Int32(center), Int32(phase))
}
private func signal(_ spec: Spec) -> [Float] {
    var result = [Float](repeating: 0, count: spec.frames * 2)
    var rng: UInt64 = 0x12345678
    for i in 0..<spec.frames {
        let part = min(5, i * 6 / spec.frames)
        let t = Double(i) / Double(spec.rate)
        rng = rng &* 6364136223846793005 &+ 1
        let noise = Double(rng >> 40) / Double(1 << 24) * 2 - 1
        let x: Double
        switch part {
        case 0: x = i == 0 || i == spec.frames / 12 ? 0.8 : 0
        case 1: x = 0.3
        case 2: x = 0.4 * sin(2 * .pi * 997 * t)
        case 3: x = 0.25 * sin(2 * .pi * Double(spec.rate) * 0.47 * t)
        case 4: x = 0.35 * sin(2 * .pi * (50 * t + 2000 * t * t))
        default: x = 0.35 * noise
        }
        result[i] = Float(x)
        result[spec.frames + i] = Float(-0.61 * x + 0.03 * noise)
    }
    return result
}
private func cpu(_ source: [Float], _ spec: Spec, _ k: Kernel) throws -> [Float] {
    var result = [Float](repeating: 0, count: spec.outputFrames * 2)
    try source.withUnsafeBufferPointer { src in
        try k.values.withUnsafeBufferPointer { kernels in
            try result.withUnsafeMutableBufferPointer { out in
                for start in stride(from: 0, to: spec.outputFrames, by: 262_144) {
                    for ch in 0..<2 {
                        try ShippingSincMeasurement.benchmarkRender(source: src.baseAddress! + ch * spec.frames,
                            count: spec.frames, output: out.baseAddress! + ch * spec.outputFrames + start,
                            start: start, frames: min(262_144, spec.outputFrames - start), kernels: kernels.baseAddress!,
                            ratio: spec.ratio, radius: k.radius, size: k.size, phases: k.phases)
                    }
                }
            }
        }
    }
    return result
}
private final class GPU {
    let device: MTLDevice, queue: MTLCommandQueue, pipeline: MTLComputePipelineState, kernels: MTLBuffer
    var gpuMS = 0.0
    var maxDispatchMS = 0.0
    var maxAllocatedBytes = 0
    init(_ k: Kernel, shader: String) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw NSError(domain: "MetalUnavailable", code: 1)
        }
        self.device = device; self.queue = queue
        let options = MTLCompileOptions()
        options.fastMathEnabled = false
        let library = try device.makeLibrary(source: String(contentsOfFile: shader, encoding: .utf8), options: options)
        pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "sinc")!)
        kernels = k.values.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)! }
    }
    func render(_ source: [Float], _ spec: Spec, _ k: Kernel) throws -> [Float] {
        try Task.checkCancellation()
        gpuMS = 0
        var output = [Float](repeating: 0, count: spec.outputFrames * 2)
        let src = source.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)! }
        for start in stride(from: 0, to: spec.outputFrames, by: 262_144) {
            try Task.checkCancellation()
            try autoreleasepool {
                let count = min(262_144, spec.outputFrames - start)
                let positions = (start..<(start + count)).map { position($0, ratio: spec.ratio, phases: k.phases) }
                let map = positions.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)! }
                let out = device.makeBuffer(length: count * 2 * MemoryLayout<Float>.stride, options: .storageModeShared)!
                let command = queue.makeCommandBuffer()!
                let encoder = command.makeComputeCommandEncoder()!
                encoder.setComputePipelineState(pipeline)
                for (i, b) in [src, kernels, map, out].enumerated() { encoder.setBuffer(b, offset: 0, index: i) }
                var params = SIMD4<UInt32>(UInt32(spec.frames), UInt32(count), UInt32(k.radius), UInt32(k.size))
                encoder.setBytes(&params, length: MemoryLayout.size(ofValue: params), index: 4)
                encoder.dispatchThreads(MTLSize(width: count, height: 2, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: min(256, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
                encoder.endEncoding()
                maxAllocatedBytes = max(maxAllocatedBytes, device.currentAllocatedSize)
                command.commit(); command.waitUntilCompleted()
                try require(command.status == .completed, "Metal command failed: \(String(describing: command.error))")
                let elapsed = (command.gpuEndTime - command.gpuStartTime) * 1000
                gpuMS += elapsed; maxDispatchMS = max(maxDispatchMS, elapsed)
                try Task.checkCancellation()
                let ptr = out.contents().bindMemory(to: Float.self, capacity: count * 2)
                output.withUnsafeMutableBufferPointer { dest in
                    for ch in 0..<2 { (dest.baseAddress! + ch * spec.outputFrames + start).update(from: ptr + ch * count, count: count) }
                }
            }
        }
        return output
    }
}
private func accuracy(_ output: [Float], _ source: [Float], _ spec: Spec, _ k: Kernel) throws -> [String: Double] {
    // Independent Float64 accumulation of the SAME quantized shipping coefficients.
    // This measures numerical error, not ideal-filter response or recovered detail.
    var indices = Set(stride(from: 0, to: spec.outputFrames, by: max(1, spec.outputFrames / 4096)))
    for boundary in [0, spec.outputFrames - 1, 262_144] + (1..<6).map({ $0 * spec.outputFrames / 6 }) {
        for offset in -180...180 where boundary + offset >= 0 && boundary + offset < spec.outputFrames { indices.insert(boundary + offset) }
    }
    var maxError = 0.0, errorEnergy = 0.0, signalEnergy = 0.0
    for ch in 0..<2 {
        for index in indices.sorted() {
            let p = position(index, ratio: spec.ratio, phases: k.phases)
            var reference = 0.0
            for tap in 0..<k.size {
                let sample = Int(p.x) - k.radius + tap
                if sample >= 0 && sample < spec.frames {
                    reference += Double(source[ch * spec.frames + sample]) * Double(k.values[Int(p.y) * k.size + tap])
                }
            }
            let error = Double(output[ch * spec.outputFrames + index]) - reference
            maxError = max(maxError, abs(error)); errorEnergy += error * error; signalEnergy += reference * reference
        }
    }
    try require(output.allSatisfy { $0.isFinite }, "Nonfinite output")
    let rms = sqrt(errorEnergy / Double(indices.count * 2))
    let snr = 10 * log10(max(signalEnergy, 1e-300) / max(errorEnergy, 1e-300))
    try require(maxError < 2e-6 && snr > 110, "Float64 reference tolerance failed")
    return ["reference_max_abs": maxError, "reference_rms": rms, "reference_snr_db": snr, "reference_samples": Double(indices.count * 2)]
}
@main
struct Benchmark {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 8 else { fatalError("backend sourceRate targetRate sourceFrames phase quality repeats shader") }
        let backend = args[0]
        let spec = Spec(rate: Int(args[1])!, target: Int(args[2])!, frames: Int(args[3])!,
                        phase: PrecisionSincPhaseMode(rawValue: args[4])!, quality: PrecisionSincQualityMode(rawValue: args[5])!)
        let repeats = Int(args[6])!
        let source = signal(spec)
        let startRSS = peakRSS()
        let prepare = now(); let k = Kernel(spec); let kernelMS = (now() - prepare) * 1000
        let setup = now(); let gpu = backend == "gpu" ? try GPU(k, shader: args[7]) : nil
        let setupMS = (now() - setup) * 1000
        var times: [Double] = [], deviceTimes: [Double] = [], output: [Float] = []
        for _ in 0...repeats {
            output = [] // Do not retain the previous output during the next measurement.
            let start = now()
            output = try autoreleasepool { try gpu?.render(source, spec, k) ?? cpu(source, spec, k) }
            times.append((now() - start) * 1000)
            deviceTimes.append(gpu?.gpuMS ?? 0)
        }
        // Snapshot before accuracy and CPU comparison allocate their own references.
        let measuredRSS = peakRSS()
        var row: [String: Any] = ["backend": backend, "source_rate": spec.rate, "target_rate": spec.target,
            "source_frames": spec.frames, "output_frames": spec.outputFrames, "phase": args[4], "quality": args[5],
            "channels": 2, "taps": k.size, "phases": k.phases, "kernel_ms": kernelMS, "backend_setup_ms": setupMS,
            "first_transform_ms": times[0], "warm_median_ms": quantile(Array(times.dropFirst()), 0.5),
            "warm_p95_ms": quantile(Array(times.dropFirst()), 0.95), "all_transform_ms": times,
            "gpu_device_median_ms": quantile(Array(deviceTimes.dropFirst()), 0.5), "max_dispatch_ms": gpu?.maxDispatchMS ?? 0,
            "peak_rss_bytes": measuredRSS, "initial_peak_rss_bytes": startRSS,
            "post_measurement_physical_footprint_bytes": footprint(),
            "metal_allocated_bytes": gpu?.maxAllocatedBytes ?? 0,
            "pcm_bytes": (source.count + output.count) * 4, "kernel_bytes": k.values.count * 4,
            "device": gpu?.device.name ?? "CPU", "os": ProcessInfo.processInfo.operatingSystemVersionString]
        for (key, value) in try accuracy(output, source, spec, k) { row[key] = value }
        if gpu != nil {
            let reference = try cpu(source, spec, k)
            var peak = 0.0, energy = 0.0
            for i in output.indices { let e = Double(output[i]) - Double(reference[i]); peak = max(peak, abs(e)); energy += e * e }
            row["cpu_gpu_max_abs"] = peak; row["cpu_gpu_rms"] = sqrt(energy / Double(output.count))
            try require(peak < 2e-6, "CPU/GPU mismatch")
        }
        let json = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        print(String(decoding: json, as: UTF8.self))
    }
}
