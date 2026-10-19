#include <metal_stdlib>
using namespace metal;

// Offline prototype only. Host computes exact shipping Double positions/phases;
// Float time accumulation on GPU would select different phases in long tracks.
struct Parameters { uint sourceFrames, outputFrames, radius, taps; };
kernel void sinc(const device float *source [[buffer(0)]],
                 const device float *coefficients [[buffer(1)]],
                 const device int2 *positions [[buffer(2)]],
                 device float *output [[buffer(3)]],
                 constant Parameters &p [[buffer(4)]],
                 uint2 index [[thread_position_in_grid]]) {
    if (index.x >= p.outputFrames || index.y >= 2) return;
    int2 position = positions[index.x];
    int start = position.x - int(p.radius);
    uint base = uint(position.y) * p.taps;
    float result = 0;
    for (uint tap = 0; tap < p.taps; ++tap) {
        int frame = start + int(tap);
        if (frame >= 0 && frame < int(p.sourceFrames)) {
            result = fma(coefficients[base + tap],
                         source[index.y * p.sourceFrames + uint(frame)], result);
        }
    }
    output[index.y * p.outputFrames + index.x] = result;
}
