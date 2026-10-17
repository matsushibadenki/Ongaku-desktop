#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <vector>

namespace ongaku {
// Final-rate, stereo-linked lookahead limiting. All storage/kernels are prepared
// outside the render callback. The independent qualification meter uses a different kernel length
// and denser phases than this detector.
class TruePeakLimiter {
public:
    static constexpr int radius = 64, phases = 8;
    bool prepare(unsigned channels, double rate) {
        if (!channels || channels > 8 || !std::isfinite(rate) || rate < 8000 || rate > 384000) return false;
        channels_ = channels;
        lookahead_ = std::max(32, int(std::ceil(rate * 0.004)));
        capacity_ = 1;
        while (capacity_ <= unsigned(lookahead_ + 2 * radius + 4)) capacity_ *= 2;
        try { samples_.assign(size_t(channels_) * capacity_, 0); plan_.assign(capacity_, 1); }
        catch (...) { return false; }
        release_ = 1 - std::exp(-1 / (0.060 * rate));
        for (int phase = 1; phase < phases; ++phase) {
            double sum = 0;
            for (int offset = -radius; offset <= radius; ++offset) {
                const double x = double(phase) / phases - offset;
                double value = 0;
                if (std::abs(x) < radius) {
                    const double sinc = std::abs(x) < 1e-12 ? 1 : std::sin(pi * x) / (pi * x);
                    value = sinc * (0.42 + 0.5 * std::cos(pi * x / radius) + 0.08 * std::cos(2 * pi * x / radius));
                }
                kernels_[phase - 1][offset + radius] = value; sum += value;
            }
            for (auto &value : kernels_[phase - 1]) value /= sum;
        }
        reset();
        return true;
    }
    void reset() noexcept {
        std::fill(samples_.begin(), samples_.end(), 0);
        std::fill(plan_.begin(), plan_.end(), 1);
        time_ = 0; gain_ = 1;
    }
    unsigned latencyFrames() const noexcept { return lookahead_ + radius; }
    void process(const float *const *input, float *const *output, unsigned frames) noexcept {
        for (unsigned frame = 0; frame < frames; ++frame, ++time_) {
            for (unsigned ch = 0; ch < channels_; ++ch) {
                const float value = input[ch][frame];
                samples_[size_t(ch) * capacity_ + slot(time_)] = std::isfinite(value) ? value : 0;
            }
            const int64_t center = time_ - radius;
            if (center >= 0) {
                double peak = 0;
                for (unsigned ch = 0; ch < channels_; ++ch) {
                    peak = std::max(peak, std::abs(double(sample(ch, center))));
                    for (const auto &kernel : kernels_) {
                        double value = 0;
                        for (int offset = -radius; offset <= radius; ++offset)
                            value += sample(ch, center + offset) * kernel[offset + radius];
                        peak = std::max(peak, std::abs(value));
                    }
                }
                // 0.5 dB reconstruction/envelope guard below the -1 dBTP target.
                const double required = peak > ceiling ? ceiling / peak : 1;
                if (required < 1) {
                    for (int ahead = 0; ahead <= lookahead_; ++ahead) {
                        const int64_t position = center - lookahead_ + ahead;
                        if (position < 0) continue;
                        const double ramp = 1 - (1 - required) * double(ahead + 1) / double(lookahead_ + 1);
                        plan_[slot(position)] = std::min(plan_[slot(position)], ramp);
                    }
                }
            }
            const int64_t position = time_ - latencyFrames();
            if (position < 0) {
                for (unsigned ch = 0; ch < channels_; ++ch) output[ch][frame] = 0;
            } else {
                gain_ = std::min(plan_[slot(position)], gain_ + (1 - gain_) * release_);
                for (unsigned ch = 0; ch < channels_; ++ch) output[ch][frame] = float(sample(ch, position) * gain_);
                plan_[slot(position)] = 1;
            }
        }
    }
private:
    static constexpr double pi = 3.14159265358979323846;
    static constexpr double ceiling = 0.8413951416451951; // -1.5 dBFS detector target
    unsigned channels_ = 0, capacity_ = 0;
    int lookahead_ = 0;
    int64_t time_ = 0;
    double gain_ = 1, release_ = 0;
    std::vector<float> samples_;
    std::vector<double> plan_;
    std::array<std::array<double, 2 * radius + 1>, phases - 1> kernels_{};
    unsigned slot(int64_t position) const noexcept { return unsigned(uint64_t(position) & (capacity_ - 1)); }
    float sample(unsigned channel, int64_t position) const noexcept {
        return position < 0 ? 0 : samples_[size_t(channel) * capacity_ + slot(position)];
    }
};
}
