#pragma once
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>

namespace ongaku {
/// One control writer, one render reader. Commands take effect at the next
/// successful render block; each ramp then advances only with rendered frames.
class GainEnvelope {
    static_assert(std::atomic<uint64_t>::is_always_lock_free);
    static_assert(std::atomic<float>::is_always_lock_free);
    std::atomic<uint64_t> sequence{0}, requestedFrames{0}, completed{0};
    std::atomic<float> requestedTarget{0};
    uint64_t applied = 0, duration = 0, elapsed = 0; // render thread only
    float current = 0, origin = 0, target = 0;
    bool settled = true;
public:
    uint64_t ramp(float gain, uint64_t frames) noexcept {
        // Invalid requests fail closed and can never amplify the signal.
        gain = std::isfinite(gain) ? std::clamp(gain, 0.f, 1.f) : 0.f;
        sequence.fetch_add(1);
        requestedTarget.store(gain);
        requestedFrames.store(frames);
        return sequence.fetch_add(1) + 1;
    }
    bool isComplete(uint64_t token) const noexcept {
        return token != 0 && !(token & 1) && sequence.load() == token && completed.load() == token;
    }
    // Resource lifecycle only: caller must quiesce render and command writers.
    // Invalidate old tokens across reset/reallocation instead of reusing IDs.
    void resetMuted() noexcept {
        applied = ramp(0, 0);
        duration = elapsed = 0;
        current = origin = target = 0;
        settled = true;
        completed.store(applied);
    }
    void begin() noexcept {
        // Bounded reads, no locks/spinning/allocations on the audio thread.
        for (int attempt = 0; attempt < 2; ++attempt) {
            const auto before = sequence.load();
            if (before & 1) continue;
            const auto gain = requestedTarget.load();
            const auto frames = requestedFrames.load();
            if (sequence.load() != before) continue;
            if (before != applied) {
                applied = before;
                origin = current;
                target = gain;
                duration = frames;
                elapsed = 0;
                settled = false;
            }
            break;
        }
    }
    float next() noexcept {
        if (settled) return current;
        if (elapsed < duration) {
            ++elapsed;
            const double p = double(elapsed) / double(duration);
            const double blend = (1.0 - std::cos(3.14159265358979323846 * p)) * 0.5;
            current = float(origin + (target - origin) * blend);
        } else {
            current = target;
        }
        if (elapsed == duration) {
            current = target; // Exact endpoint, including exact silence.
            settled = true;
            completed.store(applied);
        }
        return current;
    }
};
} // namespace ongaku
